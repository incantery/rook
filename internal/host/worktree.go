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
// own data dir (never inside the user's repos), branches under rook/<name>.
// rook never deletes work: removal refuses while the tree is dirty or the
// branch holds commits unreachable from every other ref, unless forced.
// The branch always survives removal — it may live on in a PR.

// worktreeDir is where a worktree workspace's checkout lives. Keeping them
// under DataDir means cleanup only ever deletes inside rook's own territory.
func worktreeDir(name string) string {
	return filepath.Join(DataDir(), "worktrees", name)
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
	// the rook/<name> branch, so they need no exclusion.
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
