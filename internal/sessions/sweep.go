package sessions

import (
	"fmt"
	"strings"

	"github.com/incantery/rook/internal/attention"
)

// Sweep is the status bar's 5-second heartbeat, run by the #() segment
// in status-right: it prints the bar (attention debt from the feed)
// and, as the same pass, stamps every window's @rook_agent option from
// its panes — waiting / working / done — so the window tabs read as
// live agent state. Stamps are diffed: an unchanged window costs no
// tmux command.
func Sweep() error {
	fmt.Print(attention.Bar(attention.Load()))

	states := windowStates()
	current := stampedWindows()
	for id, state := range states {
		want := ""
		if state != StateNone {
			want = state.String()
		}
		if current[id] == want {
			delete(current, id)
			continue
		}
		if want == "" {
			rookTmux("set-option", "-w", "-u", "-t", id, "@rook_agent")
		} else {
			rookTmux("set-option", "-w", "-t", id, "@rook_agent", want)
		}
		delete(current, id)
	}
	// Windows stamped once but agentless now (the pane exited).
	for id, had := range current {
		if had != "" {
			rookTmux("set-option", "-w", "-u", "-t", id, "@rook_agent")
		}
	}
	return nil
}

// windowStates classifies every window on the server by its agent
// panes, one capture per agent pane.
func windowStates() map[string]AgentState {
	out, err := rookTmux("list-panes", "-a", "-F",
		"#{window_id}\t#{pane_id}\t#{pane_current_command}\t#{pane_title}")
	if err != nil {
		return nil
	}
	states := map[string]AgentState{}
	for line := range strings.SplitSeq(strings.TrimSpace(out), "\n") {
		f := strings.Split(line, "\t")
		if len(f) < 4 {
			continue
		}
		if _, seen := states[f[0]]; !seen {
			states[f[0]] = StateNone
		}
		if IsAgentPane(f[2], f[3]) {
			states[f[0]] = states[f[0]].merge(paneState(f[1]))
		}
	}
	return states
}

// stampedWindows reads the stamps already on the server.
func stampedWindows() map[string]string {
	out, err := rookTmux("list-windows", "-a", "-F", "#{window_id}\t#{@rook_agent}")
	if err != nil {
		return map[string]string{}
	}
	stamped := map[string]string{}
	for line := range strings.SplitSeq(strings.TrimSpace(out), "\n") {
		id, state, _ := strings.Cut(line, "\t")
		if id != "" {
			stamped[id] = state
		}
	}
	return stamped
}
