package host

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/incantery/rook/internal/relay"
)

// fakeMailbox stands in for a rook-server: it records what the host sent
// and hands back whatever answers the test has queued.
type fakeMailbox struct {
	mu        sync.Mutex
	published []relay.Ask
	retracted []string
	answers   []relay.Answered
}

func (m *fakeMailbox) server(t *testing.T) *relay.Client {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		m.mu.Lock()
		defer m.mu.Unlock()
		switch {
		case r.Method == http.MethodPost && r.URL.Path == "/v1/asks":
			var a relay.Ask
			json.NewDecoder(r.Body).Decode(&a)
			m.published = append(m.published, a)
			w.WriteHeader(http.StatusNoContent)
		case r.Method == http.MethodDelete && strings.HasPrefix(r.URL.Path, "/v1/asks/"):
			m.retracted = append(m.retracted, strings.TrimPrefix(r.URL.Path, "/v1/asks/"))
			w.WriteHeader(http.StatusNoContent)
		case r.Method == http.MethodGet && r.URL.Path == "/v1/answers":
			json.NewEncoder(w).Encode(map[string]any{"answered": m.answers})
			m.answers = nil // read-once, like the real thing
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	t.Cleanup(srv.Close)
	return relay.New(srv.URL, "tok")
}

func (m *fakeMailbox) sent() ([]relay.Ask, []string) {
	m.mu.Lock()
	defer m.mu.Unlock()
	return append([]relay.Ask(nil), m.published...), append([]string(nil), m.retracted...)
}

// hostWithAsk builds a host holding one session and one pending ask.
func hostWithAsk(t *testing.T, escalated bool) (*Host, *session) {
	t.Helper()
	s := &session{info: SessionInfo{ID: "s1", Workspace: "rook"}}
	h := &Host{
		sessions: map[string]*session{"s1": s},
		asks: map[string]*askState{"a1": {
			session:   "s1",
			escalated: escalated,
			doneCh:    make(chan struct{}),
			created:   time.Now(),
		}},
	}
	h.ctx, h.cancel = context.WithCancel(context.Background())
	t.Cleanup(h.cancel)
	return h, s
}

// waitFor polls until cond holds — publish and retract run off the request
// path, so the assertion has to outlast the goroutine, not race it.
func waitFor(t *testing.T, what string, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if cond() {
			return
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatalf("timed out waiting for %s", what)
}

// settleQuiet gives a would-be background call time to happen, for the
// assertions that something did NOT get sent.
func settleQuiet() { time.Sleep(150 * time.Millisecond) }

// An answer from the phone and an answer from the pane are the SAME event.
// Two settle paths would drift within a week, so this locks the shape: the
// waiter wakes, and every attached surface is told to stand down.
func TestRemoteAnswerSettlesLikeTheDesk(t *testing.T) {
	m := &fakeMailbox{}
	h, _ := hostWithAsk(t, true)
	h.relay = m.server(t)

	answer := json.RawMessage(`{"answers":[{"question":"?","selected":["yes"]}]}`)
	h.applyRemoteAnswer("a1", answer)

	h.askMu.Lock()
	a := h.asks["a1"]
	done, got := a.done, string(a.answer)
	h.askMu.Unlock()
	if !done {
		t.Fatal("remote answer left the ask undecided")
	}
	if got != string(answer) {
		t.Fatalf("answer stored as %s, want %s", got, answer)
	}
	select {
	case <-a.doneCh:
	default:
		t.Fatal("doneCh not closed — a blocked rookctl would still be parked")
	}

	// The pane stands down by the ask leaving the queue: there is no push
	// any more (the frame socket went with the webview), so `done` IS the
	// stand-down — GET /asks stops listing it and the app drops the form.
	h.askMu.Lock()
	listed := !h.asks["a1"].done
	h.askMu.Unlock()
	if listed {
		t.Fatal("a settled ask must leave the queue — the pane would sit open on it")
	}

	// an answer that came THROUGH the relay was already consumed by the
	// drain; retracting it would be a pointless round trip
	settleQuiet()
	if _, retracted := m.sent(); len(retracted) != 0 {
		t.Fatalf("retracted an ask the relay itself answered: %v", retracted)
	}
}

// Answered at the desk: the card has to leave the phone, or you learn to
// ignore the phone.
func TestDeskAnswerRetractsFromTheMailbox(t *testing.T) {
	m := &fakeMailbox{}
	h, _ := hostWithAsk(t, true)
	h.relay = m.server(t)

	if got := h.settleAsk("a1", json.RawMessage(`{"canceled":true}`), sourceApp); got != settledOK {
		t.Fatalf("settleAsk = %v, want settledOK", got)
	}
	waitFor(t, "the retract", func() bool {
		_, retracted := m.sent()
		return len(retracted) == 1 && retracted[0] == "a1"
	})
}

// An ask that never reached the mailbox has nothing to withdraw — no
// remote configured, or the publish failed.
func TestUnescalatedAskIsNotRetracted(t *testing.T) {
	m := &fakeMailbox{}
	h, _ := hostWithAsk(t, false)
	h.relay = m.server(t)

	h.settleAsk("a1", json.RawMessage(`{"canceled":true}`), sourceApp)
	settleQuiet()
	if _, retracted := m.sent(); len(retracted) != 0 {
		t.Fatalf("retracted an ask that never escalated: %v", retracted)
	}
}

// First write wins across surfaces, and the loser is told which it was.
func TestSettleRaceAndUnknown(t *testing.T) {
	h, _ := hostWithAsk(t, false)
	if got := h.settleAsk("a1", json.RawMessage(`1`), sourceApp); got != settledOK {
		t.Fatalf("first settle = %v, want settledOK", got)
	}
	if got := h.settleAsk("a1", json.RawMessage(`2`), sourceRelay); got != settledAlready {
		t.Fatalf("second settle = %v, want settledAlready", got)
	}
	if got := h.settleAsk("nope", json.RawMessage(`1`), sourceRelay); got != settledUnknown {
		t.Fatalf("unknown ask = %v, want settledUnknown", got)
	}
}

// Escalation carries the workspace as the card's heading — the only context
// the phone gets about which agent is talking.
func TestEscalateCarriesWorkspace(t *testing.T) {
	m := &fakeMailbox{}
	h, _ := hostWithAsk(t, false)
	h.relay = m.server(t)

	h.askMu.Lock()
	st := h.asks["a1"]
	h.askMu.Unlock()
	h.escalate(st, "a1", json.RawMessage(`[{"question":"?"}]`))
	waitFor(t, "the publish", func() bool {
		published, _ := m.sent()
		return len(published) == 1
	})

	published, _ := m.sent()
	if len(published) != 1 {
		t.Fatalf("published %d asks, want 1", len(published))
	}
	if published[0].Title != "rook" || published[0].Workspace != "rook" {
		t.Fatalf("published %+v, want workspace/title 'rook'", published[0])
	}
	h.askMu.Lock()
	escalated := h.asks["a1"].escalated
	h.askMu.Unlock()
	if !escalated {
		t.Fatal("escalated flag not set — a desk answer would never retract")
	}
}

// outstanding() is what keeps the poll off the network when nothing is
// waiting: steady state must be idle.
func TestOutstanding(t *testing.T) {
	h, _ := hostWithAsk(t, false)
	if h.outstanding() {
		t.Fatal("un-escalated ask counts as outstanding — the poll would never idle")
	}
	h.askMu.Lock()
	h.asks["a1"].escalated = true
	h.askMu.Unlock()
	if !h.outstanding() {
		t.Fatal("escalated, undecided ask is not outstanding")
	}
	h.settleAsk("a1", json.RawMessage(`1`), sourceRelay)
	if h.outstanding() {
		t.Fatal("settled ask still counts as outstanding")
	}
}
