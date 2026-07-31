package host

// Reconcile's contract: every liveness signal read at once, and an
// answer that never claims more than the signals support.

import (
	"crypto/ed25519"
	"encoding/json"
	"strings"
	"testing"
	"time"

	edgev1 "github.com/incantery/rook/gen/rook/edge/v1"
	"github.com/incantery/rook/internal/edgesign"
)

func reconcileCmd(t *testing.T, priv ed25519.PrivateKey, id, run, session string) *edgev1.EdgeCommand {
	t.Helper()
	return edgeCmd(t, priv, id, run, "reconcile_session",
		&edgev1.ReconcileSession{SessionId: session}, func(c *edgev1.EdgeCommand) {
			c.ResourceType, c.ResourceId = "agent_session", session
		})
}

type reconcileReport struct {
	SessionID  string `json:"sessionId"`
	Worktree   string `json:"worktree"`
	State      string `json:"state"`
	Summary    string `json:"summary"`
	Window     bool   `json:"window"`
	Claimed    bool   `json:"claimed"`
	AgentAlive bool   `json:"agentAlive"`
	Note       string `json:"note"`
	Transcript struct {
		State         string `json:"state"`
		SilentSeconds int    `json:"silentSeconds"`
		Tool          string `json:"tool"`
		Interactive   bool   `json:"interactive"`
		Ask           string `json:"ask"`
	} `json:"transcript"`
}

func decodeReconcile(t *testing.T, result string) reconcileReport {
	t.Helper()
	var r reconcileReport
	if err := json.Unmarshal([]byte(result), &r); err != nil {
		t.Fatalf("report %s: %v", result, err)
	}
	return r
}

// lastAgentKind is what the device most recently told the cloud.
func lastAgentKind(t *testing.T, h *Host) string {
	t.Helper()
	kind := ""
	for _, ev := range journaledEvents(t, h) {
		if ev.Type == eventTypeAgentEvent {
			kind = agentPayload(t, ev).Kind
		}
	}
	return kind
}

func TestEdgeReconcileSession(t *testing.T) {
	h, devKey := edgeAgentHost(t)
	pub, priv, err := edgesign.NewKey()
	if err != nil {
		t.Fatal(err)
	}
	run := "wfr_reconcile_1"
	ses := startedSession(t, h, pub, devKey, priv, run)
	claim := "tsc_" + run
	n := 0
	reconcile := func() reconcileReport {
		t.Helper()
		n++
		status, result := h.edgeExecuteOne(reconcileCmd(t, priv,
			"cmd_rec_"+string(rune('a'+n)), run, ses.SessionID), pub, false)
		if status != "succeeded" {
			t.Fatalf("reconcile: %s %s", status, result)
		}
		return decodeReconcile(t, result)
	}

	// Claimed and working: the ordinary answer.
	h.aw.notify(claim, "starting up") // creates the agentwatch state
	h.aw.mu.Lock()                    // …then put it where the reducer would
	h.aw.states[claim].State = "working"
	h.aw.states[claim].Interactive = false
	h.aw.states[claim].LastEvent = time.Now()
	h.aw.mu.Unlock()
	got := reconcile()
	if !got.Window || !got.Claimed || !got.AgentAlive || got.State != "progress" {
		t.Fatalf("working session: %+v", got)
	}
	if got.Worktree != ses.Workspace || got.Transcript.State != "working" {
		t.Fatalf("report: %+v", got)
	}

	// Quiet is IdleUncertain, and §8.4 is explicit that it is NOT blocked
	// and NOT dead: the process is provably there, so it reconciles to
	// working — with the silence and its last tool as detail, not verdict.
	h.aw.mu.Lock()
	h.aw.states[claim].State = "quiet"
	h.aw.states[claim].Tool = "Bash"
	h.aw.states[claim].LastEvent = time.Now().Add(-4 * time.Minute)
	h.aw.mu.Unlock()
	got = reconcile()
	if got.State != "progress" || !strings.Contains(got.Summary, "quiet") {
		t.Fatalf("quiet session must reconcile to working: %+v", got)
	}
	if !strings.Contains(got.Summary, "Bash") || got.Transcript.SilentSeconds < 200 {
		t.Fatalf("the silence must be reported as detail: %+v", got)
	}

	// A pending interactive prompt is what it is.
	h.aw.mu.Lock()
	h.aw.states[claim].State = "needs_input"
	h.aw.states[claim].Interactive = true
	h.aw.states[claim].Ask = "may I run `rm -rf build`?"
	h.aw.states[claim].LastEvent = time.Now()
	h.aw.mu.Unlock()
	if got = reconcile(); got.State != "waiting_input" || !strings.Contains(got.Summary, "rm -rf build") {
		t.Fatalf("waiting session: %+v", got)
	}

	// The claim dies while the window lives — the agent left, the shell
	// stayed. §8.4's Disconnected, and the only place this device can say
	// that word from evidence rather than from a guess.
	h.bindMu.Lock()
	h.claimFg[claim] = 999999 // a pgrp that is not the tty's
	h.bindMu.Unlock()
	got = reconcile()
	if !got.Window || !got.Claimed || got.AgentAlive {
		t.Fatalf("a dead claim must still report the window: %+v", got)
	}
	if got.State != "disconnected" {
		t.Fatalf("dead claim: %+v", got)
	}
	if lastAgentKind(t, h) != "disconnected" {
		t.Fatalf("the correction must reach the cloud: %s", lastAgentKind(t, h))
	}

	// The window closing is the plainest fact of all.
	h.kill(ses.RookSession)
	waitFor(t, "the window to go", func() bool { return h.get(ses.RookSession) == nil })
	got = reconcile()
	if got.Window || got.State != "stopped" {
		t.Fatalf("closed window: %+v", got)
	}
}

// An unobservable session is not a stopped one. Without the claim hook
// this device cannot see inside a window, and reconcile says exactly
// that rather than inventing a verdict.
func TestEdgeReconcileUnobservable(t *testing.T) {
	h, devKey := edgeAgentHost(t)
	pub, priv, err := edgesign.NewKey()
	if err != nil {
		t.Fatal(err)
	}
	run := "wfr_reconcile_2"
	ses := startedSession(t, h, pub, devKey, priv, run)

	// No SessionStart hook ever ran: drop the claim the helper planted.
	h.bindMu.Lock()
	delete(h.claims, "tsc_"+run)
	h.bindMu.Unlock()

	before := len(journaledEvents(t, h))
	status, result := h.edgeExecuteOne(reconcileCmd(t, priv, "cmd_rec_u", run, ses.SessionID), pub, false)
	if status != "succeeded" {
		t.Fatalf("reconcile: %s %s", status, result)
	}
	got := decodeReconcile(t, result)
	if !got.Window || got.Claimed || got.State != "" {
		t.Fatalf("unobservable session: %+v", got)
	}
	if !strings.Contains(got.Note, "claude-plugin") {
		t.Fatalf("the report must say WHY it cannot see: %+v", got)
	}
	if after := len(journaledEvents(t, h)); after != before {
		t.Fatalf("nothing may be asserted about an unobservable session: %d -> %d", before, after)
	}

	// A session this device never started is not addressable at all.
	if status, result := h.edgeExecuteOne(reconcileCmd(t, priv, "cmd_rec_n", run, "ses_nobody"), pub, false); status != "rejected" ||
		!strings.Contains(result, "no session") {
		t.Fatalf("unknown session: %s %s", status, result)
	}
}
