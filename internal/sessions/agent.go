package sessions

import (
	"regexp"
	"strings"
)

// AgentState is what a Claude pane is doing, read from its screen the
// same way a human glancing at it would. Empirically derived from real
// panes (2026-08-19): working shows a spinner line "✳ Billowing… (9s ·
// ↓ 159 tokens)" or "esc to interrupt"; waiting shows a dialog
// ("Enter to confirm", "Do you want", numbered ❯ options); a bare
// prompt footer is done. Past-tense lines ("✻ Brewed for 5s") carry no
// ellipsis, so they never read as working.
type AgentState int

const (
	StateNone AgentState = iota // no agent in the pane
	StateDone                   // at the prompt, nothing running
	StateWorking
	StateWaiting // a dialog needs the human
)

var (
	// spinner glyph frames Claude Code animates through, then one
	// word, then the ellipsis that only running work carries.
	spinnerLineRe = regexp.MustCompile(`^[·✢✳✶✻✽*+]\s\S+…`)
	optionLineRe  = regexp.MustCompile(`^❯?\s*\d+\.\s`)
	// Claude Code's native install names its binary by version.
	versionCmdRe = regexp.MustCompile(`^[0-9.]+$`)
)

// IsAgentPane says whether a pane hosts Claude, from its command name
// or the "✳ " title prefix Claude Code sets.
func IsAgentPane(currentCommand, title string) bool {
	return versionCmdRe.MatchString(currentCommand) ||
		currentCommand == "claude" ||
		strings.HasPrefix(title, "✳ ")
}

// Classify reads captured pane content and returns the agent's state.
// Waiting outranks working: a dialog needs the human even if a spinner
// is still on screen.
func Classify(content string) AgentState {
	state := StateDone
	for line := range strings.SplitSeq(content, "\n") {
		l := strings.TrimSpace(line)
		switch {
		case strings.Contains(l, "Enter to confirm"),
			strings.Contains(l, "Do you want"),
			optionLineRe.MatchString(l):
			return StateWaiting
		case spinnerLineRe.MatchString(l),
			strings.Contains(l, "esc to interrupt"):
			state = StateWorking
		}
	}
	return state
}

// Chip renders the state for a picker row or preview line.
func (s AgentState) Chip() string {
	switch s {
	case StateWaiting:
		return accent + bold + "● waiting" + reset
	case StateWorking:
		return "✳ working"
	case StateDone:
		return dim + "· done" + reset
	}
	return ""
}

// merge keeps the state that most needs attention.
func (s AgentState) merge(o AgentState) AgentState {
	if o > s {
		return o
	}
	return s
}

// String is the machine name used by `rook ls --json`.
func (s AgentState) String() string {
	switch s {
	case StateDone:
		return "done"
	case StateWorking:
		return "working"
	case StateWaiting:
		return "waiting"
	}
	return "none"
}
