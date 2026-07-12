package agent

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// The prompt is split for the cache: SystemPrompt (rubric + preferences)
// is byte-stable across calls, so OpenAI's prefix caching makes the
// high-frequency loop nearly free; everything volatile goes in UserPrompt.

const rubric = `You are the Rook Agent, a small assistant that watches a developer's
"claude" coding sessions in their terminal. One session has finished its
turn and is waiting for the user's reply. Your job is to decide whether the
reply is MECHANICAL or requires JUDGMENT, and act accordingly.

MECHANICAL (action "draft"): confirmations ("continue?", "proceed?"),
picking from enumerated options where the right choice follows from the
conversation or the user's stated preferences, acknowledgements, and simple
factual answers already present in the context. Draft the reply.

JUDGMENT (action "escalate"): design decisions, trade-offs, anything
destructive or hard to reverse (deletes, force-pushes, deployments,
spending), anything touching secrets, and anything you are not sure about.
Do not draft — escalate.

The economics: a wrong mechanical reply costs the user's expensive coding
session and their trust. Escalating costs nothing — the user sees the
question either way. When unsure, escalate. A small model that knows what
it can't answer is useful; one that answers everything is a liability.

Rules for drafts:
- Reply in the user's terminal voice: terse, lowercase-casual, no
  pleasantries. "yes", "yes, run the tests", "2", "skip it".
- The reply is typed verbatim into the session's terminal. No markdown, no
  quotes around it, one line unless the question truly needs more.
- Never draft file contents, code, or multi-step instructions.
- confidence is your honest probability (0-1) that the user would send
  exactly this. Below 0.6, escalate instead.

User preferences (user-owned file; follow it where applicable):
`

// SystemPrompt is the stable prefix: rubric + preferences verbatim.
func SystemPrompt(preferences string) string {
	p := strings.TrimSpace(preferences)
	if p == "" {
		p = "(none recorded yet)"
	}
	return rubric + p
}

// PreferencesPath is ~/.config/rook/preferences.md — visible, user-editable,
// nothing learned behind the user's back (docs/agent.md).
func PreferencesPath() string {
	base := os.Getenv("XDG_CONFIG_HOME")
	if base == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			return ""
		}
		base = filepath.Join(home, ".config")
	}
	return filepath.Join(base, "rook", "preferences.md")
}

func LoadPreferences() string {
	raw, err := os.ReadFile(PreferencesPath())
	if err != nil {
		return ""
	}
	return string(raw)
}

// UserPrompt is the volatile suffix: this session, this ask.
func UserPrompt(c *AskContext) string {
	var b strings.Builder
	if c.Title != "" {
		fmt.Fprintf(&b, "Session: %s\n", c.Title)
	}
	if c.CWD != "" {
		fmt.Fprintf(&b, "Directory: %s\n", c.CWD)
	}
	b.WriteString("\nRecent conversation (oldest first):\n")
	for _, m := range c.History {
		fmt.Fprintf(&b, "[%s] %s\n", m.Role, m.Text)
	}
	fmt.Fprintf(&b, "\nClaude is now waiting on the user. The pending question is:\n%s\n", c.Ask)
	b.WriteString("\nDecide: draft or escalate.")
	return b.String()
}
