package cmdjournal

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func openAt(t *testing.T, path string, now time.Time) *Log {
	t.Helper()
	l, err := Open(path, 7*24*time.Hour, now)
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	return l
}

// The bug this package exists for: an answer types into a pane, the
// process dies before the ack, the cloud redelivers. A second process
// must know the effect already happened.
func TestDeliverySurvivesARestart(t *testing.T) {
	path := filepath.Join(t.TempDir(), "d.jsonl")
	now := time.Date(2026, 8, 4, 12, 0, 0, 0, time.UTC)

	first := openAt(t, path, now)
	first.MarkDelivered("ask_1")
	if !first.Delivered("ask_1") {
		t.Fatal("delivery not visible to the writer")
	}

	// The crash: no close, no ack, a whole new process.
	second := openAt(t, path, now)
	if !second.Delivered("ask_1") {
		t.Error("a redelivered answer would type twice — the guarantee is gone")
	}
	if second.Delivered("ask_2") {
		t.Error("an untouched key came back delivered")
	}
}

// Attempts persist too, or a permanently undeliverable answer gets a
// fresh budget every relaunch and pends forever.
func TestAttemptsPersistAndBound(t *testing.T) {
	path := filepath.Join(t.TempDir(), "d.jsonl")
	now := time.Date(2026, 8, 4, 12, 0, 0, 0, time.UTC)

	l := openAt(t, path, now)
	for want := 1; want <= 3; want++ {
		if got := l.Failed("cmd:x"); got != want {
			t.Fatalf("Failed returned %d, want %d", got, want)
		}
	}

	again := openAt(t, path, now)
	if got := again.Failed("cmd:x"); got != 4 {
		t.Errorf("attempts after restart: %d, want 4 — the budget reset", got)
	}
	if again.Delivered("cmd:x") {
		t.Error("failing to land must not read as landed")
	}
}

// Both rails share one log; their keys must not collide or leak into
// each other.
func TestRailsShareTheLogWithoutColliding(t *testing.T) {
	path := filepath.Join(t.TempDir(), "d.jsonl")
	now := time.Date(2026, 8, 4, 12, 0, 0, 0, time.UTC)

	l := openAt(t, path, now)
	l.MarkDelivered("abc") // an ask id
	l.Failed("cmd:abc")    // a command that happens to share it
	if !l.Delivered("abc") {
		t.Error("the ask lost its record")
	}
	if l.Delivered("cmd:abc") {
		t.Error("the command inherited the ask's delivery")
	}
}

// Entries past the window leave on the next compaction; a zero
// timestamp is kept, because forgetting a delivery is the failure that
// matters and an unparseable date is not evidence it is safe to forget.
func TestWindowDropsOldButKeepsUndated(t *testing.T) {
	path := filepath.Join(t.TempDir(), "d.jsonl")
	now := time.Date(2026, 8, 4, 12, 0, 0, 0, time.UTC)

	old := Entry{Key: "stale", Delivered: true, At: now.Add(-30 * 24 * time.Hour)}
	fresh := Entry{Key: "recent", Delivered: true, At: now.Add(-time.Hour)}
	undated := Entry{Key: "undated", Delivered: true}
	writeLines(t, path, old, fresh, undated)

	l := openAt(t, path, now)
	if l.Delivered("stale") {
		t.Error("an entry past the window came back")
	}
	if !l.Delivered("recent") {
		t.Error("a fresh entry was dropped")
	}
	if !l.Delivered("undated") {
		t.Error("an undated entry was dropped — that risks a double effect")
	}
}

// A torn tail is what a reader sees while the writer is mid-append. It
// must cost that one line, never the file.
func TestTornTailIsSkipped(t *testing.T) {
	path := filepath.Join(t.TempDir(), "d.jsonl")
	now := time.Date(2026, 8, 4, 12, 0, 0, 0, time.UTC)

	writeLines(t, path, Entry{Key: "good", Delivered: true, At: now})
	f, err := os.OpenFile(path, os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		t.Fatal(err)
	}
	_, _ = f.WriteString(`{"key":"torn","deliv`)
	f.Close()

	l := openAt(t, path, now)
	if !l.Delivered("good") {
		t.Error("a torn tail took the whole file with it")
	}
	if l.Delivered("torn") {
		t.Error("half a line was believed")
	}
}

// No state home, or a directory that cannot be made: the bridge must
// still run, forgetting across restarts rather than refusing to start.
func TestUnwritableDegradesToMemory(t *testing.T) {
	l, err := Open("", time.Hour, time.Now())
	if err != nil {
		t.Fatalf("empty path should not error: %v", err)
	}
	l.MarkDelivered("k")
	if !l.Delivered("k") {
		t.Error("memory-only log does not remember within the process")
	}

	file := filepath.Join(t.TempDir(), "not-a-dir")
	if err := os.WriteFile(file, []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	blocked, err := Open(filepath.Join(file, "sub", "d.jsonl"), time.Hour, time.Now())
	if err == nil {
		t.Error("an unmakeable directory should be reported")
	}
	if blocked == nil {
		t.Fatal("a failed Open must still return a usable log")
	}
	blocked.MarkDelivered("k")
	if !blocked.Delivered("k") {
		t.Error("degraded log does not work in memory")
	}
}

// Compaction keeps the last state per key and survives a reopen.
func TestCompactionKeepsLastStatePerKey(t *testing.T) {
	path := filepath.Join(t.TempDir(), "d.jsonl")
	now := time.Date(2026, 8, 4, 12, 0, 0, 0, time.UTC)

	l := openAt(t, path, now)
	l.Failed("k")
	l.Failed("k")
	l.MarkDelivered("k")
	l.compact()

	after := openAt(t, path, now)
	if !after.Delivered("k") {
		t.Error("compaction lost the delivery")
	}
	if got := after.Failed("k"); got != 3 {
		t.Errorf("attempts after compaction: %d, want 3", got)
	}
}

func writeLines(t *testing.T, path string, entries ...Entry) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	f, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	for _, e := range entries {
		line, err := json.Marshal(e)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := f.Write(append(line, '\n')); err != nil {
			t.Fatal(err)
		}
	}
}
