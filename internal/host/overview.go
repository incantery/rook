package host

import (
	"net/http"
	"slices"
	"sort"
	"sync"
)

// GET /overview: the mission-control payload (issue #12) — every workspace
// in ONE call, each carrying the live rollup its dashboard would show:
// agent states, attention, git, foreground processes. One endpoint instead
// of N status calls so the landing screen can poll it like the dashboard
// polls /workspaces/{name}/status. Old frontends never ask; new frontends
// fall back to /workspaces when this 404s on an old daemon.

// overviewAgent is the card-sized slice of an AgentStatus: enough to say
// what the agent is doing (and asking), nothing session-internal.
type overviewAgent struct {
	State string `json:"state"` // working | needs_input | quiet
	Title string `json:"title,omitempty"`
	Ask   string `json:"ask,omitempty"`
	Tool  string `json:"tool,omitempty"`
}

// StageInfo is one row of a work item's checklist: the persisted stage rows
// plus the synthetic coding stage in front. NeedsInput is live agent state
// decorated at read time — deliberately not a persisted status.
type StageInfo struct {
	Name        string `json:"name"`
	Status      string `json:"status"` // pending | running | done | error
	NeedsInput  bool   `json:"needsInput,omitempty"`
	Detail      string `json:"detail,omitempty"`
	rookSession string // decoration key, never serialized
}

type overviewItem struct {
	workspaceListItem
	// Live rollup — only populated for workspaces with sessions; idle
	// workspaces cost nothing (no lsof, no git probe). Idle worktrees
	// already carry dirty/ahead on their PR snapshot.
	Git       *GitInfo        `json:"git,omitempty"`
	Fg        []string        `json:"fg,omitempty"` // distinct foreground commands, window order
	Agents    []overviewAgent `json:"agents,omitempty"`
	Attention int             `json:"attention,omitempty"`
	// Stages is the work item's checklist (worktrees only, workflow
	// configured or already seeded) — assembled even for idle workspaces,
	// so an errored pipeline stays visible with no live sessions.
	Stages []StageInfo `json:"stages,omitempty"`
}

func (h *Host) handleOverview(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	items := h.workspaceList()
	out := make([]overviewItem, len(items))
	var wg sync.WaitGroup
	for i, it := range items {
		out[i] = overviewItem{workspaceListItem: it}
		// checklist OUTSIDE the sessions guard: an idle worktree's errored
		// or finished pipeline must still render
		out[i].Stages = h.stageList(&it)
		if it.Sessions == 0 {
			continue
		}
		wg.Add(1)
		go func(o *overviewItem, name string) {
			defer wg.Done()
			st := h.statusFor(name, true)
			o.Git = st.Git
			o.Attention = st.Attention
			for _, s := range st.Sessions {
				if s.Fg != "" && !slices.Contains(o.Fg, s.Fg) {
					o.Fg = append(o.Fg, s.Fg)
				}
				if s.Agent != nil {
					o.Agents = append(o.Agents, overviewAgent{
						State: s.Agent.State, Title: s.Agent.Title,
						Ask: s.Agent.Ask, Tool: s.Agent.Tool,
					})
				}
				// a running stage whose window is waiting on the user: the
				// checklist's ◉ — live state, decorated, never persisted
				for j := range o.Stages {
					if o.Stages[j].Status == "running" && o.Stages[j].rookSession == s.ID &&
						s.Agent != nil && s.Agent.State == "needs_input" {
						o.Stages[j].NeedsInput = true
					}
				}
			}
			// needs_input leads — the card's one-liner shows the first agent
			sort.SliceStable(o.Agents, func(a, b int) bool {
				return agentRank(o.Agents[a].State) < agentRank(o.Agents[b].State)
			})
		}(&out[i], it.Name)
	}
	wg.Wait()
	writeJSON(w, out)
}

// stageList assembles a work item's checklist. The synthetic coding stage
// leads — running until the PR exists (or stage rows do), derived from the
// PR snapshot, never persisted. Before the PR opens, the configured plan
// shows as pending rows so the whole pipeline is visible up front. A PR
// that's already open/merged/closed with no rows means the workflow never
// triggered (host was down at the transition) — no checklist, no false
// promise it will run.
func (h *Host) stageList(it *workspaceListItem) []StageInfo {
	if it.WorktreeOf == "" {
		return nil
	}
	rows := h.reg.stagesFor(it.Name)
	if len(rows) > 0 {
		out := make([]StageInfo, 0, len(rows)+1)
		out = append(out, StageInfo{Name: "coding", Status: "done"})
		for _, r := range rows {
			out = append(out, StageInfo{Name: r.Name, Status: r.Status, Detail: r.Detail, rookSession: r.RookSession})
		}
		return out
	}
	if it.PR != nil && it.PR.State != "none" {
		return nil
	}
	configured := workflowFor(&it.WorkspaceInfo)
	if len(configured) == 0 {
		return nil
	}
	out := make([]StageInfo, 0, len(configured)+1)
	out = append(out, StageInfo{Name: "coding", Status: "running"})
	for _, name := range configured {
		out = append(out, StageInfo{Name: name, Status: "pending"})
	}
	return out
}

func agentRank(state string) int {
	switch state {
	case "needs_input":
		return 0
	case "working":
		return 1
	default:
		return 2
	}
}
