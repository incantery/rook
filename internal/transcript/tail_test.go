package transcript

import (
	"os"
	"path/filepath"
	"testing"
)

// tailFile creates a transcript file and returns its path plus an appender.
func tailFile(t *testing.T, name string) (string, func(string)) {
	t.Helper()
	path := filepath.Join(t.TempDir(), name)
	if err := os.WriteFile(path, nil, 0o644); err != nil {
		t.Fatal(err)
	}
	return path, func(s string) {
		t.Helper()
		f, err := os.OpenFile(path, os.O_APPEND|os.O_WRONLY, 0o644)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := f.WriteString(s); err != nil {
			t.Fatal(err)
		}
		f.Close()
	}
}

func read(t *testing.T, tl *Tail) []Line {
	t.Helper()
	lines, err := tl.Read()
	if err != nil {
		t.Fatalf("Read: %v", err)
	}
	return lines
}

const lineA = `{"type":"user","uuid":"a","message":{"role":"user","content":"hello"}}`
const lineB = `{"type":"assistant","uuid":"b","message":{"role":"assistant","content":[{"type":"text","text":"hi"}]}}`

func TestTailSessionIDFromFilename(t *testing.T) {
	// An assistant record carries no sessionId; the file is authoritative.
	path, _ := tailFile(t, "3da3683e-cf53-421a-b6ad-af3b76945bcd.jsonl")
	tl := NewTail(path)
	if got := tl.SessionID(); got != "3da3683e-cf53-421a-b6ad-af3b76945bcd" {
		t.Errorf("SessionID = %q", got)
	}
}

func TestTailReadsAppendedLines(t *testing.T) {
	path, add := tailFile(t, "s1.jsonl")
	tl := NewTail(path)

	if got := read(t, tl); got != nil {
		t.Fatalf("empty file returned %d lines", len(got))
	}

	add(lineA + "\n")
	lines := read(t, tl)
	if len(lines) != 1 || lines[0].Record.UUID != "a" {
		t.Fatalf("got %+v, want one record uuid=a", lines)
	}
	if lines[0].SessionID != "s1" {
		t.Errorf("SessionID = %q", lines[0].SessionID)
	}

	// nothing new
	if got := read(t, tl); got != nil {
		t.Fatalf("re-read returned %d lines, want 0", len(got))
	}

	add(lineB + "\n")
	lines = read(t, tl)
	if len(lines) != 1 || lines[0].Record.UUID != "b" {
		t.Fatalf("got %+v, want one record uuid=b", lines)
	}
}

// The half-written line at the end of a live transcript must not be parsed
// as if it were whole.
func TestTailWithholdsPartialLine(t *testing.T) {
	path, add := tailFile(t, "s1.jsonl")
	tl := NewTail(path)

	add(lineA + "\n")
	add(lineB[:40]) // torn mid-write, no newline

	lines := read(t, tl)
	if len(lines) != 1 || lines[0].Record.UUID != "a" {
		t.Fatalf("got %d lines, want only the complete one", len(lines))
	}
	if tl.Malformed != 0 {
		t.Errorf("Malformed = %d — a partial line is not malformed, it is unfinished", tl.Malformed)
	}

	// the rest of the line lands
	add(lineB[40:] + "\n")
	lines = read(t, tl)
	if len(lines) != 1 || lines[0].Record.UUID != "b" {
		t.Fatalf("got %+v, want the now-complete record b", lines)
	}
	if tl.Malformed != 0 {
		t.Errorf("Malformed = %d, want 0", tl.Malformed)
	}
}

func TestTailOffsetsPointAtLineStarts(t *testing.T) {
	path, add := tailFile(t, "s1.jsonl")
	tl := NewTail(path)
	add(lineA + "\n" + lineB + "\n")

	lines := read(t, tl)
	if len(lines) != 2 {
		t.Fatalf("got %d lines, want 2", len(lines))
	}
	if lines[0].Offset != 0 {
		t.Errorf("first offset = %d, want 0", lines[0].Offset)
	}
	if want := int64(len(lineA) + 1); lines[1].Offset != want {
		t.Errorf("second offset = %d, want %d", lines[1].Offset, want)
	}
	if want := int64(len(lineA) + len(lineB) + 2); tl.Offset() != want {
		t.Errorf("Offset() = %d, want %d", tl.Offset(), want)
	}

	// An offset must be seekable back to its own line.
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	rec, err := Parse(data[lines[1].Offset : lines[1].Offset+int64(len(lineB))])
	if err != nil {
		t.Fatalf("re-parse at offset: %v", err)
	}
	if rec.UUID != "b" {
		t.Errorf("re-parsed uuid = %q, want b", rec.UUID)
	}
}

func TestTailMalformedLineDoesNotStallStream(t *testing.T) {
	path, add := tailFile(t, "s1.jsonl")
	tl := NewTail(path)
	add("{ this is not json\n" + lineA + "\n")

	lines := read(t, tl)
	if len(lines) != 1 || lines[0].Record.UUID != "a" {
		t.Fatalf("got %+v, want the good record to survive its bad neighbour", lines)
	}
	if tl.Malformed != 1 {
		t.Errorf("Malformed = %d, want 1", tl.Malformed)
	}
}

func TestTailBlankLinesIgnored(t *testing.T) {
	path, add := tailFile(t, "s1.jsonl")
	tl := NewTail(path)
	add("\n\n" + lineA + "\n\n")

	if lines := read(t, tl); len(lines) != 1 {
		t.Fatalf("got %d lines, want 1", len(lines))
	}
	if tl.Malformed != 0 {
		t.Errorf("Malformed = %d — a blank line is not malformed", tl.Malformed)
	}
}

// Backlog must be distinguishable from appends: replaying a discovered
// file's history would otherwise look like every historical turn just
// ended.
func TestTailMarksBacklogNotLive(t *testing.T) {
	path, add := tailFile(t, "s1.jsonl")
	add(lineA + "\n")
	tl := NewTail(path)

	lines := read(t, tl)
	if len(lines) != 1 {
		t.Fatalf("got %d lines", len(lines))
	}
	if lines[0].Live {
		t.Error("a line already in the file when we first looked is backlog, not live")
	}

	add(lineB + "\n")
	lines = read(t, tl)
	if len(lines) != 1 {
		t.Fatalf("got %d lines", len(lines))
	}
	if !lines[0].Live {
		t.Error("an append after catching up must be Live")
	}
}

func TestTailEmptyFileCatchesUpImmediately(t *testing.T) {
	// A session file created and then written to: there is no backlog, so
	// the first record is a live append.
	path, add := tailFile(t, "s1.jsonl")
	tl := NewTail(path)
	read(t, tl) // reaches EOF on an empty file

	add(lineA + "\n")
	lines := read(t, tl)
	if len(lines) != 1 || !lines[0].Live {
		t.Fatalf("got %+v, want one Live line", lines)
	}
}

func TestTailSeekEndIsCaughtUp(t *testing.T) {
	path, add := tailFile(t, "s1.jsonl")
	add(lineA + "\n")
	tl := NewTail(path)
	if err := tl.SeekEnd(); err != nil {
		t.Fatal(err)
	}
	add(lineB + "\n")
	lines := read(t, tl)
	if len(lines) != 1 || !lines[0].Live {
		t.Fatalf("got %+v, want one Live line — SeekEnd leaves no backlog", lines)
	}
}

// A replaced file is backlog again, not a burst of new events.
func TestTailTruncateRereadIsNotLive(t *testing.T) {
	path, add := tailFile(t, "s1.jsonl")
	tl := NewTail(path)
	add(lineA + "\n")
	read(t, tl)
	add(lineB + "\n")
	if lines := read(t, tl); !lines[0].Live {
		t.Fatal("setup: appends should be live")
	}

	if err := os.WriteFile(path, []byte(lineA+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	lines := read(t, tl)
	if len(lines) != 1 {
		t.Fatalf("got %d lines", len(lines))
	}
	if lines[0].Live {
		t.Error("re-read after truncation is backlog, not new events")
	}
}

func TestTailSeekEndSkipsHistory(t *testing.T) {
	path, add := tailFile(t, "s1.jsonl")
	add(lineA + "\n")

	tl := NewTail(path)
	if err := tl.SeekEnd(); err != nil {
		t.Fatal(err)
	}
	if got := read(t, tl); got != nil {
		t.Fatalf("SeekEnd still returned %d historical lines", len(got))
	}

	add(lineB + "\n")
	if lines := read(t, tl); len(lines) != 1 || lines[0].Record.UUID != "b" {
		t.Fatalf("got %+v, want only the line written after SeekEnd", lines)
	}
}

// A shrinking file is a replaced file, not an appended one.
func TestTailResetsOnTruncate(t *testing.T) {
	path, add := tailFile(t, "s1.jsonl")
	tl := NewTail(path)
	add(lineA + "\n" + lineB + "\n")
	if len(read(t, tl)) != 2 {
		t.Fatal("setup")
	}

	if err := os.WriteFile(path, []byte(lineA+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	lines := read(t, tl)
	if len(lines) != 1 || lines[0].Record.UUID != "a" {
		t.Fatalf("got %+v, want a re-read from zero after truncation", lines)
	}
}

func TestTailMissingFile(t *testing.T) {
	tl := NewTail(filepath.Join(t.TempDir(), "gone.jsonl"))
	if _, err := tl.Read(); err == nil {
		t.Error("Read on a missing file should error")
	}
}
