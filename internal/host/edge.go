package host

// The edge client: this machine as a REAL device on rook-cloud's edge
// protocol ([cloud] edge = true). The loop is journal-shaped end to end:
//
//	sync    — pull pending commands, journal each by id, ack (an ack
//	          means "durably journaled", nothing more)
//	execute — for every unresolved journal row, run the §12.2/§13.5
//	          checklist (cloud signature, ledger payload digest, fencing
//	          era, expiry, approval grant, single-use), then the typed
//	          actuator; outcome + signed events + grant spend + fence
//	          raise land in ONE journal transaction
//	submit  — resubmit every unacked signed event until the cloud's
//	          cursor covers it
//
// Delivery is at-least-once and the journal makes the effect
// at-most-once; a crash between any two steps re-runs the step, and
// every actuator converges (create finds its tree, cleanup finds its
// absence, a started session refuses to start twice). What this device
// offers is worktree create/inspect/cleanup and starting an agent
// session in one — everything else is REJECTED by name.
//
// A session, once started, outlives the command that started it, and its
// own facts ride the same journal on the same sequence: that half lives
// in edgeagent.go.
//
// The unit of trust is the checklist, not the transport: a command that
// fails any check is resolved "rejected" without effect, which the run
// hears as a routed outcome instead of a hung step.

import (
	"context"
	"crypto/ed25519"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"runtime"
	"strings"
	"time"

	"connectrpc.com/connect"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/types/known/anypb"
	"google.golang.org/protobuf/types/known/timestamppb"

	edgev1 "github.com/incantery/rook/gen/rook/edge/v1"
	"github.com/incantery/rook/internal/config"
	"github.com/incantery/rook/internal/edge"
	"github.com/incantery/rook/internal/edgesign"
)

// edgeCapabilities is what this device honestly offers (§11.5). Ops
// outside it are rejected by name — capability growth is a code change
// here and a registration change on the wire, never an accident.
//
// They are separate on purpose, because they fail differently and a run
// should be able to tell before it routes: "worktree" is filesystem
// work; "agent" starts a session and reports on it; "agent_control"
// reaches back INTO a live one, the only capability here that puts
// keystrokes in front of a running agent and the only one whose effect
// cannot be re-run to converge; "verify" runs a named suite the USER
// configured, and is the only one whose absence is a matter of local
// config rather than of code (see edgeverify.go); "artifact" declares
// what a run produced without the bytes ever leaving (edgeartifact.go);
// "release" is §6.6 compensation — dropping a hold, which is a different
// authority from cleanup's and spans more than one resource type
// (edgerelease.go).
var edgeCapabilities = []string{"worktree", "agent", "agent_control", "verify", "artifact", "release"}

const eventTypeCommandResult = "com.rook.edge.command_result.v1"

// initEdge wires the edge client when the machine opted in. Called from
// New; refusing to run without a journal is the whole point.
func (h *Host) initEdge() {
	cfg := config.Load()
	if cfg.CloudURL == "" || !cfg.CloudEdge {
		return
	}
	c := edge.New(cfg.CloudURL, config.CloudToken())
	if c == nil {
		log.Printf("edge: [cloud] edge = true but no machine token — run `rookctl set-cloud-token`")
		return
	}
	if h.reg.db == nil {
		log.Printf("edge: refusing to run without a database — commands without a journal would be unauditable")
		return
	}
	h.edge = c
	h.edgeNudge = make(chan struct{}, 1)
	go h.runEdge(h.ctx)
}

// edgeDeviceKey loads the persistent device signing key, minting one on
// first run. A key that fails to persist is fatal for the edge client:
// registration commits this device to a public key, and a key that
// rotates on every restart breaks that commitment.
func edgeDeviceKey() (ed25519.PrivateKey, error) {
	if seed := config.EdgeSeed(); seed != "" {
		key, err := edgesign.DecodeSeed(seed)
		if err != nil {
			return nil, fmt.Errorf("stored edge seed: %w", err)
		}
		return key, nil
	}
	_, key, err := edgesign.NewKey()
	if err != nil {
		return nil, err
	}
	if err := config.SetEdgeSeed(edgesign.EncodeSeed(key)); err != nil {
		return nil, fmt.Errorf("persist edge seed: %w", err)
	}
	return key, nil
}

// runEdge is the device loop: register once (retrying — a laptop wakes
// up offline), then sync at the server's cadence with the wake stream
// cutting waits short. Errors log on the first failure after a success;
// an authentication refusal parks the loop for good, because a revoked
// token never fixes itself.
func (h *Host) runEdge(ctx context.Context) {
	key, err := edgeDeviceKey()
	if err != nil {
		log.Printf("edge: device key: %v — edge client disabled", err)
		return
	}
	hostname, _ := os.Hostname()

	var reg *edgev1.RegisterDeviceResponse
	for backoff := time.Second; ; backoff = min(backoff*2, 2*time.Minute) {
		rctx, cancel := context.WithTimeout(ctx, 20*time.Second)
		reg, err = h.edge.Register(rctx, hostname, runtime.GOOS, edgeCapabilities,
			key.Public().(ed25519.PublicKey))
		cancel()
		if err == nil {
			break
		}
		if connect.CodeOf(err) == connect.CodeUnauthenticated {
			log.Printf("edge: register: %v — token revoked? edge client parked", err)
			return
		}
		select {
		case <-ctx.Done():
			return
		case <-time.After(backoff):
		}
	}
	cloudKey := ed25519.PublicKey(reg.CloudPublicKey)
	log.Printf("edge: device %s registered (cloud signing: %v, capabilities: %s)",
		reg.DeviceId, len(cloudKey) > 0, strings.Join(edgeCapabilities, ","))

	// Publish the signing identity: until this lands, a session's sensors
	// have nothing to sign with and drop what they see. Nothing has been
	// started from the cloud yet at this point, so nothing is lost.
	h.edgeSeqMu.Lock()
	h.edgeKey, h.edgeDevice = key, reg.DeviceId
	h.edgeSeqMu.Unlock()

	wake := h.edgeNudge
	go h.edge.Watch(ctx, wake)

	failed := false
	for {
		poll, err := h.edgeSyncPass(ctx, cloudKey, key)
		switch {
		case connect.CodeOf(err) == connect.CodeUnauthenticated:
			log.Printf("edge: %v — token revoked? edge client parked", err)
			return
		case err != nil:
			if ctx.Err() != nil {
				return
			}
			if !failed {
				log.Printf("edge: sync pass: %v", err)
			}
			failed = true
		default:
			failed = false
		}
		select {
		case <-ctx.Done():
			return
		case <-time.After(time.Duration(max(poll, 1)) * time.Second):
		case <-wake:
		}
	}
}

// edgeSyncPass runs one full journal-shaped pass and returns the
// server's idle-poll hint.
func (h *Host) edgeSyncPass(ctx context.Context, cloudKey ed25519.PublicKey, devKey ed25519.PrivateKey) (uint32, error) {
	cursor, err := h.reg.edgeAckedCursor()
	if err != nil {
		return 0, err
	}
	sctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	sync, err := h.edge.RPC.SyncEdge(sctx, connect.NewRequest(&edgev1.SyncEdgeRequest{
		ProtocolVersion:     edge.ProtocolVersion,
		AckedDeviceSequence: cursor,
	}))
	cancel()
	if err != nil {
		return 0, fmt.Errorf("sync: %w", err)
	}
	poll := sync.Msg.PollIntervalSeconds

	// Journal, then ack: the ack's meaning IS "durably journaled".
	for _, cmd := range sync.Msg.Commands {
		raw, err := proto.Marshal(cmd)
		if err != nil {
			return poll, fmt.Errorf("marshal %s: %w", cmd.CommandId, err)
		}
		fresh, err := h.reg.journalEdgeCommand(cmd.CommandId, raw)
		if err != nil {
			return poll, fmt.Errorf("journal %s: %w", cmd.CommandId, err)
		}
		if fresh {
			log.Printf("edge: journaled %s (%s) for run %s", cmd.CommandId, cmd.Payload.TypeUrl, cmd.WorkflowRunId)
		}
		actx, cancel := context.WithTimeout(ctx, 20*time.Second)
		_, err = h.edge.RPC.AckCommand(actx, connect.NewRequest(&edgev1.AckCommandRequest{
			CommandId: cmd.CommandId,
		}))
		cancel()
		if err != nil {
			return poll, fmt.Errorf("ack %s: %w", cmd.CommandId, err)
		}
	}

	if err := h.edgeExecutePending(cloudKey, devKey); err != nil {
		return poll, err
	}
	return poll, h.edgeSubmitEvents(ctx)
}

// edgeExecutePending drains the journal's unresolved commands serially —
// one journal, one executor, mirroring the one-writer discipline the
// registry already lives by.
//
// A row found in 'executing' is a crash scar, and the executor tells the
// actuator so. Most actuators do not care: they converge, and re-running
// is how they finish. The ones that CANNOT converge — typing at a live
// agent is the standing example, because a second delivery is a second
// message, not the same one — use the flag to refuse rather than repeat.
func (h *Host) edgeExecutePending(cloudKey ed25519.PublicKey, devKey ed25519.PrivateKey) error {
	pending, err := h.reg.unresolvedEdgeCommands()
	if err != nil {
		return err
	}
	for _, row := range pending {
		var cmd edgev1.EdgeCommand
		if err := proto.Unmarshal(row.Command, &cmd); err != nil {
			// A journal row that no longer parses can never execute or be
			// reported — resolve it rejected so it stops haunting the loop.
			log.Printf("edge: journaled %s does not parse: %v", row.CommandID, err)
			if err := h.resolveEdge(&cmd, row.CommandID, "rejected",
				fmt.Sprintf(`{"reason":"journaled command does not parse: %v"}`, err), devKey); err != nil {
				return err
			}
			continue
		}
		reconciling := row.Phase == "executing"
		if reconciling {
			log.Printf("edge: reconciling %s after restart", row.CommandID)
		}
		status, result := h.edgeExecuteOne(&cmd, cloudKey, reconciling)
		if err := h.resolveEdge(&cmd, cmd.CommandId, status, result, devKey); err != nil {
			return err
		}
		log.Printf("edge: %s (%s) for run %s -> %s", cmd.CommandId, cmd.Payload.GetTypeUrl(), cmd.WorkflowRunId, status)
		// Only now may the session speak: the receipt that introduces it
		// holds the lower sequence, and the cloud applies them in order.
		h.edgeAnnounceSession(&cmd, status, result)
	}
	return nil
}

// edgeExecuteOne runs the checklist and, if every check holds, the
// typed actuator. The returned status uses the ledger vocabulary the
// cloud accepts from devices: succeeded | failed | rejected.
//
// reconciling says this row was already 'executing' when the pass began
// — see edgeExecutePending.
func (h *Host) edgeExecuteOne(cmd *edgev1.EdgeCommand, cloudKey ed25519.PublicKey, reconciling bool) (string, string) {
	if reason := h.refuseEdge(cmd, cloudKey); reason != "" {
		log.Printf("edge: refusing %s without executing: %s", cmd.CommandId, reason)
		data, _ := json.Marshal(map[string]string{"reason": reason})
		return "rejected", string(data)
	}
	if err := h.reg.markEdgeExecuting(cmd.CommandId); err != nil {
		data, _ := json.Marshal(map[string]string{"reason": "journal unavailable: " + err.Error()})
		return "rejected", string(data)
	}
	return h.edgeActuate(cmd, reconciling)
}

// refuseEdge is the pre-execution checklist; a non-empty return is the
// refusal reason. Order is fixed — each check assumes the previous held.
func (h *Host) refuseEdge(cmd *edgev1.EdgeCommand, cloudKey ed25519.PublicKey) string {
	if len(cloudKey) > 0 && !edgesign.VerifyCommand(cloudKey, cmd) {
		return "cloud_signature does not verify"
	}
	if len(cmd.LedgerPayload) > 0 {
		if _, err := edgesign.VerifiedLedgerPayload(cmd); err != nil {
			return err.Error()
		}
	}
	if cmd.ExpiresAt != nil && time.Now().After(cmd.ExpiresAt.AsTime()) {
		return "command expired " + cmd.ExpiresAt.AsTime().UTC().Format(time.RFC3339)
	}
	if cmd.ResourceType != "" && cmd.ResourceId != "" {
		resource := cmd.ResourceType + ":" + cmd.ResourceId
		if fence, err := h.reg.edgeFence(resource); err != nil {
			return "journal unavailable: " + err.Error()
		} else if cmd.FencingToken < fence {
			return fmt.Sprintf("stale fencing token %d for %s (device has honored %d)", cmd.FencingToken, resource, fence)
		}
	}
	if cmd.ApprovalGrantId != "" {
		if _, err := edgesign.VerifyCommandGrant(cloudKey, cmd, time.Now()); err != nil {
			return "grant refused: " + err.Error()
		}
		spender, err := h.reg.edgeGrantSpender(cmd.ApprovalGrantId)
		if err != nil {
			return "journal unavailable: " + err.Error()
		}
		if spender != "" && spender != cmd.CommandId {
			return fmt.Sprintf("grant %s already spent by %s", cmd.ApprovalGrantId, spender)
		}
	}
	return ""
}

// resolveEdge signs the result event and lands outcome + event + grant
// spend + fence raise in the journal's one composed transaction.
//
// The sequence mutex is held across allocate→sign→write because the
// executor is no longer the journal's only writer: a live session's own
// facts are journaled from the transcript and pty goroutines.
func (h *Host) resolveEdge(cmd *edgev1.EdgeCommand, commandID, status, result string, devKey ed25519.PrivateKey) error {
	h.edgeSeqMu.Lock()
	defer h.edgeSeqMu.Unlock()
	maxSeq, err := h.reg.edgeMaxSeq()
	if err != nil {
		return err
	}
	payload, err := anypb.New(&edgev1.CommandResult{
		CommandId:  commandID,
		Status:     status,
		ResultJson: []byte(result),
	})
	if err != nil {
		return err
	}
	ev := &edgev1.EdgeEvent{
		// Cause and outcome derive the id — a reconciled re-execution
		// that converged on the same outcome converges on the same event,
		// and the cloud's dedupe treats it as the convergence it is.
		EventId:        fmt.Sprintf("devevt_%s_%s", commandID, status),
		DeviceId:       cmd.DeviceId,
		DeviceSequence: maxSeq + 1,
		CommandId:      commandID,
		Type:           eventTypeCommandResult,
		OccurredAt:     timestamppb.Now(),
		FencingToken:   cmd.FencingToken,
		Payload:        payload,
	}
	edgesign.SignEvent(devKey, ev)
	raw, err := proto.Marshal(ev)
	if err != nil {
		return err
	}
	grantID, resource := "", ""
	if status == "succeeded" && cmd.ApprovalGrantId != "" {
		grantID = cmd.ApprovalGrantId
	}
	if cmd.ResourceType != "" && cmd.ResourceId != "" {
		resource = cmd.ResourceType + ":" + cmd.ResourceId
	}
	return h.reg.resolveEdgeCommand(commandID, status, result,
		[]journaledEdgeEvent{{Seq: maxSeq + 1, Raw: raw}}, grantID, resource, cmd.FencingToken)
}

// edgeSubmitEvents resubmits every unacked signed event, in order, and
// records the cloud's cursor. A rejection is surfaced loudly and left
// unacked: a contradicted event is an operator problem, not something
// to silently bury.
func (h *Host) edgeSubmitEvents(ctx context.Context) error {
	seqs, raws, err := h.reg.unackedEdgeEvents()
	if err != nil || len(raws) == 0 {
		return err
	}
	events := make([]*edgev1.EdgeEvent, 0, len(raws))
	for i, raw := range raws {
		var ev edgev1.EdgeEvent
		if err := proto.Unmarshal(raw, &ev); err != nil {
			return fmt.Errorf("journaled event %d does not parse: %w", seqs[i], err)
		}
		events = append(events, &ev)
	}
	sctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	res, err := h.edge.RPC.SubmitEvents(sctx, connect.NewRequest(&edgev1.SubmitEventsRequest{Events: events}))
	cancel()
	if err != nil {
		return fmt.Errorf("submit: %w", err)
	}
	for _, rej := range res.Msg.Rejections {
		log.Printf("edge: cloud refused event seq %d: %s", rej.DeviceSequence, rej.Reason)
	}
	return h.reg.ackEdgeEvents(res.Msg.AckedDeviceSequence)
}

// ---------------------------------------------------------------------
// Typed actuators. Each converges: run twice, land once.

// edgeWorkspaceName is the registry name a run's worktree lives under —
// derived, so create and cleanup agree without a lookup table.
func edgeWorkspaceName(workflowRunID string) string {
	return truncateSlug(slugify(strings.ToLower(workflowRunID)), 48)
}

func (h *Host) edgeActuate(cmd *edgev1.EdgeCommand, reconciling bool) (string, string) {
	switch {
	case cmd.Payload.MessageIs(&edgev1.CreateWorktree{}):
		var p edgev1.CreateWorktree
		_ = cmd.Payload.UnmarshalTo(&p)
		return h.edgeCreateWorktree(cmd, &p)
	case cmd.Payload.MessageIs(&edgev1.CleanupWorktree{}):
		return h.edgeCleanupWorktree(cmd)
	case cmd.Payload.MessageIs(&edgev1.InspectRepository{}):
		var p edgev1.InspectRepository
		_ = cmd.Payload.UnmarshalTo(&p)
		return h.edgeInspectRepository(&p)
	case cmd.Payload.MessageIs(&edgev1.StartAgentSession{}):
		var p edgev1.StartAgentSession
		_ = cmd.Payload.UnmarshalTo(&p)
		return h.edgeStartAgentSession(cmd, &p)
	case cmd.Payload.MessageIs(&edgev1.SendAgentInput{}):
		var p edgev1.SendAgentInput
		_ = cmd.Payload.UnmarshalTo(&p)
		return h.edgeSendAgentInput(cmd, &p, reconciling)
	case cmd.Payload.MessageIs(&edgev1.InterruptAgentSession{}):
		var p edgev1.InterruptAgentSession
		_ = cmd.Payload.UnmarshalTo(&p)
		return h.edgeInterruptAgentSession(cmd, &p)
	case cmd.Payload.MessageIs(&edgev1.RunVerification{}):
		var p edgev1.RunVerification
		_ = cmd.Payload.UnmarshalTo(&p)
		return h.edgeRunVerification(cmd, &p)
	case cmd.Payload.MessageIs(&edgev1.CollectArtifact{}):
		var p edgev1.CollectArtifact
		_ = cmd.Payload.UnmarshalTo(&p)
		return h.edgeCollectArtifact(cmd, &p)
	case cmd.Payload.MessageIs(&edgev1.ReconcileSession{}):
		var p edgev1.ReconcileSession
		_ = cmd.Payload.UnmarshalTo(&p)
		return h.edgeReconcileSession(cmd, &p)
	case cmd.Payload.MessageIs(&edgev1.ReleaseResource{}):
		var p edgev1.ReleaseResource
		_ = cmd.Payload.UnmarshalTo(&p)
		return h.edgeReleaseResource(cmd, &p)
	default:
		// Named refusal, not silence: the run hears "rejected" and routes,
		// instead of waiting on a capability this device never offered.
		data, _ := json.Marshal(map[string]string{
			"reason": "op not offered by this device (capabilities: " + strings.Join(edgeCapabilities, ",") + ")",
		})
		return "rejected", string(data)
	}
}

// edgeCreateWorktree cuts a real worktree for the run: repository names
// a registered workspace (never a path — the cloud does not know
// paths), the branch is rook/<run>, and the receipt carries what only
// the device knows: the branch it cut and the commit it cut from.
func (h *Host) edgeCreateWorktree(cmd *edgev1.EdgeCommand, p *edgev1.CreateWorktree) (string, string) {
	src := h.reg.get(p.Repository)
	if src == nil || src.Root == "" {
		data, _ := json.Marshal(map[string]string{
			"reason": fmt.Sprintf("no workspace named %q on this device", p.Repository)})
		return "rejected", string(data)
	}
	if gitInfo(src.Root) == nil {
		data, _ := json.Marshal(map[string]string{
			"reason": fmt.Sprintf("workspace %q is not a git repo", p.Repository)})
		return "rejected", string(data)
	}
	name := edgeWorkspaceName(cmd.WorkflowRunId)
	branch := "rook/" + cmd.WorkflowRunId
	dir := worktreeDir(name)

	// Convergence: our own earlier (or crashed) creation is a success to
	// re-report, not a collision. Anything else holding the name is.
	if ws := h.reg.get(name); ws != nil {
		if ws.WorktreeOf == p.Repository && ws.Branch == branch {
			return "succeeded", edgeWorktreeReceipt(dir, branch, p.Repository)
		}
		data, _ := json.Marshal(map[string]string{
			"reason": fmt.Sprintf("workspace %q already exists and is not this run's worktree", name)})
		return "rejected", string(data)
	}
	if branchExists(src.Root, branch) {
		// The run's own branch with the run's own tree at our dir is a
		// crash scar (effect ran, registry insert didn't): adopt it — the
		// registry row is the only missing piece. The branch without the
		// tree is genuinely someone else's leftover, and a refusal.
		if _, err := os.Stat(dir); err != nil {
			data, _ := json.Marshal(map[string]string{
				"reason": fmt.Sprintf("branch %s already exists (left by an earlier worktree)", branch)})
			return "failed", string(data)
		}
	} else if err := worktreeAddAt(src.Root, dir, branch, p.BaseRef); err != nil {
		data, _ := json.Marshal(map[string]string{"reason": err.Error()})
		return "failed", string(data)
	}
	if _, err := h.reg.createWorktreeWS(name, dir, p.Repository, branch, nil); err != nil {
		_ = worktreeRemove(dir, true) // roll back the checkout; nothing is in it yet
		data, _ := json.Marshal(map[string]string{"reason": err.Error()})
		return "failed", string(data)
	}
	return "succeeded", edgeWorktreeReceipt(dir, branch, p.Repository)
}

// edgeWorktreeReceipt reads the receipt fields from the tree itself, so
// a re-reported convergence carries the same truth as the first report.
func edgeWorktreeReceipt(dir, branch, repository string) string {
	base, _ := runGit(dir, 10*time.Second, "rev-parse", "HEAD")
	data, _ := json.Marshal(map[string]string{
		"branch": branch, "baseCommit": base, "repository": repository,
	})
	return string(data)
}

// edgeCleanupWorktree removes the run's worktree — the grant-gated
// destructive op. Risk refuses politely (failed, with the counts
// named): the run routes on, the tree survives, and the registry still
// shows it — exactly the reviewable state the rule wants.
func (h *Host) edgeCleanupWorktree(cmd *edgev1.EdgeCommand) (string, string) {
	name := edgeWorkspaceName(cmd.WorkflowRunId)
	ws := h.reg.get(name)
	if ws == nil || ws.WorktreeOf == "" {
		// Convergence: already gone (or never ours) is a success to report.
		data, _ := json.Marshal(map[string]string{"removed": name, "note": "no such worktree on this device"})
		return "succeeded", string(data)
	}
	if _, err := os.Stat(ws.Root); err == nil {
		dirty, unmerged, err := worktreeRisk(ws.Root, ws.Branch)
		if err != nil {
			data, _ := json.Marshal(map[string]string{
				"reason": fmt.Sprintf("can't prove the worktree is safe to remove: %v", err)})
			return "failed", string(data)
		}
		if dirty > 0 || unmerged > 0 {
			data, _ := json.Marshal(map[string]string{
				"reason": fmt.Sprintf("worktree has %d dirty file(s) and %d unmerged commit(s) on %s — preserved", dirty, unmerged, ws.Branch)})
			return "failed", string(data)
		}
		for _, id := range h.sessionsIn(name) {
			h.kill(id)
		}
		if err := worktreeRemove(ws.Root, false); err != nil {
			data, _ := json.Marshal(map[string]string{"reason": err.Error()})
			return "failed", string(data)
		}
	}
	h.reg.remove(name)
	h.prm.forget(name)
	h.reg.deleteStages(name)
	data, _ := json.Marshal(map[string]string{"removed": name, "branch": ws.Branch})
	return "succeeded", string(data)
}

// edgeInspectRepository reports a workspace's git state — read-only,
// the cheapest true answer a device can give.
func (h *Host) edgeInspectRepository(p *edgev1.InspectRepository) (string, string) {
	ws := h.reg.get(p.Repository)
	if ws == nil || ws.Root == "" {
		data, _ := json.Marshal(map[string]string{
			"reason": fmt.Sprintf("no workspace named %q on this device", p.Repository)})
		return "rejected", string(data)
	}
	gi := gitInfo(ws.Root)
	if gi == nil {
		data, _ := json.Marshal(map[string]string{
			"reason": fmt.Sprintf("workspace %q is not a git repo", p.Repository)})
		return "rejected", string(data)
	}
	head, _ := runGit(ws.Root, 10*time.Second, "rev-parse", "HEAD")
	data, _ := json.Marshal(map[string]any{
		"repository": p.Repository, "branch": gi.Branch, "head": head,
	})
	return "succeeded", string(data)
}
