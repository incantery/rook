// Package worktree is rook's worktree-per-agent model: one git worktree,
// one branch, one rook session, and a lifecycle that ends with the
// branch merged and all three gone. Git owns the worktrees (this is a
// thin layer over `git worktree`), rook owns the sessions; the package
// is what ties a checkout to the place you work in it.
//
// Layout: a worktree for repo R named N lives beside the repo at
// <parent-of-R>/R--N, so its rook session is named R--N — unambiguous
// across repos, and it shows up in zoxide like any other directory.
package worktree

import (
	"bufio"
	"bytes"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/incantery/rook/internal/tmux"
)

// Repo is the main checkout a set of worktrees hangs off.
type Repo struct {
	Root string // the main worktree's top level
	Name string // its directory name, the prefix of every worktree dir
}

// Worktree is one row of `rook worktree ls`.
type Worktree struct {
	Name    string `json:"name"` // short name: the dir minus the repo prefix; "" for main
	Path    string `json:"path"`
	Branch  string `json:"branch"` // "" when detached
	Head    string `json:"head"`   // short commit
	Main    bool   `json:"main"`   // the repo's own checkout
	Dirty   bool   `json:"dirty"`
	Ahead   int    `json:"ahead"`  // commits on Branch not on the main branch
	Behind  int    `json:"behind"` // commits on the main branch not on Branch
	Session string `json:"session"`
	Live    bool   `json:"live"` // the session exists on the rook server
}

// Options carry the per-repo conventions worktree creation follows —
// files the checkout needs but git doesn't track.
type Options struct {
	// Copy are repo-relative paths copied from the main checkout into a
	// new worktree (".env", "config/local.toml").
	Copy []string
	// Link are repo-relative paths symlinked to the main checkout's
	// copy: heavy caches no two worktrees need twice ("node_modules").
	Link []string
}

// Find resolves the repo containing dir. A worktree answers with its
// true home, so any checkout of the repo gets the same Repo.
func Find(dir string) (Repo, error) {
	out, err := git(dir, "rev-parse", "--git-common-dir")
	if err != nil {
		return Repo{}, fmt.Errorf("%s is not in a git repository", dir)
	}
	common := strings.TrimSpace(out)
	if !filepath.IsAbs(common) {
		common = filepath.Join(dir, common)
	}
	root := filepath.Dir(common)
	if filepath.Base(common) != ".git" {
		// bare repo: the common dir IS the repo
		root = common
	}
	root, err = filepath.Abs(root)
	if err != nil {
		return Repo{}, err
	}
	// git reports real paths (/private/var, not /var on macOS); match it
	// so worktree paths compare equal to ours.
	if real, err := filepath.EvalSymlinks(root); err == nil {
		root = real
	}
	return Repo{Root: root, Name: filepath.Base(root)}, nil
}

// Path is where a worktree named name lives for this repo.
func (r Repo) Path(name string) string {
	return filepath.Join(filepath.Dir(r.Root), r.Name+"--"+name)
}

// nameOf is Path's inverse: the short name of a worktree at path, or ""
// when the path doesn't follow the convention (the main checkout, or a
// worktree someone made by hand).
func (r Repo) nameOf(path string) string {
	base := filepath.Base(path)
	if rest, ok := strings.CutPrefix(base, r.Name+"--"); ok && filepath.Dir(path) == filepath.Dir(r.Root) {
		return rest
	}
	return ""
}

// DefaultBranch is the branch worktrees branch from and merge into:
// what origin/HEAD points at, else main, else master, else whatever the
// main checkout has out.
func (r Repo) DefaultBranch() string {
	if out, err := git(r.Root, "symbolic-ref", "--short", "refs/remotes/origin/HEAD"); err == nil {
		return strings.TrimPrefix(strings.TrimSpace(out), "origin/")
	}
	for _, b := range []string{"main", "master"} {
		if _, err := git(r.Root, "rev-parse", "--verify", "--quiet", "refs/heads/"+b); err == nil {
			return b
		}
	}
	out, _ := git(r.Root, "branch", "--show-current")
	return strings.TrimSpace(out)
}

// List enumerates the repo's worktrees, main first, with live status:
// dirtiness, distance from the default branch, and whether a rook
// session is open on it.
func (r Repo) List() ([]Worktree, error) {
	out, err := git(r.Root, "worktree", "list", "--porcelain")
	if err != nil {
		return nil, fmt.Errorf("git worktree list: %s", strings.TrimSpace(out))
	}
	base := r.DefaultBranch()
	var wts []Worktree
	var cur *Worktree
	flush := func() {
		if cur != nil {
			wts = append(wts, *cur)
			cur = nil
		}
	}
	sc := bufio.NewScanner(strings.NewReader(out))
	for sc.Scan() {
		line := sc.Text()
		switch {
		case strings.HasPrefix(line, "worktree "):
			flush()
			p := strings.TrimPrefix(line, "worktree ")
			cur = &Worktree{Path: p, Name: r.nameOf(p), Session: tmux.SessionName(p)}
		case cur == nil:
		case strings.HasPrefix(line, "HEAD "):
			cur.Head = shortHash(strings.TrimPrefix(line, "HEAD "))
		case strings.HasPrefix(line, "branch "):
			cur.Branch = strings.TrimPrefix(strings.TrimPrefix(line, "branch "), "refs/heads/")
		case line == "bare":
			cur.Main = true
		}
	}
	flush()
	live := liveSessions()
	for i := range wts {
		wt := &wts[i]
		if wt.Path == r.Root {
			wt.Main = true
		}
		wt.Live = live[wt.Session]
		if st, err := git(wt.Path, "status", "--porcelain"); err == nil {
			wt.Dirty = strings.TrimSpace(st) != ""
		}
		if wt.Branch != "" && wt.Branch != base && base != "" {
			wt.Ahead, wt.Behind = distance(wt.Path, base, wt.Branch)
		}
	}
	return wts, nil
}

// Get finds the worktree named name, by short name or by branch.
func (r Repo) Get(name string) (Worktree, error) {
	wts, err := r.List()
	if err != nil {
		return Worktree{}, err
	}
	for _, wt := range wts {
		if !wt.Main && (wt.Name == name || wt.Branch == name || filepath.Base(wt.Path) == name) {
			return wt, nil
		}
	}
	return Worktree{}, fmt.Errorf("no worktree %q (rook worktree ls)", name)
}

// MainWorktree is the repo's own checkout as a row.
func (r Repo) MainWorktree() (Worktree, error) {
	wts, err := r.List()
	if err != nil {
		return Worktree{}, err
	}
	for _, wt := range wts {
		if wt.Main {
			return wt, nil
		}
	}
	return Worktree{}, fmt.Errorf("no main checkout found for %s", r.Name)
}

// New creates a worktree named name on a branch of the same name — the
// existing branch if there is one, a fresh one off `from` (the default
// branch when empty) otherwise — applies the copy/link conventions, and
// returns it. It does not open a session; Open does.
func (r Repo) New(name, from string, opts Options) (Worktree, error) {
	if name == "" || strings.ContainsAny(name, " /\\:") {
		return Worktree{}, fmt.Errorf("worktree name %q: one word, no slashes", name)
	}
	path := r.Path(name)
	if _, err := os.Stat(path); err == nil {
		return Worktree{}, fmt.Errorf("%s already exists", path)
	}
	args := []string{"worktree", "add"}
	if _, err := git(r.Root, "rev-parse", "--verify", "--quiet", "refs/heads/"+name); err == nil {
		args = append(args, path, name)
	} else {
		if from == "" {
			from = r.DefaultBranch()
		}
		args = append(args, "-b", name, path, from)
	}
	if out, err := git(r.Root, args...); err != nil {
		return Worktree{}, fmt.Errorf("git worktree add: %s", strings.TrimSpace(out))
	}
	for _, rel := range opts.Copy {
		if err := copyPath(filepath.Join(r.Root, rel), filepath.Join(path, rel)); err != nil {
			fmt.Fprintf(os.Stderr, "rook: copy %s: %v\n", rel, err)
		}
	}
	for _, rel := range opts.Link {
		src := filepath.Join(r.Root, rel)
		if _, err := os.Stat(src); err != nil {
			continue // nothing to link to yet; not an error
		}
		dst := filepath.Join(path, rel)
		os.MkdirAll(filepath.Dir(dst), 0o755)
		os.RemoveAll(dst)
		if err := os.Symlink(src, dst); err != nil {
			fmt.Fprintf(os.Stderr, "rook: link %s: %v\n", rel, err)
		}
	}
	return r.Get(name)
}

// Open makes sure a rook session exists on the worktree and, when the
// caller is inside rook, switches to it. Outside tmux it just creates
// the session: the caller prints the path and the user attaches.
func Open(wt Worktree) error {
	if !tmux.HasSession(wt.Session) {
		if out, err := tmux.Run("new-session", "-d", "-s", wt.Session, "-c", wt.Path); err != nil {
			return fmt.Errorf("creating session %s: %v\n%s", wt.Session, err, out)
		}
	}
	if tmux.InsideRook() {
		if out, err := tmux.Run("switch-client", "-t", "="+wt.Session); err != nil {
			return fmt.Errorf("switching to %s: %v\n%s", wt.Session, err, out)
		}
	}
	return nil
}

// Merge lands the worktree's branch on the default branch in the main
// checkout, then removes the worktree, its session, and the branch —
// the whole lifecycle in one step. It refuses when either checkout is
// dirty or when the merge doesn't apply cleanly (the main checkout is
// left with the merge aborted, nothing half-done).
func (r Repo) Merge(name string) error {
	wt, err := r.Get(name)
	if err != nil {
		return err
	}
	if wt.Branch == "" {
		return fmt.Errorf("%s is detached; nothing to merge", wt.Name)
	}
	if wt.Dirty {
		return fmt.Errorf("%s has uncommitted changes; commit or stash them first", wt.Name)
	}
	base := r.DefaultBranch()
	if cur, _ := git(r.Root, "branch", "--show-current"); strings.TrimSpace(cur) != base {
		return fmt.Errorf("main checkout is on %q, not %s; check out %s first", strings.TrimSpace(cur), base, base)
	}
	if st, _ := git(r.Root, "status", "--porcelain"); strings.TrimSpace(st) != "" {
		return fmt.Errorf("main checkout has uncommitted changes; merge needs it clean")
	}
	if out, err := git(r.Root, "merge", "--no-edit", wt.Branch); err != nil {
		git(r.Root, "merge", "--abort")
		return fmt.Errorf("merge %s: %s", wt.Branch, strings.TrimSpace(out))
	}
	return r.Remove(wt, true)
}

// Remove deletes a worktree, kills its session, and deletes its branch.
// Without force it refuses dirty checkouts and unmerged branches.
func (r Repo) Remove(wt Worktree, force bool) error {
	if wt.Main {
		return fmt.Errorf("refusing to remove the main checkout")
	}
	// Every refusal happens before anything is touched: a worktree that
	// is half-removed (tree gone, branch kept, session dead) is worse
	// than one that is still there.
	if wt.Dirty && !force {
		return fmt.Errorf("%s has uncommitted changes (--force to discard)", wt.Name)
	}
	if wt.Branch != "" && !force {
		if _, err := git(r.Root, "merge-base", "--is-ancestor", wt.Branch, r.DefaultBranch()); err != nil {
			return fmt.Errorf("%s has commits not on %s (merge it, or --force to drop them)", wt.Branch, r.DefaultBranch())
		}
	}
	if tmux.HasSession(wt.Session) {
		if out, err := tmux.Run("kill-session", "-t", "="+wt.Session); err != nil {
			return fmt.Errorf("killing session %s: %s", wt.Session, strings.TrimSpace(out))
		}
	}
	args := []string{"worktree", "remove"}
	if force {
		args = append(args, "--force")
	}
	if out, err := git(r.Root, append(args, wt.Path)...); err != nil {
		return fmt.Errorf("git worktree remove: %s", strings.TrimSpace(out))
	}
	if wt.Branch != "" {
		flag := "-d"
		if force {
			flag = "-D"
		}
		if out, err := git(r.Root, "branch", flag, wt.Branch); err != nil {
			return fmt.Errorf("worktree removed, but branch %s kept: %s", wt.Branch, strings.TrimSpace(out))
		}
	}
	return nil
}

// distance counts commits on each side of the fork between base and
// branch, as seen from dir.
func distance(dir, base, branch string) (ahead, behind int) {
	out, err := git(dir, "rev-list", "--left-right", "--count", branch+"..."+base)
	if err != nil {
		return 0, 0
	}
	f := strings.Fields(out)
	if len(f) == 2 {
		ahead, _ = strconv.Atoi(f[0])
		behind, _ = strconv.Atoi(f[1])
	}
	return ahead, behind
}

func liveSessions() map[string]bool {
	out, err := tmux.Run("list-sessions", "-F", "#{session_name}")
	live := map[string]bool{}
	if err != nil {
		return live
	}
	for _, s := range strings.Fields(out) {
		live[s] = true
	}
	return live
}

func shortHash(h string) string {
	if len(h) > 7 {
		return h[:7]
	}
	return h
}

// git runs git in dir and returns its combined output; callers that
// only want the answer TrimSpace it.
func git(dir string, args ...string) (string, error) {
	cmd := exec.Command("git", args...)
	cmd.Dir = dir
	var buf bytes.Buffer
	cmd.Stdout, cmd.Stderr = &buf, &buf
	err := cmd.Run()
	return buf.String(), err
}

// copyPath copies a file or directory tree.
func copyPath(src, dst string) error {
	info, err := os.Lstat(src)
	if err != nil {
		return err
	}
	switch {
	case info.Mode()&os.ModeSymlink != 0:
		target, err := os.Readlink(src)
		if err != nil {
			return err
		}
		return os.Symlink(target, dst)
	case info.IsDir():
		if err := os.MkdirAll(dst, info.Mode().Perm()); err != nil {
			return err
		}
		entries, err := os.ReadDir(src)
		if err != nil {
			return err
		}
		for _, e := range entries {
			if err := copyPath(filepath.Join(src, e.Name()), filepath.Join(dst, e.Name())); err != nil {
				return err
			}
		}
		return nil
	default:
		data, err := os.ReadFile(src)
		if err != nil {
			return err
		}
		if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
			return err
		}
		return os.WriteFile(dst, data, info.Mode().Perm())
	}
}
