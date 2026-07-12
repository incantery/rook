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

type overviewItem struct {
	workspaceListItem
	// Live rollup — only populated for workspaces with sessions; idle
	// workspaces cost nothing (no lsof, no git probe). Idle worktrees
	// already carry dirty/ahead on their PR snapshot.
	Git       *GitInfo        `json:"git,omitempty"`
	Fg        []string        `json:"fg,omitempty"` // distinct foreground commands, window order
	Agents    []overviewAgent `json:"agents,omitempty"`
	Attention int             `json:"attention,omitempty"`
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
