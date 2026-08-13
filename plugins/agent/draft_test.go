package main

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// chanWriter hands each frame the conn writes to a channel, so a test
// can play rook's half of the wire.
type chanWriter struct{ ch chan string }

func (w chanWriter) Write(p []byte) (int, error) {
	w.ch <- string(p)
	return len(p), nil
}

func draftedDigest() Digest {
	return Digest{
		ID: "s1:aa", SessionTitle: "release", Headline: "It shipped.",
		Prompt: "ship it", FullText: "A long reply about shipping with a question: tag now or wait?",
		At: t0,
	}
}

func waitState(t *testing.T, st *store, id, want string) Digest {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		var got Digest
		if st.update(id, func(d *Digest) { got = *d }) && got.ReplyState == want {
			return got
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("digest never reached state %q", want)
	return Digest{}
}

func TestDraftLifecycleFromActionToReadyRows(t *testing.T) {
	var sentUser string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var body struct {
			Messages []chatMsg `json:"messages"`
		}
		raw, _ := io.ReadAll(r.Body)
		json.Unmarshal(raw, &body)
		sentUser = body.Messages[1].Content
		io.WriteString(w, completion("Tag now; the branch is green and waiting buys nothing.", 200, 40))
	}))
	defer srv.Close()
	z := &Summarizer{Client: srv.Client(), Base: srv.URL, Key: "k", Model: "gpt-5-mini"}
	st := &store{keep: 10}
	st.add(draftedDigest())

	rep := act(nil, st, z, nil, 1, json.RawMessage(`{"itemId":"s1:aa","actionId":"draft"}`))
	if !rep.OK {
		t.Fatalf("draft refused: %+v", rep)
	}
	d := waitState(t, st, "s1:aa", "ready")
	if d.Reply == "" || d.CostUSD == 0 {
		t.Fatalf("ready without a reply or a bill: %+v", d)
	}
	// The draft worked from the FULL turn, not the digest.
	if !strings.Contains(sentUser, "tag now or wait?") {
		t.Fatalf("draft did not see the full reply: %q", sentUser)
	}
	its := items(st, t0)
	it := its[0]
	if it.State != "ready" || it.Actions[0].ID != "copy" {
		t.Fatalf("ready row: %+v", it)
	}
	var titles []string
	for _, c := range it.Children {
		titles = append(titles, c.Title)
	}
	joined := strings.Join(titles, "|")
	if !strings.Contains(joined, "↩ suggested reply:") || !strings.Contains(joined, "Tag now;") {
		t.Fatalf("reply rows: %v", titles)
	}
}

func TestDraftFailureIsAChipAndAReasonNotADeadRow(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(429)
		io.WriteString(w, `{"error":{"message":"rate limit exceeded"}}`)
	}))
	defer srv.Close()
	z := &Summarizer{Client: srv.Client(), Base: srv.URL, Key: "k", Model: "gpt-5-mini"}
	st := &store{keep: 10}
	st.add(draftedDigest())
	_ = act(nil, st, z, nil, 1, json.RawMessage(`{"itemId":"s1:aa","actionId":"draft"}`))
	waitState(t, st, "s1:aa", "draft failed")
	it := items(st, t0)[0]
	if it.State != "draft failed" {
		t.Fatalf("chip: %+v", it)
	}
	// The headline and the retry path both survive a failed draft.
	if it.Title != "It shipped." || it.Actions[0].ID != "draft" {
		t.Fatalf("failed-draft row: %+v", it)
	}
	var joined string
	for _, c := range it.Children {
		joined += c.Title + "|"
	}
	if !strings.Contains(joined, "rate limit") {
		t.Fatalf("the reason must be readable: %v", joined)
	}
}

func TestCopyAsksRookAndBelievesTheAnswer(t *testing.T) {
	frames := make(chan string, 4)
	c := &conn{out: chanWriter{frames}}
	st := &store{keep: 10}
	d := draftedDigest()
	d.Reply = "Tag now."
	d.ReplyState = "ready"
	st.add(d)

	rep := act(c, st, nil, nil, 1, json.RawMessage(`{"itemId":"s1:aa","actionId":"copy"}`))
	if !rep.OK {
		t.Fatalf("copy refused: %+v", rep)
	}
	frame := <-frames
	if !strings.Contains(frame, `"op":"clipboard.set"`) || !strings.Contains(frame, "Tag now.") {
		t.Fatalf("frame: %s", frame)
	}
	var req struct {
		ID uint64 `json:"id"`
	}
	if json.Unmarshal([]byte(frame), &req) != nil {
		t.Fatal("frame did not parse")
	}
	c.deliver(req.ID, true, "", nil)
	waitState(t, st, "s1:aa", "copied")

	// And the refusal path: rook says no, the chip says so too.
	_ = act(c, st, nil, nil, 2, json.RawMessage(`{"itemId":"s1:aa","actionId":"copy"}`))
	frame = <-frames
	json.Unmarshal([]byte(frame), &req)
	c.deliver(req.ID, false, "not granted: clipboard.set", nil)
	got := waitState(t, st, "s1:aa", "clip refused")
	if !strings.Contains(got.ReplyErr, "not granted") {
		t.Fatalf("refusal reason: %+v", got)
	}
}

func TestCopyWithNothingDraftedRefuses(t *testing.T) {
	st := &store{keep: 10}
	st.add(draftedDigest())
	rep := act(nil, st, nil, nil, 1, json.RawMessage(`{"itemId":"s1:aa","actionId":"copy"}`))
	if rep.OK {
		t.Fatal("copied a reply that does not exist")
	}
}

func TestActOnAReplyChunkActsOnItsDigest(t *testing.T) {
	st := &store{keep: 10}
	d := draftedDigest()
	d.Reply = "Tag now."
	st.add(d)
	rep := act(nil, st, nil, nil, 1, json.RawMessage(`{"itemId":"s1:aa:r0","actionId":"dismiss"}`))
	if !rep.OK || len(st.list()) != 0 {
		t.Fatalf("dismiss via reply chunk: %+v, left %d", rep, len(st.list()))
	}
}

func TestChunkTextLosesNoWords(t *testing.T) {
	long := strings.Repeat("some words of a drafted reply ", 30)
	chunks := chunkText(long, 240)
	if len(chunks) < 2 {
		t.Fatalf("expected several chunks, got %d", len(chunks))
	}
	for _, c := range chunks {
		if len(c) > 240 {
			t.Fatalf("chunk over cap: %d bytes", len(c))
		}
	}
	if strings.Join(chunks, " ") != strings.Join(strings.Fields(long), " ") {
		t.Fatal("rejoined chunks must equal the original text")
	}
	hard := chunkText(strings.Repeat("x", 500), 240)
	if len(hard) != 3 {
		t.Fatalf("unbreakable run: %d chunks", len(hard))
	}
}

func TestExpandCarriesTheRoughReplyIntoThePrompt(t *testing.T) {
	var sentUser string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var body struct {
			Messages []chatMsg `json:"messages"`
		}
		raw, _ := io.ReadAll(r.Body)
		json.Unmarshal(raw, &body)
		sentUser = body.Messages[1].Content
		io.WriteString(w, completion("Sounds good — tag now, and keep the regression test in.", 200, 40))
	}))
	defer srv.Close()
	z := &Summarizer{Client: srv.Client(), Base: srv.URL, Key: "k", Model: "gpt-5-mini"}
	st := &store{keep: 10}
	st.add(draftedDigest())

	rep := act(nil, st, z, nil, 1, json.RawMessage(`{"itemId":"s1:aa","actionId":"expand","input":"yeah sounds good but keep the test"}`))
	if !rep.OK {
		t.Fatalf("expand refused: %+v", rep)
	}
	d := waitState(t, st, "s1:aa", "ready")
	if d.Reply == "" {
		t.Fatalf("no reply: %+v", d)
	}
	// The rough words AND the full turn both reached the model — the
	// polish must come from what the agent actually said.
	if !strings.Contains(sentUser, "yeah sounds good but keep the test") {
		t.Fatalf("guidance missing from prompt: %q", sentUser)
	}
	if !strings.Contains(sentUser, "tag now or wait?") {
		t.Fatalf("full turn missing from prompt: %q", sentUser)
	}
}

func TestExpandOnNothingRefusesBeforeSpendingAnything(t *testing.T) {
	st := &store{keep: 10}
	st.add(draftedDigest())
	rep := act(nil, st, &Summarizer{}, nil, 1, json.RawMessage(`{"itemId":"s1:aa","actionId":"expand","input":"   "}`))
	if rep.OK {
		t.Fatal("expanded whitespace into a bill")
	}
}
