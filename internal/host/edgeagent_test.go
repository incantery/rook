package host

// The agent adapter's contract: the identity the device mints, the
// at-most-once spawn behind it, and the ordering that lets a session's
// own facts mean anything to the cloud.

import (
	"crypto/ed25519"
	"encoding/json"
	"path/filepath"
	"strings"
	"testing"

	"google.golang.org/protobuf/proto"

	edgev1 "github.com/incantery/rook/gen/rook/edge/v1"
	"github.com/incantery/rook/internal/edge"
	"github.com/incantery/rook/internal/edgesign"
)

// edgeAgentHost is newEdgeHost plus everything registration would have
// published: a signing identity, a device id, and a non-nil client, so
// the sensors are live without a cloud to talk to.
func edgeAgentHost(t *testing.T) (h *Host, devKey ed25519.PrivateKey) {
	t.Helper()
	h, _ = newEdgeHost(t)
	_, devKey, err := edgesign.NewKey()
	if err != nil {
		t.Fatal(err)
	}
	h.edge = &edge.Client{}
	h.edgeKey, h.edgeDevice = devKey, "dev_t"
	return h, devKey
}

// runEdgeCommand puts a command through the real path — journal,
// execute, resolve, announce — because ordering is half of what this
// file is testing and edgeExecuteOne alone would skip it.
func runEdgeCommand(t *testing.T, h *Host, cloudKey ed25519.PublicKey, devKey ed25519.PrivateKey, cmd *edgev1.EdgeCommand) {
	t.Helper()
	raw, err := proto.Marshal(cmd)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := h.reg.journalEdgeCommand(cmd.CommandId, raw); err != nil {
		t.Fatal(err)
	}
	if err := h.edgeExecutePending(cloudKey, devKey); err != nil {
		t.Fatal(err)
	}
}

// journaledEvents decodes the whole unacked batch, in the order the
// cloud will apply it.
func journaledEvents(t *testing.T, h *Host) []*edgev1.EdgeEvent {
	t.Helper()
	_, raws, err := h.reg.unackedEdgeEvents()
	if err != nil {
		t.Fatal(err)
	}
	out := make([]*edgev1.EdgeEvent, 0, len(raws))
	for _, raw := range raws {
		var ev edgev1.EdgeEvent
		if err := proto.Unmarshal(raw, &ev); err != nil {
			t.Fatal(err)
		}
		out = append(out, &ev)
	}
	return out
}

// windowsIn counts live windows in a workspace — the assertion that
// matters for at-most-once spawning.
func windowsIn(h *Host, workspace string) int {
	h.mu.Lock()
	defer h.mu.Unlock()
	n := 0
	for _, s := range h.sessions {
		if s.info.Workspace == workspace {
			n++
		}
	}
	return n
}

func agentPayload(t *testing.T, ev *edgev1.EdgeEvent) *edgev1.AgentEvent {
	t.Helper()
	var ae edgev1.AgentEvent
	if err := ev.Payload.UnmarshalTo(&ae); err != nil {
		t.Fatalf("event %s is not an AgentEvent: %v", ev.EventId, err)
	}
	return &ae
}

// The refusals that come before anything is spawned. Both are the same
// rule — the device does not improvise — and both must be NAMED, so the
// run routes instead of parking.
func TestEdgeStartAgentSessionRefusals(t *testing.T) {
	h, _ := edgeAgentHost(t)
	pub, priv, err := edgesign.NewKey()
	if err != nil {
		t.Fatal(err)
	}
	run := "wfr_refuse_1"

	// No worktree: start_agent_session before create_worktree succeeded.
	noTree := edgeCmd(t, priv, "cmd_notree", run, "start_agent_session",
		&edgev1.StartAgentSession{AgentProfile: "implementer"}, nil)
	if status, result := h.edgeExecuteOne(noTree, pub, false); status != "rejected" ||
		!strings.Contains(result, "create_worktree") {
		t.Fatalf("no worktree: %s %s, want rejected naming create_worktree", status, result)
	}

	// A profile this device does not resolve. The refusal lists what it
	// does offer — a cloud pinning an unknown profile should be able to
	// see the mismatch without reading device source.
	create := edgeCmd(t, priv, "cmd_c", run, "create_worktree",
		&edgev1.CreateWorktree{Repository: "src", BaseRef: "main"}, nil)
	if status, result := h.edgeExecuteOne(create, pub, false); status != "succeeded" {
		t.Fatalf("create: %s %s", status, result)
	}
	badProfile := edgeCmd(t, priv, "cmd_prof", run, "start_agent_session",
		&edgev1.StartAgentSession{AgentProfile: "vibes"}, nil)
	status, result := h.edgeExecuteOne(badProfile, pub, false)
	if status != "rejected" || !strings.Contains(result, "vibes") ||
		!strings.Contains(result, "implementer") {
		t.Fatalf("unknown profile: %s %s, want rejected naming both", status, result)
	}

	// A refused start claims no identity: the cloud must be free to mint
	// the same command id again once the profile is fixed.
	if ses, err := h.reg.edgeSession(edgeSessionID("cmd_prof")); err != nil || ses != nil {
		t.Fatalf("a refused start must claim nothing: %+v %v", ses, err)
	}
}

// A spawn that fails IN PROCESS gives the identity back. The claim is
// there to stop a second agent reaching one worktree; when the device
// watched the first one not start, the claim is guarding nothing — and
// leaving it would make this command id unusable forever while telling
// the next delivery about a restart that never happened.
func TestEdgeStartAgentSessionSpawnFailure(t *testing.T) {
	h, _ := edgeAgentHost(t)
	pub, priv, err := edgesign.NewKey()
	if err != nil {
		t.Fatal(err)
	}
	run := "wfr_spawnfail"
	if status, result := h.edgeExecuteOne(edgeCmd(t, priv, "cmd_c", run, "create_worktree",
		&edgev1.CreateWorktree{Repository: "src", BaseRef: "main"}, nil), pub, false); status != "succeeded" {
		t.Fatalf("create: %s %s", status, result)
	}
	// No shell, no window — the one failure a device can be certain of.
	t.Setenv("SHELL", filepath.Join(t.TempDir(), "no-such-shell"))

	start := edgeCmd(t, priv, "cmd_sf", run, "start_agent_session",
		&edgev1.StartAgentSession{AgentProfile: "implementer"}, nil)
	status, result := h.edgeExecuteOne(start, pub, false)
	if status != "failed" || !strings.Contains(result, "could not start a window") {
		t.Fatalf("spawn failure: %s %s", status, result)
	}
	if ses, err := h.reg.edgeSession(edgeSessionID("cmd_sf")); err != nil || ses != nil {
		t.Fatalf("a start that never started must claim nothing: %+v %v", ses, err)
	}
	if n := windowsIn(h, edgeWorkspaceName(run)); n != 0 {
		t.Fatalf("windows after a failed spawn: %d", n)
	}

	// A redelivery tells the same true story rather than inventing a
	// restart — and is free to succeed once the machine is well again.
	status, result = h.edgeExecuteOne(start, pub, false)
	if status != "failed" || strings.Contains(result, "restart") {
		t.Fatalf("redelivered: %s %s, want the same honest failure", status, result)
	}
}

// The whole session lifecycle on the real path: the receipt introduces
// the identity, `started` follows it in sequence, the sensors report in
// the cloud's vocabulary, and a redelivered start never spawns twice.
func TestEdgeAgentSessionLifecycle(t *testing.T) {
	h, devKey := edgeAgentHost(t)
	pub, priv, err := edgesign.NewKey()
	if err != nil {
		t.Fatal(err)
	}
	run := "wfr_agent_1"
	name := edgeWorkspaceName(run)

	runEdgeCommand(t, h, pub, devKey, edgeCmd(t, priv, "cmd_create", run, "create_worktree",
		&edgev1.CreateWorktree{Repository: "src", BaseRef: "main"}, nil))
	start := edgeCmd(t, priv, "cmd_start", run, "start_agent_session",
		&edgev1.StartAgentSession{AgentProfile: "implementer"}, nil)
	runEdgeCommand(t, h, pub, devKey, start)

	sessionID := edgeSessionID("cmd_start")
	ses, err := h.reg.edgeSession(sessionID)
	if err != nil || ses == nil {
		t.Fatalf("the session must be journaled: %+v %v", ses, err)
	}
	if ses.Workspace != name || ses.Profile != "implementer" || ses.RookSession == "" {
		t.Fatalf("binding: %+v", ses)
	}
	if h.get(ses.RookSession) == nil {
		t.Fatalf("the window %s must exist", ses.RookSession)
	}

	// Ordering: create's receipt, start's receipt, THEN started. The
	// cloud refuses events about a session no receipt introduced, and it
	// applies the batch in sequence order — so this order is the whole
	// reason `started` is not emitted inside the actuator.
	events := journaledEvents(t, h)
	if len(events) != 3 {
		t.Fatalf("events: %d, want create receipt + start receipt + started", len(events))
	}
	if events[0].Type != eventTypeCommandResult || events[1].Type != eventTypeCommandResult {
		t.Fatalf("receipts: %s %s", events[0].Type, events[1].Type)
	}
	if events[2].Type != eventTypeAgentEvent {
		t.Fatalf("third event: %s, want an agent event", events[2].Type)
	}
	for i, ev := range events {
		if ev.DeviceSequence != uint64(i+1) {
			t.Fatalf("event %d took sequence %d", i, ev.DeviceSequence)
		}
	}
	var receipt struct {
		SessionID string `json:"sessionId"`
		Provider  string `json:"provider"`
		Worktree  string `json:"worktree"`
	}
	var res edgev1.CommandResult
	if err := events[1].Payload.UnmarshalTo(&res); err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(res.ResultJson, &receipt); err != nil {
		t.Fatal(err)
	}
	if receipt.SessionID != sessionID || receipt.Provider != edgeProvider || receipt.Worktree != name {
		t.Fatalf("receipt: %+v", receipt)
	}
	if ae := agentPayload(t, events[2]); ae.Kind != "started" || ae.SessionId != sessionID {
		t.Fatalf("started event: %+v", ae)
	}
	if events[2].CommandId != "cmd_start" {
		t.Fatalf("causation: %q, want the start command", events[2].CommandId)
	}
	if !edgesign.VerifyEvent(devKey.Public().(ed25519.PublicKey), events[2]) {
		t.Fatal("a session's own event must carry a verifying device signature")
	}

	// Redelivery: the same receipt, and crucially NO second window in the
	// worktree. Two agents loose in one tree is the failure the journal
	// row exists to prevent.
	before := windowsIn(h, name)
	runEdgeCommand(t, h, pub, devKey, start)
	if after := windowsIn(h, name); after != before {
		t.Fatalf("windows in %s: %d -> %d, a redelivered start must spawn nothing", name, before, after)
	}
	if got := journaledEvents(t, h); len(got) != 3 {
		t.Fatalf("events after redelivery: %d, want the original 3", len(got))
	}

	// The sensors, in the cloud's vocabulary. A kind the cloud already
	// holds is not news — otherwise every assistant record would mint an
	// event no step can act on.
	h.edgeEmitAgent(ses, "progress", "working", nil)
	h.edgeEmitAgent(ses, "progress", "still working", nil)
	events = journaledEvents(t, h)
	if len(events) != 4 {
		t.Fatalf("events: %d, want one progress for two identical observations", len(events))
	}
	if ae := agentPayload(t, events[3]); ae.Kind != "progress" || ae.Summary != "working" {
		t.Fatalf("progress: %+v", ae)
	}

	// A turn ending is a CLAIM, and it is news after progress.
	h.edgeEmitAgent(ses, "completion_claimed", "the change is ready", nil)
	events = journaledEvents(t, h)
	if len(events) != 5 {
		t.Fatalf("events: %d, want the claim", len(events))
	}
	if ae := agentPayload(t, events[4]); ae.Kind != "completion_claimed" {
		t.Fatalf("claim: %+v", ae)
	}

	// The window dying is the device's own observation, and it needs no
	// transcript to state.
	h.kill(ses.RookSession)
	waitFor(t, "the closed window to report stopped", func() bool {
		for _, ev := range journaledEvents(t, h) {
			if ev.Type == eventTypeAgentEvent && agentPayload(t, ev).Kind == "stopped" {
				return true
			}
		}
		return false
	})
}

// A crash between the identity claim and the spawn is the one scar this
// op can carry. Reporting it as a failure is the point: a phantom
// session the run could wait on forever is the worse answer, and
// spawning now would race whatever the lost attempt did.
func TestEdgeAgentSessionLostBeforeSpawn(t *testing.T) {
	h, _ := edgeAgentHost(t)
	pub, priv, err := edgesign.NewKey()
	if err != nil {
		t.Fatal(err)
	}
	run := "wfr_agent_scar"
	name := edgeWorkspaceName(run)
	if status, result := h.edgeExecuteOne(edgeCmd(t, priv, "cmd_c", run, "create_worktree",
		&edgev1.CreateWorktree{Repository: "src", BaseRef: "main"}, nil), pub, false); status != "succeeded" {
		t.Fatalf("create: %s %s", status, result)
	}

	// The crash: the identity was claimed, the window never came up.
	sessionID := edgeSessionID("cmd_scar")
	if fresh, err := h.reg.claimEdgeSession(edgeAgentSession{
		SessionID: sessionID, CommandID: "cmd_scar", Workspace: name, Profile: "implementer",
	}); err != nil || !fresh {
		t.Fatalf("claim: %v %v", fresh, err)
	}

	start := edgeCmd(t, priv, "cmd_scar", run, "start_agent_session",
		&edgev1.StartAgentSession{AgentProfile: "implementer"}, nil)
	status, result := h.edgeExecuteOne(start, pub, false)
	if status != "failed" || !strings.Contains(result, "restart") {
		t.Fatalf("lost session: %s %s, want failed naming the restart", status, result)
	}
	if windowsIn(h, name) != 0 {
		t.Fatal("a lost session must not be re-spawned")
	}
	// A failed start introduces nothing, so nothing may be reported about
	// it — the announcement gate is what enforces that.
	h.edgeAnnounceSession(start, status, result)
	if evs := journaledEvents(t, h); len(evs) != 0 {
		t.Fatalf("a failed start must announce nothing: %d events", len(evs))
	}
}

// startedSession runs create + start and hands back the binding, with a
// live claim standing in for the SessionStart hook the real coder would
// have fired. No claimFg is recorded, so claimAliveLocked fails open —
// the same way it does for a claim made before that check existed.
func startedSession(t *testing.T, h *Host, cloudKey ed25519.PublicKey, devKey, priv ed25519.PrivateKey, run string) *edgeAgentSession {
	t.Helper()
	runEdgeCommand(t, h, cloudKey, devKey, edgeCmd(t, priv, "cmd_"+run+"_create", run, "create_worktree",
		&edgev1.CreateWorktree{Repository: "src", BaseRef: "main"}, nil))
	runEdgeCommand(t, h, cloudKey, devKey, edgeCmd(t, priv, "cmd_"+run+"_start", run, "start_agent_session",
		&edgev1.StartAgentSession{AgentProfile: "implementer"}, nil))
	ses, err := h.reg.edgeSession(edgeSessionID("cmd_" + run + "_start"))
	if err != nil || ses == nil || ses.RookSession == "" {
		t.Fatalf("session: %+v %v", ses, err)
	}
	h.bindMu.Lock()
	h.claims["tsc_"+run] = ses.RookSession
	h.bindMu.Unlock()
	return ses
}

// inputCmd builds a send_agent_input command, which the cloud addresses
// to the SESSION rather than to the worktree.
func inputCmd(t *testing.T, priv ed25519.PrivateKey, id, run, session, text string) *edgev1.EdgeCommand {
	t.Helper()
	return edgeCmd(t, priv, id, run, "send_agent_input",
		&edgev1.SendAgentInput{SessionId: session, Input: text}, func(c *edgev1.EdgeCommand) {
			c.ResourceType, c.ResourceId = "agent_session", session
		})
}

// Typing at a live agent: it lands, and every way it could land at the
// WRONG thing is refused by name instead.
func TestEdgeSendAgentInput(t *testing.T) {
	h, devKey := edgeAgentHost(t)
	pub, priv, err := edgesign.NewKey()
	if err != nil {
		t.Fatal(err)
	}
	run := "wfr_input_1"
	ses := startedSession(t, h, pub, devKey, priv, run)

	var typed []string
	h.typeLineFn = func(s *session, line string) { typed = append(typed, line) }

	// The happy path: the supervisor's words reach the agent.
	send := inputCmd(t, priv, "cmd_send_1", run, ses.SessionID, "  precedence is last-wins  ")
	status, result := h.edgeExecuteOne(send, pub, false)
	if status != "succeeded" || !strings.Contains(result, `"delivered":true`) {
		t.Fatalf("send: %s %s", status, result)
	}
	if len(typed) != 1 || typed[0] != "precedence is last-wins" {
		t.Fatalf("typed: %q, want the trimmed input exactly once", typed)
	}

	// A restart mid-delivery must not type again: two deliveries are two
	// messages, and the run is told so rather than left to guess.
	status, result = h.edgeExecuteOne(inputCmd(t, priv, "cmd_send_2", run, ses.SessionID, "again"), pub, true)
	if status != "failed" || !strings.Contains(result, "not typed again") {
		t.Fatalf("reconciled send: %s %s", status, result)
	}
	if len(typed) != 1 {
		t.Fatalf("a reconciled delivery must type nothing: %q", typed)
	}

	// Nothing to say is not a delivery.
	if status, _ := h.edgeExecuteOne(inputCmd(t, priv, "cmd_send_3", run, ses.SessionID, "   "), pub, false); status != "rejected" {
		t.Fatalf("empty input: %s, want rejected", status)
	}

	// An interactive prompt wants a selection. rook refuses to type text
	// at those locally; a remote caller gets the same answer.
	h.aw.notify("tsc_"+run, "Claude needs permission to run `rm -rf build`")
	status, result = h.edgeExecuteOne(inputCmd(t, priv, "cmd_send_4", run, ses.SessionID, "yes"), pub, false)
	if status != "failed" || !strings.Contains(result, "selection") {
		t.Fatalf("interactive prompt: %s %s", status, result)
	}
	if len(typed) != 1 {
		t.Fatalf("nothing may be typed at a picker: %q", typed)
	}

	// A session this device never started is not addressable.
	if status, result := h.edgeExecuteOne(inputCmd(t, priv, "cmd_send_5", run, "ses_nobody", "hello"), pub, false); status != "rejected" ||
		!strings.Contains(result, "no session") {
		t.Fatalf("unknown session: %s %s", status, result)
	}

	// A window whose claim died is running something else now — a shell,
	// an editor. Typing there is not delivery.
	h.bindMu.Lock()
	delete(h.claims, "tsc_"+run)
	h.bindMu.Unlock()
	status, result = h.edgeExecuteOne(inputCmd(t, priv, "cmd_send_6", run, ses.SessionID, "hello"), pub, false)
	if status != "rejected" || !strings.Contains(result, "no longer running the agent") {
		t.Fatalf("dead claim: %s %s", status, result)
	}
	if len(typed) != 1 {
		t.Fatalf("nothing may be typed at an unclaimed window: %q", typed)
	}
}

// Interrupting ends the session, and reports something the device can
// actually observe: the window is gone, and `stopped` comes off that
// death rather than off this intent.
func TestEdgeInterruptAgentSession(t *testing.T) {
	h, devKey := edgeAgentHost(t)
	pub, priv, err := edgesign.NewKey()
	if err != nil {
		t.Fatal(err)
	}
	run := "wfr_interrupt_1"
	ses := startedSession(t, h, pub, devKey, priv, run)
	window := ses.RookSession

	stopCmd := func(id, session string) *edgev1.EdgeCommand {
		return edgeCmd(t, priv, id, run, "interrupt_agent_session",
			&edgev1.InterruptAgentSession{SessionId: session}, func(c *edgev1.EdgeCommand) {
				c.ResourceType, c.ResourceId = "agent_session", session
			})
	}

	stop := stopCmd("cmd_stop_1", ses.SessionID)
	status, result := h.edgeExecuteOne(stop, pub, false)
	if status != "succeeded" || !strings.Contains(result, `"stopped":true`) {
		t.Fatalf("interrupt: %s %s", status, result)
	}
	waitFor(t, "the interrupted window to be gone", func() bool { return h.get(window) == nil })
	waitFor(t, "the interrupted session to report stopped", func() bool {
		for _, ev := range journaledEvents(t, h) {
			if ev.Type == eventTypeAgentEvent && agentPayload(t, ev).Kind == "stopped" {
				return true
			}
		}
		return false
	})

	// Convergence: the contract is "this session is not running", and a
	// session already gone satisfies it.
	if status, result := h.edgeExecuteOne(stop, pub, false); status != "succeeded" ||
		!strings.Contains(result, "already gone") {
		t.Fatalf("re-interrupt: %s %s", status, result)
	}
	if status, result := h.edgeExecuteOne(stopCmd("cmd_stop_2", "ses_nobody"), pub, false); status != "rejected" ||
		!strings.Contains(result, "no session") {
		t.Fatalf("unknown session: %s %s", status, result)
	}
}

// An event about a session the cloud never saw start is refused at the
// gateway. The device declines to send it in the first place.
func TestEdgeAgentEventNeedsAncestry(t *testing.T) {
	h, _ := edgeAgentHost(t)
	if _, err := h.reg.claimEdgeSession(edgeAgentSession{
		SessionID: "ses_quiet", CommandID: "cmd_quiet", Workspace: "ws",
	}); err != nil {
		t.Fatal(err)
	}
	ses, err := h.reg.edgeSession("ses_quiet")
	if err != nil || ses == nil {
		t.Fatalf("session: %+v %v", ses, err)
	}
	h.edgeEmitAgent(ses, "progress", "too early", nil)
	if evs := journaledEvents(t, h); len(evs) != 0 {
		t.Fatalf("an unannounced session must report nothing: %d events", len(evs))
	}
}
