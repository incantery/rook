package agents

import (
	"fmt"
	"os"
	"strings"

	"github.com/incantery/rook/internal/sessions"
	"github.com/incantery/rook/internal/tmux"
)

// The side panel: tmux has no window-independent sidebar, so the board
// is a pane that lives in a hidden session when hidden and is joined
// to the current window when shown — the tmux-sidebar trick. One pane,
// one process, moved around; its state survives toggling.
const (
	sideSession = "rook-side"
	sideWidth   = "42"
)

// Side toggles the sidebar from the window of pane (the caller's own
// pane when empty). On: the global switch is set and the panel shown
// here; hooks (see tmux.Render) then carry it to every window you
// change to. Off: the switch is cleared and the panel parked.
func Side(pane string) error {
	if pane == "" {
		pane = os.Getenv("TMUX_PANE")
	}
	if pane == "" {
		return fmt.Errorf("the side panel needs to be toggled from inside rook")
	}
	window, err := current(pane, "#{session_name}:#{window_index}")
	if err != nil {
		return err
	}
	if on() {
		tmux.Run("set-option", "-g", "@rook_sidebar", "0")
		if p := sidePaneIn(""); p != "" {
			return park(p)
		}
		return nil
	}
	tmux.Run("set-option", "-g", "@rook_sidebar", "1")
	return show(window)
}

// Sync is the hook: when the sidebar is on and not in this window,
// bring it here. Cheap when nothing needs doing — one list-panes.
func Sync(window string) error {
	if !on() || sidePaneIn(window) != "" {
		return nil
	}
	if window == "" || strings.HasPrefix(window, sideSession+":") {
		return nil
	}
	return show(window)
}

func on() bool {
	out, _ := tmux.Run("show-option", "-gqv", "@rook_sidebar")
	return strings.TrimSpace(out) == "1"
}

// show puts the panel in a window: moving the existing one, or making
// it the first time.
func show(window string) error {
	if pane := sidePaneIn(""); pane != "" {
		out, err := tmux.Run("join-pane", "-d", "-h", "-b", "-l", sideWidth, "-s", pane, "-t", window)
		if err != nil {
			return fmt.Errorf("moving panel: %s", strings.TrimSpace(out))
		}
		return nil
	}
	self, err := os.Executable()
	if err != nil {
		self = "rook"
	}
	out, err := tmux.Run("split-window", "-d", "-h", "-b", "-l", sideWidth, "-t", window, "-P", "-F", "#{pane_id}", self+" agents --side")
	if err != nil {
		return fmt.Errorf("opening side panel: %s", strings.TrimSpace(out))
	}
	_, err = tmux.Run("set-option", "-p", "-t", strings.TrimSpace(out), "@rook_side", "1")
	return err
}

// park moves the panel out of sight into the hidden session, making
// the session first if this is the first parking.
func park(pane string) error {
	if _, err := tmux.Run("has-session", "-t", "="+sideSession); err != nil {
		if out, err := tmux.Run("new-session", "-d", "-s", sideSession, "-x", "80", "-y", "24"); err != nil {
			return fmt.Errorf("making %s: %s", sideSession, strings.TrimSpace(out))
		}
	}
	if out, err := tmux.Run("break-pane", "-d", "-s", pane, "-t", sideSession+":"); err != nil {
		return fmt.Errorf("parking panel: %s", strings.TrimSpace(out))
	}
	return nil
}

// follow is Enter in the pinned panel: go to the agent. The window
// change fires the sync hook, which brings the panel along.
func follow(a sessions.Agent) error { return sessions.Goto(a) }

// followSession is Enter on a space in the pinned panel.
func followSession(name string) error {
	_, err := tmux.Run("switch-client", "-t", "="+name)
	return err
}

// sidePaneIn finds the panel pane: in one window, or anywhere on the
// server when window is "".
func sidePaneIn(window string) string {
	args := []string{"list-panes", "-F", "#{pane_id}\t#{@rook_side}"}
	if window == "" {
		args = append(args, "-a")
	} else {
		args = append(args, "-t", window)
	}
	out, err := tmux.Run(args...)
	if err != nil {
		return ""
	}
	for line := range strings.SplitSeq(strings.TrimSpace(out), "\n") {
		id, flag, _ := strings.Cut(line, "\t")
		if flag == "1" {
			return id
		}
	}
	return ""
}

// current answers a format for a pane.
func current(pane, format string) (string, error) {
	out, err := tmux.Run("display", "-p", "-t", pane, format)
	return strings.TrimSpace(out), err
}
