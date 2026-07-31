package provider

// The protocol against a REAL child process, not a mocked pipe: the test
// binary re-execs itself as a provider (the standard Go helper-process
// trick), so spawn, the handshake, the environment hand-off, and the kill
// paths are all the ones production uses.

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"
)

// TestMain doubles as a provider. ROOK_PROVIDER_TEST_MODE is what
// Client.Env{"mode": …} becomes for a provider named "test", so reaching
// this branch at all proves the config hand-off works.
func TestMain(m *testing.M) {
	switch os.Getenv("ROOK_PROVIDER_TEST_MODE") {
	case "":
		os.Exit(m.Run())
	case "crash":
		os.Exit(3)
	case "slow":
		// Cooperative: honours the deadline rook handed it and says so.
		Serve(Describe{Name: "test"}, map[string]Handler{
			OpIssuesList: func(ctx context.Context, _ json.RawMessage) (any, error) {
				<-ctx.Done()
				return nil, fmt.Errorf("gave up: %w", ctx.Err())
			},
		})
	case "wedged":
		// Ignores the deadline entirely — the only case a kill is for.
		Serve(Describe{Name: "test"}, map[string]Handler{
			OpIssuesList: func(context.Context, json.RawMessage) (any, error) {
				time.Sleep(30 * time.Second)
				return IssuesListResult{}, nil
			},
		})
	default:
		Serve(Describe{Name: "test"}, map[string]Handler{
			OpIssuesList: func(_ context.Context, raw json.RawMessage) (any, error) {
				var p IssuesListParams
				json.Unmarshal(raw, &p)
				if p.Root == "boom" {
					return nil, fmt.Errorf("the tracker said no")
				}
				return IssuesListResult{Issues: []Issue{{
					Provider: "test", Key: "#1", Title: "in " + p.Root, Mine: true,
				}}}, nil
			},
		})
	}
	os.Exit(0)
}

func testClient(t *testing.T, mode string) *Client {
	t.Helper()
	c := New("test")
	c.Path = os.Args[0]
	c.Env = map[string]string{"mode": mode}
	t.Cleanup(c.Close)
	return c
}

// The happy path, and the two refusals that come before any work: an op
// the provider never declared, and an error it chose to report.
func TestClientCallAndRefusals(t *testing.T) {
	c := testClient(t, "ok")
	ctx := context.Background()

	var res IssuesListResult
	if err := c.Call(ctx, OpIssuesList, IssuesListParams{Root: "/w/rook"}, &res); err != nil {
		t.Fatal(err)
	}
	if len(res.Issues) != 1 || res.Issues[0].Title != "in /w/rook" {
		t.Fatalf("result: %+v", res)
	}

	// An op the handshake did not name is refused HERE, without a byte on
	// the wire — the capability list is the whole vocabulary rook will use.
	err := c.Call(ctx, "issues.write", nil, nil)
	if err == nil || !strings.Contains(err.Error(), "does not offer") {
		t.Fatalf("undeclared op: %v", err)
	}
	// And the provider is still healthy: a refusal is not a breakage.
	if err := c.Call(ctx, OpIssuesList, IssuesListParams{Root: "/w/rook"}, &res); err != nil {
		t.Fatalf("refusal must not disturb the session: %v", err)
	}

	// A provider's own failure arrives as an error, not as a dead process.
	if err := c.Call(ctx, OpIssuesList, IssuesListParams{Root: "boom"}, &res); err == nil ||
		!strings.Contains(err.Error(), "the tracker said no") {
		t.Fatalf("provider error: %v", err)
	}
	if err := c.Call(ctx, OpIssuesList, IssuesListParams{Root: "/w/rook"}, &res); err != nil {
		t.Fatalf("a reported error must not end the session: %v", err)
	}
}

// A provider that HONOURS its deadline reports its own failure, and the
// process survives it. This is the outcome graceMS exists to make the
// common one: giving up is not a breakage, and killing a provider that
// answered correctly would throw away a warm process for nothing.
func TestClientSlowProviderAnswersAndSurvives(t *testing.T) {
	c := testClient(t, "slow")
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()

	if err := c.Call(ctx, OpIssuesList, IssuesListParams{Root: "/w/rook"}, nil); err == nil ||
		!strings.Contains(err.Error(), "gave up") {
		t.Fatalf("a cooperative provider must report its own timeout: %v", err)
	}
	c.mu.Lock()
	alive := c.cmd != nil
	c.mu.Unlock()
	if !alive {
		t.Fatal("a provider that answered must not be killed")
	}
}

// A provider that IGNORES its deadline is killed rather than waited on or
// resynchronised: its answer is still in the pipe, so every later answer
// would be off by one. The next call must get a fresh process and a right
// answer — which is the whole reason killing is safe.
func TestClientWedgedProviderIsKilled(t *testing.T) {
	c := testClient(t, "wedged")
	ctx, cancel := context.WithTimeout(context.Background(), 300*time.Millisecond)
	defer cancel()

	start := time.Now()
	err := c.Call(ctx, OpIssuesList, IssuesListParams{Root: "/w/rook"}, nil)
	if err == nil || !strings.Contains(err.Error(), "timed out") {
		t.Fatalf("wedged provider: %v", err)
	}
	if el := time.Since(start); el > 5*time.Second {
		t.Fatalf("the deadline must bound the call: %s", el)
	}

	// Same client, now pointed at a provider that answers: it respawns
	// rather than staying poisoned.
	c.Env = map[string]string{"mode": "ok"}
	c.Close()
	var res IssuesListResult
	if err := c.Call(context.Background(), OpIssuesList, IssuesListParams{Root: "/w/rook"}, &res); err != nil {
		t.Fatalf("after a kill, the next call must start a fresh provider: %v", err)
	}
	if len(res.Issues) != 1 {
		t.Fatalf("result after respawn: %+v", res)
	}
}

// A provider that dies during the handshake is an error with its name on
// it, not a hang and not a panic.
func TestClientCrashOnStart(t *testing.T) {
	c := testClient(t, "crash")
	err := c.Call(context.Background(), OpIssuesList, nil, nil)
	if err == nil || !strings.Contains(err.Error(), "test") {
		t.Fatalf("crashing provider: %v", err)
	}
}

// A missing binary is a named refusal — the case where a provider is
// declared in config but was never installed.
func TestClientMissingBinary(t *testing.T) {
	c := New("nope-not-installed")
	if c.Find() {
		t.Skip("a provider by this name really exists?")
	}
	err := c.Call(context.Background(), OpIssuesList, nil, nil)
	if err == nil || !strings.Contains(err.Error(), "not installed") {
		t.Fatalf("missing provider: %v", err)
	}
}

// serve's own refusals, without a process: a version it does not speak.
func TestServeRefusesUnknownVersion(t *testing.T) {
	d := Describe{Name: "test", Capabilities: []string{OpIssuesList}}
	res := serve(d, nil, Request{V: 99, ID: 1, Op: OpDescribe})
	if res.OK || !strings.Contains(res.Error, "version 99") {
		t.Fatalf("version mismatch must be refused, not guessed: %+v", res)
	}
}
