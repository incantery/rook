package host

// Release's contract, which is mostly a contract about what it does NOT
// do: it drops a hold, it does not stop an agent, and it does not take
// away work.

import (
	"crypto/ed25519"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	edgev1 "github.com/incantery/rook/gen/rook/edge/v1"
	"github.com/incantery/rook/internal/edgesign"
)

func releaseCmd(t *testing.T, priv ed25519.PrivateKey, id, run, rtype, rid string) *edgev1.EdgeCommand {
	t.Helper()
	return edgeCmd(t, priv, id, run, "release_resource",
		&edgev1.ReleaseResource{ResourceType: rtype, ResourceId: rid}, func(c *edgev1.EdgeCommand) {
			c.ResourceType, c.ResourceId = rtype, rid
		})
}

type releaseReport struct {
	ResourceType  string `json:"resourceType"`
	ResourceID    string `json:"resourceId"`
	Released      bool   `json:"released"`
	Removed       bool   `json:"removed"`
	WindowStillUp bool   `json:"windowStillUp"`
	Branch        string `json:"branch"`
	Note          string `json:"note"`
}

func decodeRelease(t *testing.T, result string) releaseReport {
	t.Helper()
	var r releaseReport
	if err := json.Unmarshal([]byte(result), &r); err != nil {
		t.Fatalf("report %s: %v", result, err)
	}
	return r
}

// Releasing a session ends the device's obligation to narrate it —
// nothing more. The agent keeps running, and the sensors go quiet.
func TestEdgeReleaseSession(t *testing.T) {
	h, devKey := edgeAgentHost(t)
	pub, priv, err := edgesign.NewKey()
	if err != nil {
		t.Fatal(err)
	}
	run := "wfr_release_1"
	ses := startedSession(t, h, pub, devKey, priv, run)

	h.edgeEmitAgent(ses, "progress", "working", nil)
	before := len(journaledEvents(t, h))

	status, result := h.edgeExecuteOne(releaseCmd(t, priv, "cmd_rel_1", run, "agent_session", ses.SessionID), pub, false)
	if status != "succeeded" {
		t.Fatalf("release: %s %s", status, result)
	}
	got := decodeRelease(t, result)
	if !got.Released || !got.WindowStillUp {
		t.Fatalf("release must drop the hold and leave the window: %+v", got)
	}

	// The window is untouched — that is interrupt's job, not this one.
	if h.get(ses.RookSession) == nil {
		t.Fatal("releasing a session must not kill it")
	}
	// And no event: a `stopped` here would be a lie about a process that
	// is demonstrably still running.
	if after := len(journaledEvents(t, h)); after != before {
		t.Fatalf("release must report nothing about the session: %d -> %d", before, after)
	}

	// The sensors fall silent from here.
	fresh, err := h.reg.edgeSession(ses.SessionID)
	if err != nil || fresh == nil || !fresh.Released {
		t.Fatalf("the release must be journaled: %+v %v", fresh, err)
	}
	h.edgeEmitAgent(fresh, "completion_claimed", "still talking", nil)
	if after := len(journaledEvents(t, h)); after != before {
		t.Fatalf("a released session must stop reporting: %d -> %d", before, after)
	}

	// Converges, and an unknown session is refused by name.
	if status, _ := h.edgeExecuteOne(releaseCmd(t, priv, "cmd_rel_2", run, "agent_session", ses.SessionID), pub, false); status != "succeeded" {
		t.Fatalf("re-release: %s", status)
	}
	if status, result := h.edgeExecuteOne(releaseCmd(t, priv, "cmd_rel_3", run, "agent_session", "ses_nobody"), pub, false); status != "rejected" ||
		!strings.Contains(result, "no session") {
		t.Fatalf("unknown session: %s %s", status, result)
	}
}

// A worktree with work in it survives release — and release still
// SUCCEEDS, because letting go of a preserved tree is exactly what was
// asked for. That is the whole difference from cleanup_worktree, which
// tests the same predicate and calls the same outcome a failure.
func TestEdgeReleaseWorktreeKeepsWork(t *testing.T) {
	h, _ := newEdgeHost(t)
	pub, priv, err := edgesign.NewKey()
	if err != nil {
		t.Fatal(err)
	}
	run := "wfr_release_2"
	name := edgeWorkspaceName(run)
	if status, result := h.edgeExecuteOne(edgeCmd(t, priv, "cmd_c", run, "create_worktree",
		&edgev1.CreateWorktree{Repository: "src", BaseRef: "main"}, nil), pub, false); status != "succeeded" {
		t.Fatalf("create: %s %s", status, result)
	}
	ws := h.reg.get(name)
	if err := os.WriteFile(filepath.Join(ws.Root, "wip.txt"), []byte("half a thought\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	status, result := h.edgeExecuteOne(releaseCmd(t, priv, "cmd_relw", run, "worktree", "worktree_"+run), pub, false)
	if status != "succeeded" {
		t.Fatalf("release: %s %s", status, result)
	}
	got := decodeRelease(t, result)
	if !got.Released || got.Removed {
		t.Fatalf("work must survive a release: %+v", got)
	}
	if !strings.Contains(got.Note, "this is work") {
		t.Fatalf("the reason must name what was kept: %+v", got)
	}
	if h.reg.get(name) == nil {
		t.Fatal("a kept worktree must stay in the registry, where it is reviewable")
	}
	if _, err := os.Stat(filepath.Join(ws.Root, "wip.txt")); err != nil {
		t.Fatalf("the work itself must survive: %v", err)
	}
}

// An EMPTY tree the run created is §6.6's one narrow removal: there is
// nothing in it to lose, so undoing the creation is genuine compensation
// rather than an undo of anyone's work.
func TestEdgeReleaseWorktreeEmpty(t *testing.T) {
	h, _ := newEdgeHost(t)
	pub, priv, err := edgesign.NewKey()
	if err != nil {
		t.Fatal(err)
	}
	run := "wfr_release_3"
	name := edgeWorkspaceName(run)
	if status, result := h.edgeExecuteOne(edgeCmd(t, priv, "cmd_c", run, "create_worktree",
		&edgev1.CreateWorktree{Repository: "src", BaseRef: "main"}, nil), pub, false); status != "succeeded" {
		t.Fatalf("create: %s %s", status, result)
	}

	status, result := h.edgeExecuteOne(releaseCmd(t, priv, "cmd_rele", run, "worktree", "worktree_"+run), pub, false)
	if status != "succeeded" {
		t.Fatalf("release: %s %s", status, result)
	}
	if got := decodeRelease(t, result); !got.Removed || !strings.Contains(got.Note, "left nothing") {
		t.Fatalf("an empty tree may go: %+v", got)
	}
	if h.reg.get(name) != nil {
		t.Fatal("a removed worktree must leave the registry")
	}
	// Converges: nothing left to let go of.
	if status, result := h.edgeExecuteOne(releaseCmd(t, priv, "cmd_rele2", run, "worktree", "worktree_"+run), pub, false); status != "succeeded" ||
		!strings.Contains(result, "no worktree") {
		t.Fatalf("re-release: %s %s", status, result)
	}
}

// git is not the only witness that a tree is in use. An agent that has
// read all morning and written nothing leaves a CLEAN status — and
// pulling the checkout out from under it is exactly the surprise release
// exists not to cause.
func TestEdgeReleaseWorktreeKeepsAWindow(t *testing.T) {
	h, devKey := edgeAgentHost(t)
	pub, priv, err := edgesign.NewKey()
	if err != nil {
		t.Fatal(err)
	}
	run := "wfr_release_4"
	name := edgeWorkspaceName(run)
	// The agent here writes nothing, so to git this tree looks as empty as
	// the one TestEdgeReleaseWorktreeEmpty is allowed to remove. The window
	// is the only thing standing between it and removal.
	ses := startedSession(t, h, pub, devKey, priv, run)

	status, result := h.edgeExecuteOne(releaseCmd(t, priv, "cmd_relw4", run, "worktree", "worktree_"+run), pub, false)
	if status != "succeeded" {
		t.Fatalf("release: %s %s", status, result)
	}
	got := decodeRelease(t, result)
	if !got.Released || got.Removed {
		t.Fatalf("a tree with a window in it must survive: %+v", got)
	}
	if !strings.Contains(got.Note, "window") {
		t.Fatalf("the reason must name what was kept: %+v", got)
	}
	// Release lets go; it does not reach in. Both the window and the
	// checkout it is sitting in are still there.
	if h.get(ses.RookSession) == nil {
		t.Fatal("releasing a worktree must not kill the windows in it")
	}
	ws := h.reg.get(name)
	if ws == nil {
		t.Fatal("a kept worktree must stay in the registry")
	}
	if _, err := os.Stat(ws.Root); err != nil {
		t.Fatalf("the checkout must survive: %v", err)
	}
}

// The rest of the vocabulary: a lease this device never held, and a
// resource type it does not know.
func TestEdgeReleaseOtherResources(t *testing.T) {
	h, _ := newEdgeHost(t)
	pub, priv, err := edgesign.NewKey()
	if err != nil {
		t.Fatal(err)
	}
	run := "wfr_release_4"

	status, result := h.edgeExecuteOne(releaseCmd(t, priv, "cmd_ti", run, "terminal_input", "ses_x"), pub, false)
	if status != "succeeded" || !strings.Contains(result, "held in the cloud") {
		t.Fatalf("terminal input: %s %s", status, result)
	}
	status, result = h.edgeExecuteOne(releaseCmd(t, priv, "cmd_zz", run, "gpu", "gpu0"), pub, false)
	if status != "rejected" || !strings.Contains(result, "gpu") || !strings.Contains(result, "worktree") {
		t.Fatalf("unknown resource type: %s %s", status, result)
	}
}
