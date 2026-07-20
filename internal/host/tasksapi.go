package host

// HTTP surface for RookTask + the review work-type. Workspace-scoped
// endpoints (prepare a review, list the tree) hang off /workspaces/{name}/…;
// per-task verbs use global ids under /tasks/{id}/… — `rookctl approve 12`
// works from anywhere, exactly like the thread verbs.

import (
	"database/sql"
	"encoding/json"
	"net/http"
	"strconv"
	"strings"
)

// handleWorkspaceReview is POST /workspaces/{name}/review {scope, arg} —
// prepare (or rebuild) a review batch. Pure git; returns the parent task.
func (h *Host) handleWorkspaceReview(w http.ResponseWriter, r *http.Request, name string) {
	ws, top, ok := h.reviewRepo(w, name)
	if !ok {
		return
	}
	var req struct {
		Scope, Arg string
		DryRun     bool
	}
	json.NewDecoder(r.Body).Decode(&req)
	// dry run: build the batch in memory, write nothing to rook.db
	if req.DryRun {
		parent, err := h.dryRunReview(ws, top, req.Scope, req.Arg)
		if err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		writeJSON(w, map[string]any{
			"task":   parent,
			"gate":   gateFromChildren(parent.Children, parentVerb(parent)),
			"dryRun": true,
		})
		return
	}
	parent, err := h.prepareReview(ws, top, req.Scope, req.Arg)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	// return the tree and its gate in one payload — the caller renders both
	parent.Children = h.reg.childrenOf(parent.ID)
	writeJSON(w, map[string]any{"task": parent, "gate": h.reviewGateFor(parent)})
}

// handleWorkspaceTasks is GET /workspaces/{name}/tasks?workType= — the root
// tasks (children one level deep). Review parents carry their gate.
func (h *Host) handleWorkspaceTasks(w http.ResponseWriter, r *http.Request, name string) {
	if h.reg.get(name) == nil {
		http.Error(w, "no such workspace: "+name, http.StatusNotFound)
		return
	}
	roots := h.reg.listRootTasks(name, r.URL.Query().Get("workType"))
	type rootWithGate struct {
		*RookTask
		Gate *reviewGate `json:"gate,omitempty"`
		// a Haiku triage fan-out is in flight — clients poll while true
		Scoring bool `json:"scoring,omitempty"`
	}
	out := make([]rootWithGate, 0, len(roots))
	for _, t := range roots {
		rw := rootWithGate{RookTask: t, Scoring: h.isScoring(t.ID)}
		if t.WorkType == "review" {
			g := h.reviewGateFor(t)
			rw.Gate = &g
		}
		out = append(out, rw)
	}
	writeJSON(w, out)
}

// handleTask routes /tasks/{id} and /tasks/{id}/{state,score,gate}. Ids are
// global, so these verbs need no workspace.
func (h *Host) handleTask(w http.ResponseWriter, r *http.Request) {
	rest := strings.TrimPrefix(r.URL.Path, "/tasks/")
	idStr, action, _ := strings.Cut(rest, "/")
	id, err := strconv.ParseInt(idStr, 10, 64)
	if err != nil {
		http.Error(w, "not found", http.StatusNotFound)
		return
	}
	switch {
	case action == "" && r.Method == http.MethodGet:
		t := h.reg.getTask(id)
		if t == nil {
			http.Error(w, "no such task", http.StatusNotFound)
			return
		}
		t.Children = h.reg.childrenOf(t.ID)
		writeJSON(w, struct {
			*RookTask
			Scoring bool `json:"scoring,omitempty"`
		}{t, h.isScoring(id)})
	case action == "state" && r.Method == http.MethodPost:
		h.handleTaskState(w, r, id)
	case action == "score" && r.Method == http.MethodPost:
		h.handleTaskScore(w, r, id)
	case action == "score-all" && r.Method == http.MethodPost:
		// trigger the Haiku triage fan-out for a review root; async — poll
		// the task (scoring flag + per-child detail) to watch it land
		t := h.reg.getTask(id)
		if t == nil {
			http.Error(w, "no such task", http.StatusNotFound)
			return
		}
		if t.WorkType != "review" || t.ParentID != 0 {
			http.Error(w, "score-all wants a review root", http.StatusBadRequest)
			return
		}
		if err := h.scoreReviewAsync(t); err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		writeJSON(w, map[string]any{"scoring": true})
	case action == "gate" && r.Method == http.MethodGet:
		t := h.reg.getTask(id)
		if t == nil {
			http.Error(w, "no such task", http.StatusNotFound)
			return
		}
		writeJSON(w, h.reviewGateFor(t))
	default:
		http.Error(w, "not found", http.StatusNotFound)
	}
}

// handleTaskState is POST /tasks/{id}/state {state} — a leaf's disposition.
// Accepts a comma-separated id list in the PATH too? No: bulk goes through
// repeated calls from rookctl; keep the endpoint single-id and simple.
func (h *Host) handleTaskState(w http.ResponseWriter, r *http.Request, id int64) {
	var req struct{ State string }
	json.NewDecoder(r.Body).Decode(&req)
	t := h.reg.getTask(id)
	if t == nil {
		http.Error(w, "no such task", http.StatusNotFound)
		return
	}
	// the work_type owns the vocabulary — review is the only one today
	if t.WorkType == "review" && !validReviewLeafState(req.State) {
		http.Error(w, "invalid review state: "+req.State, http.StatusBadRequest)
		return
	}
	if err := h.reg.setTaskState(id, req.State); err != nil {
		http.Error(w, "no such task", http.StatusNotFound)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// handleTaskScore is POST /tasks/{id}/score — a scorer's write path. The body
// merges into the task's detail bag (never clobbering {scope,…}); scores are
// disposable, so we store whatever the scorer sends verbatim.
func (h *Host) handleTaskScore(w http.ResponseWriter, r *http.Request, id int64) {
	var incoming map[string]json.RawMessage
	if err := json.NewDecoder(r.Body).Decode(&incoming); err != nil {
		http.Error(w, "bad body: "+err.Error(), http.StatusBadRequest)
		return
	}
	if err := h.reg.mergeTaskDetail(id, incoming); err != nil {
		if err == sql.ErrNoRows {
			http.Error(w, "no such task", http.StatusNotFound)
			return
		}
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}
