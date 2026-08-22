package worktree

import (
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

func gitRun(t *testing.T, dir string, args ...string) string {
	t.Helper()
	cmd := exec.Command("git", args...)
	cmd.Dir = dir
	cmd.Env = append(os.Environ(),
		"GIT_AUTHOR_NAME=t", "GIT_AUTHOR_EMAIL=t@t", "GIT_COMMITTER_NAME=t", "GIT_COMMITTER_EMAIL=t@t")
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("git %v: %v\n%s", args, err, out)
	}
	return string(out)
}

func newRepo(t *testing.T) Repo {
	t.Helper()
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git not on PATH")
	}
	root := filepath.Join(t.TempDir(), "myrepo")
	gitRun(t, ".", "init", "-q", "-b", "main", root)
	os.WriteFile(filepath.Join(root, "a.txt"), []byte("a\n"), 0o644)
	os.WriteFile(filepath.Join(root, ".env"), []byte("SECRET=1\n"), 0o644)
	os.WriteFile(filepath.Join(root, ".gitignore"), []byte(".env\nnode_modules\n"), 0o644)
	os.MkdirAll(filepath.Join(root, "node_modules", "x"), 0o755)
	gitRun(t, root, "add", "a.txt", ".gitignore")
	gitRun(t, root, "commit", "-q", "-m", "init")
	repo, err := Find(root)
	if err != nil {
		t.Fatal(err)
	}
	if repo.Name != "myrepo" {
		t.Fatalf("repo name %q", repo.Name)
	}
	return repo
}

func TestLifecycle(t *testing.T) {
	// Keep this test off the user's rook server.
	t.Setenv("ROOK_SOCKET", "rook-worktree-test")
	t.Setenv("XDG_STATE_HOME", t.TempDir())
	repo := newRepo(t)

	wt, err := repo.New("feature", "", Options{Copy: []string{".env"}, Link: []string{"node_modules"}})
	if err != nil {
		t.Fatal(err)
	}
	if wt.Path != repo.Path("feature") || wt.Branch != "feature" || wt.Name != "feature" {
		t.Fatalf("new worktree = %+v", wt)
	}
	if wt.Session != "myrepo--feature" {
		t.Errorf("session %q", wt.Session)
	}
	if b, _ := os.ReadFile(filepath.Join(wt.Path, ".env")); string(b) != "SECRET=1\n" {
		t.Errorf(".env not copied: %q", b)
	}
	if target, err := os.Readlink(filepath.Join(wt.Path, "node_modules")); err != nil || target != filepath.Join(repo.Root, "node_modules") {
		t.Errorf("node_modules not linked: %q %v", target, err)
	}

	// Found from inside the worktree too: it answers with its home.
	if r2, err := Find(wt.Path); err != nil || r2.Root != repo.Root {
		t.Errorf("Find from worktree = %+v %v", r2, err)
	}

	wts, err := repo.List()
	if err != nil {
		t.Fatal(err)
	}
	if len(wts) != 2 || !wts[0].Main || wts[1].Name != "feature" {
		t.Fatalf("list = %+v", wts)
	}

	// Work on it: dirty, then committed and ahead.
	os.WriteFile(filepath.Join(wt.Path, "b.txt"), []byte("b\n"), 0o644)
	if got, _ := repo.Get("feature"); !got.Dirty {
		t.Error("untracked file must read as dirty")
	}
	if err := repo.Merge("feature"); err == nil {
		t.Error("merge must refuse a dirty worktree")
	}
	gitRun(t, wt.Path, "add", "b.txt")
	gitRun(t, wt.Path, "commit", "-q", "-m", "b")
	got, _ := repo.Get("feature")
	if got.Dirty || got.Ahead != 1 || got.Behind != 0 {
		t.Errorf("after commit: %+v", got)
	}

	// rm without force refuses the unmerged branch and keeps the tree.
	if err := repo.Remove(got, false); err == nil {
		t.Error("rm must refuse an unmerged branch")
	}
	if _, err := os.Stat(filepath.Join(wt.Path, "b.txt")); err != nil {
		t.Fatal("a refused rm must not touch the worktree")
	}

	if err := repo.Merge("feature"); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(wt.Path); !os.IsNotExist(err) {
		t.Error("worktree dir must be gone after merge")
	}
	if _, err := os.Stat(filepath.Join(repo.Root, "b.txt")); err != nil {
		t.Error("merge must land b.txt on main")
	}
	if out := gitRun(t, repo.Root, "branch", "--list", "feature"); out != "" {
		t.Errorf("branch must be deleted, got %q", out)
	}
	if wts, _ := repo.List(); len(wts) != 1 {
		t.Errorf("list after merge = %+v", wts)
	}
}

func TestNewRejectsBadNames(t *testing.T) {
	repo := newRepo(t)
	for _, bad := range []string{"", "a b", "a/b"} {
		if _, err := repo.New(bad, "", Options{}); err == nil {
			t.Errorf("New(%q) must fail", bad)
		}
	}
}
