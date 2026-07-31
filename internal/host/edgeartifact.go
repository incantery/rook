package host

// collect_artifact: turning what a run PRODUCED into something the cloud
// can reason about without holding it.
//
// The division of labour is §10.5's, and it is the reason this file is
// short. Bytes stay on the device. What crosses is a DECLARATION —
// identity, kind, digest, size, and a locator — so the cloud's evidence
// graph can link a claim to a thing, and a later verification can
// re-hash that thing and find out whether the claim still stands. The
// cloud's ResolveArtifactUpload is Unimplemented today ("artifact upload
// arrives with the artifact store"), so this device never tries to
// upload; the declaration is the whole contract, and it is enough for
// everything the first slice does with it.
//
// Identity is the run plus the digest: `art_<run>_<kind>_<12 hex>`, with
// the run SLUGGED — the same slug every other use of a run id takes
// (edgeWorkspaceName), because this id becomes a filename below and
// filepath.Join cleans `..` segments. A run id is a string the cloud
// chose, and this is the one place one reaches a path.
//
// The digest half is what makes an idempotent collect possible at all,
// since the thing being collected is a live working tree: re-collecting
// unchanged content converges exactly — same id, same digest, nothing to
// contradict — while changed content is a DIFFERENT artifact rather than
// a re-declaration the cloud would have to refuse (ErrDigestMismatch).
//
// The run half is not decoration. Without it, two runs that produce
// byte-identical output produce the same artifact id, and the cloud
// converges the second declaration onto the FIRST run's artifact row —
// so the second run's evidence graph comes up empty for work it really
// did. Rare, but not exotic: a retried task, or the same task re-run
// after cleanup. Found by declaring one twice against the real store.
// Convergence was only ever needed WITHIN a run, and scoping the id
// there costs nothing.
//
// The locator names the artifact device-relatively —
// `rook-artifact://<workspace>/<id>` — and never an absolute path.
// Filesystem paths stay home, the same line cloud.go draws for status.
//
// Bytes are written OUTSIDE the worktree, under rook's data dir. Two
// reasons, both load-bearing: the tree being measured must not gain
// files because it was measured, and evidence has to outlive
// cleanup_worktree, which is the last thing a run does.

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"strings"
	"time"

	edgev1 "github.com/incantery/rook/gen/rook/edge/v1"
)

// The kinds this device can produce, each mapped to something it already
// has rather than something it would have to invent. They line up with
// the storage classes the cloud already resolves (diff, test_log, report)
// and with §19.4's evidence — the change, the tests, the review.
const (
	artifactDiff    = "diff"
	artifactTestLog = "test_log"
	artifactReport  = "report"
)

// artifactDefaultKind is what an unqualified collect means. The cloud's
// ledger has no artifactKind field yet — typedPayload builds
// CollectArtifact from the session alone — so today every collect
// arrives unqualified, and the change is the thing worth collecting.
const artifactDefaultKind = artifactDiff

// reportCandidates are where the shipped profiles leave their prose, in
// the order a collect prefers them. Kept next to the profiles they
// mirror: a profile that writes somewhere new adds its line here.
var reportCandidates = []string{".rook/review.md", ".rook/investigation.md"}

const (
	artifactGitTimeout   = 2 * time.Minute
	artifactMaxUntracked = 200
)

// edgeArtifactDir is where collected bytes live: outside every worktree,
// keyed by the workspace the run owns, so cleanup cannot take the
// evidence with it.
func edgeArtifactDir(workspace string) string {
	return filepath.Join(DataDir(), "artifacts", workspace)
}

// edgeCollectArtifact produces, stores, and declares one artifact.
func (h *Host) edgeCollectArtifact(cmd *edgev1.EdgeCommand, p *edgev1.CollectArtifact) (string, string) {
	ses, err := h.reg.edgeSession(p.SessionId)
	if err != nil {
		return "rejected", edgeReason("journal unavailable: " + err.Error())
	}
	if ses == nil {
		return "rejected", edgeReason("no session " + p.SessionId + " on this device")
	}
	ws := h.reg.get(ses.Workspace)
	if ws == nil || ws.Root == "" {
		return "rejected", edgeReason("the worktree for session " + p.SessionId + " is gone")
	}
	kind := strings.TrimSpace(p.ArtifactKind)
	if kind == "" {
		kind = artifactDefaultKind
	}

	body, summary, reason := h.edgeArtifactBody(ws, kind)
	switch {
	case reason != "":
		return "rejected", edgeReason(reason)
	case len(body) == 0:
		// Nothing to collect is not an artifact. Declaring an empty diff
		// as evidence would let a claim rest on it.
		return "failed", edgeReason(fmt.Sprintf(
			"nothing to collect for kind %q in %s", kind, ses.Workspace))
	}

	sum := sha256.Sum256(body)
	digest := "sha256:" + hex.EncodeToString(sum[:])
	artifactID := fmt.Sprintf("art_%s_%s_%s",
		edgeWorkspaceName(cmd.WorkflowRunId), kind, hex.EncodeToString(sum[:6]))
	locator := "rook-artifact://" + ses.Workspace + "/" + artifactID

	dir := edgeArtifactDir(ses.Workspace)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return "failed", edgeReason("artifact store unavailable: " + err.Error())
	}
	if err := os.WriteFile(filepath.Join(dir, artifactID), body, 0o600); err != nil {
		return "failed", edgeReason("could not store the artifact: " + err.Error())
	}

	receipt, _ := json.Marshal(map[string]any{
		"artifactId": artifactID, "kind": kind, "digest": digest,
		"sizeBytes": len(body), "locator": locator, "summary": summary,
	})

	// The declaration crosses once per artifact. A redelivered collect
	// that found the same bytes has nothing to add — and one that found
	// DIFFERENT bytes is a different artifact by construction, so it
	// declares on its own.
	fresh, err := h.reg.claimEdgeArtifact(artifactID, ses.SessionID, cmd.CommandId)
	if err != nil {
		return "failed", edgeReason("journal unavailable: " + err.Error())
	}
	if fresh {
		detail, _ := json.Marshal(map[string]any{
			"artifactId": artifactID, "kind": kind, "digest": digest,
			"sizeBytes": len(body), "locator": locator,
		})
		h.edgeEmitAgent(ses, "artifact_published", summary, detail)
	}
	log.Printf("edge: collected %s (%s, %d bytes) for session %s", artifactID, kind, len(body), ses.SessionID)
	return "succeeded", string(receipt)
}

// edgeArtifactBody produces the bytes for a kind. A non-empty reason is
// a refusal — a kind this device does not know, which is the same
// discipline profiles and suites keep.
func (h *Host) edgeArtifactBody(ws *WorkspaceInfo, kind string) (body []byte, summary, reason string) {
	switch kind {
	case artifactDiff:
		top, err := repoTop(ws.Root)
		if err != nil {
			return nil, "", "workspace " + ws.Name + " is not a git repo"
		}
		// The base is rook's own answer to "what is this worktree's
		// work" (reviewBaseFor): for a worktree that is the merge-base
		// with its source branch — the whole task, not just what is
		// uncommitted. Collecting a different change than the review
		// surface shows would make two truths out of one.
		base := h.reviewBaseFor(ws, top, "")
		diff, untracked := worktreeDiff(top, base.ref)
		s := fmt.Sprintf("the change in %s against %s", ws.Name, base.name)
		if untracked > 0 {
			s += fmt.Sprintf(" (%d new file(s) included)", untracked)
		}
		return diff, s, ""
	case artifactTestLog:
		// Written by the verification run itself: the receipt carries
		// only a tail, and this is what makes that truncation honest.
		body, err := os.ReadFile(filepath.Join(edgeArtifactDir(ws.Name), verifyLogName))
		if err != nil {
			return nil, "", "no verification has run for " + ws.Name + " on this device"
		}
		return body, "the last verification run's full output", ""
	case artifactReport:
		for _, rel := range reportCandidates {
			if body, err := os.ReadFile(filepath.Join(ws.Root, rel)); err == nil && len(body) > 0 {
				return body, "the agent's written " + filepath.Base(rel), ""
			}
		}
		return nil, "", "the agent wrote none of " + strings.Join(reportCandidates, ", ") + " in " + ws.Name
	}
	return nil, "", fmt.Sprintf("no artifact kind %q on this device (offered: %s, %s, %s)",
		kind, artifactDiff, artifactReport, artifactTestLog)
}

// worktreeDiff renders the tree's whole change as one unified diff:
// tracked work against ref, then each untracked file against nothing.
//
// The second half is not a nicety. `git diff` cannot see a file git has
// never been told about, so a change that ADDS files would otherwise be
// declared as evidence while omitting the part that matters most — the
// new code. --no-index exits non-zero when the files differ, which for
// this loop is every time, so its status carries no information and is
// deliberately ignored.
func worktreeDiff(top, ref string) (diff []byte, untracked int) {
	tracked, err := gitOut(top, artifactGitTimeout, "diff", ref)
	if err == nil {
		diff = append(diff, tracked...)
	}
	others, err := gitOut(top, artifactGitTimeout, "ls-files", "--others", "--exclude-standard", "-z")
	if err != nil {
		return diff, 0
	}
	for _, f := range strings.Split(strings.TrimRight(string(others), "\x00"), "\x00") {
		if f == "" {
			continue
		}
		if untracked == artifactMaxUntracked {
			diff = append(diff, fmt.Appendf(nil,
				"\n# rook: stopped after %d new files; more were present\n", artifactMaxUntracked)...)
			break
		}
		untracked++
		out, _ := gitOut(top, artifactGitTimeout, "diff", "--no-index", "--", os.DevNull, f)
		diff = append(diff, out...)
	}
	return diff, untracked
}
