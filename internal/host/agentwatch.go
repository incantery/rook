package host

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// agentwatch is the attention router's sensor layer (docs/agent.md,
// milestone 1): it consumes agentmon's derived-event stream over stdout
// (`agentmon watch --dry-run`) and reduces it to one state per live claude
// session. No LLM anywhere — classification here is mechanical:
//
//	turn_completed        → needs_input (claude finished, waiting on you)
//	any transcript event  → working
//	session_idle mid-turn → quiet (long tool run — or a permission prompt;
//	                        the transcript can't tell them apart, so we
//	                        report the tool and the silence, not a guess)
//
// agentmon (github.com/incantery/agentmon) stays dumb and reusable; the
// correlation of transcript sessions to rook windows happens here, by cwd.
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
}

// agentmonEvent mirrors the envelope of agentmon's derived events. Payload
// stays raw until the type is known; unknown types are skipped, never fatal
// (same posture as agentmon itself).
type agentmonEvent struct {
	SessionID string          `json:"session_id"`
	AgentID   string          `json:"agent_id"`
	Project   string          `json:"project"`
	TS        time.Time       `json:"ts"`
	Type      string          `json:"type"`
	Payload   json.RawMessage `json:"payload"`
}

// findAgentmon resolves the agentmon binary: PATH first (daemon PATHs are
// minimal, so this usually misses), then the conventional spots on a dev
// machine. Empty means the attention layer is off — rook works without it.
func findAgentmon() string {
	if p, err := exec.LookPath("agentmon"); err == nil {
		return p
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	for _, p := range []string{
		filepath.Join(home, "go", "bin", "agentmon"),
		filepath.Join(home, "go", "src", "github.com", "incantery", "agentmon", "bin", "agentmon"),
	} {
		if st, err := os.Stat(p); err == nil && st.Mode()&0o111 != 0 {
			return p
		}
	}
	return ""
}

func newAgentWatch() *agentWatch {
	return &agentWatch{states: make(map[string]*AgentStatus)}
}

// run spawns agentmon and pumps its events forever, restarting with backoff
// if it dies (or isn't installed yet — it may appear later).
func (a *agentWatch) run(ctx context.Context) {
	for {
		bin := findAgentmon()
		if bin == "" {
			log.Println("agentwatch: agentmon not found; attention layer off (retry in 5m)")
			select {
			case <-ctx.Done():
				return
			case <-time.After(5 * time.Minute):
				continue
			}
		}
		a.pump(ctx, bin)
		select {
		case <-ctx.Done():
			return
		case <-time.After(15 * time.Second):
		}
	}
}

func (a *agentWatch) pump(ctx context.Context, bin string) {
	// --dry-run: stdout sink, no spool/state on disk — on restart we
	// fast-forward to "now", which is exactly right for live attention.
	// --level full so Ask can hold what claude actually said; it never
	// leaves this machine. --idle-after 20s: attention-speed, not 60s.
	cmd := exec.CommandContext(ctx, bin, "watch", "--dry-run", "--level", "full", "--idle-after", "20s")
	out, err := cmd.StdoutPipe()
	if err != nil {
		log.Printf("agentwatch: pipe: %v", err)
		return
	}
	cmd.Stderr = nil
	if err := cmd.Start(); err != nil {
		log.Printf("agentwatch: start %s: %v", bin, err)
		return
	}
	log.Printf("agentwatch: consuming %s", bin)
	sc := bufio.NewScanner(out)
	sc.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for sc.Scan() {
		var ev agentmonEvent
		if json.Unmarshal(sc.Bytes(), &ev) != nil {
			continue
		}
		a.apply(&ev)
	}
	cmd.Wait()
	log.Println("agentwatch: agentmon exited")
}

func (a *agentWatch) apply(ev *agentmonEvent) {
	if ev.AgentID != "" {
		return // subagent transcripts don't change the main session's state
	}
	if ev.Project == usageProbeDir() {
		return // the usage prober's own headless runs are not sessions
	}
	now := ev.TS
	if now.IsZero() {
		now = time.Now()
	}

	a.mu.Lock()

	if ev.Type == "session_ended" {
		delete(a.states, ev.SessionID)
		a.mu.Unlock()
		return
	}
	st := a.states[ev.SessionID]
	if st == nil {
		st = &AgentStatus{SessionID: ev.SessionID, State: "working", Since: now}
		a.states[ev.SessionID] = st
	}
	if ev.Project != "" {
		st.Project = ev.Project
	}
	st.LastEvent = now
	setState := func(s string) {
		if st.State != s {
			st.State, st.Since = s, now
		}
	}
	record := func(role, text string) {
		if text == "" {
			return
		}
		if r := []rune(text); len(r) > histMaxText {
			text = string(r[:histMaxText]) + "…"
		}
		st.history = append(st.history, histMsg{Role: role, Text: text, TS: now})
		if len(st.history) > histCap {
			st.history = st.history[len(st.history)-histCap:]
		}
	}
	// deferred so hooks run after the lock drops — they call back into
	// host state that must never nest inside agentwatch's mutex
	var userReplied, turnDone, turnFinished bool
	var userReply string

	switch ev.Type {
	case "session_started":
		var p struct {
			CWD string `json:"cwd"`
		}
		json.Unmarshal(ev.Payload, &p)
		if p.CWD != "" {
			st.CWD = p.CWD
		}
	case "session_title":
		var p struct {
			Title string `json:"title"`
		}
		json.Unmarshal(ev.Payload, &p)
		st.Title = p.Title
	case "user_prompt":
		var p struct {
			Text string `json:"text"`
		}
		json.Unmarshal(ev.Payload, &p)
		setState("working")
		st.Ask, st.askDraft, st.Tool = "", "", ""
		st.Interactive = false
		record("user", p.Text)
		userReplied, userReply = true, p.Text
	case "assistant_message":
		var p struct {
			Model   string   `json:"model"`
			CostUSD *float64 `json:"cost_usd"`
			Text    string   `json:"text"`
		}
		json.Unmarshal(ev.Payload, &p)
		setState("working")
		if p.Model != "" {
			st.Model = p.Model
		}
		if p.CostUSD != nil {
			st.CostUSD += *p.CostUSD
		}
		if p.Text != "" {
			st.askDraft = tail(p.Text, 200)
		}
		record("assistant", p.Text)
	case "tool_call":
		var p struct {
			Name  string `json:"name"`
			Input string `json:"input"`
		}
		json.Unmarshal(ev.Payload, &p)
		setState("working")
		st.Tool = p.Name
		record("tool", strings.TrimSpace(p.Name+" "+p.Input))
		// The one mid-turn prompt the transcript CAN identify: claude's
		// question picker. No turn_completed will come while it's up, so
		// it becomes an ask right here — flagged interactive, because the
		// window wants a menu selection, not typed text.
		if p.Name == "AskUserQuestion" {
			setState("needs_input")
			st.Ask, st.Interactive = pickerAsk(p.Input), true
			st.AskSeq++
			turnDone = true // prior asks' open drafts are now stale
		}
	case "tool_result":
		// for a picker, the result IS the user's answer — the ask is over
		setState("working")
		if st.Interactive {
			st.Ask, st.Interactive = "", false
		}
	case "turn_completed":
		setState("needs_input")
		st.Ask, st.Tool = st.askDraft, ""
		st.Interactive = false
		st.AskSeq++
		turnDone = true
		turnFinished = true
	case "session_idle":
		if st.State == "working" {
			setState("quiet")
		}
	}
	askSeq := st.AskSeq
	a.mu.Unlock()

	if userReplied && a.onUserReply != nil {
		a.onUserReply(ev.SessionID, userReply)
	}
	if turnDone && a.onTurnCompleted != nil {
		a.onTurnCompleted(ev.SessionID, askSeq)
	}
	if turnFinished && a.onTurnFinished != nil {
		a.onTurnFinished(ev.SessionID)
	}
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
	c.history = nil
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
		c.history = nil // ring copies stay inside the watcher; use context()
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
