package agent

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
)

// fakeHost is enough of rook-host for the loop: one canned attention item,
// a context for it, a spend counter, and a channel capturing posted drafts.
type fakeHost struct {
	*httptest.Server
	spend  Spend
	askSeq int
	drafts chan DraftPost
}

func newFakeHost(t *testing.T) *fakeHost {
	t.Helper()
	f := &fakeHost{askSeq: 1, drafts: make(chan DraftPost, 4)}
	mux := http.NewServeMux()
	mux.HandleFunc("/attention", func(w http.ResponseWriter, r *http.Request) {
		json.NewEncoder(w).Encode([]AttentionItem{{
			Workspace: "ws", RookSession: "s1", AgentSession: "t1",
			AskSeq: 1, State: "needs_input", Ask: "Run the tests?",
		}})
	})
	mux.HandleFunc("/agents/t1/context", func(w http.ResponseWriter, r *http.Request) {
		json.NewEncoder(w).Encode(map[string]any{
			"sessionId": "t1", "title": "fix the parser", "cwd": "/repo",
			"askSeq": f.askSeq, "state": "needs_input", "ask": "Run the tests?",
			"history": []map[string]string{{"role": "assistant", "text": "Done. Run the tests?"}},
		})
	})
	mux.HandleFunc("/agents/t1/draft", func(w http.ResponseWriter, r *http.Request) {
		var d DraftPost
		json.NewDecoder(r.Body).Decode(&d)
		f.drafts <- d
		json.NewEncoder(w).Encode(map[string]int64{"id": 1})
	})
	mux.HandleFunc("/agent/spend", func(w http.ResponseWriter, r *http.Request) {
		json.NewEncoder(w).Encode(f.spend)
	})
	f.Server = httptest.NewServer(mux)
	t.Cleanup(f.Close)
	return f
}

// fakeOpenAI returns a fixed judgment and counts calls.
func fakeOpenAI(t *testing.T, j Judgment) (*httptest.Server, *atomic.Int32) {
	t.Helper()
	var calls atomic.Int32
	content, _ := json.Marshal(j)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		json.NewEncoder(w).Encode(map[string]any{
			"choices": []map[string]any{{"message": map[string]any{"content": string(content)}}},
			"usage": map[string]any{
				"prompt_tokens": 900, "completion_tokens": 30,
				"prompt_tokens_details": map[string]any{"cached_tokens": 800},
			},
		})
	}))
	t.Cleanup(srv.Close)
	return srv, &calls
}

func testAgent(host *fakeHost, ai *httptest.Server) *Agent {
	a := New(&Client{Endpoint: host.URL, Token: "t", http: http.DefaultClient},
		NewOpenAI("k", "gpt-5.4-nano"), 1.00)
	a.AI.BaseURL = ai.URL
	a.Debounce = 0
	return a
}

func TestJudgePostsDraft(t *testing.T) {
	host := newFakeHost(t)
	ai, calls := fakeOpenAI(t, Judgment{Action: "draft", Reply: "yes", Confidence: 0.92, Reason: "mechanical"})
	a := testAgent(host, ai)

	item := AttentionItem{AgentSession: "t1", AskSeq: 1, State: "needs_input"}
	a.judge(context.Background(), item)

	d := <-host.drafts
	if d.Action != "draft" || d.Reply != "yes" || d.AskSeq != 1 {
		t.Fatalf("posted draft = %+v", d)
	}
	if d.InputTokens != 900 || d.CachedTokens != 800 || d.OutputTokens != 30 {
		t.Errorf("token accounting: %+v", d)
	}
	// (900-800)*0.20 + 800*0.02 + 30*1.25 per million
	want := (100*0.20 + 800*0.02 + 30*1.25) / 1e6
	if d.CostUSD < want*0.99 || d.CostUSD > want*1.01 {
		t.Errorf("cost = %v, want ≈%v", d.CostUSD, want)
	}
	if calls.Load() != 1 {
		t.Errorf("openai calls = %d, want 1", calls.Load())
	}
}

// A hesitant draft must leave as an escalation — the gate is enforced on
// our side, not just requested of the model.
func TestLowConfidenceEscalates(t *testing.T) {
	host := newFakeHost(t)
	ai, _ := fakeOpenAI(t, Judgment{Action: "draft", Reply: "refactor the store", Confidence: 0.4})
	a := testAgent(host, ai)

	a.judge(context.Background(), AttentionItem{AgentSession: "t1", AskSeq: 1, State: "needs_input"})
	d := <-host.drafts
	if d.Action != "escalate" || d.Reply != "" {
		t.Fatalf("low-confidence judgment posted as %+v, want escalate/empty", d)
	}
}

// Over the daily cap: no model call, no draft — the ask surfaces raw.
func TestBudgetGuard(t *testing.T) {
	host := newFakeHost(t)
	host.spend = Spend{TodayUSD: 1.50}
	ai, calls := fakeOpenAI(t, Judgment{Action: "draft", Reply: "yes", Confidence: 0.9})
	a := testAgent(host, ai)

	a.judge(context.Background(), AttentionItem{AgentSession: "t1", AskSeq: 1, State: "needs_input"})
	if calls.Load() != 0 {
		t.Fatalf("openai called %d times despite blown budget", calls.Load())
	}
	select {
	case d := <-host.drafts:
		t.Fatalf("draft posted despite blown budget: %+v", d)
	default:
	}
	// and the loop pauses rather than re-probing every 2s
	a.mu.Lock()
	paused := !a.pauseUntil.IsZero()
	a.mu.Unlock()
	if !paused {
		t.Error("budget breach should set a pause")
	}
}

// The ask moved on during the debounce → the call is skipped entirely.
func TestStaleAskSkipped(t *testing.T) {
	host := newFakeHost(t)
	host.askSeq = 2 // context now reports a newer ask
	ai, calls := fakeOpenAI(t, Judgment{Action: "draft", Reply: "yes", Confidence: 0.9})
	a := testAgent(host, ai)

	a.judge(context.Background(), AttentionItem{AgentSession: "t1", AskSeq: 1, State: "needs_input"})
	if calls.Load() != 0 {
		t.Fatalf("openai called for a stale ask")
	}
}

// tick marks each fresh ask exactly once — a second tick with the same
// items must not double-judge, and pruning frees keys for resolved asks.
func TestTickDedupe(t *testing.T) {
	host := newFakeHost(t)
	ai, calls := fakeOpenAI(t, Judgment{Action: "draft", Reply: "yes", Confidence: 0.9})
	a := testAgent(host, ai)

	items := []AttentionItem{{AgentSession: "t1", AskSeq: 1, State: "needs_input"}}
	a.tick(context.Background(), items)
	<-host.drafts
	a.tick(context.Background(), items) // same ask again
	a.tick(context.Background(), nil)   // ask resolved → key pruned
	a.tick(context.Background(), items) // same key returns (host restarted, say)
	<-host.drafts
	if got := calls.Load(); got != 2 {
		t.Fatalf("openai calls = %d, want 2 (once per fresh sighting)", got)
	}
}
