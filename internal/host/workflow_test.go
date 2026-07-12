package host

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/incantery/rook/internal/config"
)

// writeHostConfig writes ~/.config/rook/config inside the test's isolated
// XDG_CONFIG_HOME (config.Load hot-reads it per call, so no restart needed).
func writeHostConfig(t *testing.T, content string) {
	t.Helper()
	dir := os.Getenv("XDG_CONFIG_HOME")
	if dir == "" {
		t.Fatal("test must set XDG_CONFIG_HOME first")
	}
	if err := os.MkdirAll(filepath.Join(dir, "rook"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "rook", "config"), []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

// killAllSessions reaps every live shell a workflow test spawned.
func killAllSessions(h *Host) {
	h.mu.Lock()
	var ids []string
	for id := range h.sessions {
		ids = append(ids, id)
	}
	h.mu.Unlock()
	for _, id := range ids {
		h.kill(id)
	}
}

// waitGone blocks until the session disappears (readPump reaps it) or the
// timeout hits.
func waitGone(t *testing.T, h *Host, id string) {
	t.Helper()
	for range 200 {
		if h.get(id) == nil {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("session %s never died", id)
}

// workflowFor's precedence: own key (where empty = explicit opt-out), then
// the source workspace's via WorktreeOf (configure the repo once), then the
// global list.
func TestWorkflowFor(t *testing.T) {
	t.Setenv("XDG_CONFIG_HOME", t.TempDir())
	writeHostConfig(t, `
workflow = /security-review, /review
workflow-src = /custom
workflow-quiet =
`)
	if got := workflowFor(&WorkspaceInfo{Name: "other"}); len(got) != 2 {
		t.Fatalf("global fallback: %v", got)
	}
	if got := workflowFor(&WorkspaceInfo{Name: "src"}); len(got) != 1 || got[0] != "/custom" {
		t.Fatalf("own key: %v", got)
	}
	if got := workflowFor(&WorkspaceInfo{Name: "src-t1", WorktreeOf: "src"}); len(got) != 1 || got[0] != "/custom" {
		t.Fatalf("worktree must inherit the source's list: %v", got)
	}
	if got := workflowFor(&WorkspaceInfo{Name: "quiet"}); len(got) != 0 {
		t.Fatalf("empty override must opt out of the global list: %v", got)
	}
	if got := workflowFor(&WorkspaceInfo{Name: "quiet-t1", WorktreeOf: "quiet"}); len(got) != 0 {
		t.Fatalf("opt-out must inherit too: %v", got)
	}
	if got := workflowFor(nil); got != nil {
		t.Fatalf("nil workspace: %v", got)
	}
}

// The engine end to end (below the gh poll — the none→open transition is
// four lines in pollPRs; the trigger's dedup lives in insertStages, which
// this exercises): seed once across repeated triggers, stage completion
// gated on the stage's own window, sequential advance, halt on a lost
// window.
func TestWorkflowEngine(t *testing.T) {
	h, srv, _ := newWorktreeHost(t)
	defer killAllSessions(h)
	writeHostConfig(t, "workflow = /security-review, /review, /final\n")
	c := &wtClient{srv.URL, h.Token()}

	code, body := c.do(t, "POST", "/workspaces", map[string]any{"worktreeFrom": "src"})
	if code != 200 {
		t.Fatalf("create worktree: %d %s", code, body)
	}
	var ws WorkspaceInfo
	json.Unmarshal([]byte(body), &ws)

	// the trigger: coding done (PR appeared) → seed + spawn stage 1
	h.maybeStartWorkflow(h.reg.get(ws.Name))
	run := h.reg.runningStage(ws.Name)
	if run == nil || run.Name != "/security-review" || run.RookSession == "" {
		t.Fatalf("first stage must be running in a window: %+v", run)
	}
	if h.get(run.RookSession) == nil {
		t.Fatal("the stage's window must be live")
	}

	// repeated poll ticks re-fire the trigger: no reseed, no second window
	h.maybeStartWorkflow(h.reg.get(ws.Name))
	if st := h.reg.stagesFor(ws.Name); len(st) != 3 {
		t.Fatalf("reseeded to %d rows", len(st))
	}
	if again := h.reg.runningStage(ws.Name); again == nil || again.ID != run.ID {
		t.Fatalf("running stage changed on retrigger: %+v", again)
	}

	// attribution gate: a DIFFERENT window in the same worktree (a manual
	// claude, the original coding agent) finishing its turn must not
	// complete the review stage
	other, err := h.spawn(80, 24, ws.Root, ws.Name)
	if err != nil {
		t.Fatal(err)
	}
	h.bindMu.Lock()
	h.claims["t-other"] = other.info.ID
	h.claims["t-stage"] = run.RookSession
	h.bindMu.Unlock()
	h.onTurnFinished("t-other")
	if s := h.reg.runningStage(ws.Name); s == nil || s.ID != run.ID {
		t.Fatalf("foreign turn completed the stage: %+v", s)
	}

	// the stage's own window finishing advances the pipeline
	h.onTurnFinished("t-stage")
	run2 := h.reg.runningStage(ws.Name)
	if run2 == nil || run2.Name != "/review" {
		t.Fatalf("pipeline must advance to /review: %+v", run2)
	}
	if st := h.reg.stagesFor(ws.Name); st[0].Status != "done" {
		t.Fatalf("finished stage must read done: %+v", st[0])
	}

	// window closed mid-stage → the poll-ride reconciler errors it and the
	// pipeline HALTS (no silent skip to stage 3)
	h.kill(run2.RookSession)
	waitGone(t, h, run2.RookSession)
	h.reconcileStage(ws.Name)
	st := h.reg.stagesFor(ws.Name)
	if st[1].Status != "error" || st[1].Detail == "" {
		t.Fatalf("lost window must error the stage with a detail: %+v", st[1])
	}
	h.advanceWorkflow(ws.Name)
	if st = h.reg.stagesFor(ws.Name); st[2].Status != "pending" {
		t.Fatalf("an errored pipeline must not advance: %+v", st[2])
	}

	// workspace deletion clears the pipeline
	if code, body := c.do(t, "DELETE", "/workspaces/"+ws.Name+"?force=1", nil); code != 204 {
		t.Fatalf("delete: %d %s", code, body)
	}
	if len(h.reg.stagesFor(ws.Name)) != 0 {
		t.Fatal("workspace deletion must drop its stages")
	}
}

// No workflow configured = the feature is off: the trigger must not seed,
// spawn, or leave any trace.
func TestWorkflowOffByDefault(t *testing.T) {
	h, srv, _ := newWorktreeHost(t)
	defer killAllSessions(h)
	c := &wtClient{srv.URL, h.Token()}
	code, body := c.do(t, "POST", "/workspaces", map[string]any{"worktreeFrom": "src"})
	if code != 200 {
		t.Fatalf("create worktree: %d %s", code, body)
	}
	var ws WorkspaceInfo
	json.Unmarshal([]byte(body), &ws)

	if cfg := config.Load(); len(cfg.Workflow) != 0 {
		t.Fatalf("test env leaked a workflow: %v", cfg.Workflow)
	}
	h.maybeStartWorkflow(h.reg.get(ws.Name))
	if len(h.reg.stagesFor(ws.Name)) != 0 {
		t.Fatal("no workflow configured must mean no stages")
	}
	h.mu.Lock()
	n := len(h.sessions)
	h.mu.Unlock()
	if n != 0 {
		t.Fatalf("no workflow configured must spawn nothing, got %d sessions", n)
	}
}

// GET /overview carries the checklist: absent when the feature is off,
// the configured plan (synthetic coding row leading) before the PR opens,
// live statuses once seeded — and never on non-worktree workspaces.
func TestOverviewStages(t *testing.T) {
	h, srv, _ := newWorktreeHost(t)
	defer killAllSessions(h)
	c := &wtClient{srv.URL, h.Token()}
	code, body := c.do(t, "POST", "/workspaces", map[string]any{"worktreeFrom": "src"})
	if code != 200 {
		t.Fatalf("create worktree: %d %s", code, body)
	}
	var ws WorkspaceInfo
	json.Unmarshal([]byte(body), &ws)

	find := func(name string) *overviewItem {
		t.Helper()
		code, body := c.do(t, "GET", "/overview", nil)
		if code != 200 {
			t.Fatalf("overview: %d %s", code, body)
		}
		var items []overviewItem
		json.Unmarshal([]byte(body), &items)
		for i := range items {
			if items[i].Name == name {
				return &items[i]
			}
		}
		t.Fatalf("%s missing from overview", name)
		return nil
	}

	// feature off: no stages field at all (old frontends see nothing new)
	if it := find(ws.Name); it.Stages != nil {
		t.Fatalf("stages must be absent with no workflow: %+v", it.Stages)
	}

	// configured, PR not open yet: the whole plan renders — synthetic
	// coding stage running, the review stages pending
	writeHostConfig(t, "workflow = /security-review, /review\n")
	it := find(ws.Name)
	if len(it.Stages) != 3 || it.Stages[0].Name != "coding" || it.Stages[0].Status != "running" ||
		it.Stages[1].Status != "pending" || it.Stages[2].Status != "pending" {
		t.Fatalf("pre-PR plan: %+v", it.Stages)
	}
	// the source workspace never carries a checklist
	if src := find("src"); src.Stages != nil {
		t.Fatalf("non-worktree workspace must not carry stages: %+v", src.Stages)
	}

	// seeded and running: coding flips done, rows carry live status
	h.maybeStartWorkflow(h.reg.get(ws.Name))
	it = find(ws.Name)
	if len(it.Stages) != 3 || it.Stages[0].Status != "done" ||
		it.Stages[1].Name != "/security-review" || it.Stages[1].Status != "running" {
		t.Fatalf("seeded checklist: %+v", it.Stages)
	}

	// PR already open with no rows (host was down at the transition): no
	// checklist — an honest nothing beats a forever-pending promise
	h.reg.deleteStages(ws.Name)
	h.prm.set(ws.Name, PRSnapshot{State: "open", Number: 7, CheckedAt: time.Now()})
	if it = find(ws.Name); it.Stages != nil {
		t.Fatalf("open PR without rows must carry no checklist: %+v", it.Stages)
	}
}
