package main

import (
	"path/filepath"
	"testing"
	"time"
)

// A digest — and the draft the human paid for on top of it — survives
// a relaunch, and a dismissal is just as durable: the journal replays
// into the next run's ring.
func TestDigestsAndDismissalsSurviveARelaunch(t *testing.T) {
	now := time.Now()
	path := filepath.Join(t.TempDir(), "digests.jsonl")

	st := newStore(100, path, 48*time.Hour, now)
	st.add(Digest{ID: "s:aa", SessionID: "s", Headline: "shipped the thing", At: now})
	st.add(Digest{ID: "t:bb", SessionID: "t", Headline: "asked a question", At: now})
	if !st.update("s:aa", func(d *Digest) { d.Reply = "looks good"; d.ReplyState = "ready" }) {
		t.Fatal("update lost its digest")
	}

	st2 := newStore(100, path, 48*time.Hour, now)
	ds := st2.list()
	if len(ds) != 2 {
		t.Fatalf("want 2 restored digests, got %d", len(ds))
	}
	var s Digest
	for _, d := range ds {
		if d.ID == "s:aa" {
			s = d
		}
	}
	if s.Reply != "looks good" || s.ReplyState != "ready" {
		t.Errorf("the draft did not survive the relaunch: %+v", s)
	}

	if !st2.dismiss("t:bb") {
		t.Fatal("dismiss lost its digest")
	}
	st3 := newStore(100, path, 48*time.Hour, now)
	if st3.has("t:bb") {
		t.Error("a dismissed digest rose from the journal")
	}
	if !st3.has("s:aa") {
		t.Error("the living digest was lost with the dismissed one")
	}
}

// spent is the double-billing guard across relaunches: a turn whose
// digest came back from the journal is already paid for, even though
// this run's done map has never seen it.
func TestRestoredDigestsAreAlreadySpent(t *testing.T) {
	now := time.Now()
	path := filepath.Join(t.TempDir(), "digests.jsonl")
	st := newStore(100, path, 48*time.Hour, now)
	h := shortHash("the reply text")
	st.add(Digest{ID: "s:" + h, SessionID: "s", Headline: "done", At: now})

	st2 := newStore(100, path, 48*time.Hour, now)
	done := map[string]string{}
	if !spent(done, st2, "s", h) {
		t.Error("a journaled digest must count as spent after relaunch")
	}
	if spent(done, st2, "s", shortHash("a different reply")) {
		t.Error("a new reply must not count as spent")
	}
	if spent(done, st2, "u", h) {
		t.Error("another session must not count as spent")
	}
}

// An empty --log means the old behavior exactly: in-memory only, no
// file anywhere.
func TestEmptyLogPathDisablesPersistence(t *testing.T) {
	st := newStore(100, "", 48*time.Hour, time.Now())
	st.add(Digest{ID: "x:1", SessionID: "x", Headline: "ephemeral", At: time.Now()})
	if st.log != nil {
		t.Fatal("no path must mean no journal")
	}
}
