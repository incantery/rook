package digestlog

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func openT(t *testing.T, path string, now time.Time) *Log {
	t.Helper()
	l, err := Open(path, 48*time.Hour, now)
	if err != nil {
		t.Fatal(err)
	}
	return l
}

// The journal's whole contract in one walk: snapshots append, the last
// line per id wins, a tombstone drops the id, the window drops the
// stale, and the result comes back newest first.
func TestReplayKeepsLastPerIDAndDropsTombstonesAndStale(t *testing.T) {
	now := time.Date(2026, 8, 4, 12, 0, 0, 0, time.UTC)
	path := filepath.Join(t.TempDir(), "digests.jsonl")
	l := openT(t, path, now)

	l.Append(Digest{ID: "a:1", SessionID: "a", Headline: "first cut", At: now.Add(-2 * time.Hour)})
	l.Append(Digest{ID: "a:1", SessionID: "a", Headline: "first cut", Reply: "drafted", At: now.Add(-2 * time.Hour)})
	l.Append(Digest{ID: "b:1", SessionID: "b", Headline: "gone soon", At: now.Add(-1 * time.Hour)})
	// A tombstone carries the dismissal time — with a zero At the window
	// filter would hide a broken Dismissed check (a vacuity this test
	// once had).
	l.Append(Digest{ID: "b:1", Dismissed: true, At: now})
	l.Append(Digest{ID: "c:1", SessionID: "c", Headline: "ancient", At: now.Add(-72 * time.Hour)})
	l.Append(Digest{ID: "d:1", SessionID: "d", Headline: "newest", At: now.Add(-1 * time.Minute)})

	ds := Load(path, 48*time.Hour, now)
	if len(ds) != 2 {
		t.Fatalf("want 2 live digests, got %d: %+v", len(ds), ds)
	}
	if ds[0].ID != "d:1" || ds[1].ID != "a:1" {
		t.Errorf("not newest-first: %s then %s", ds[0].ID, ds[1].ID)
	}
	if ds[1].Reply != "drafted" {
		t.Errorf("last line per id did not win — the draft is lost: %+v", ds[1])
	}
}

// A corrupt line — a torn tail mid-append, a stray editor save — is
// skipped, and every intact line still loads.
func TestCorruptLinesAreSkippedNotFatal(t *testing.T) {
	now := time.Now()
	path := filepath.Join(t.TempDir(), "digests.jsonl")
	l := openT(t, path, now)
	l.Append(Digest{ID: "a:1", SessionID: "a", Headline: "kept", At: now})

	f, _ := os.OpenFile(path, os.O_WRONLY|os.O_APPEND, 0o600)
	f.WriteString(`{"id":"b:1","headline":"torn`)
	f.Close()

	ds := Load(path, 48*time.Hour, now)
	if len(ds) != 1 || ds[0].ID != "a:1" {
		t.Fatalf("intact line lost to the torn one: %+v", ds)
	}
}

// Open compacts a grown file down to the live window's survivors — and
// the survivors keep their newest state, tombstones and history gone.
func TestOpenCompactsAGrownFile(t *testing.T) {
	now := time.Now()
	path := filepath.Join(t.TempDir(), "digests.jsonl")
	l := openT(t, path, now)
	pad := strings.Repeat("x", 64*1024)
	for range 200 {
		l.Append(Digest{ID: "old", SessionID: "s", Headline: "rewritten", FullText: pad, At: now.Add(-49 * time.Hour)})
	}
	l.Append(Digest{ID: "live", SessionID: "s", Headline: "survivor", FullText: pad, At: now})

	before, _ := os.Stat(path)
	if before.Size() <= maxBytes {
		t.Fatalf("fixture too small to trigger compaction: %d", before.Size())
	}
	openT(t, path, now)
	after, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if after.Size() >= before.Size()/2 {
		t.Errorf("compaction did not shrink the file: %d -> %d", before.Size(), after.Size())
	}
	ds := Load(path, 48*time.Hour, now)
	if len(ds) != 1 || ds[0].ID != "live" || ds[0].Headline != "survivor" {
		t.Fatalf("survivors mangled by compaction: %+v", ds)
	}
}

// Latest is the export view: newest presentable digest per session,
// where errored and headline-less digests do not present.
func TestLatestSkipsErrsAndKeepsNewestPerSession(t *testing.T) {
	now := time.Now()
	ds := []Digest{
		{ID: "s:3", SessionID: "s", Headline: "", Err: "HTTP 500", At: now},
		{ID: "s:2", SessionID: "s", Headline: "newer", At: now.Add(-1 * time.Minute)},
		{ID: "s:1", SessionID: "s", Headline: "older", At: now.Add(-1 * time.Hour)},
		{ID: "t:1", SessionID: "t", Headline: "other", At: now.Add(-2 * time.Hour)},
	}
	m := Latest(ds)
	if m["s"].Headline != "newer" {
		t.Errorf("want the newest presentable digest for s, got %q", m["s"].Headline)
	}
	if m["t"].Headline != "other" {
		t.Errorf("session t lost: %+v", m)
	}
}
