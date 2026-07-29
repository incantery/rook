package host

import (
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
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

// maprangeFixtures is the table this implementation and app/src/anchor.zig
// BOTH answer to. It lives outside this package because it belongs to
// neither side — see the file's own header for the format and for why
// mirrored hand-written tests were not enough.
const maprangeFixtures = "../../app/src/testdata/anchor_maprange.txt"

func TestMapRange(t *testing.T) {
	raw, err := os.ReadFile(maprangeFixtures)
	if err != nil {
		t.Fatalf("shared fixtures: %v", err)
	}
	declared, seen := -1, 0
	for ln := range strings.SplitSeq(string(raw), "\n") {
		line := strings.TrimSpace(ln)
		if line == "" {
			continue
		}
		if strings.HasPrefix(line, "#") {
			if i := strings.Index(line, "cases:"); i >= 0 {
				if declared, err = strconv.Atoi(strings.TrimSpace(line[i+len("cases:"):])); err != nil {
					t.Fatalf("case count: %v", err)
				}
			}
			continue
		}
		f := strings.Split(line, "|")
		if len(f) != 4 {
			t.Fatalf("malformed row: %q", line)
		}
		name := strings.TrimSpace(f[0])
		var hunks []hunk
		for _, g := range strings.Fields(f[1]) {
			var h hunk
			if _, err := fmt.Sscanf(g, "%d,%d,%d,%d", &h.oldStart, &h.oldCount, &h.newStart, &h.newCount); err != nil {
				t.Fatalf("%s: hunk %q: %v", name, g, err)
			}
			hunks = append(hunks, h)
		}
		var start, end, wantStart, wantEnd int
		var outdated bool
		if _, err := fmt.Sscanf(strings.TrimSpace(f[2]), "%d %d", &start, &end); err != nil {
			t.Fatalf("%s: range: %v", name, err)
		}
		if _, err := fmt.Sscanf(strings.TrimSpace(f[3]), "%d %d %t", &wantStart, &wantEnd, &outdated); err != nil {
			t.Fatalf("%s: want: %v", name, err)
		}
		seen++
		if s, e, out := mapRange(hunks, start, end); s != wantStart || e != wantEnd || out != outdated {
			t.Errorf("%s: got %d-%d outdated=%v, want %d-%d outdated=%v",
				name, s, e, out, wantStart, wantEnd, outdated)
		}
	}
	// Vacuity guard: without it, a parser bug that skipped every row
	// reads as a passing test. Both sides check the file's own count.
	if declared < 0 {
		t.Fatal("fixtures declare no case count")
	}
	if seen != declared {
		t.Fatalf("read %d cases, file declares %d", seen, declared)
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
	h.anchorThreadNow(ws, repo, th)
	if th.CurrentStart != 3 || th.CurrentEnd != 4 || th.Outdated {
		t.Fatalf("same-sha: %+v", th)
	}

	// two lines inserted above → range rides down
	os.WriteFile(filepath.Join(repo, "f.txt"), []byte("a\nb\nl1\nl2\nl3\nl4\nl5\n"), 0o644)
	h.anchorThreadNow(ws, repo, th)
	if th.CurrentStart != 5 || th.CurrentEnd != 6 || th.Outdated {
		t.Fatalf("shift: %+v", th)
	}

	// anchored line edited → outdated, range stays at stored positions
	th.CurrentStart, th.CurrentEnd, th.Outdated = th.StartLine, th.EndLine, false
	os.WriteFile(filepath.Join(repo, "f.txt"), []byte("l1\nl2\nCHANGED\nl4\nl5\n"), 0o644)
	h.anchorThreadNow(ws, repo, th)
	if !th.Outdated || th.CurrentStart != 3 {
		t.Fatalf("overlap: %+v", th)
	}

	// file gone → outdated
	th.Outdated = false
	os.Remove(filepath.Join(repo, "f.txt"))
	h.anchorThreadNow(ws, repo, th)
	if !th.Outdated {
		t.Fatalf("deleted file: %+v", th)
	}

	// blob missing (pruned) → outdated, never an error
	th2 := &ThreadInfo{Workspace: "src", Path: "a.txt", StartLine: 1, EndLine: 1,
		BlobSHA: "nope", CurrentStart: 1, CurrentEnd: 1}
	h.anchorThreadNow(ws, repo, th2)
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
	h.anchorThreadNow(ws, repo, th3)
	if th3.Outdated || th3.CurrentStart != 1 || th3.CurrentEnd != 1 {
		t.Fatalf("original-side against diverged tree: %+v", th3)
	}
}
