package host

// release_resource: §6.6's compensation, which is a much narrower thing
// than it sounds and is deliberately NOT cleanup.
//
// The spec lists what compensation may be — release a lease, close a
// port, revoke a credential, remove an EMPTY worktree the run created —
// and then draws the line that matters: "'Undo the code change' is not a
// generic compensation." §6.5 says the same from the other side: never
// delete a dirty worktree automatically, cleanup is its own typed,
// policy-checked operation. So this op releases the device's HOLD on a
// resource; it does not undo what happened inside it.
//
// The clearest way to see the difference is against cleanup_worktree,
// which tests the same predicate and takes the opposite disposition:
//
//	                  tree is empty        tree has work
//	cleanup_worktree  removes it           FAILS, tree preserved
//	release_resource  removes it           SUCCEEDS, tree preserved
//
// Both preserve work. They disagree about what the outcome MEANS,
// because their jobs differ: cleanup exists to remove, so preserving is
// a failed cleanup; release exists to let go, and a released hold over a
// preserved tree is exactly what was asked for. Which is also why
// cleanup is grant-gated and this is not — release's destructive path
// cannot reach anything a human would want back.
//
// Releasing a session does NOT stop it. That is interrupt's job, and
// conflating them would make "the run stopped tracking this" and "the
// agent was killed" the same message. What release does is stop the
// device NARRATING a session the run has let go of: the sensors go
// quiet, the window and its scrollback stay exactly where the human left
// them, and no event is emitted — a `stopped` here would be a lie about
// a process that may well still be running.

import (
	"encoding/json"
	"fmt"
	"log"
	"os"
	"strings"

	edgev1 "github.com/incantery/rook/gen/rook/edge/v1"
)

// edgeReleaseResource drops this device's hold on one resource.
func (h *Host) edgeReleaseResource(cmd *edgev1.EdgeCommand, p *edgev1.ReleaseResource) (string, string) {
	switch p.ResourceType {
	case "agent_session":
		return h.edgeReleaseSession(p.ResourceId)
	case "worktree":
		return h.edgeReleaseWorktree(cmd)
	case "terminal_input":
		// The input-ownership lease (§6.5) is held in the Cloud, which is
		// what stops it minting a send while a human has the keys — this
		// device never held it, so there is nothing here to let go of.
		// Answering plainly beats inventing local state to release.
		data, _ := json.Marshal(map[string]any{
			"resourceType": p.ResourceType, "resourceId": p.ResourceId,
			"released": true, "note": "terminal input ownership is held in the cloud, not here",
		})
		return "succeeded", string(data)
	}
	return "rejected", edgeReason(fmt.Sprintf(
		"no resource type %q on this device (offered: agent_session, worktree, terminal_input)",
		p.ResourceType))
}

// edgeReleaseSession stops the device reporting on a session without
// touching it. Converges: a session already released, or one this device
// never knew, is a hold that is not held.
func (h *Host) edgeReleaseSession(sessionID string) (string, string) {
	ses, err := h.reg.edgeSession(sessionID)
	if err != nil {
		return "rejected", edgeReason("journal unavailable: " + err.Error())
	}
	if ses == nil {
		return "rejected", edgeReason("no session " + sessionID + " on this device")
	}
	if err := h.reg.releaseEdgeSession(sessionID); err != nil {
		return "failed", edgeReason("journal unavailable: " + err.Error())
	}
	// Deliberately no event and no kill: see the package comment. The
	// receipt records whether the window outlived the hold, because that
	// is the fact a human reading the run's record will want.
	live := h.get(ses.RookSession) != nil
	log.Printf("edge: released session %s (window still up: %v)", sessionID, live)
	data, _ := json.Marshal(map[string]any{
		"resourceType": "agent_session", "resourceId": sessionID,
		"released": true, "windowStillUp": live,
	})
	return "succeeded", string(data)
}

// edgeReleaseWorktree drops the hold, and removes the tree only when it
// can prove there is nothing in it to lose — §6.6's "remove an empty
// worktree created by the run", and nothing wider.
func (h *Host) edgeReleaseWorktree(cmd *edgev1.EdgeCommand) (string, string) {
	name := edgeWorkspaceName(cmd.WorkflowRunId)
	ws := h.reg.get(name)
	if ws == nil || ws.WorktreeOf == "" {
		// Already gone, or never this run's: the hold is not held.
		data, _ := json.Marshal(map[string]any{
			"resourceType": "worktree", "resourceId": name,
			"released": true, "removed": false, "note": "no worktree for this run on this device",
		})
		return "succeeded", string(data)
	}

	res := map[string]any{
		"resourceType": "worktree", "resourceId": name,
		"released": true, "branch": ws.Branch,
	}
	if _, err := os.Stat(ws.Root); err == nil {
		// Every reason to keep the tree, not the first one found. A tree
		// can be occupied AND have work in it, and a receipt that named
		// only one would understate what survived — the whole point of
		// this op's report is that a human can read what it did not do.
		var keep []string
		if dirty, unmerged, err := worktreeRisk(ws.Root, ws.Branch); err != nil {
			// Cannot prove it is empty, so it is not empty.
			keep = append(keep, "could not prove the worktree is empty: "+err.Error())
		} else if dirty > 0 || unmerged > 0 {
			keep = append(keep, fmt.Sprintf(
				"%d uncommitted file(s) and %d unmerged commit(s) on %s — this is work, not an empty tree",
				dirty, unmerged, ws.Branch))
		}
		// git is not the only witness. An agent that has read all morning
		// and written nothing leaves a clean status, and a shell sitting in
		// the tree leaves none at all; pulling the checkout out from under
		// either is exactly the surprise release exists not to cause.
		// cleanup kills its windows first because removing is its job —
		// release's job is to let go, so a window is reason enough to stop.
		if live := h.sessionsIn(name); len(live) > 0 {
			keep = append(keep, fmt.Sprintf("%d window(s) still open in it", len(live)))
		}
		switch {
		case len(keep) > 0:
			// Releasing the hold still SUCCEEDS; only the tree stays.
			res["removed"], res["note"] = false, "kept: "+strings.Join(keep, "; ")
		default:
			if rmErr := worktreeRemove(ws.Root, false); rmErr != nil {
				res["removed"], res["note"] = false, "kept: "+rmErr.Error()
			} else {
				h.reg.remove(name)
				h.prm.forget(name)
				h.reg.deleteStages(name)
				res["removed"], res["note"] = true, "the run created it and left nothing in it"
			}
		}
	} else {
		// The registry row outlived the checkout: drop the row and
		// everything keyed to it, exactly as cleanup does — a workspace
		// that no longer exists must not leave a PR snapshot or stage rows
		// behind to be read as live.
		h.reg.remove(name)
		h.prm.forget(name)
		h.reg.deleteStages(name)
		res["removed"], res["note"] = false, "the checkout was already gone"
	}
	data, _ := json.Marshal(res)
	log.Printf("edge: released worktree %s (removed: %v)", name, res["removed"])
	return "succeeded", string(data)
}
