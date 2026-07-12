package host

import (
	"log"

	"github.com/incantery/rook/internal/config"
)

// The staged review workflow: when a worktree's coding agent opens its PR
// (the observed none→open transition in pollPRs), the host runs the
// configured slash commands sequentially, one window per stage, in that
// worktree. Event-driven — no goroutine of its own: pollPRs triggers and
// reconciles, the turn_completed hook advances. Stage rows in rook.db are
// the only state; the stages surface on /overview as a checklist.

// workflowFor resolves a workspace's pipeline from the (hot-read) config:
// its own workflow-<ws> key first — where an explicit empty list means
// "opted out" — then the source workspace's (configure the repo once,
// every tree inherits, cf. jira-project in trackersFor), then the global
// workflow. Empty = feature off.
func workflowFor(ws *WorkspaceInfo) []string {
	if ws == nil {
		return nil
	}
	cfg := config.Load()
	if names, ok := cfg.Workflows[ws.Name]; ok {
		return names
	}
	if ws.WorktreeOf != "" {
		if names, ok := cfg.Workflows[ws.WorktreeOf]; ok {
			return names
		}
	}
	return cfg.Workflow
}

// maybeStartWorkflow seeds and starts the pipeline for a worktree whose PR
// just appeared. insertStages is the dedup source of truth: rows already
// existing (a lost trigger race, a re-fired transition) means nothing to do.
func (h *Host) maybeStartWorkflow(ws *WorkspaceInfo) {
	names := workflowFor(ws)
	if len(names) == 0 {
		return
	}
	seeded, err := h.reg.insertStages(ws.Name, names)
	if err != nil {
		log.Printf("workflow: seed %s: %v", ws.Name, err)
		return
	}
	if !seeded {
		return
	}
	log.Printf("workflow: %s → %v", ws.Name, names)
	h.advanceWorkflow(ws.Name)
}

// advanceWorkflow spawns the workspace's next pending stage — if nothing is
// running and nothing has errored (an error halts the pipeline; the ✗ and
// the still-pending rest stay visible, retry is a follow-up). wfMu keeps
// concurrent advances (poll trigger racing a turn completion) from spawning
// two windows for one stage.
func (h *Host) advanceWorkflow(name string) {
	h.wfMu.Lock()
	defer h.wfMu.Unlock()
	if h.reg.runningStage(name) != nil {
		return
	}
	var next *Stage
	for _, st := range h.reg.stagesFor(name) {
		if st.Status == "error" {
			return
		}
		if st.Status == "pending" {
			next = st
			break
		}
	}
	if next == nil {
		return
	}
	s, err := h.spawnTask(name, next.Name)
	if err != nil {
		// halt visibly: the stage erred before it had a window
		if h.reg.startStage(next.ID, "") {
			h.reg.finishStage(next.ID, "error", "spawn failed: "+err.Error())
		}
		log.Printf("workflow: %s stage %q spawn: %v", name, next.Name, err)
		return
	}
	h.reg.startStage(next.ID, s.info.ID)
	log.Printf("workflow: %s stage %q running in %s", name, next.Name, s.info.ID)
}

// onTurnFinished is the stage-completion sensor: a genuine turn_completed
// from agentwatch (never AskUserQuestion or a permission notify — those go
// through onTurnCompleted, the ask-invalidation hook). The rook_session
// gate is load-bearing: only the window the stage claimed may complete it —
// a manual claude or the coding agent in the same worktree must not.
func (h *Host) onTurnFinished(agentSession string) {
	s := h.pairedSession(agentSession, true)
	if s == nil {
		return
	}
	stage := h.reg.runningStage(s.info.Workspace)
	if stage == nil || stage.RookSession == "" || stage.RookSession != s.info.ID {
		return
	}
	if h.reg.finishStage(stage.ID, "done", "") {
		log.Printf("workflow: %s stage %q done", s.info.Workspace, stage.Name)
		h.advanceWorkflow(s.info.Workspace)
	}
}

// reconcileStage errors a running stage whose window no longer exists (the
// user closed it, the shell died). Piggybacked on pollPRs — a minute of lag
// is fine for a spinner that would otherwise spin forever. The pipeline
// halts (error semantics), it does not skip ahead.
func (h *Host) reconcileStage(name string) {
	stage := h.reg.runningStage(name)
	if stage == nil || stage.RookSession == "" {
		return
	}
	if h.get(stage.RookSession) == nil {
		if h.reg.finishStage(stage.ID, "error", "window closed before the stage finished") {
			log.Printf("workflow: %s stage %q lost its window", name, stage.Name)
		}
	}
}
