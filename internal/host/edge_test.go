package host

// The edge client's contract, tested at the seams that matter: the
// journal's at-most-once effect, the §12.2/§13.5 refusal checklist, the
// converging actuators against a real git repo, and the crash scars a
// restart must reconcile.

import (
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/types/known/anypb"
	"google.golang.org/protobuf/types/known/timestamppb"

	edgev1 "github.com/incantery/rook/gen/rook/edge/v1"
	"github.com/incantery/rook/internal/edgesign"
)

// newEdgeHost stands up a host with an isolated data dir and a source
// workspace pointing at a fresh git repo with one commit — the edge
// actuators' whole world.
func newEdgeHost(t *testing.T) (h *Host, repo string) {
	t.Helper()
	t.Setenv("XDG_DATA_HOME", t.TempDir())
	t.Setenv("XDG_STATE_HOME", t.TempDir())
	cfgDir := t.TempDir()
	t.Setenv("XDG_CONFIG_HOME", cfgDir)
	// No test in this file starts a real coder: the agent actuator types
	// whatever `coder` names into a real pty, and a test that launched
	// claude would spend money to prove a journal works.
	if err := os.MkdirAll(filepath.Join(cfgDir, "rook"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(cfgDir, "rook", "config"),
		[]byte("coder = /usr/bin/true\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	repo = t.TempDir()
	gitT(t, repo, "init", "-b", "main")
	if err := os.WriteFile(filepath.Join(repo, "a.txt"), []byte("hello\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	gitT(t, repo, "add", ".")
	gitT(t, repo, "commit", "-m", "init")
	h = New()
	h.reg.upsert("src", repo, false)
	return h, repo
}

// edgeCmd builds a wire-faithful command: ledger payload aboard, digest
// over those bytes, signed when key != nil — the same envelope the
// cloud's gateway ships.
func edgeCmd(t *testing.T, key ed25519.PrivateKey, id, run, op string, payload proto.Message, mutate func(*edgev1.EdgeCommand)) *edgev1.EdgeCommand {
	t.Helper()
	anyp, err := anypb.New(payload)
	if err != nil {
		t.Fatal(err)
	}
	ledger := fmt.Appendf(nil, `{"op":%q,"step":"s"}`, op)
	sum := sha256.Sum256(ledger)
	cmd := &edgev1.EdgeCommand{
		ProtocolVersion: "rook-edge/1",
		CommandId:       id,
		DeviceId:        "dev_t",
		WorkflowRunId:   run,
		ResourceType:    "worktree",
		ResourceId:      "worktree_" + run,
		FencingToken:    1,
		ExpiresAt:       timestamppb.New(time.Now().Add(time.Hour)),
		IdempotencyKey:  id,
		Payload:         anyp,
		PayloadDigest:   sum[:],
		LedgerPayload:   ledger,
	}
	if mutate != nil {
		mutate(cmd)
	}
	if key != nil {
		edgesign.SignCommand(key, cmd)
	}
	return cmd
}

// The journal: one arrival owes one execution, redeliveries converge,
// and resolution is a single composed write that never repeats.
func TestEdgeJournalAtMostOnce(t *testing.T) {
	h, _ := newEdgeHost(t)

	fresh, err := h.reg.journalEdgeCommand("cmd_1", []byte("raw"))
	if err != nil || !fresh {
		t.Fatalf("first arrival: (%v, %v), want fresh", fresh, err)
	}
	if again, err := h.reg.journalEdgeCommand("cmd_1", []byte("raw")); err != nil || again {
		t.Fatalf("redelivery must converge: (%v, %v)", again, err)
	}

	if err := h.reg.resolveEdgeCommand("cmd_1", "succeeded", `{"ok":true}`,
		[]journaledEdgeEvent{{Seq: 1, Raw: []byte("ev1")}}, "apr_1", "worktree:wt_1", 3); err != nil {
		t.Fatal(err)
	}
	// Re-resolving (a reconciled redelivery) adds nothing.
	if err := h.reg.resolveEdgeCommand("cmd_1", "succeeded", `{"ok":true}`,
		[]journaledEdgeEvent{{Seq: 2, Raw: []byte("dup")}}, "apr_1", "worktree:wt_1", 3); err != nil {
		t.Fatal(err)
	}
	seqs, raws, err := h.reg.unackedEdgeEvents()
	if err != nil || len(seqs) != 1 || seqs[0] != 1 || string(raws[0]) != "ev1" {
		t.Fatalf("events after double resolve: %v %q %v", seqs, raws, err)
	}

	// The composed write landed everything at once.
	if spender, _ := h.reg.edgeGrantSpender("apr_1"); spender != "cmd_1" {
		t.Fatalf("grant spender: %q", spender)
	}
	if fence, _ := h.reg.edgeFence("worktree:wt_1"); fence != 3 {
		t.Fatalf("fence: %d", fence)
	}

	// Acked events retire; sequences never come back.
	if err := h.reg.ackEdgeEvents(1); err != nil {
		t.Fatal(err)
	}
	if cursor, _ := h.reg.edgeAckedCursor(); cursor != 1 {
		t.Fatalf("cursor: %d", cursor)
	}
	if maxSeq, _ := h.reg.edgeMaxSeq(); maxSeq != 1 {
		t.Fatalf("max seq must survive acking: %d", maxSeq)
	}
	if seqs, _, _ := h.reg.unackedEdgeEvents(); len(seqs) != 0 {
		t.Fatalf("acked events must stop submitting: %v", seqs)
	}
}

// The checklist: each refusal fires by name, none executes anything.
func TestEdgeRefusalChecklist(t *testing.T) {
	h, _ := newEdgeHost(t)
	pub, priv, err := edgesign.NewKey()
	if err != nil {
		t.Fatal(err)
	}

	refusals := map[string]struct {
		cmd  *edgev1.EdgeCommand
		want string
	}{
		"tampered signature": {
			cmd: func() *edgev1.EdgeCommand {
				c := edgeCmd(t, priv, "cmd_sig", "wfr_a", "create_worktree",
					&edgev1.CreateWorktree{Repository: "src"}, nil)
				c.FencingToken = 99
				return c
			}(),
			want: "cloud_signature",
		},
		"ledger payload mismatch": {
			cmd: edgeCmd(t, priv, "cmd_pl", "wfr_b", "create_worktree",
				&edgev1.CreateWorktree{Repository: "src"}, func(c *edgev1.EdgeCommand) {
					c.LedgerPayload = []byte(`{"op":"create_worktree","step":"s","force":"true"}`)
				}),
			want: "ledger payload",
		},
		"expired": {
			cmd: edgeCmd(t, priv, "cmd_exp", "wfr_c", "create_worktree",
				&edgev1.CreateWorktree{Repository: "src"}, func(c *edgev1.EdgeCommand) {
					c.ExpiresAt = timestamppb.New(time.Now().Add(-time.Minute))
				}),
			want: "expired",
		},
		"grant named but absent": {
			cmd: edgeCmd(t, priv, "cmd_ng", "wfr_d", "cleanup_worktree",
				&edgev1.CleanupWorktree{WorktreeId: "worktree_wfr_d"}, func(c *edgev1.EdgeCommand) {
					c.ApprovalGrantId = "apr_missing"
				}),
			want: "grant refused",
		},
	}
	for name, tc := range refusals {
		reason := h.refuseEdge(tc.cmd, pub)
		if !strings.Contains(reason, tc.want) {
			t.Errorf("%s: reason %q, want %q named", name, reason, tc.want)
		}
	}

	// Stale fence: the journal has honored era 5; era 1 arrives late.
	// (Resolution only lands on a journaled row — same as production.)
	if _, err := h.reg.journalEdgeCommand("cmd_fence", []byte("raw")); err != nil {
		t.Fatal(err)
	}
	if err := h.reg.resolveEdgeCommand("cmd_fence", "succeeded", "{}",
		nil, "", "worktree:worktree_wfr_e", 5); err != nil {
		t.Fatal(err)
	}
	stale := edgeCmd(t, priv, "cmd_stale", "wfr_e", "create_worktree",
		&edgev1.CreateWorktree{Repository: "src"}, nil)
	if reason := h.refuseEdge(stale, pub); !strings.Contains(reason, "stale fencing token") {
		t.Errorf("stale fence: %q", reason)
	}

	// Spent grant: another command owns it forever.
	if _, err := h.reg.journalEdgeCommand("cmd_spender", []byte("raw")); err != nil {
		t.Fatal(err)
	}
	if err := h.reg.resolveEdgeCommand("cmd_spender", "succeeded", "{}",
		nil, "apr_spent", "", 0); err != nil {
		t.Fatal(err)
	}
	spent := edgeCmd(t, priv, "cmd_thief", "wfr_f", "cleanup_worktree",
		&edgev1.CleanupWorktree{WorktreeId: "worktree_wfr_f"}, func(c *edgev1.EdgeCommand) {
			c.ApprovalGrantId = "apr_spent"
			doc := grantFor(t, priv, c)
			c.ApprovalGrant = doc
			edgesign.SignCommand(priv, c)
		})
	if reason := h.refuseEdge(spent, pub); !strings.Contains(reason, "already spent") {
		t.Errorf("spent grant: %q", reason)
	}
}

// grantFor mints a valid signed grant bound to the command, the way
// DecideApproval does on the cloud.
func grantFor(t *testing.T, key ed25519.PrivateKey, cmd *edgev1.EdgeCommand) []byte {
	t.Helper()
	doc := edgesign.GrantDoc{
		Schema: edgesign.GrantSchema, GrantID: cmd.ApprovalGrantId, RequestID: cmd.ApprovalGrantId,
		ActorID: "usr_t", ActionType: "cleanup_worktree",
		ActionDigest: "sha256:" + edgesign.ActionDigest(
			cmd.WorkflowRunId, cmd.DeviceId, cmd.ResourceType, cmd.ResourceId, cmd.LedgerPayload),
		ResourceScope: []string{"device:" + cmd.DeviceId, cmd.ResourceType + ":" + cmd.ResourceId},
		WorkflowRunID: cmd.WorkflowRunId,
		IssuedAt:      time.Now().UTC().Format(time.RFC3339),
		ExpiresAt:     time.Now().Add(time.Hour).UTC().Format(time.RFC3339),
		SingleUse:     true,
	}
	if err := edgesign.SignGrant(key, &doc); err != nil {
		t.Fatal(err)
	}
	raw, err := json.Marshal(doc)
	if err != nil {
		t.Fatal(err)
	}
	return raw
}

// The whole lifecycle against a real repo: create cuts a real worktree
// and registers it, redelivery converges on the same receipt, a dirty
// tree refuses cleanup by name, a clean one goes, and gone stays gone.
func TestEdgeWorktreeLifecycle(t *testing.T) {
	h, _ := newEdgeHost(t)
	pub, priv, err := edgesign.NewKey()
	if err != nil {
		t.Fatal(err)
	}
	run := "wfr_lifecycle_1"
	name := edgeWorkspaceName(run)

	create := edgeCmd(t, priv, "cmd_create", run, "create_worktree",
		&edgev1.CreateWorktree{Repository: "src", BaseRef: "main"}, nil)
	status, result := h.edgeExecuteOne(create, pub, false)
	if status != "succeeded" {
		t.Fatalf("create: %s %s", status, result)
	}
	var receipt map[string]string
	if err := json.Unmarshal([]byte(result), &receipt); err != nil {
		t.Fatal(err)
	}
	if receipt["branch"] != "rook/"+run || receipt["repository"] != "src" || len(receipt["baseCommit"]) < 7 {
		t.Fatalf("receipt: %v", receipt)
	}
	ws := h.reg.get(name)
	if ws == nil || ws.WorktreeOf != "src" {
		t.Fatalf("worktree workspace must be registered: %+v", ws)
	}
	if _, err := os.Stat(ws.Root); err != nil {
		t.Fatalf("the tree must exist: %v", err)
	}

	// Redelivery converges on the same receipt, no second tree.
	status2, result2 := h.edgeExecuteOne(create, pub, false)
	if status2 != "succeeded" || result2 != result {
		t.Fatalf("redelivered create: %s %s, want the same receipt", status2, result2)
	}

	// Dirty tree: cleanup refuses with the damage named; tree survives.
	if err := os.WriteFile(filepath.Join(ws.Root, "wip.txt"), []byte("wip\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	cleanup := edgeCmd(t, priv, "cmd_cleanup", run, "cleanup_worktree",
		&edgev1.CleanupWorktree{WorktreeId: "worktree_" + run}, func(c *edgev1.EdgeCommand) {
			c.ApprovalGrantId = "apr_cleanup"
			c.ApprovalGrant = grantFor(t, priv, c)
			edgesign.SignCommand(priv, c)
		})
	status, result = h.edgeExecuteOne(cleanup, pub, false)
	if status != "failed" || !strings.Contains(result, "dirty") {
		t.Fatalf("dirty cleanup: %s %s, want failed with dirty named", status, result)
	}
	if h.reg.get(name) == nil {
		t.Fatal("a refused cleanup must preserve the workspace")
	}

	// Clean it; cleanup goes; gone converges.
	if err := os.Remove(filepath.Join(ws.Root, "wip.txt")); err != nil {
		t.Fatal(err)
	}
	if status, result = h.edgeExecuteOne(cleanup, pub, false); status != "succeeded" {
		t.Fatalf("clean cleanup: %s %s", status, result)
	}
	if h.reg.get(name) != nil {
		t.Fatal("cleanup must drop the workspace")
	}
	if status, _ = h.edgeExecuteOne(cleanup, pub, false); status != "succeeded" {
		t.Fatalf("cleanup of the already-gone: %s, want succeeded", status)
	}

	// A payload this device does not actuate is a NAMED rejection, not
	// silence — the run hears "rejected" and routes instead of waiting on
	// a capability nobody has.
	//
	// The probe is deliberately a payload that can never become an op: it
	// is an event body, so no future slice can quietly turn this
	// assertion into a test of something that now works. Three real ops
	// were consumed here before that was worth doing.
	unknown := edgeCmd(t, priv, "cmd_unknown", run, "not_an_op",
		&edgev1.CommandResult{CommandId: "cmd_x", Status: "succeeded"}, nil)
	if status, result = h.edgeExecuteOne(unknown, pub, false); status != "rejected" || !strings.Contains(result, "not offered") {
		t.Fatalf("unsupported op: %s %s", status, result)
	}
}

// Crash scars: a command caught mid-execution — including the worst
// case, effect done but registry insert lost — re-executes on the next
// pass and converges instead of colliding with its own leftovers.
func TestEdgeCrashReconciliation(t *testing.T) {
	h, repo := newEdgeHost(t)
	pub, priv, err := edgesign.NewKey()
	if err != nil {
		t.Fatal(err)
	}
	run := "wfr_crash_1"
	name := edgeWorkspaceName(run)
	create := edgeCmd(t, priv, "cmd_crash", run, "create_worktree",
		&edgev1.CreateWorktree{Repository: "src", BaseRef: "main"}, nil)

	// The crash: journaled, marked executing, the git effect ran — and
	// nothing else. No registry row, no resolution, no events.
	raw, err := proto.Marshal(create)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := h.reg.journalEdgeCommand(create.CommandId, raw); err != nil {
		t.Fatal(err)
	}
	if err := h.reg.markEdgeExecuting(create.CommandId); err != nil {
		t.Fatal(err)
	}
	if err := worktreeAddAt(repo, worktreeDir(name), "rook/"+run, "main"); err != nil {
		t.Fatal(err)
	}

	// The restart: a fresh executor pass over the journal.
	_, devKey, err := edgesign.NewKey()
	if err != nil {
		t.Fatal(err)
	}
	if err := h.edgeExecutePending(pub, devKey); err != nil {
		t.Fatal(err)
	}

	// Converged: adopted, resolved succeeded, exactly one signed event.
	if ws := h.reg.get(name); ws == nil || ws.Branch != "rook/"+run {
		t.Fatalf("the crashed create must be adopted: %+v", ws)
	}
	pending, err := h.reg.unresolvedEdgeCommands()
	if err != nil || len(pending) != 0 {
		t.Fatalf("journal must be drained: %v %v", pending, err)
	}
	seqs, raws, err := h.reg.unackedEdgeEvents()
	if err != nil || len(raws) != 1 {
		t.Fatalf("events: %v %v", seqs, err)
	}
	var ev edgev1.EdgeEvent
	if err := proto.Unmarshal(raws[0], &ev); err != nil {
		t.Fatal(err)
	}
	if ev.EventId != "devevt_cmd_crash_succeeded" || ev.DeviceSequence != 1 {
		t.Fatalf("event: %s seq %d", ev.EventId, ev.DeviceSequence)
	}
	var res edgev1.CommandResult
	if err := ev.Payload.UnmarshalTo(&res); err != nil || res.Status != "succeeded" {
		t.Fatalf("result payload: %+v %v", &res, err)
	}
	if !edgesign.VerifyEvent(devKey.Public().(ed25519.PublicKey), &ev) {
		t.Fatal("the journaled event must carry a verifying device signature")
	}
}
