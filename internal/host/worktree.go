package host

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// Worktree workspaces: a workspace whose root is a `git worktree add` off a
// source workspace's repo — one branch per task, so parallel agent sessions
// stop stomping each other in a shared checkout. Trees live under rook's
// own data dir (never inside the user's repos), branches under
// <prefix><name> (rook/ unless branch-prefix-<workspace> says otherwise;
// an issue's key and title join with branch-delimiter-<workspace>).
// rook never deletes work: removal refuses while the tree is dirty or the
// branch holds commits unreachable from every other ref, unless forced.
// The branch always survives removal — it may live on in a PR.

// worktreeDir is where a worktree workspace's checkout lives. Keeping them
// under DataDir means cleanup only ever deletes inside rook's own territory.
func worktreeDir(name string) string {
	return filepath.Join(DataDir(), "worktrees", name)
}

// issueSlugs splits the issue that spawned a worktree into the two halves
// its names are built from — the key slug and the slugified title, "#9" +
// "Top bar alignment" → "9" + "top-bar-alignment" — so that the name means
// something in the workspace list, `git branch`, and the eventual PR. The
// halves stay apart because the two names join them differently: a workspace
// name is a directory, so it always joins with "-", while a branch joins with
// the workspace's configured delimiter. Both empty (no issue, or nothing
// slug-safe in it) sends the caller to the <source>-t<n> fallback.
func issueSlugs(issue *spawnIssue) (key, title string) {
	if issue == nil {
		return "", ""
	}
	// titles run long; cut at a word boundary so the tail stays readable
	return slugify(issue.Key), truncateSlug(slugify(strings.ToLower(issue.Title)), 32)
}

// joinSlugs joins an issue's halves with sep, tolerating either being empty
// so a key-only issue never trails a dangling separator.
func joinSlugs(key, title, sep string) string {
	if key == "" || title == "" {
		return key + title
	}
	return key + sep + title
}

// slugify keeps s safe as both a directory name and a git branch segment:
// alphanumeric runs survive (case intact — jira keys read PROJ-42), and
// everything between them collapses to single hyphens.
func slugify(s string) string {
	var b strings.Builder
	pending := false
	for _, r := range s {
		alnum := r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r >= '0' && r <= '9'
		if !alnum {
			pending = b.Len() > 0
			continue
		}
		if pending {
			b.WriteByte('-')
			pending = false
		}
		b.WriteRune(r)
	}
	return b.String()
}

// truncateSlug caps a slug at max bytes, backing up to the previous hyphen
// so no word is cut mid-way.
func truncateSlug(s string, max int) string {
	if len(s) <= max {
		return s
	}
	s = s[:max]
	if i := strings.LastIndexByte(s, '-'); i > 0 {
		s = s[:i]
	}
	return s
}

// runGit runs git in dir with a hard timeout, returning trimmed combined
// output — worktree ops happen inside request handlers and must not hang.
func runGit(dir string, timeout time.Duration, args ...string) (string, error) {
	git, err := exec.LookPath("git")
	if err != nil {
		git = "/usr/bin/git"
	}
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	out, err := exec.CommandContext(ctx, git, append([]string{"-C", dir}, args...)...).CombinedOutput()
	text := strings.TrimSpace(string(out))
	if err != nil {
		if text != "" {
			return text, fmt.Errorf("git %s: %s", args[0], text)
		}
		return text, fmt.Errorf("git %s: %w", args[0], err)
	}
	return text, nil
}

// branchExists reports whether repoRoot already has the local branch —
// deleted worktrees leave their branch behind (deliberately), and a new
// worktree must not silently adopt or collide with one.
func branchExists(repoRoot, branch string) bool {
	_, err := runGit(repoRoot, 10*time.Second, "rev-parse", "--verify", "--quiet", "refs/heads/"+branch)
	return err == nil
}

func worktreeAdd(repoRoot, dir, branch string) error {
	if err := os.MkdirAll(filepath.Dir(dir), 0o700); err != nil {
		return err
	}
	_, err := runGit(repoRoot, 30*time.Second, "worktree", "add", "-b", branch, dir)
	return err
}

// worktreeRisk reports what removing the worktree would lose: dirty files
// (tracked changes + untracked, git status lines) and commits on its branch
// that no other local or remote ref can reach. An error means the answer is
// unknown — callers must treat unknown as risky, never as clean.
func worktreeRisk(dir, branch string) (dirty, unmerged int, err error) {
	status, err := runGit(dir, 10*time.Second, "status", "--porcelain")
	if err != nil {
		return 0, 0, err
	}
	if status != "" {
		dirty = strings.Count(status, "\n") + 1
	}
	// --exclude only scopes the next --branches; remote refs never contain
	// the worktree's branch, so they need no exclusion.
	count, err := runGit(dir, 10*time.Second,
		"rev-list", "--count", branch, "--not", "--exclude="+branch, "--branches", "--remotes")
	if err != nil {
		return dirty, 0, err
	}
	unmerged, err = strconv.Atoi(count)
	return dirty, unmerged, err
}

// worktreeRepo resolves the main repository a worktree belongs to, from the
// worktree itself — the source workspace record may be long gone. Callers
// that need the repo after removal must resolve it BEFORE removing.
func worktreeRepo(dir string) (string, error) {
	common, err := runGit(dir, 10*time.Second, "rev-parse", "--path-format=absolute", "--git-common-dir")
	if err != nil {
		return "", err
	}
	return filepath.Dir(common), nil
}

// worktreeRemove detaches and deletes the checkout (branch stays).
func worktreeRemove(dir string, force bool) error {
	repo, err := worktreeRepo(dir)
	if err != nil {
		return err
	}
	args := []string{"worktree", "remove"}
	if force {
		args = append(args, "--force")
	}
	_, err = runGit(repo, 30*time.Second, append(args, dir)...)
	return err
}

// branchDelete prunes the local branch — the close-the-loop cleanup once
// its PR merged. -D, not -d: a squash merge leaves the branch "unmerged"
// in git's eyes, and the caller carries the merged fact.
func branchDelete(repoRoot, branch string) error {
	_, err := runGit(repoRoot, 10*time.Second, "branch", "-D", branch)
	return err
}
