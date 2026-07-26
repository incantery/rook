package host

import (
	"net/http"
	"slices"
	"sort"
	"sync"
	"time"
)

// GET /overview: the mission-control payload (issue #12) — every workspace
// in ONE call, each carrying the live rollup its dashboard would show:
// agent states, attention, git, foreground processes. One endpoint instead
// of N status calls so the landing screen can poll it like the dashboard
// polls /workspaces/{name}/status. Old frontends never ask; new frontends
// fall back to /workspaces when this 404s on an old daemon.

// overviewAgent is the row-sized slice of an AgentStatus: enough to say what
// the agent is doing (and asking), and enough to OPEN it.
//
// The ids are what changed. This used to feed a workspace card's chips —
// counts and a one-liner, nothing you could act on — so it named nothing and
// an agent could only be addressed as "the workspace it happens to be in". A
// row you press ↵ on is a different contract: SessionID addresses the
// transcript (the conversation view), RookSession addresses the pty (raw
// attach). Two ids because they are two different things, and the deck offers
// both verbs. Same asymmetry PaneRef had, same fix.
//
// In practice BOTH are always set, and that is worth knowing rather than
// hoping. Rows are built from correlated sessions only (see handleOverview),
// and correlate() only ever attaches an agent to a window whose foreground
// process is the coder — so a row cannot exist without a pty behind it, and
// the agent named itself the moment the watcher saw it.
//
// The cost is the inverse: an agent the host CANNOT correlate gets no row at
// all. Shell out of claude (ctrl-Z, or a `git log` at the prompt) and its
// window stops being a claude window, so the agent drops off the deck until
// you come back. correlate() already keeps the fact — AgentSession is set on
// the session regardless of what's foreground — so this is fixable without
// new sensors, and it is worth fixing precisely because the deck exists to
// watch agents you are NOT sitting in front of.
//
// omitempty stays on both anyway: an old daemon omits these fields entirely,
// and clients read them as absent and drop the verb they cannot reach. That
// is the fail-open half, and it is real even though the empty-string half
// isn't.
type overviewAgent struct {
	State string `json:"state"` // working | needs_input | quiet
	Title string `json:"title,omitempty"`
	Ask   string `json:"ask,omitempty"`
	Tool  string `json:"tool,omitempty"`
	// SessionID is the claude transcript id — the conversation view.
	SessionID string `json:"sessionId,omitempty"`
	// RookSession is the pty session holding this agent's claude — raw
	// attach, and what the deck's ↵-into-the-terminal jumps to.
	RookSession string  `json:"rookSession,omitempty"`
	Model       string  `json:"model,omitempty"`
	CostUSD     float64 `json:"costUsd,omitempty"`
	// LastEvent drives the row's age column. Not omitempty: a zero time
	// marshals as a zero date rather than vanishing, and the reader needs
	// to tell "no activity recorded" from "field absent".
	LastEvent time.Time `json:"lastEvent"`
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
	writeJSON(w, h.overviewItems())
}

// overviewItems assembles the mission-control rollup. Split from the
// handler because the cloud reporter (cloud.go) sends the same picture the
// deck renders — one assembly, two consumers, no drift between what you
// see at the desk and what you see on your phone.
func (h *Host) overviewItems() []overviewItem {
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
					o.Agents = append(o.Agents, agentRow(s))
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
	return out
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

// agentRow projects a correlated session into the row the deck renders.
//
// It is split out of the assembly loop because it is the part worth testing.
// s.ID is the pty the agent was correlated to; s.Agent.SessionID is its
// transcript — two ids, from two different objects, that a struct literal
// nested three levels inside a goroutine could quietly stop carrying without
// anything failing to compile. The symptom would be a row that renders
// perfectly and does nothing when you press ↵.
func agentRow(s sessionStatus) overviewAgent {
	return overviewAgent{
		State: s.Agent.State, Title: s.Agent.Title,
		Ask: s.Agent.Ask, Tool: s.Agent.Tool,
		SessionID: s.Agent.SessionID, RookSession: s.ID,
		Model: s.Agent.Model, CostUSD: s.Agent.CostUSD,
		LastEvent: s.Agent.LastEvent,
	}
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
