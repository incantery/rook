package agent

import (
	"context"
	"net/http"
	"testing"
	"time"
)

// budgetEngine reports the deadline its calls were handed.
type budgetEngine struct {
	timeout time.Duration
	got     chan time.Duration
}

func (e *budgetEngine) Name() string           { return "stub" }
func (e *budgetEngine) Timeout() time.Duration { return e.timeout }

func (e *budgetEngine) record(ctx context.Context) {
	dl, ok := ctx.Deadline()
	if !ok {
		e.got <- 0 // no deadline at all is its own failure
		return
	}
	e.got <- time.Until(dl)
}

func (e *budgetEngine) Judge(ctx context.Context, _, _ string) (*Judgment, Usage, error) {
	e.record(ctx)
	return &Judgment{Action: "escalate", Reason: "stub"}, Usage{}, nil
}

func (e *budgetEngine) Extract(ctx context.Context, _, _ string) (*Extraction, Usage, error) {
	e.record(ctx)
	return &Extraction{}, Usage{}, nil
}

func testBudgetAgent(endpoint string, eng *budgetEngine) *Agent {
	a := New(&Client{Endpoint: endpoint, Token: "t", http: http.DefaultClient}, eng, 1.00)
	a.Debounce = 0
	return a
}

// Both call sites must take their budget from the ENGINE. They used to share
// a 30s constant, which was sized when OpenAI was the only engine — a number
// the ClaudeCode engine cannot live inside (a cold `claude -p` spends ~15s
// before inference, on a config rook does not control). Wiring, not
// arithmetic: a hardcoded constant would still pass a test that only read
// Timeout().
func TestCallBudgetComesFromTheEngine(t *testing.T) {
	const declared = 97 * time.Second // a value no constant would coincide with

	for _, tc := range []struct {
		name     string
		endpoint func(*testing.T) string
		call     func(*Agent)
	}{
		{
			"judge",
			func(t *testing.T) string { return newFakeHost(t).URL },
			func(a *Agent) {
				a.judge(context.Background(), AttentionItem{
					AgentSession: "t1", AskSeq: 1, State: "needs_input",
				})
			},
		},
		{
			"extract",
			func(t *testing.T) string { return extractHost(t, sampleRows, Spend{}).URL },
			func(a *Agent) { a.extract(context.Background()) },
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			// Both paths read the real prefs store, and extract reads the real
			// cursor — which on a live machine is far past sampleRows, so an
			// unisolated run reads "nothing to extract" and never calls the
			// engine at all. The test would pass its own point silently.
			isolate(t)

			eng := &budgetEngine{timeout: declared, got: make(chan time.Duration, 1)}
			tc.call(testBudgetAgent(tc.endpoint(t), eng))

			select {
			case got := <-eng.got:
				// The clock moves between WithTimeout and Deadline; a second
				// of slack reads "same number" without pinning the scheduler.
				if got < declared-time.Second || got > declared {
					t.Fatalf("%s call budget = %v, want the engine's declared %v", tc.name, got, declared)
				}
			case <-time.After(5 * time.Second):
				t.Fatalf("%s never reached the engine", tc.name)
			}
		})
	}
}

// The two engines must not converge on one number — that convergence IS the
// bug this replaced. The floor is borrowed from TestClaudeCodeLive, which
// gives the real CLI 90s: production trusting the CLI less than the test does
// was the tell that the shared constant was wrong.
func TestEngineBudgetsAreNotShared(t *testing.T) {
	fast := NewOpenAI("k", "gpt-5.4-nano").Timeout()
	slow := (&ClaudeCode{}).Timeout()

	if slow <= fast {
		t.Fatalf("claude budget %v does not exceed the OpenAI budget %v — a cold `claude -p` "+
			"spends ~15s before inference, and that number scales with the user's global config", slow, fast)
	}
	if slow < 90*time.Second {
		t.Errorf("claude budget %v is under the 90s TestClaudeCodeLive allows the real CLI; "+
			"a timeout burns the call's tokens, records no ledger row, and pauses the drafter 60s", slow)
	}
}
