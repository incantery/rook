package main

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/incantery/rook/plugins/internal/digestlog"
	"github.com/incantery/rook/plugins/internal/transcript"
)

// The digest source reads the journal fresh per call: the newest
// presentable digest per session, full text included, and honest
// misses for sessions the membrane has not summarized.
func TestDigestSourceReadsTheJournal(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "digests.jsonl")
	log, err := digestlog.Open(path, 48*time.Hour, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	older := digestlog.Digest{
		ID: "d1", SessionID: "sess-1", Headline: "first pass",
		FullText: "the first full reply", At: time.Now().Add(-time.Hour),
	}
	newest := digestlog.Digest{
		ID: "d2", SessionID: "sess-1", Headline: "second pass",
		Bullets:  []string{"a", "b"},
		FullText: "the second full reply, every word",
		Prompt:   "go again",
		Reply:    "drafted", ReplyState: "ready",
		At: time.Now(),
	}
	for _, d := range []digestlog.Digest{older, newest} {
		if err := log.Append(d); err != nil {
			t.Fatal(err)
		}
	}

	h := &lk{digestLog: path, sc: &transcript.Scanner{Window: 48 * time.Hour}}

	got, ok := h.Digest("sess-1")
	if !ok {
		t.Fatal("journal has sess-1; source says no")
	}
	if got.Headline != "second pass" || got.FullText != "the second full reply, every word" ||
		got.Prompt != "go again" || got.Reply != "drafted" || got.ReplyState != "ready" ||
		len(got.Bullets) != 2 {
		t.Fatalf("wrong digest came back: %+v", got)
	}

	if _, ok := h.Digest("sess-unknown"); ok {
		t.Fatal("an unsummarized session must be a miss, not an empty digest")
	}

	// No journal configured — every lookup is a miss, never a crash.
	none := &lk{sc: &transcript.Scanner{Window: 48 * time.Hour}}
	if _, ok := none.Digest("sess-1"); ok {
		t.Fatal("no journal path must mean no digests")
	}

	_ = os.Remove(path)
	if _, ok := h.Digest("sess-1"); ok {
		t.Fatal("a deleted journal must read as empty, not stale")
	}
}
