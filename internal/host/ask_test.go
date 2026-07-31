package host

import (
	"context"
	"encoding/json"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

// typedLines records what the doorbell would have typed, so these tests can
// assert on delivery without a tty.
type typedLines struct {
	mu    sync.Mutex
	lines []string
}

func (tl *typedLines) at(_ *session, line string) {
	tl.mu.Lock()
	defer tl.mu.Unlock()
	tl.lines = append(tl.lines, line)
}

func (tl *typedLines) all() []string {
	tl.mu.Lock()
	defer tl.mu.Unlock()
	return append([]string(nil), tl.lines...)
}

// askHost builds a host holding one session ("s1") and whatever asks the
// test names, with the doorbell's pty write captured.
func askHost(t *testing.T, asks map[string]*askState) (*Host, *session, *typedLines) {
	t.Helper()
	s := &session{info: SessionInfo{ID: "s1", Workspace: "rook"}}
	for _, a := range asks {
		if a.doneCh == nil {
			a.doneCh = make(chan struct{})
		}
		if a.created.IsZero() {
			a.created = time.Now()
		}
	}
	tl := &typedLines{}
	h := &Host{
		sessions:   map[string]*session{"s1": s},
		asks:       asks,
		claims:     map[string]string{},
		claimFg:    map[string]int{},
		typeLineFn: tl.at,
	}
	h.ctx, h.cancel = context.WithCancel(context.Background())
	t.Cleanup(h.cancel)
	return h, s, tl
}

func drain(t *testing.T, h *Host, s *session) struct {
	Answered []struct {
		AskID  string          `json:"askId"`
		Answer json.RawMessage `json:"answer"`
	} `json:"answered"`
	Pending []string `json:"pending"`
} {
	t.Helper()
	var out struct {
		Answered []struct {
			AskID  string          `json:"askId"`
			Answer json.RawMessage `json:"answer"`
		} `json:"answered"`
		Pending []string `json:"pending"`
	}
	w := httptest.NewRecorder()
	h.handleSessionAsks(w, s)
	if err := json.Unmarshal(w.Body.Bytes(), &out); err != nil {
		t.Fatalf("drain returned %s: %v", w.Body.String(), err)
	}
	return out
}

// The drain is the async ask's only delivery, and it is read-once: a second
// call must not hand the same decision to the agent twice.
func TestDrainYieldsDecidedAsksOnceAndListsPending(t *testing.T) {
	h, s, _ := askHost(t, map[string]*askState{
		"a1": {session: "s1", notify: true},
		"a2": {session: "s1", notify: true},
	})
	h.settleAsk("a1", json.RawMessage(`{"answers":[{"question":"?","selected":["A"]}]}`), sourceApp)

	got := drain(t, h, s)
	if len(got.Answered) != 1 || got.Answered[0].AskID != "a1" {
		t.Fatalf("drained %+v, want just a1", got.Answered)
	}
	if len(got.Pending) != 1 || got.Pending[0] != "a2" {
		t.Fatalf("pending %v, want [a2] — an undecided ask has to stay visible", got.Pending)
	}

	again := drain(t, h, s)
	if len(again.Answered) != 0 {
		t.Fatalf("re-drained %+v — the read is supposed to consume", again.Answered)
	}
	if len(again.Pending) != 1 {
		t.Fatalf("pending %v after the read, want a2 still there", again.Pending)
	}
}

// A blocking ask (`rookctl ask`) is owned by its long-poll. If the drain
// handed it out, the answer would go to an agent that never asked and the
// blocked CLI would hang forever.
func TestDrainIgnoresBlockingAsks(t *testing.T) {
	h, s, _ := askHost(t, map[string]*askState{"a1": {session: "s1"}})
	h.settleAsk("a1", json.RawMessage(`{"canceled":true}`), sourceApp)

	got := drain(t, h, s)
	if len(got.Answered) != 0 || len(got.Pending) != 0 {
		t.Fatalf("drain exposed a blocking ask: %+v", got)
	}
	h.askMu.Lock()
	still := h.asks["a1"] != nil
	h.askMu.Unlock()
	if !still {
		t.Fatal("drain deleted a blocking ask out from under its long-poll")
	}
}

// The doorbell rings at a live claim, and says which ask to collect.
func TestDoorbellRingsAtALiveClaim(t *testing.T) {
	h, _, tl := askHost(t, map[string]*askState{"a1": {session: "s1", notify: true}})
	h.claims["t1"] = "s1"

	h.settleAsk("a1", json.RawMessage(`{"answers":[]}`), sourceApp)
	waitFor(t, "the doorbell", func() bool { return len(tl.all()) == 1 })

	line := tl.all()[0]
	if want := "rook ask a1 answered"; len(line) < len(want) || line[:len(want)] != want {
		t.Fatalf("doorbell typed %q, want it to name the ask", line)
	}
	h.askMu.Lock()
	owed := h.asks["a1"].doorbellOwed
	h.askMu.Unlock()
	if owed {
		t.Fatal("a doorbell that rang is still owed")
	}
}

// The stranding case: answered while the window had no live agent. Typing
// then would run the line as a shell command, so the delivery has to wait —
// and the next claude to claim the window has to get it.
func TestOwedDoorbellRingsOnTheNextClaim(t *testing.T) {
	h, _, tl := askHost(t, map[string]*askState{"a1": {session: "s1", notify: true}})

	h.settleAsk("a1", json.RawMessage(`{"answers":[]}`), sourceApp)
	waitFor(t, "the owed flag", func() bool {
		h.askMu.Lock()
		defer h.askMu.Unlock()
		return h.asks["a1"].doorbellOwed
	})
	if got := tl.all(); len(got) != 0 {
		t.Fatalf("typed %q at a window with no live agent", got)
	}

	// a fresh claude claims the window (rookctl claim, SessionStart hook)
	h.claims["t2"] = "s1"
	h.ringOwedDoorbells("s1")

	if got := tl.all(); len(got) != 1 {
		t.Fatalf("owed doorbell delivered %d lines, want 1 — the answer was stranded", len(got))
	}
	h.askMu.Lock()
	owed := h.asks["a1"].doorbellOwed
	h.askMu.Unlock()
	if owed {
		t.Fatal("owed flag survived delivery — the next claim would ring again")
	}

	// …and only once: a second claim on the same window is not a second answer
	h.ringOwedDoorbells("s1")
	if got := tl.all(); len(got) != 1 {
		t.Fatalf("rang %d times, want 1", len(got))
	}
}

// An owed doorbell is not a lost answer: the drain still has it, because
// the agent that finally reads it is the one the line points at.
func TestOwedAnswerIsStillInTheDrain(t *testing.T) {
	h, s, _ := askHost(t, map[string]*askState{"a1": {session: "s1", notify: true}})
	answer := json.RawMessage(`{"answers":[{"question":"?","selected":[]}]}`)
	h.settleAsk("a1", answer, sourceApp)
	waitFor(t, "the owed flag", func() bool {
		h.askMu.Lock()
		defer h.askMu.Unlock()
		return h.asks["a1"].doorbellOwed
	})

	got := drain(t, h, s)
	if len(got.Answered) != 1 || string(got.Answered[0].Answer) != string(answer) {
		t.Fatalf("drained %+v, want the answer that had nobody to ring", got.Answered)
	}
}

// The queue lists what is still open, and a SESSION-SCOPED ask is in it.
//
// It did not used to be: a session ask was pushed over that session's frame
// socket and skipped here to avoid double-rendering it. That socket went
// with the webview, so skipping made the MCP ask tool's questions invisible
// — created, escalated, and listed nowhere. The session survives as
// provenance, which is what the app renders "where did this come from" from.
func TestAskQueueListsSessionScopedAsks(t *testing.T) {
	h, _, _ := askHost(t, map[string]*askState{
		"a1": {session: "s1", questions: json.RawMessage(`[{"q":"a"}]`)},
		"a2": {session: "s1", questions: json.RawMessage(`[{"q":"b"}]`)},
		"a3": {questions: json.RawMessage(`[{"q":"c"}]`)},
	})
	h.settleAsk("a2", json.RawMessage(`{"canceled":true}`), sourceApp)

	w := httptest.NewRecorder()
	h.handleAskQueue(w, httptest.NewRequest("GET", "/asks", nil))
	var got []struct {
		ID      string `json:"id"`
		Session string `json:"session"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &got); err != nil {
		t.Fatal(err)
	}
	if len(got) != 2 {
		t.Fatalf("queue listed %d asks %+v, want the two undecided", len(got), got)
	}
	seen := map[string]string{}
	for _, g := range got {
		seen[g.ID] = g.Session
	}
	if _, ok := seen["a2"]; ok {
		t.Fatal("a settled ask must leave the queue")
	}
	if seen["a1"] != "s1" {
		t.Fatalf("a session ask must carry its provenance: %+v", got)
	}
	if seen["a3"] != "" {
		t.Fatalf("a session-less ask has no provenance to carry: %+v", got)
	}
}

// The session-less queue: an app that holds no wire-v3 session socket can
// still be handed a question. The zig app is exactly that client — it owns
// its ptys in-process, registers no sessions, and $ROOK_SESSION is unset in
// its shells, so the push path is unreachable from it in both directions.
func TestAskQueueCreatesListsAndSettles(t *testing.T) {
	h, _, _ := askHost(t, map[string]*askState{})

	// Create, session-less.
	w := httptest.NewRecorder()
	body := `{"questions":[{"question":"Ship it?","options":[{"label":"Yes"},{"label":"No"}]}]}`
	h.handleAskQueue(w, httptest.NewRequest("POST", "/asks", strings.NewReader(body)))
	if w.Code != 200 {
		t.Fatalf("create: got %d, want 200 (%s)", w.Code, w.Body.String())
	}
	var created struct {
		AskID string `json:"askId"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &created); err != nil || created.AskID == "" {
		t.Fatalf("create returned %s", w.Body.String())
	}

	// List: pending, with the questions carried verbatim so a polling app
	// needs nothing else to render the form.
	list := func() []struct {
		ID        string          `json:"id"`
		Questions json.RawMessage `json:"questions"`
	} {
		t.Helper()
		rec := httptest.NewRecorder()
		h.handleAskQueue(rec, httptest.NewRequest("GET", "/asks", nil))
		var out []struct {
			ID        string          `json:"id"`
			Questions json.RawMessage `json:"questions"`
		}
		if err := json.Unmarshal(rec.Body.Bytes(), &out); err != nil {
			t.Fatalf("list returned %s: %v", rec.Body.String(), err)
		}
		return out
	}

	got := list()
	if len(got) != 1 || got[0].ID != created.AskID {
		t.Fatalf("list: got %+v, want the created ask", got)
	}
	if !strings.Contains(string(got[0].Questions), "Ship it?") {
		t.Errorf("questions not carried through: %s", got[0].Questions)
	}

	// Answering retires it from the queue — otherwise a polling app would
	// re-render a question the human already decided.
	h.settleAsk(created.AskID, json.RawMessage(`{"answers":[{"question":"Ship it?","selected":["Yes"]}]}`), sourceApp)
	if got := list(); len(got) != 0 {
		t.Errorf("answered ask still listed: %+v", got)
	}
}

// This used to assert the OPPOSITE — that the queue omits session-scoped
// asks, because they were delivered over that session's frame socket and
// listing them too would double-render them. The socket is gone with the
// webview it served, so the exclusion stopped being deduplication and
// became a disappearance: an MCP ask was created, escalated to the relay,
// and then listed nowhere any app could see it. See
// TestAskQueueListsSessionScopedAsks for the behaviour that replaced it.
