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

// Side toggles the pinned board in the window of pane (the caller's
// own pane when empty).
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
	// Already showing here? Park it.
	if pane := sidePaneIn(window); pane != "" {
		return park(pane)
	}
	// Parked somewhere? Bring it. (It may also be showing in another
	// window; join-pane moves it from wherever it is.)
	if pane := sidePaneIn(""); pane != "" {
		_, err := tmux.Run("join-pane", "-h", "-b", "-l", sideWidth, "-s", pane, "-t", window)
		return err
	}
	// First time: make it.
	self, err := os.Executable()
	if err != nil {
		self = "rook"
	}
	out, err := tmux.Run("split-window", "-h", "-b", "-l", sideWidth, "-t", window, "-P", "-F", "#{pane_id}", self+" agents --side")
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

// follow is Enter in the pinned panel: go to the agent, and bring the
// panel along so it stays on screen in the new window.
func follow(a sessions.Agent) error {
	self := os.Getenv("TMUX_PANE")
	target := "=" + a.Session + ":" + a.Window
	if self != "" {
		here, _ := current(self, "#{session_name}:#{window_index}")
		if strings.TrimPrefix(target, "=") != here {
			if out, err := tmux.Run("join-pane", "-d", "-h", "-b", "-l", sideWidth, "-s", self, "-t", target); err != nil {
				return fmt.Errorf("moving panel: %s", strings.TrimSpace(out))
			}
		}
	}
	return sessions.Goto(a)
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
