package host

// The collector's contract: it declares what the run actually produced,
// it declares it once, and the bytes never leave.

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

func collectCmd(t *testing.T, priv ed25519.PrivateKey, id, run, session, kind string) *edgev1.EdgeCommand {
	t.Helper()
	return edgeCmd(t, priv, id, run, "collect_artifact",
		&edgev1.CollectArtifact{SessionId: session, ArtifactKind: kind}, func(c *edgev1.EdgeCommand) {
			c.ResourceType, c.ResourceId = "agent_session", session
		})
}

type artifactReceipt struct {
	ArtifactID string `json:"artifactId"`
	Kind       string `json:"kind"`
	Digest     string `json:"digest"`
	SizeBytes  int    `json:"sizeBytes"`
	Locator    string `json:"locator"`
	Summary    string `json:"summary"`
}

func decodeArtifact(t *testing.T, result string) artifactReceipt {
	t.Helper()
	var r artifactReceipt
	if err := json.Unmarshal([]byte(result), &r); err != nil {
		t.Fatalf("receipt %s: %v", result, err)
	}
	return r
}

// artifactEvents returns the artifact declarations journaled so far.
func artifactEvents(t *testing.T, h *Host) []*edgev1.AgentEvent {
	t.Helper()
	var out []*edgev1.AgentEvent
	for _, ev := range journaledEvents(t, h) {
		if ev.Type != eventTypeAgentEvent {
			continue
		}
		if ae := agentPayload(t, ev); ae.Kind == "artifact_published" {
			out = append(out, ae)
		}
	}
	return out
}

func TestEdgeCollectArtifact(t *testing.T) {
	h, devKey := edgeAgentHost(t)
	pub, priv, err := edgesign.NewKey()
	if err != nil {
		t.Fatal(err)
	}
	run := "wfr_collect_1"
	ses := startedSession(t, h, pub, devKey, priv, run)
	ws := h.reg.get(ses.Workspace)

	// An empty tree has produced nothing. That is not an artifact — a
	// claim must not get to rest on one.
	status, result := h.edgeExecuteOne(collectCmd(t, priv, "cmd_a0", run, ses.SessionID, ""), pub, false)
	if status != "failed" || !strings.Contains(result, "nothing to collect") {
		t.Fatalf("empty tree: %s %s", status, result)
	}

	// The agent's work: one edit and one NEW file. The new file is the
	// case `git diff` cannot see on its own, and the one that matters
	// most in a change.
	if err := os.WriteFile(filepath.Join(ws.Root, "a.txt"), []byte("hello, edited\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(ws.Root, "added.txt"), []byte("brand new\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	status, result = h.edgeExecuteOne(collectCmd(t, priv, "cmd_a1", run, ses.SessionID, ""), pub, false)
	if status != "succeeded" {
		t.Fatalf("collect: %s %s", status, result)
	}
	got := decodeArtifact(t, result)
	if got.Kind != artifactDiff || !strings.HasPrefix(got.Digest, "sha256:") || got.SizeBytes == 0 {
		t.Fatalf("receipt: %+v", got)
	}
	// Run-scoped AND content-addressed: the run so two runs producing
	// identical bytes stay two artifacts, the digest so one run
	// re-collecting identical bytes stays one. The run half is the same
	// slug the workspace took, so the id and the directory it lands in
	// agree about which run owns it.
	if !strings.HasPrefix(got.ArtifactID, "art_"+edgeWorkspaceName(run)+"_diff_") {
		t.Fatalf("the id must name the run and the content: %q", got.ArtifactID)
	}
	// The locator addresses the artifact without naming a path on this
	// machine — filesystem paths stay home.
	if got.Locator != "rook-artifact://"+ses.Workspace+"/"+got.ArtifactID {
		t.Fatalf("locator: %q", got.Locator)
	}
	if strings.Contains(got.Locator, ws.Root) || strings.Contains(result, ws.Root) {
		t.Fatalf("no absolute path may cross: %s", result)
	}

	// The bytes are the change, both halves of it, and they live outside
	// the tree that was measured.
	stored := filepath.Join(edgeArtifactDir(ses.Workspace), got.ArtifactID)
	body, err := os.ReadFile(stored)
	if err != nil {
		t.Fatalf("stored bytes: %v", err)
	}
	if !strings.Contains(string(body), "hello, edited") {
		t.Fatalf("the edit must be in the diff:\n%s", body)
	}
	if !strings.Contains(string(body), "brand new") || !strings.Contains(string(body), "added.txt") {
		t.Fatalf("an added file must be in the diff:\n%s", body)
	}
	if strings.HasPrefix(stored, ws.Root) {
		t.Fatalf("artifacts must not live in the tree they measure: %s", stored)
	}
	if _, err := os.Stat(filepath.Join(ws.Root, ".rook")); err == nil {
		t.Fatal("collecting must not add files to the worktree")
	}

	// One declaration crossed, and it carries what the evidence graph
	// needs: id, kind, digest.
	events := artifactEvents(t, h)
	if len(events) != 1 {
		t.Fatalf("declarations: %d, want 1", len(events))
	}
	var decl struct {
		ArtifactID string `json:"artifactId"`
		Kind       string `json:"kind"`
		Digest     string `json:"digest"`
		Locator    string `json:"locator"`
	}
	if err := json.Unmarshal(events[0].DataJson, &decl); err != nil {
		t.Fatal(err)
	}
	if decl.ArtifactID != got.ArtifactID || decl.Kind != artifactDiff || decl.Digest != got.Digest {
		t.Fatalf("declaration: %+v", decl)
	}

	// Re-collecting unchanged content converges: same id, same receipt,
	// and NOTHING re-declared — a second declaration of the same id is
	// exactly what the cloud would have to refuse.
	status, again := h.edgeExecuteOne(collectCmd(t, priv, "cmd_a2", run, ses.SessionID, ""), pub, false)
	if status != "succeeded" || decodeArtifact(t, again).ArtifactID != got.ArtifactID {
		t.Fatalf("re-collect: %s %s", status, again)
	}
	if n := len(artifactEvents(t, h)); n != 1 {
		t.Fatalf("declarations after re-collect: %d, want the original 1", n)
	}

	// Changed content is a DIFFERENT artifact, not a contradiction of the
	// first one — which is the whole reason the id is the digest.
	if err := os.WriteFile(filepath.Join(ws.Root, "a.txt"), []byte("hello, edited twice\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	status, moved := h.edgeExecuteOne(collectCmd(t, priv, "cmd_a3", run, ses.SessionID, ""), pub, false)
	second := decodeArtifact(t, moved)
	if status != "succeeded" || second.ArtifactID == got.ArtifactID || second.Digest == got.Digest {
		t.Fatalf("changed content must be its own artifact: %s %s", status, moved)
	}
	if n := len(artifactEvents(t, h)); n != 2 {
		t.Fatalf("declarations: %d, want one per distinct artifact", n)
	}
}

// The artifact id becomes a FILENAME, and half of it is a string the
// cloud chose. A collect addresses a session, so its command's own run id
// is free to be anything at all — including a path that climbs out of the
// store. It must not get to.
func TestEdgeCollectArtifactStaysInTheStore(t *testing.T) {
	h, devKey := edgeAgentHost(t)
	pub, priv, err := edgesign.NewKey()
	if err != nil {
		t.Fatal(err)
	}
	run := "wfr_collect_3"
	ses := startedSession(t, h, pub, devKey, priv, run)
	ws := h.reg.get(ses.Workspace)
	if err := os.WriteFile(filepath.Join(ws.Root, "a.txt"), []byte("changed\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	escape := "wfr_x/../../../../../../../../tmp/rook-escaped"
	status, result := h.edgeExecuteOne(collectCmd(t, priv, "cmd_esc", escape, ses.SessionID, ""), pub, false)
	if status != "succeeded" {
		t.Fatalf("collect: %s %s", status, result)
	}
	got := decodeArtifact(t, result)
	if strings.ContainsAny(got.ArtifactID, `/\`) || strings.Contains(got.ArtifactID, "..") {
		t.Fatalf("an id that is about to be a filename: %q", got.ArtifactID)
	}
	// The invariant, stated the way the filesystem reads it: joining the id
	// onto the store lands IN the store, one level down and nowhere else.
	dir := edgeArtifactDir(ses.Workspace)
	stored := filepath.Join(dir, got.ArtifactID)
	if filepath.Dir(stored) != dir {
		t.Fatalf("the bytes escaped the store: %s, want a child of %s", stored, dir)
	}
	if _, err := os.Stat(stored); err != nil {
		t.Fatalf("stored bytes: %v", err)
	}
	// And the locator the cloud gets says the same thing.
	if got.Locator != "rook-artifact://"+ses.Workspace+"/"+got.ArtifactID {
		t.Fatalf("locator: %q", got.Locator)
	}
}

// The other two kinds, and the refusals. Each kind is backed by
// something the device already has; a kind it does not know is named.
func TestEdgeCollectArtifactKinds(t *testing.T) {
	h, devKey := edgeAgentHost(t)
	pub, priv, err := edgesign.NewKey()
	if err != nil {
		t.Fatal(err)
	}
	run := "wfr_collect_2"
	ses := startedSession(t, h, pub, devKey, priv, run)
	ws := h.reg.get(ses.Workspace)

	// report: the prose a profile was told to write.
	status, result := h.edgeExecuteOne(collectCmd(t, priv, "cmd_r0", run, ses.SessionID, artifactReport), pub, false)
	if status != "rejected" || !strings.Contains(result, "review.md") {
		t.Fatalf("no report yet: %s %s", status, result)
	}
	if err := os.MkdirAll(filepath.Join(ws.Root, ".rook"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(ws.Root, ".rook", "review.md"),
		[]byte("# Verdict\n\nShip it.\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	status, result = h.edgeExecuteOne(collectCmd(t, priv, "cmd_r1", run, ses.SessionID, artifactReport), pub, false)
	if status != "succeeded" {
		t.Fatalf("report: %s %s", status, result)
	}
	if got := decodeArtifact(t, result); got.Kind != artifactReport || !strings.Contains(got.Summary, "review.md") {
		t.Fatalf("report receipt: %+v", got)
	}

	// test_log: the verification run's WHOLE output, which is what makes
	// the receipt's truncated tail an acceptable trade.
	status, result = h.edgeExecuteOne(collectCmd(t, priv, "cmd_t0", run, ses.SessionID, artifactTestLog), pub, false)
	if status != "rejected" || !strings.Contains(result, "no verification has run") {
		t.Fatalf("no verification yet: %s %s", status, result)
	}
	withSuites(t, "verify-loud = echo the whole log\n")
	if status, result := h.edgeExecuteOne(edgeCmd(t, priv, "cmd_verify", run, "run_verification",
		&edgev1.RunVerification{Suite: "loud"}, nil), pub, false); status != "succeeded" {
		t.Fatalf("verify: %s %s", status, result)
	}
	status, result = h.edgeExecuteOne(collectCmd(t, priv, "cmd_t1", run, ses.SessionID, artifactTestLog), pub, false)
	if status != "succeeded" {
		t.Fatalf("test_log: %s %s", status, result)
	}
	log := decodeArtifact(t, result)
	body, err := os.ReadFile(filepath.Join(edgeArtifactDir(ses.Workspace), log.ArtifactID))
	if err != nil || !strings.Contains(string(body), "the whole log") {
		t.Fatalf("stored log: %q %v", body, err)
	}

	// A kind this device cannot produce is refused by name, listing what
	// it can — the same discipline profiles and suites keep.
	status, result = h.edgeExecuteOne(collectCmd(t, priv, "cmd_x", run, ses.SessionID, "screenshot"), pub, false)
	if status != "rejected" || !strings.Contains(result, "screenshot") || !strings.Contains(result, "diff") {
		t.Fatalf("unknown kind: %s %s", status, result)
	}

	// A session this device never started is not addressable.
	status, result = h.edgeExecuteOne(collectCmd(t, priv, "cmd_n", run, "ses_nobody", ""), pub, false)
	if status != "rejected" || !strings.Contains(result, "no session") {
		t.Fatalf("unknown session: %s %s", status, result)
	}
}
