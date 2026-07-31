package host

import (
	"encoding/json"
	"fmt"
	"strings"
	"sync"
	"time"
)

// agentwatch is the attention router's sensor layer (docs/agent.md,
// milestone 1): one state per live claude session, reduced from Claude
// Code's transcripts. No LLM anywhere — classification is mechanical:
//
//	system/turn_duration  → needs_input (claude finished, waiting on you)
//	any record            → working
//	silence mid-turn      → quiet (long tool run — or a permission prompt;
//	                        the transcript can't tell them apart, so we
//	                        report the tool and the silence, not a guess)
//
// This file holds the state, the notify hook, and the readers. The source
// that fills it lives in transcriptwatch.go, which reads
// ~/.claude/projects/**/*.jsonl directly.
//
// It used to read agentmon's derived-event stream instead
// (`agentmon watch --dry-run`). That went away on 2026-07-15: agentmon is a
// telemetry shipper, its parser caps every content field at 2KB and never
// carries a tool_use id, and rook needs whole records — see the amendment
// in docs/agent.md. agentmon keeps its own job; both read the same tree and
// neither knows the other exists.
//
// Correlation of transcript sessions to rook windows happens here, by cwd.
type agentWatch struct {
	mu     sync.Mutex
	states map[string]*AgentStatus // by transcript session id

	// Hooks fire (outside the lock) so the host can attribute replies to
	// open drafts and expire them — agentwatch itself stays a pure sensor.
	onUserReply     func(sessionID, text string)
	onTurnCompleted func(sessionID string, askSeq int)
	// onTurnFinished fires ONLY on a genuine turn_completed event — never
	// for AskUserQuestion or a permission notify, which also route through
	// onTurnCompleted (its contract is ask-invalidation, not "turn done").
	// The workflow engine keys stage completion on this distinction: an
	// agent asking a question has NOT finished its stage.
	onTurnFinished func(sessionID string)
}

// histMsg is one entry of a session's recent-conversation ring: the context
// the drafter reads. Text is capped, and it never leaves this machine
// except inside the drafting prompt.
type histMsg struct {
	Role string    `json:"role"` // user | assistant | tool
	Text string    `json:"text"`
	TS   time.Time `json:"ts"`
}

const (
	histCap     = 12
	histMaxText = 700
)

// AgentStatus is what the dashboard shows and what the future nano tier
// will read. Ask is the tail of claude's last message — at needs_input it
// is literally the question waiting for an answer.
type AgentStatus struct {
	SessionID string `json:"sessionId"`
	CWD       string `json:"cwd"`
	// Project is the session's project path as agentmon reports it. CWD
	// is only present when the watcher saw session_started (pre-existing
	// transcripts are fast-forwarded), so correlation falls back to this.
	Project string  `json:"project,omitempty"`
	State   string  `json:"state"` // working | needs_input | quiet
	Title   string  `json:"title,omitempty"`
	Ask     string  `json:"ask,omitempty"`
	Tool    string  `json:"tool,omitempty"` // last tool requested
	Model   string  `json:"model,omitempty"`
	CostUSD float64 `json:"costUsd,omitempty"`
	// AskSeq increments on every ask — turn_completed, or an interactive
	// prompt appearing mid-turn: it is the identity of "this ask". Drafts,
	// decisions, notifications, and invalidation all key on (sessionId,
	// askSeq) to tell "same ask still waiting" from "a new ask".
	AskSeq int `json:"askSeq"`
	// Interactive: the ask is a TUI prompt (AskUserQuestion picker), not a
	// text prompt — it wants arrows/numbers in the window, so the drafter
	// skips it and the host refuses to type into it. Surface + jump only.
	Interactive bool      `json:"interactive,omitempty"`
	Since       time.Time `json:"since"`     // when State last changed
	LastEvent   time.Time `json:"lastEvent"` // any activity
	askDraft    string    // last assistant text, promoted to Ask on turn end
	history     []histMsg // recent-conversation ring (histCap entries)
	// seenMsg dedupes cost across the several transcript lines Claude Code
	// writes for one API response, each repeating the same message id and
	// usage object. Only used by the transcript reader — agentmon does this
	// dedupe inside its own parser and stamps a cost we just add up. Dies
	// with the session.
	seenMsg map[string]bool
}

func newAgentWatch() *agentWatch {
	return &agentWatch{states: make(map[string]*AgentStatus)}
}

// notify is the Claude Code Notification hook landing (via `rookctl
// notify-hook`): it fires when claude needs tool permission, or as a 60s
// idle reminder. Permission prompts are otherwise invisible to the
// transcript (just a tool_call then silence — "quiet"), so this hook is
// the only mechanical source for the most common "needs you" moment.
// Already-surfaced asks ignore it (the idle reminder repeats what
// turn_completed said); anything else becomes an interactive ask — a
// permission menu takes selections, not typed text.
func (a *agentWatch) notify(sessionID, message string) {
	now := time.Now()
	a.mu.Lock()
	st := a.states[sessionID]
	if st == nil {
		// agentmon may not have seen this session yet (fresh transcript,
		// startup lag) — the claim hook still correlates it to a window
		st = &AgentStatus{SessionID: sessionID, State: "working", Since: now}
		a.states[sessionID] = st
	}
	if st.State == "needs_input" {
		st.LastEvent = now
		a.mu.Unlock()
		return
	}
	st.State, st.Since, st.LastEvent = "needs_input", now, now
	st.Ask, st.Interactive = message, true
	st.AskSeq++
	seq := st.AskSeq
	a.mu.Unlock()
	if a.onTurnCompleted != nil {
		a.onTurnCompleted(sessionID, seq) // prior asks' open drafts → stale
	}
}

// context returns a session's live status plus a copy of its history ring —
// the drafter's whole view of the world for one ask.
func (a *agentWatch) context(sessionID string) (AgentStatus, []histMsg, bool) {
	a.mu.Lock()
	defer a.mu.Unlock()
	st := a.states[sessionID]
	if st == nil {
		return AgentStatus{}, nil, false
	}
	hist := make([]histMsg, len(st.history))
	copy(hist, st.history)
	c := *st
	c.history, c.seenMsg = nil, nil
	return c, hist, true
}

// snapshot returns live states, dropping sessions with no activity for an
// hour (closed terminals never emit session_ended fast enough to matter).
func (a *agentWatch) snapshot() []*AgentStatus {
	a.mu.Lock()
	defer a.mu.Unlock()
	cutoff := time.Now().Add(-time.Hour)
	out := make([]*AgentStatus, 0, len(a.states))
	for id, st := range a.states {
		if st.LastEvent.Before(cutoff) {
			delete(a.states, id)
			continue
		}
		c := *st
		// ring copies stay inside the watcher; use context()
		c.history, c.seenMsg = nil, nil
		out = append(out, &c)
	}
	return out
}

// pickerAsk renders an AskUserQuestion tool input as one readable ask:
// the question plus its numbered options. The input may arrive truncated
// (agentmon caps content at 2KB), so a parse failure degrades to a generic
// line rather than losing the ask.
func pickerAsk(input string) string {
	var p struct {
		Questions []struct {
			Question string `json:"question"`
			Options  []struct {
				Label string `json:"label"`
			} `json:"options"`
		} `json:"questions"`
	}
	if json.Unmarshal([]byte(input), &p) != nil || len(p.Questions) == 0 || p.Questions[0].Question == "" {
		return "Claude is asking a question (interactive prompt)"
	}
	q := p.Questions[0]
	var b strings.Builder
	b.WriteString(q.Question)
	for i, o := range q.Options {
		if i == 0 {
			b.WriteString("  —")
		}
		fmt.Fprintf(&b, " %d) %s", i+1, o.Label)
	}
	if n := len(p.Questions) - 1; n > 0 {
		fmt.Fprintf(&b, " (+%d more question%s)", n, map[bool]string{true: "s"}[n > 1])
	}
	return b.String()
}

func tail(s string, n int) string {
	r := []rune(strings.TrimSpace(s))
	if len(r) <= n {
		return string(r)
	}
	return "…" + string(r[len(r)-n:])
}
