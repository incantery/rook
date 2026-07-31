package host

import (
	"slices"
	"sort"
	"sync"
	"time"
)

// overviewItems is the machine's live picture: every workspace in ONE
// pass, each carrying its live rollup — agent states, attention, git,
// foreground processes.
//
// It was GET /overview, the webview's mission-control payload. The endpoint
// went with the agent deck in the strip; the projection stayed, because
// cloudProject reads it to build the status snapshot this machine pushes.
// That is now its only caller, and cloudProject is the privacy line.

// overviewAgent is the row-sized slice of an AgentStatus: enough to say what
// the agent is doing (and asking), and enough to OPEN it.
//
// The ids are what changed. This used to feed a workspace card's chips —
// counts and a one-liner, nothing you could act on — so it named nothing and
// an agent could only be addressed as "the workspace it happens to be in". A
// row you press ↵ on is a different contract: SessionID addresses the
// transcript (the conversation view), RookSession addresses the pty (raw
// attach). Two ids because they are two different things. Same asymmetry
// PaneRef had, same fix. The deck that pressed ↵ has left; the ids stay,
// because whatever renders this list next needs to address both.
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

func (h *Host) overviewItems() []overviewItem {
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
					o.Agents = append(o.Agents, agentRow(s))
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
