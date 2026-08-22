package sessions

import (
	"fmt"
	"sort"
	"strings"

	"github.com/incantery/rook/internal/attention"
)

// Agent is one agent pane on the rook server, with everything the
// agents view needs to say where it is and what it wants.
type Agent struct {
	PaneID     string     `json:"pane"`
	Session    string     `json:"session"`
	Window     string     `json:"window"`
	WindowName string     `json:"window_name"`
	Dir        string     `json:"dir"`
	Repo       string     `json:"repo,omitempty"`
	Branch     string     `json:"branch,omitempty"`
	State      AgentState `json:"-"`
	StateName  string     `json:"state"`
	// Headline is the newest attention item pointing at the session,
	// "" when nothing is published for it.
	Headline string `json:"headline,omitempty"`
}

// Agents lists every agent pane on the server, the ones that need a
// human first, then working, then done; ties keep server order. One
// list-panes call, one capture per agent pane.
func Agents() []Agent {
	out, err := rookTmux("list-panes", "-a", "-F",
		"#{pane_id}\t#{session_name}\t#{window_index}\t#{window_name}\t#{pane_current_path}\t#{pane_current_command}\t#{pane_title}")
	if err != nil {
		return nil
	}
	feed := attention.Load()
	var agents []Agent
	for line := range strings.SplitSeq(strings.TrimSpace(out), "\n") {
		f := strings.Split(line, "\t")
		if len(f) < 7 || !IsAgentPane(f[5], f[6]) {
			continue
		}
		a := Agent{PaneID: f[0], Session: f[1], Window: f[2], WindowName: f[3], Dir: f[4]}
		a.Repo, a.Branch = gitInfo(a.Dir)
		a.State = paneState(a.PaneID)
		items := attention.ForSession(feed, a.Session)
		if attention.AnyWaiting(items) {
			a.State = a.State.merge(StateWaiting)
		}
		for _, it := range items {
			if a.Headline == "" || it.Waiting() {
				a.Headline = it.Headline
			}
		}
		a.StateName = a.State.String()
		agents = append(agents, a)
	}
	sort.SliceStable(agents, func(i, j int) bool { return agents[i].State > agents[j].State })
	return agents
}

// Screen is a pane's current screen as text, for a preview.
func Screen(paneID string) string {
	out, err := rookTmux("capture-pane", "-p", "-t", paneID)
	if err != nil {
		return ""
	}
	return strings.TrimRight(out, "\n")
}

// Goto switches the rook client to a pane: its session, window, and
// the pane itself.
func Goto(a Agent) error {
	if out, err := rookTmux("switch-client", "-t", "="+a.Session); err != nil {
		return fmtErr("switching to %s: %s", a.Session, out)
	}
	if out, err := rookTmux("select-window", "-t", "="+a.Session+":"+a.Window); err != nil {
		return fmtErr("selecting window %s: %s", a.Window, out)
	}
	if out, err := rookTmux("select-pane", "-t", a.PaneID); err != nil {
		return fmtErr("selecting pane %s: %s", a.PaneID, out)
	}
	return nil
}

func fmtErr(format, what, out string) error {
	return fmt.Errorf(format, what, strings.TrimSpace(out))
}
