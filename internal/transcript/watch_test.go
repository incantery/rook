package transcript

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// startWatcher runs a Watcher over root with a fast fallback sweep, so the
// tests do not depend on fsnotify delivering anything. It returns the line
// channel; the watcher stops when the test ends.
func startWatcher(t *testing.T, root string, maxAge time.Duration) <-chan Line {
	t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)

	out := make(chan Line, 64)
	w := &Watcher{Root: root, MaxAge: maxAge, Poll: 10 * time.Millisecond}
	go func() {
		if err := w.Run(ctx, out); err != nil && ctx.Err() == nil {
			t.Errorf("Run: %v", err)
		}
	}()
	return out
}

func want(t *testing.T, out <-chan Line, uuid string) Line {
	t.Helper()
	deadline := time.After(3 * time.Second)
	for {
		select {
		case ln := <-out:
			if ln.Record.UUID == uuid {
				return ln
			}
		case <-deadline:
			t.Fatalf("timed out waiting for record %q", uuid)
		}
	}
}

func silent(t *testing.T, out <-chan Line, d time.Duration) {
	t.Helper()
	select {
	case ln := <-out:
		t.Fatalf("unexpected line: session=%q uuid=%q", ln.SessionID, ln.Record.UUID)
	case <-time.After(d):
	}
}

func writeSession(t *testing.T, dir, name, content string) string {
	t.Helper()
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, name)
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestWatcherFindsSessionsAndTagsThem(t *testing.T) {
	root := t.TempDir()
	proj := filepath.Join(root, "-Users-seth-go-src-rook")
	writeSession(t, proj, "sess-1.jsonl", lineA+"\n")

	out := startWatcher(t, root, time.Hour)
	ln := want(t, out, "a")
	if ln.SessionID != "sess-1" {
		t.Errorf("SessionID = %q, want sess-1", ln.SessionID)
	}
}

func TestWatcherStreamsAppends(t *testing.T) {
	root := t.TempDir()
	proj := filepath.Join(root, "proj")
	path := writeSession(t, proj, "s.jsonl", lineA+"\n")

	out := startWatcher(t, root, time.Hour)
	want(t, out, "a")

	f, err := os.OpenFile(path, os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		t.Fatal(err)
	}
	f.WriteString(lineB + "\n")
	f.Close()

	want(t, out, "b")
}

func TestWatcherPicksUpNewProjectAndSession(t *testing.T) {
	root := t.TempDir()
	out := startWatcher(t, root, time.Hour)

	// a project directory that did not exist when the watcher started
	writeSession(t, filepath.Join(root, "brand-new-proj"), "s9.jsonl", lineB+"\n")
	if ln := want(t, out, "b"); ln.SessionID != "s9" {
		t.Errorf("SessionID = %q, want s9", ln.SessionID)
	}
}

// Subagent transcripts are 91% of the files in a real tree and rook drops
// their traffic anyway, so they must never be globbed.
func TestWatcherIgnoresSubagentTranscripts(t *testing.T) {
	root := t.TempDir()
	proj := filepath.Join(root, "proj")
	writeSession(t, filepath.Join(proj, "sess-1", "subagents"), "agent-deadbeef.jsonl", lineA+"\n")
	writeSession(t, filepath.Join(proj, "sess-1"), "journal.jsonl", lineA+"\n")

	out := startWatcher(t, root, time.Hour)
	silent(t, out, 150*time.Millisecond)

	// ...but the session file beside them is followed
	writeSession(t, proj, "sess-1.jsonl", lineB+"\n")
	want(t, out, "b")
}

func TestWatcherIgnoresStaleSessions(t *testing.T) {
	root := t.TempDir()
	proj := filepath.Join(root, "proj")
	old := writeSession(t, proj, "ancient.jsonl", lineA+"\n")
	stale := time.Now().Add(-24 * time.Hour)
	if err := os.Chtimes(old, stale, stale); err != nil {
		t.Fatal(err)
	}

	out := startWatcher(t, root, time.Hour)
	silent(t, out, 150*time.Millisecond)
}

// A session that goes quiet past MaxAge and later resumes must come back:
// the sweep re-checks mtime, it does not remember a verdict.
func TestWatcherReTailsRevivedSession(t *testing.T) {
	root := t.TempDir()
	proj := filepath.Join(root, "proj")
	path := writeSession(t, proj, "revived.jsonl", lineA+"\n")
	stale := time.Now().Add(-24 * time.Hour)
	if err := os.Chtimes(path, stale, stale); err != nil {
		t.Fatal(err)
	}

	out := startWatcher(t, root, time.Hour)
	silent(t, out, 100*time.Millisecond)

	f, err := os.OpenFile(path, os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		t.Fatal(err)
	}
	f.WriteString(lineB + "\n")
	f.Close()

	// Re-tailed from zero, so the history arrives too — the point is that
	// the session is visible again at all.
	want(t, out, "b")
}

func TestWatcherMissingRootIsNotFatal(t *testing.T) {
	// The tree does not exist until claude runs once. That is a wait, not
	// an error.
	root := filepath.Join(t.TempDir(), "not-yet")
	out := startWatcher(t, root, time.Hour)
	silent(t, out, 100*time.Millisecond)

	writeSession(t, filepath.Join(root, "proj"), "s.jsonl", lineA+"\n")
	want(t, out, "a")
}

func TestWatcherStopsOnContextCancel(t *testing.T) {
	root := t.TempDir()
	writeSession(t, filepath.Join(root, "proj"), "s.jsonl", lineA+"\n")

	ctx, cancel := context.WithCancel(context.Background())
	out := make(chan Line, 8)
	done := make(chan error, 1)
	w := &Watcher{Root: root, Poll: 10 * time.Millisecond}
	go func() { done <- w.Run(ctx, out) }()

	cancel()
	select {
	case err := <-done:
		if err != context.Canceled {
			t.Errorf("Run returned %v, want context.Canceled", err)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("Run did not return after cancel")
	}
}
