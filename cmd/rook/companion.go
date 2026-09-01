package main

import (
	"fmt"
	"os"
	"strings"
	"time"

	"github.com/incantery/rook/internal/mux"
)

// runCompanion answers the one question rook can answer about the
// companion and nothing else can: is she open in here, and where.
//
// Rook watches for one program by name — the config names it, vera
// first — and the engine publishes what it sees in its own pane table
// (docs/surfaces.md, the `companion` block of the state feed). This
// verb is that block, read out loud. `--json` hands over rook's own
// bytes for anything that would rather parse than read.
//
// The exit status is the short answer, so a script never has to parse
// the long one: 0 when she is open in rook, 1 when she is not.
func runCompanion(args []string) error {
	for _, a := range args {
		if a != "--json" && a != "-json" {
			return fmt.Errorf("usage: rook companion [--json]")
		}
	}
	if len(args) > 0 {
		raw := mux.CompanionJSON()
		fmt.Println(raw)
		if strings.Contains(raw, `"open":true`) {
			return nil
		}
		os.Exit(1)
	}
	c := mux.CompanionState()
	for _, line := range companionLines(c, time.Now()) {
		fmt.Println(line)
	}
	if c == nil || !c.Open {
		os.Exit(1)
	}
	return nil
}

// companionLines is what the verb prints: one line per pane running
// the companion, or one line saying why there are none.
func companionLines(c *mux.Companion, now time.Time) []string {
	if c == nil {
		// No slot, or no server. Rook says what it knows rather than
		// guessing which: either way it knows of no companion.
		return []string{"rook knows of no companion — is one configured, and is rook running?"}
	}
	if !c.Open || len(c.Panes) == 0 {
		return []string{c.Name + " is not open in rook"}
	}
	lines := make([]string, 0, len(c.Panes))
	for _, p := range c.Panes {
		parts := []string{c.Name, companionWhere(p), fmt.Sprintf("pane %d", p.Pane)}
		if p.Focused {
			parts = append(parts, "in front of you")
		} else if p.Visible {
			parts = append(parts, "on the glass")
		} else {
			parts = append(parts, "out of sight")
		}
		if age := since(p.Since, now); age != "" {
			parts = append(parts, "open "+age)
		}
		lines = append(lines, strings.Join(parts, " · "))
	}
	return lines
}

// companionWhere names the place a pane sits in, in the words the
// person uses for it: a window of a workspace, the side rail, or the
// popup floating over the lot.
func companionWhere(p mux.CompanionPane) string {
	switch p.Place {
	case "popup":
		if p.Workspace == "" {
			return "the popup"
		}
		return p.Workspace + ", the popup"
	case "pin":
		if p.Workspace == "" {
			return "the rail, every workspace"
		}
		return p.Workspace + ", the rail"
	default:
		if p.Window == nil {
			return p.Workspace
		}
		return fmt.Sprintf("%s, window %d", p.Workspace, *p.Window)
	}
}

// since renders how long she has been open, coarsely: the answer is
// "a while" or "just now", never a stopwatch.
func since(ms int64, now time.Time) string {
	if ms <= 0 {
		return ""
	}
	d := now.Sub(time.UnixMilli(ms))
	switch {
	case d < 0:
		return ""
	case d < time.Minute:
		return "just now"
	case d < time.Hour:
		return fmt.Sprintf("%dm", int(d.Minutes()))
	case d < 24*time.Hour:
		return fmt.Sprintf("%dh", int(d.Hours()))
	default:
		return fmt.Sprintf("%dd", int(d.Hours())/24)
	}
}
