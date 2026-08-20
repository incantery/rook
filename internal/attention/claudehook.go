package attention

import (
	"encoding/json"
	"io"
	"time"
)

// HandleClaudeHook is the target of Claude Code's hooks: rook wired as
// `rook claude-hook` for Notification, UserPromptSubmit, Stop and
// SessionEnd. A Notification means that session is waiting on the
// human — a permission ask or an idle prompt — so it publishes one
// waiting item under the session's own publisher file; the other
// events mean the human engaged or the session ended, so they clear
// it. Hooks run inside every Claude turn: this must be fast, tolerate
// any input, and never fail the turn — errors are swallowed by
// design, the TTL cleans up whatever a crash leaves behind.
func HandleClaudeHook(stdin io.Reader) {
	var ev struct {
		Event     string `json:"hook_event_name"`
		SessionID string `json:"session_id"`
		CWD       string `json:"cwd"`
		Message   string `json:"message"`
	}
	if err := json.NewDecoder(io.LimitReader(stdin, 1<<20)).Decode(&ev); err != nil || ev.SessionID == "" {
		return
	}
	id := ev.SessionID
	if len(id) > 8 {
		id = id[:8]
	}
	id = "claude-" + id

	switch ev.Event {
	case "Notification":
		headline := ev.Message
		if headline == "" {
			headline = "claude is waiting on you"
		}
		if len(headline) > 100 {
			headline = headline[:100] + "…"
		}
		Publish(id, []Item{{
			Dir:      ev.CWD,
			Kind:     "waiting",
			Headline: headline,
			At:       time.Now(),
			Source:   "claude",
		}})
	case "UserPromptSubmit", "Stop", "SessionEnd":
		Publish(id, nil)
	}
}
