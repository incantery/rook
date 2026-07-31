package host

import (
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"time"

	"github.com/incantery/rook/internal/config"
)

// spawnTask is the shared "start the coder on a task" actuator: a fresh
// window in the workspace's root, the coder command typed in once the shell
// has had a beat to come up. Spawn drafts, the conflict-resolve chip, and
// thread nudges all actuate through this one seam. The coder CLI comes
// from the (hot-read) config — `coder = ...`, claude unless overridden —
// and the claim hook correlates the new session on its own.
func (h *Host) spawnTask(ws, task string) (*session, error) {
	wsInfo := h.reg.upsert(ws, "", false)
	s, err := h.spawn(100, 30, wsInfo.Root, ws)
	if err != nil {
		return nil, err
	}
	coder := config.Load().Coder
	if coder == "" {
		coder = "claude"
	}
	go func() {
		time.Sleep(400 * time.Millisecond) // let the shell come up
		s.pty.Write([]byte(coder + " " + shellQuote(task) + "\r"))
	}()
	return s, nil
}

// handleWorkspaceSpawn is POST /workspaces/{name}/spawn: start the coder on
// a task in a fresh window here. The body carries a literal task or a preset
// the host expands — host-built prompts are the house pattern (cf.
// tracker.BuildTask), so every surface actuates the identical thing.
func (h *Host) handleWorkspaceSpawn(w http.ResponseWriter, r *http.Request, name string) {
	ws := h.reg.get(name)
	if ws == nil {
		http.Error(w, "no such workspace: "+name, http.StatusNotFound)
		return
	}
	var req struct {
		Task   string
		Preset string
	}
	json.NewDecoder(r.Body).Decode(&req)
	task := strings.TrimSpace(req.Task)
	switch req.Preset {
	case "":
	case "resolve-conflicts":
		task = resolveConflictsTask(ws)
	default:
		http.Error(w, "unknown preset: "+req.Preset, http.StatusBadRequest)
		return
	}
	if task == "" {
		http.Error(w, "task or preset required", http.StatusBadRequest)
		return
	}
	s, err := h.spawnTask(name, task)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	writeJSON(w, s.info)
}

// resolveConflictsTask is the conflicts chip's prompt: merge (never rebase)
// origin's default branch in, keep both sides' intent, and push so the PR
// updates. The agent pushes via the user's own git auth — the host never
// touches GitHub (READ, NEVER MIRROR).
func resolveConflictsTask(ws *WorkspaceInfo) string {
	branch := ws.Branch
	if branch == "" {
		branch = "the current branch"
	}
	var b strings.Builder
	fmt.Fprintf(&b, "This worktree's PR has merge conflicts with the base branch. Resolve them:\n")
	fmt.Fprintf(&b, "1. Run `git fetch origin`, then merge origin's default branch (see `git remote show origin`) into %s. Do NOT rebase and do NOT force-push.\n", branch)
	fmt.Fprintf(&b, "2. Resolve every conflict preserving the intent of BOTH sides — read the surrounding code before choosing.\n")
	fmt.Fprintf(&b, "3. Run the project's build/tests to confirm the merge is sound.\n")
	fmt.Fprintf(&b, "4. Commit the merge and push the branch so the PR updates.\n")
	return b.String()
}
