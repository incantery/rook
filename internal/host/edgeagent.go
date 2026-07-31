package host

// The agent half of the edge protocol: a cloud-coordinated run gets a
// REAL claude on this machine, and the session's own word gets back.
//
// Two directions, and they are not symmetric.
//
// Down, three ops. start_agent_session: the cloud names a worktree and a
// PROFILE — never a prompt (§11.2). The device owns the resolution, the
// way handleWorkspaceSpawn owns its presets: a closed set of host-built
// prompts, and an unknown name is refused by name. What actually starts
// is a pty running the coder CLI interactively — ADR 0004, TUI only, no
// `-p` and no stream-json. The identity the cloud will use for the rest
// of the session's life is minted HERE and carried out in the receipt.
// send_agent_input types at that session; interrupt_agent_session ends
// it. Those two reach into a RUNNING agent, which is why they carry
// their own capability and their own refusals. reconcile_session reaches
// into nothing — it only looks, and reports what it saw.
//
// Up: agent events. The device observes and reports; it never asks the
// cloud what state to be in. The sensors are the ones rook already
// trusts — the transcript reducer (agentwatch.go) and pty liveness — and
// the vocabulary is the cloud's, which is what keeps this file a
// translation rather than an interpretation:
//
//	started            the window exists and the coder was typed at it
//	progress           the session went back to work
//	waiting_input      an interactive prompt is up (permission, picker)
//	completion_claimed a turn ended — a CLAIM, which verification upholds
//	stopped            the window is gone
//	disconnected       the agent left a window that is still up
//
// The last one is the odd one out: it comes from asking rather than from
// watching, because "the process I was watching is no longer there" is
// not something a transcript can say. It is reconcile's to report.
//
// One kind is deliberately NOT emitted. `blocked` wants a structured "I
// need a decision from a human", which on this device means an ask — and
// an ask needs an attached app to render it (ask.go), which a
// cloud-started session does not have. It arrives with its own slice;
// inventing it from a guess would put words in the session's mouth.
//
// Ordering is load-bearing. The cloud refuses events about a session no
// receipt introduced, and events are submitted in sequence order — so
// `started` cannot be emitted inside the actuator, where it would take a
// sequence BELOW the receipt that introduces it. It is emitted after the
// command resolves, and the session's `kind` column is the gate: until
// the announcement lands, every observed fact is dropped rather than
// sent ahead of its own ancestry.

import (
	"encoding/json"
	"fmt"
	"log"
	"slices"
	"strings"
	"time"

	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/types/known/anypb"
	"google.golang.org/protobuf/types/known/timestamppb"

	edgev1 "github.com/incantery/rook/gen/rook/edge/v1"
	"github.com/incantery/rook/internal/edgesign"
)

const eventTypeAgentEvent = "com.rook.edge.agent_event.v1"

// edgeProvider names what actually runs, for the receipt. The cloud
// stores it verbatim; it is how a later API-billed adapter is told apart
// from this one without re-reading the code.
const edgeProvider = "claude-code-tui"

// edgeAgentProfiles is this device's resolved-profile table (§8.5, in
// its first and smallest form): a profile name becomes the prompt the
// coder is started on. Host-built and closed, for the same reason
// spawntask's presets are — a name the device does not know is a
// refusal, never a prompt the cloud got to write.
//
// Every prompt ends at the working tree on purpose. Publication is out
// of the first slice (§19.3), and the boundary is stated to the agent
// rather than assumed of it.
var edgeAgentProfiles = map[string]string{
	"investigator": "You are investigating, not changing anything. Read the code in this " +
		"worktree and work out what is actually going on. Do not edit, commit, push, or " +
		"open a pull request. Finish by writing your findings to .rook/investigation.md: " +
		"what you found, the evidence for it, and what you would change.",
	"implementer": "Make the change this worktree was created for. Keep it to ONE reviewable " +
		"diff, and run the project's own build and tests before you say you are done. " +
		"Commit nothing, push nothing, and open no pull request — leave the change in the " +
		"working tree for review.",
	"reviewer": "You are reviewing, not changing anything. Read the uncommitted change in " +
		"this worktree (`git diff`) and judge it: does it do what it claims, does it break " +
		"anything, is it tested. Do not edit, commit, or push. Finish by writing your " +
		"verdict and reasoning to .rook/review.md.",
}

// edgeSessionID mints the identity the cloud will address this session
// by. Derived from the command, so a redelivered start converges on the
// same name instead of introducing a second session for one intent.
func edgeSessionID(commandID string) string {
	return "ses_" + strings.TrimPrefix(commandID, "cmd_")
}

// edgeStartAgentSession is the actuator. Its convergence rule is the
// strict one: the journal row is a CLAIM on the identity, taken before
// the spawn, and once taken this command never spawns again. Two agents
// loose in one worktree is the failure this whole file exists to avoid —
// worse than any stall, and unlike a stall it is not visible from the
// cloud.
func (h *Host) edgeStartAgentSession(cmd *edgev1.EdgeCommand, p *edgev1.StartAgentSession) (string, string) {
	prompt, ok := edgeAgentProfiles[p.AgentProfile]
	if !ok {
		return "rejected", edgeReason(fmt.Sprintf("no agent profile named %q on this device (offered: %s)",
			p.AgentProfile, strings.Join(sortedKeys(edgeAgentProfiles), ", ")))
	}
	// The worktree is derived from the run, exactly as create and cleanup
	// derive it — the device does not keep a lookup table, so the three
	// ops cannot disagree about which tree a run owns.
	name := edgeWorkspaceName(cmd.WorkflowRunId)
	ws := h.reg.get(name)
	if ws == nil || ws.Root == "" {
		return "rejected", edgeReason(fmt.Sprintf(
			"no worktree for run %s on this device — create_worktree has not succeeded here", cmd.WorkflowRunId))
	}

	sessionID := edgeSessionID(cmd.CommandId)
	receipt := func(rookSession string) string {
		data, _ := json.Marshal(map[string]string{
			"sessionId": sessionID, "provider": edgeProvider,
			"worktree": name, "rookSession": rookSession, "profile": p.AgentProfile,
		})
		return string(data)
	}

	fresh, err := h.reg.claimEdgeSession(edgeAgentSession{
		SessionID: sessionID, CommandID: cmd.CommandId, Workspace: name,
		Profile: p.AgentProfile, Fence: cmd.FencingToken,
	})
	if err != nil {
		return "rejected", edgeReason("journal unavailable: " + err.Error())
	}
	if !fresh {
		// The identity is already ours. Either this is a plain redelivery,
		// or a restart caught the command mid-execution.
		prior, err := h.reg.edgeSession(sessionID)
		if err != nil || prior == nil {
			return "rejected", edgeReason("journal unavailable")
		}
		if prior.RookSession == "" {
			// The claim landed and the spawn did not — the one crash scar
			// this op can have. Report it as the failure it is: a phantom
			// session the run could wait on forever is the worse answer,
			// and spawning now would race whatever the lost attempt did.
			return "failed", edgeReason("session was lost to a restart before its window started")
		}
		// It started. Whether the window is still up is the session's own
		// story to tell, through its own events — the receipt reports what
		// the receipt reported.
		return "succeeded", receipt(prior.RookSession)
	}

	s, err := h.spawnTask(name, prompt)
	if err != nil {
		// Nothing started, and this device watched it not start — so the
		// claim goes back rather than standing guard over a session that
		// does not exist. A retry of this very command may then spawn, which
		// is what convergence means when the effect provably did not happen.
		if derr := h.reg.dropEdgeSession(sessionID); derr != nil {
			log.Printf("edge: could not release the claim on %s: %v", sessionID, derr)
		}
		return "failed", edgeReason("could not start a window in " + name + ": " + err.Error())
	}
	if err := h.reg.bindEdgeSession(sessionID, s.info.ID); err != nil {
		// The window is up and unreachable by the sensors. Kill it rather
		// than leave an unattributable agent spending in a worktree.
		h.kill(s.info.ID)
		return "failed", edgeReason("journal unavailable after spawn: " + err.Error())
	}
	log.Printf("edge: session %s = window %s (%s in %s)", sessionID, s.info.ID, p.AgentProfile, name)
	return "succeeded", receipt(s.info.ID)
}

// edgeAnnounceSession emits `started` once the start receipt is durably
// journaled — the sequence AFTER the one that introduces the session.
// Called by the executor for every resolved command; anything that is
// not a successful start falls through untouched.
func (h *Host) edgeAnnounceSession(cmd *edgev1.EdgeCommand, status, result string) {
	if status != "succeeded" || !cmd.Payload.MessageIs(&edgev1.StartAgentSession{}) {
		return
	}
	var r struct {
		SessionID string `json:"sessionId"`
		Profile   string `json:"profile"`
		Worktree  string `json:"worktree"`
	}
	if json.Unmarshal([]byte(result), &r) != nil || r.SessionID == "" {
		return
	}
	first, err := h.reg.announceEdgeSession(r.SessionID)
	if err != nil {
		log.Printf("edge: announce %s: %v", r.SessionID, err)
		return
	}
	if !first {
		return // a redelivered start: the cloud has heard this session start
	}
	ses, err := h.reg.edgeSession(r.SessionID)
	if err != nil || ses == nil {
		return
	}
	h.edgeEmitAgent(ses, "started", fmt.Sprintf("%s session up in %s", r.Profile, r.Worktree), nil)
}

// edgeSendAgentInput types the supervisor's words at a live agent. It is
// the only actuator here that puts keystrokes in front of a running
// process, so it asks more questions than the others before it acts, and
// every refusal is a refusal to type at the wrong thing:
//
//   - a session this device never started is not addressable;
//   - a window that closed cannot be typed at;
//   - a window whose CLAIM is dead is running something else now — a
//     shell, an editor — and typing there is not delivery, it is
//     keystrokes into whatever is there (see claimAliveLocked);
//   - an agent sitting on an interactive prompt wants a SELECTION, not a
//     line of text. rook already refuses to type at those locally; a
//     remote caller gets the same answer for the same reason.
//
// And it is the one op here that cannot converge: typing twice is two
// messages, not one. A reconciled row therefore reports the uncertainty
// instead of repeating the delivery — a supervisor deciding to send
// again is a decision, and a device that re-typed on every restart would
// be making that decision silently, and always.
func (h *Host) edgeSendAgentInput(cmd *edgev1.EdgeCommand, p *edgev1.SendAgentInput, reconciling bool) (string, string) {
	input := strings.TrimSpace(p.Input)
	if input == "" {
		return "rejected", edgeReason("no input to deliver")
	}
	ses, s, claim, reason := h.edgeLiveAgent(p.SessionId)
	if reason != "" {
		return "rejected", edgeReason(reason)
	}
	if reconciling {
		return "failed", edgeReason(
			"a restart interrupted this delivery — it may already have reached the agent, so it was not typed again")
	}
	if st, _, ok := h.aw.context(claim); ok && st.State == "needs_input" && st.Interactive {
		return "failed", edgeReason(
			"the agent is on an interactive prompt and wants a selection, not typed text: " + edgeSummary(st.Ask))
	}
	h.typeLine(s, input)
	log.Printf("edge: session %s <- %d bytes of input", ses.SessionID, len(input))
	data, _ := json.Marshal(map[string]any{
		"sessionId": ses.SessionID, "delivered": true, "bytes": len(input),
	})
	return "succeeded", string(data)
}

// edgeInterruptAgentSession ends a session the run has given up on.
//
// It ends it by closing the window, which is a choice worth stating. The
// gentler reading of "interrupt" — an ESC at the TUI to abandon the
// current turn — would leave a session the Cloud has recorded as stopped
// with an agent still in it, still spending. Unattributed spend is the
// thing this file refuses everywhere else, so it will not introduce it
// here. The window's death, unlike a keystroke's effect, is something
// the device can observe and therefore state.
//
// The `stopped` event comes from that observation rather than from this
// intent: killing the window wakes the sensor in readPump's teardown,
// exactly as an ordinary `exit` would. Which of the two lands first does
// not matter — the session's ancestry is long since established, and
// receipt and event agree on the outcome either way.
func (h *Host) edgeInterruptAgentSession(cmd *edgev1.EdgeCommand, p *edgev1.InterruptAgentSession) (string, string) {
	ses, err := h.reg.edgeSession(p.SessionId)
	if err != nil {
		return "rejected", edgeReason("journal unavailable: " + err.Error())
	}
	if ses == nil {
		return "rejected", edgeReason("no session " + p.SessionId + " on this device")
	}
	// Convergence, and the reason this op needs no reconciliation flag:
	// the contract is "this session is not running", and a session already
	// gone satisfies it. Re-running lands on exactly the same answer.
	if ses.RookSession == "" || h.get(ses.RookSession) == nil {
		data, _ := json.Marshal(map[string]any{
			"sessionId": ses.SessionID, "stopped": true, "note": "the session was already gone",
		})
		return "succeeded", string(data)
	}
	h.kill(ses.RookSession)
	log.Printf("edge: session %s interrupted — window %s killed", ses.SessionID, ses.RookSession)
	data, _ := json.Marshal(map[string]any{
		"sessionId": ses.SessionID, "stopped": true, "rookSession": ses.RookSession,
	})
	return "succeeded", string(data)
}

// edgeReconcileSession answers "what is actually true about this session
// right now" — §11.4's rule that the Cloud does not assume a missing
// socket means a dead agent, run from the other end.
//
// It reaches into nothing. Every signal is one this device already keeps
// — the journal binding, the window, the claim's process group, the
// transcript reducer — and reconcile just reads all of them at once and
// says what they add up to. That is why it needs no capability of its
// own beyond "agent": looking is what "agent" already covers.
//
// The interesting case is quiet. §8.4 is explicit that IdleUncertain is
// NOT blocked: a silent agent may be thinking, running a long tool,
// waiting on a prompt nobody observed, or dead — and the transcript
// cannot tell those apart. So a quiet session whose process is provably
// still there reconciles to WORKING, which is both what the state
// machine prescribes (IdleUncertain --> Working: reconciled) and the
// only thing the evidence supports. The uncertainty does not vanish; it
// moves into the receipt, where a supervisor can read how long the
// silence has run and what tool started it.
//
// The receipt is deliberately fuller than the event. What crosses as a
// FACT stays inside the cloud's vocabulary; what a human might need to
// judge the session rides back as detail — minus the things cloud.go
// keeps home either way, which is why the foreground process becomes a
// boolean here rather than a name.
func (h *Host) edgeReconcileSession(cmd *edgev1.EdgeCommand, p *edgev1.ReconcileSession) (string, string) {
	ses, err := h.reg.edgeSession(p.SessionId)
	if err != nil {
		return "rejected", edgeReason("journal unavailable: " + err.Error())
	}
	if ses == nil {
		// Not addressable, and not a lie either way: this device has no
		// row, so it has nothing to reconcile against.
		return "rejected", edgeReason("no session " + p.SessionId + " on this device")
	}

	obs := map[string]any{
		"sessionId": ses.SessionID,
		"worktree":  ses.Workspace,
		"lastKind":  ses.Kind,
	}
	report := func(kind, summary string) (string, string) {
		obs["state"], obs["summary"] = kind, summary
		if kind != "" {
			h.edgeEmitAgent(ses, kind, summary, nil)
		}
		data, _ := json.Marshal(obs)
		log.Printf("edge: reconciled %s -> %s (%s)", ses.SessionID, kind, summary)
		return "succeeded", string(data)
	}

	s := h.get(ses.RookSession)
	obs["window"] = s != nil
	if s == nil {
		return report("stopped", "the session's window is gone")
	}

	claim, alive := h.claimOnWindow(s)
	obs["claimed"], obs["agentAlive"] = claim != "", alive
	switch {
	case claim == "":
		// The window is up and this device cannot see inside it: the
		// SessionStart hook never ran, so there is no claim to test. Report
		// the window honestly and assert NOTHING about the agent — an
		// unobservable session is not a stopped one.
		obs["note"] = "no agent claim on this window — is the rook claude-plugin installed?"
		return report("", "the window is up; this device cannot observe the agent in it")
	case !alive:
		// The claim's process group is no longer the tty's. The agent that
		// claimed this window is gone; the window moved on to a shell, or
		// an editor. §8.4's Disconnected, and the only place this device
		// can say that word from evidence.
		return report("disconnected", "the agent left its window — the claim's process is gone")
	}

	st, _, known := h.aw.context(claim)
	if !known {
		obs["note"] = "no transcript for the claimed agent yet"
		return report("progress", "the agent's process is alive; nothing observed from it yet")
	}
	silent := time.Since(st.LastEvent).Round(time.Second)
	obs["transcript"] = map[string]any{
		"state": st.State, "silentSeconds": int(silent.Seconds()),
		"tool": st.Tool, "interactive": st.Interactive, "ask": edgeSummary(st.Ask),
	}
	switch st.State {
	case "needs_input":
		return report("waiting_input", st.Ask)
	case "quiet":
		// IdleUncertain, reconciled. The process is provably there, so the
		// session is working; the silence and its last tool are the detail,
		// not the verdict.
		s := fmt.Sprintf("alive but quiet for %s", silent)
		if st.Tool != "" {
			s += " since requesting " + st.Tool
		}
		return report("progress", s)
	default:
		return report("progress", "working")
	}
}

// edgeLiveAgent resolves a cloud session id to the window and the live
// claude claim on it. A non-empty reason is the refusal, phrased for
// whoever ends up reading the run's record rather than for this file.
func (h *Host) edgeLiveAgent(sessionID string) (*edgeAgentSession, *session, string, string) {
	ses, err := h.reg.edgeSession(sessionID)
	if err != nil {
		return nil, nil, "", "journal unavailable: " + err.Error()
	}
	if ses == nil {
		return nil, nil, "", "no session " + sessionID + " on this device"
	}
	s := h.get(ses.RookSession)
	if s == nil {
		return nil, nil, "", "session " + sessionID + " has no window — it has stopped"
	}
	claim := h.agentClaimOn(s)
	if claim == "" {
		return nil, nil, "", "the window for " + sessionID +
			" is no longer running the agent that claimed it"
	}
	return ses, s, claim, ""
}

// ---------------------------------------------------------------------
// The sensors' side.

// edgeAgentSignal is the transcript reducer's bridge: agentwatch names a
// moment in the CLAUDE session, and this resolves it to the window, the
// window to a cloud session, and only then reports. A signal from a
// session no cloud run started stops here, which is the common case —
// most claudes on this machine are the user's own.
func (h *Host) edgeAgentSignal(agentSession, kind, summary string) {
	if h.edge == nil {
		return
	}
	// Correlate now rather than wait: a picker or a permission prompt is
	// a ROUTABLE fact, and dropping the first one because the claim had
	// not landed yet would park a run on a session that is, in fact,
	// asking. The turn-end path already pays this cost every turn.
	s := h.pairedSession(agentSession, true)
	if s == nil {
		return
	}
	ses, err := h.reg.edgeSessionForWindow(s.info.ID)
	if err != nil || ses == nil {
		return
	}
	h.edgeEmitAgent(ses, kind, summary, nil)
}

// edgeWindowClosed reports a window's death. The shell exiting is the
// device's own observation and needs no transcript, which is what makes
// it the one liveness fact this adapter can state without hedging.
func (h *Host) edgeWindowClosed(rookSession string) {
	if h.edge == nil {
		return
	}
	ses, err := h.reg.edgeSessionForWindow(rookSession)
	if err != nil || ses == nil {
		return
	}
	h.edgeEmitAgent(ses, "stopped", "the session's window exited", nil)
}

// edgeEmitAgent journals one signed session fact. It never blocks on the
// network: the sync loop's submit step carries it, and the nudge only
// spares it the poll interval. A kind the cloud already holds is dropped
// here rather than sent — see reportEdgeSessionKind.
func (h *Host) edgeEmitAgent(ses *edgeAgentSession, kind, summary string, detail []byte) {
	if ses.Kind == "" && kind != "started" {
		return // not announced yet: an event ahead of its own ancestry
	}
	if ses.Released {
		// The run let go of this session (§6.6). The window may still be
		// running — narrating it is what ended, not the agent.
		return
	}
	// artifact_published is not a session STATE — it says what the
	// session produced, not how it is doing — so it neither moves the
	// kind column nor is deduped by it. Its convergence is its
	// content-addressed identity, enforced before it gets here
	// (claimEdgeArtifact).
	if state := kind != "artifact_published"; state {
		news, err := h.reg.reportEdgeSessionKind(ses.SessionID, kind)
		if err != nil {
			log.Printf("edge: session %s -> %s: %v", ses.SessionID, kind, err)
			return
		}
		if !news && kind != "started" {
			return
		}
	}
	payload, err := anypb.New(&edgev1.AgentEvent{
		SessionId: ses.SessionID,
		Kind:      kind,
		Summary:   edgeSummary(summary),
		DataJson:  detail,
	})
	if err != nil {
		return
	}

	h.edgeSeqMu.Lock()
	defer h.edgeSeqMu.Unlock()
	if h.edgeKey == nil {
		return // registration has not completed; nothing can be signed yet
	}
	seq, err := h.reg.edgeMaxSeq()
	if err != nil {
		log.Printf("edge: session %s -> %s: %v", ses.SessionID, kind, err)
		return
	}
	seq++
	ev := &edgev1.EdgeEvent{
		// The sequence is allocated exactly once and never reused, which
		// makes it the one identity that cannot collide — and a
		// resubmission carries these very bytes, so the cloud dedupes on
		// the same name it first saw.
		EventId:        fmt.Sprintf("devevt_%s_%d", ses.SessionID, seq),
		DeviceId:       h.edgeDevice,
		DeviceSequence: seq,
		CommandId:      ses.CommandID, // causation: the start that made this session
		Type:           eventTypeAgentEvent,
		OccurredAt:     timestamppb.Now(),
		FencingToken:   ses.Fence,
		Payload:        payload,
	}
	edgesign.SignEvent(h.edgeKey, ev)
	raw, err := proto.Marshal(ev)
	if err != nil {
		return
	}
	if err := h.reg.appendEdgeEvent(seq, raw); err != nil {
		log.Printf("edge: journal session event %s: %v", ev.EventId, err)
		return
	}
	log.Printf("edge: session %s -> %s (seq %d)", ses.SessionID, kind, seq)
	select {
	case h.edgeNudge <- struct{}{}:
	default: // a pending nudge needs no second one
	}
}

// edgeSummary caps a presentation line. Terminal text stays presentation
// (ADR 0004): anything a workflow must ACT on belongs in a typed field,
// so there is no cost to being ruthless here.
func edgeSummary(s string) string {
	s = strings.Join(strings.Fields(s), " ")
	if r := []rune(s); len(r) > 240 {
		return string(r[:240]) + "…"
	}
	return s
}

func edgeReason(reason string) string {
	data, _ := json.Marshal(map[string]string{"reason": reason})
	return string(data)
}

func sortedKeys(m map[string]string) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	slices.Sort(out)
	return out
}
