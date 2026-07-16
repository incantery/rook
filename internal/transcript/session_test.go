package transcript

import (
	"fmt"
	"path/filepath"
	"strings"
	"testing"
)

func TestFindSession(t *testing.T) {
	root := t.TempDir()
	writeSession(t, filepath.Join(root, "-Users-seth-rook"), "sess-abc.jsonl", lineA+"\n")
	writeSession(t, filepath.Join(root, "-Users-seth-other"), "sess-xyz.jsonl", lineA+"\n")
	// a subagent transcript with a colliding stem, deeper in the tree
	writeSession(t, filepath.Join(root, "-Users-seth-rook", "sess-abc", "subagents"), "sess-zzz.jsonl", lineA+"\n")

	got, err := FindSession(root, "sess-xyz")
	if err != nil {
		t.Fatalf("FindSession: %v", err)
	}
	if want := filepath.Join(root, "-Users-seth-other", "sess-xyz.jsonl"); got != want {
		t.Errorf("got %q, want %q", got, want)
	}

	if _, err := FindSession(root, "sess-zzz"); err == nil {
		t.Error("a subagent transcript must not resolve as a session")
	}
	if _, err := FindSession(root, "nope"); err == nil {
		t.Error("unknown session should error")
	}
}

// Session ids are uuids; anything with a separator is a caller trying to
// walk out of the tree.
func TestFindSessionRejectsTraversal(t *testing.T) {
	root := t.TempDir()
	writeSession(t, filepath.Join(root, "proj"), "s.jsonl", lineA+"\n")

	for _, bad := range []string{"../../etc/passwd", "..", "a/b", `a\b`, "s.jsonl", ""} {
		if _, err := FindSession(root, bad); err == nil {
			t.Errorf("FindSession(%q) resolved; it must not", bad)
		}
	}
}

func TestReadSessionWindow(t *testing.T) {
	dir := t.TempDir()
	var b strings.Builder
	for i := range 10 {
		fmt.Fprintf(&b, `{"type":"user","uuid":"u%d","message":{"role":"user","content":"m%d"}}`+"\n", i, i)
	}
	path := filepath.Join(dir, "s.jsonl")
	writeSession(t, dir, "s.jsonl", b.String())

	// default window: the tail of the file, in file order
	lines, more, err := ReadSession(path, 4, 0)
	if err != nil {
		t.Fatal(err)
	}
	if len(lines) != 4 {
		t.Fatalf("got %d lines, want 4", len(lines))
	}
	if lines[0].Record.UUID != "u6" || lines[3].Record.UUID != "u9" {
		t.Errorf("window = %s..%s, want u6..u9 (newest, in file order)", lines[0].Record.UUID, lines[3].Record.UUID)
	}
	if !more {
		t.Error("more = false, but six older records exist")
	}

	// page backward from the window's first offset
	older, more, err := ReadSession(path, 4, lines[0].Offset)
	if err != nil {
		t.Fatal(err)
	}
	if len(older) != 4 || older[0].Record.UUID != "u2" || older[3].Record.UUID != "u5" {
		t.Fatalf("older window = %+v, want u2..u5", older)
	}
	if !more {
		t.Error("more = false, but u0/u1 still exist")
	}

	// the last page reports no more
	oldest, more, err := ReadSession(path, 4, older[0].Offset)
	if err != nil {
		t.Fatal(err)
	}
	if len(oldest) != 2 || oldest[0].Record.UUID != "u0" {
		t.Fatalf("oldest window = %+v, want u0..u1", oldest)
	}
	if more {
		t.Error("more = true at the start of the file")
	}
}

func TestReadSessionShorterThanWindow(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "s.jsonl")
	writeSession(t, dir, "s.jsonl", lineA+"\n"+lineB+"\n")

	lines, more, err := ReadSession(path, 50, 0)
	if err != nil {
		t.Fatal(err)
	}
	if len(lines) != 2 {
		t.Fatalf("got %d lines, want 2", len(lines))
	}
	if more {
		t.Error("more = true on a file smaller than the window")
	}
}
