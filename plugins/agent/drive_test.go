package main

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/incantery/rook/plugins/internal/transcript"
	veradrive "github.com/incantery/vera/drive"
)

func TestDriveJudgeShowsTheWholeConversation(t *testing.T) {
	var sentUser string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var body struct {
			Messages []chatMsg `json:"messages"`
		}
		raw, _ := io.ReadAll(r.Body)
		json.Unmarshal(raw, &body)
		sentUser = body.Messages[1].Content
		io.WriteString(w, completion("CONTINUE\nAsk for the hypothesis directly.", 200, 20))
	}))
	defer srv.Close()
	var spent float64
	j := driveJudge{
		z:     &Summarizer{Client: srv.Client(), Base: srv.URL, Key: "k", Model: "gpt-5-mini"},
		spend: func(c float64) { spent += c },
	}
	v, err := j.Judge(context.Background(), "get a hypothesis", []veradrive.Exchange{
		{Prompt: "hypothesize about the term", Reply: "I don't have access to that information"},
	})
	if err != nil || v.Done || v.Prompt != "Ask for the hypothesis directly." {
		t.Fatalf("v=%+v err=%v", v, err)
	}
	for _, want := range []string{"get a hypothesis", "hypothesize about the term", "I don't have access"} {
		if !strings.Contains(sentUser, want) {
			t.Fatalf("the judge did not see %q: %q", want, sentUser)
		}
	}
	if spent == 0 {
		t.Fatal("a judgment costs money and the meter must say so")
	}
}

// driveWorld fakes the session a drive converses with: Deliver lands
// the prompt and a scripted reply appears as a finished turn.
type driveWorld struct {
	mu      sync.Mutex
	s       transcript.Session
	replies []string
	sent    []string
}

func newDriveWorld(state transcript.State) *driveWorld {
	return &driveWorld{s: transcript.Session{
		ID: "sess-1", Cwd: "/repo", Title: "release", State: state, LastText: "the old turn",
	}}
}

func (w *driveWorld) scan(time.Time) []transcript.Session {
	w.mu.Lock()
	defer w.mu.Unlock()
	return []transcript.Session{w.s}
}

// RunTurn is the fake's half of veradrive.Turner. It waits for the
// session to go quiet exactly as the real TUI turner does — a fake
// that typed into a working session would make the stop test prove
// nothing, since the whole point there is a drive parked on the wait.
func (w *driveWorld) RunTurn(ctx context.Context, sessionID, prompt string) (veradrive.Turn, error) {
	for w.working() {
		select {
		case <-ctx.Done():
			return veradrive.Turn{}, errors.New("stopped")
		case <-time.After(time.Millisecond):
		}
	}
	w.mu.Lock()
	defer w.mu.Unlock()
	w.sent = append(w.sent, prompt)
	reply := "reply to: " + prompt
	if n := len(w.sent) - 1; n < len(w.replies) {
		reply = w.replies[n]
	}
	w.s.Prompt = prompt
	w.s.LastText = reply
	w.s.State = transcript.StateNeedsYou
	return veradrive.Turn{Reply: reply, SessionID: sessionID}, nil
}

func (w *driveWorld) working() bool {
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.s.State == transcript.StateWorking
}

func (w *driveWorld) host(z *Summarizer, maxTurns int) *driveHost {
	return &driveHost{
		sum: z, maxTurns: maxTurns,
		newScan:   func() func(time.Time) []transcript.Session { return w.scan },
		newDriver: func(func(time.Time) []transcript.Session, func(string)) veradrive.Turner { return w },
	}
}

func waitRun(t *testing.T, dv *driveHost, id string, want func(driveRun) bool) driveRun {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		var got driveRun
		if dv.book.update(id, func(r *driveRun) { got = *r }) && want(got) {
			return got
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatal("the run never reached the wanted state")
	return driveRun{}
}

func driveDigest() Digest {
	return Digest{ID: "sess-1:aa", SessionID: "sess-1", SessionTitle: "release",
		Headline: "It stalled.", At: t0}
}

func TestDriveLifecycleFromActionToDoneRow(t *testing.T) {
	// The judge's script: one push past the deflection, then done.
	verdicts := []string{
		"CONTINUE\nYou do not need access — give your best hypothesis anyway.",
		"DONE\nThe worker offered three hypotheses.",
	}
	call := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		v := verdicts[call%len(verdicts)]
		call++
		io.WriteString(w, completion(v, 300, 30))
	}))
	defer srv.Close()
	z := &Summarizer{Client: srv.Client(), Base: srv.URL, Key: "k", Model: "gpt-5-mini"}
	w := newDriveWorld(transcript.StateNeedsYou)
	w.replies = []string{"I don't have access to that information", "here are three hypotheses"}
	dv := w.host(z, 4)
	st := &store{keep: 10}
	st.add(driveDigest())

	rep := act(nil, st, z, dv, 1, json.RawMessage(`{"itemId":"sess-1:aa","actionId":"drive","input":"get a hypothesis about the term"}`))
	if !rep.OK {
		t.Fatalf("drive refused: %+v", rep)
	}
	got := waitRun(t, dv, "drive:1", func(r driveRun) bool { return r.finished })
	if !got.done || got.turns != 2 || !strings.Contains(got.reason, "three hypotheses") {
		t.Fatalf("run: %+v", got)
	}
	// The first prompt is the goal verbatim; the second is the judge's.
	if w.sent[0] != "get a hypothesis about the term" || !strings.Contains(w.sent[1], "best hypothesis") {
		t.Fatalf("sent: %v", w.sent)
	}
	// The panel: a done row wearing the reason, the goal, and the final
	// reply — the deliverable, readable where the goal was given.
	it := dv.book.items(t0)[0]
	if it.State != "done" || !strings.Contains(it.Title, "three hypotheses") || it.Actions[0].ID != "dismiss" {
		t.Fatalf("row: %+v", it)
	}
	var joined string
	for _, c := range it.Children {
		joined += c.Title + "|"
	}
	if !strings.Contains(joined, "⛿ goal:") || !strings.Contains(joined, "here are three hypotheses") {
		t.Fatalf("children: %v", joined)
	}
	if got.cost == 0 {
		t.Fatal("two judgments cost money and the row must say so")
	}
}

func TestDriveRefusalsBeforeAnythingIsTyped(t *testing.T) {
	st := &store{keep: 10}
	st.add(driveDigest())
	// No key, no judge, no drive.
	rep := act(nil, st, nil, (&driveWorld{}).host(nil, 4), 1,
		json.RawMessage(`{"itemId":"sess-1:aa","actionId":"drive","input":"goal"}`))
	if rep.OK || !strings.Contains(rep.Error, "no OpenAI key") {
		t.Fatalf("rep: %+v", rep)
	}
	// A goal of whitespace is not a goal.
	w := newDriveWorld(transcript.StateNeedsYou)
	dv := w.host(&Summarizer{}, 4)
	rep = act(nil, st, &Summarizer{}, dv, 2,
		json.RawMessage(`{"itemId":"sess-1:aa","actionId":"drive","input":"   "}`))
	if rep.OK || !strings.Contains(rep.Error, "say what") {
		t.Fatalf("rep: %+v", rep)
	}
}

func TestDriveRefusesASecondDriverOnOneSession(t *testing.T) {
	// A judge that never answers keeps the first drive alive.
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		time.Sleep(2 * time.Second)
		io.WriteString(w, completion("DONE\nmet", 10, 5))
	}))
	defer srv.Close()
	z := &Summarizer{Client: srv.Client(), Base: srv.URL, Key: "k", Model: "gpt-5-mini"}
	w := newDriveWorld(transcript.StateNeedsYou)
	dv := w.host(z, 4)
	if _, err := dv.start("sess-1", "release", "goal one"); err != nil {
		t.Fatalf("first drive refused: %v", err)
	}
	if _, err := dv.start("sess-1", "release", "goal two"); err == nil || !strings.Contains(err.Error(), "already driving") {
		t.Fatalf("second drive: %v", err)
	}
	dv.book.stop("drive:1")
	waitRun(t, dv, "drive:1", func(r driveRun) bool { return r.finished })
}

func TestStopEndsALiveDriveAndDismissClearsTheRow(t *testing.T) {
	// A session that never goes quiet: the loop waits, the stop lands
	// between polls.
	w := newDriveWorld(transcript.StateWorking)
	dv := w.host(&Summarizer{Client: http.DefaultClient, Base: "http://127.0.0.1:0", Model: "gpt-5-mini"}, 4)
	if _, err := dv.start("sess-1", "release", "goal"); err != nil {
		t.Fatalf("start: %v", err)
	}
	// Dismissing a live run must refuse — stop is the only exit.
	rep := act(nil, nil, nil, dv, 1, json.RawMessage(`{"itemId":"drive:1","actionId":"dismiss"}`))
	if rep.OK {
		t.Fatal("dismissed a running drive")
	}
	rep = act(nil, nil, nil, dv, 2, json.RawMessage(`{"itemId":"drive:1","actionId":"stop"}`))
	if !rep.OK {
		t.Fatalf("stop refused: %+v", rep)
	}
	got := waitRun(t, dv, "drive:1", func(r driveRun) bool { return r.finished })
	if got.done || !strings.Contains(got.reason, "stopped") {
		t.Fatalf("run: %+v", got)
	}
	// Acting on a child row acts on the run it belongs to.
	rep = act(nil, nil, nil, dv, 3, json.RawMessage(`{"itemId":"drive:1:goal","actionId":"dismiss"}`))
	if !rep.OK || len(dv.book.items(t0)) != 0 {
		t.Fatalf("dismiss: %+v, rows left %d", rep, len(dv.book.items(t0)))
	}
}

func TestDigestRowsOfferTheDrive(t *testing.T) {
	st := &store{keep: 10}
	st.add(driveDigest())
	it := items(st, t0)[0]
	var ids []string
	for _, a := range it.Actions {
		ids = append(ids, a.ID)
	}
	if !strings.Contains(strings.Join(ids, ","), "drive") {
		t.Fatalf("actions: %v", ids)
	}
	for _, a := range it.Actions {
		if a.ID == "drive" && a.Input != "INPUT_TEXT" {
			t.Fatalf("the drive action must ask for the goal: %+v", a)
		}
	}
}
