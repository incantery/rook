package sessions

import (
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

func TestParseSurvivesLineForms(t *testing.T) {
	home, _ := os.UserHomeDir()
	cases := []struct {
		line string
		kind Kind
		val  string
	}{
		{"\x1b[33m●\x1b[0m rook", KindSession, "rook"},
		{"● tmux", KindSession, "tmux"},
		{"\x1b[90m○\x1b[0m ~/dev/rook", KindDir, "~/dev/rook"},
		{"~/dev/rook", KindDir, "~/dev/rook"},
		{"/tmp/x", KindDir, "/tmp/x"},
		{"bare-name", KindSession, "bare-name"},
		// rows carry annotations in the picker; Parse must shed them
		{"● tmux  ✳ working", KindSession, "tmux"},
		{"● tmux  ⎇ rook", KindSession, "tmux"},
		{"● tmux  ⎇ rook  ● waiting", KindSession, "tmux"},
		{"\x1b[33m●\x1b[0m rk  \x1b[33m\x1b[1m● waiting\x1b[0m", KindSession, "rk"},
		{"● dev  · done", KindSession, "dev"},
	}
	for _, c := range cases {
		got := Parse(c.line)
		if got.Kind != c.kind || got.Value != c.val {
			t.Errorf("Parse(%q) = %v %q, want %v %q", c.line, got.Kind, got.Value, c.kind, c.val)
		}
	}
	if expand("~/x") != home+"/x" {
		t.Errorf("expand(~/x) = %q", expand("~/x"))
	}
}

func TestRowLineRoundTrips(t *testing.T) {
	for _, r := range []Row{{KindSession, "rook"}, {KindDir, "~/dev/rook"}} {
		if got := Parse(r.Line()); got != r {
			t.Errorf("Parse(Line(%v)) = %v", r, got)
		}
	}
}

func TestGitInfoNamesWorktreesByTheirHome(t *testing.T) {
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git not on PATH")
	}
	root := t.TempDir()
	repo := filepath.Join(root, "myrepo")
	run := func(args ...string) {
		t.Helper()
		cmd := exec.Command("git", args...)
		cmd.Env = append(os.Environ(),
			"GIT_AUTHOR_NAME=t", "GIT_AUTHOR_EMAIL=t@t", "GIT_COMMITTER_NAME=t", "GIT_COMMITTER_EMAIL=t@t")
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v\n%s", args, err, out)
		}
	}
	run("init", "-q", "-b", "main", repo)
	run("-C", repo, "commit", "-q", "--allow-empty", "-m", "x")
	wt := filepath.Join(root, "wt-feature")
	run("-C", repo, "worktree", "add", "-q", "-b", "feature/one", wt)

	if r, b := gitInfo(repo); r != "myrepo" || b != "main" {
		t.Errorf("repo checkout: got %q/%q", r, b)
	}
	if r, b := gitInfo(wt); r != "myrepo" || b != "feature/one" {
		t.Errorf("worktree must answer with its true home: got %q/%q", r, b)
	}
	if r, _ := gitInfo(root); r != "" {
		t.Errorf("non-repo dir must be silent, got %q", r)
	}
	if r, _ := gitInfo(""); r != "" {
		t.Errorf("empty dir must be silent, got %q", r)
	}
}

func TestMergeDedupesDirsBehindSessions(t *testing.T) {
	home, _ := os.UserHomeDir()
	rows := Merge(
		[]string{"rook", "tmux"},
		[]string{home + "/dev/rook", home + "/other/project"},
	)
	// dev/rook would recreate session "rook": only the session row and
	// the novel dir must survive.
	if len(rows) != 3 {
		t.Fatalf("got %d rows: %v", len(rows), rows)
	}
	if rows[2].Kind != KindDir || rows[2].Value != "~/other/project" {
		t.Errorf("dir row = %v, want contracted ~/other/project", rows[2])
	}
}
