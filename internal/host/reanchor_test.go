package host

import (
	"os"
	"path/filepath"
	"testing"
)

func TestGitBlobSHA(t *testing.T) {
	// git's own canonical examples: `echo hello | git hash-object --stdin`
	if got := gitBlobSHA([]byte("hello\n")); got != "ce013625030ba8dba906f756967f9e9ca394464a" {
		t.Fatalf("hello blob: %s", got)
	}
	if got := gitBlobSHA(nil); got != "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391" {
		t.Fatalf("empty blob: %s", got)
	}
}

func TestParseHunks(t *testing.T) {
	diff := []byte(`diff --git a/a b/b
index ce01362..0f2416e 100644
--- a/a
+++ b/b
@@ -2,0 +3,2 @@
+x
+y
@@ -10,3 +12 @@
-a
-b
-c
+z
`)
	hunks := parseHunks(diff)
	want := []hunk{{2, 0, 3, 2}, {10, 3, 12, 1}}
	if len(hunks) != 2 || hunks[0] != want[0] || hunks[1] != want[1] {
		t.Fatalf("hunks: %+v", hunks)
	}
}

func TestMapRange(t *testing.T) {
	cases := []struct {
		name       string
		hunks      []hunk
		start, end int
		wantStart  int
		wantEnd    int
		outdated   bool
	}{
		{"no hunks", nil, 5, 7, 5, 7, false},
		{"insertion above shifts down", []hunk{{2, 0, 3, 2}}, 5, 7, 7, 9, false},
		{"deletion above shifts up", []hunk{{1, 3, 1, 0}}, 10, 12, 7, 9, false},
		{"replacement above shifts by delta", []hunk{{1, 2, 1, 5}}, 10, 12, 13, 15, false},
		{"change below is invisible", []hunk{{20, 2, 20, 4}}, 5, 7, 5, 7, false},
		{"edit inside range outdates", []hunk{{6, 1, 6, 1}}, 5, 7, 5, 7, true},
		{"edit overlapping start outdates", []hunk{{3, 4, 3, 1}}, 5, 7, 5, 7, true},
		{"insertion strictly inside outdates", []hunk{{5, 0, 6, 2}}, 5, 7, 5, 7, true},
		{"insertion at range start shifts", []hunk{{4, 0, 5, 2}}, 5, 7, 7, 9, false},
		{"insertion at range end is below", []hunk{{7, 0, 8, 2}}, 5, 7, 5, 7, false},
		{"whole range deleted outdates", []hunk{{4, 6, 4, 0}}, 5, 7, 5, 7, true},
	}
	for _, c := range cases {
		s, e, out := mapRange(c.hunks, c.start, c.end)
		if s != c.wantStart || e != c.wantEnd || out != c.outdated {
			t.Errorf("%s: got %d-%d outdated=%v, want %d-%d outdated=%v",
				c.name, s, e, out, c.wantStart, c.wantEnd, c.outdated)
		}
	}
}

func TestAnchorNow(t *testing.T) {
	h, _, repo := newWorktreeHost(t)
	ws := h.reg.get("src")
	// anchored content: 5 lines
	orig := []byte("l1\nl2\nl3\nl4\nl5\n")
	os.WriteFile(filepath.Join(repo, "f.txt"), orig, 0o644)
	sha := gitBlobSHA(orig)
	h.reg.putAnchorBlob(sha, orig)
	// Side is left unset — empty side must behave as "modified".
	th := &ThreadInfo{Workspace: "src", Path: "f.txt", StartLine: 3, EndLine: 4,
		BlobSHA: sha, CurrentStart: 3, CurrentEnd: 4}

	// same content → fast path, no change
	h.anchorNow(ws, repo, th)
	if th.CurrentStart != 3 || th.CurrentEnd != 4 || th.Outdated {
		t.Fatalf("same-sha: %+v", th)
	}

	// two lines inserted above → range rides down
	os.WriteFile(filepath.Join(repo, "f.txt"), []byte("a\nb\nl1\nl2\nl3\nl4\nl5\n"), 0o644)
	h.anchorNow(ws, repo, th)
	if th.CurrentStart != 5 || th.CurrentEnd != 6 || th.Outdated {
		t.Fatalf("shift: %+v", th)
	}

	// anchored line edited → outdated, range stays at stored positions
	th.CurrentStart, th.CurrentEnd, th.Outdated = th.StartLine, th.EndLine, false
	os.WriteFile(filepath.Join(repo, "f.txt"), []byte("l1\nl2\nCHANGED\nl4\nl5\n"), 0o644)
	h.anchorNow(ws, repo, th)
	if !th.Outdated || th.CurrentStart != 3 {
		t.Fatalf("overlap: %+v", th)
	}

	// file gone → outdated
	th.Outdated = false
	os.Remove(filepath.Join(repo, "f.txt"))
	h.anchorNow(ws, repo, th)
	if !th.Outdated {
		t.Fatalf("deleted file: %+v", th)
	}

	// blob missing (pruned) → outdated, never an error
	th2 := &ThreadInfo{Workspace: "src", Path: "a.txt", StartLine: 1, EndLine: 1,
		BlobSHA: "nope", CurrentStart: 1, CurrentEnd: 1}
	h.anchorNow(ws, repo, th2)
	if !th2.Outdated {
		t.Fatalf("missing blob: %+v", th2)
	}

	// original-side thread anchored to committed content: the regression
	// this fix prevents. a.txt is committed (HEAD) as "hello\n"; even
	// though the working tree copy has since diverged, re-anchoring an
	// original-side thread must compare against the BASE, not the tree —
	// so it stays NOT outdated with the stored range.
	helloSHA := gitBlobSHA([]byte("hello\n"))
	h.reg.putAnchorBlob(helloSHA, []byte("hello\n"))
	os.WriteFile(filepath.Join(repo, "a.txt"), []byte("edited\n"), 0o644)
	th3 := &ThreadInfo{Workspace: "src", Path: "a.txt", StartLine: 1, EndLine: 1,
		Side: "original", BlobSHA: helloSHA, CurrentStart: 1, CurrentEnd: 1}
	h.anchorNow(ws, repo, th3)
	if th3.Outdated || th3.CurrentStart != 1 || th3.CurrentEnd != 1 {
		t.Fatalf("original-side against diverged tree: %+v", th3)
	}
}
