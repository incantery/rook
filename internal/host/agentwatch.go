package host

import (
	"bufio"
	"context"
	"encoding/json"
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
}

// AgentStatus is what the dashboard shows and what the future nano tier
// will read. Ask is the tail of claude's last message — at needs_input it
// is literally the question waiting for an answer.
type AgentStatus struct {
	SessionID string `json:"sessionId"`
	CWD       string `json:"cwd"`
	// Project is the session's project path as agentmon reports it. CWD
	// is only present when the watcher saw session_started (pre-existing
	// transcripts are fast-forwarded), so correlation falls back to this.
	Project   string    `json:"project,omitempty"`
	State     string    `json:"state"` // working | needs_input | quiet
	Title     string    `json:"title,omitempty"`
	Ask       string    `json:"ask,omitempty"`
	Tool      string    `json:"tool,omitempty"` // last tool requested
	Model     string    `json:"model,omitempty"`
	CostUSD   float64   `json:"costUsd,omitempty"`
	Since     time.Time `json:"since"`        // when State last changed
	LastEvent time.Time `json:"lastEvent"`    // any activity
	askDraft  string    // last assistant text, promoted to Ask on turn end
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
	now := ev.TS
	if now.IsZero() {
		now = time.Now()
	}

	a.mu.Lock()
	defer a.mu.Unlock()

	if ev.Type == "session_ended" {
		delete(a.states, ev.SessionID)
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
		setState("working")
		st.Ask, st.askDraft, st.Tool = "", "", ""
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
	case "tool_call":
		var p struct {
			Name string `json:"name"`
		}
		json.Unmarshal(ev.Payload, &p)
		setState("working")
		st.Tool = p.Name
	case "tool_result":
		setState("working")
	case "turn_completed":
		setState("needs_input")
		st.Ask, st.Tool = st.askDraft, ""
	case "session_idle":
		if st.State == "working" {
			setState("quiet")
		}
	}
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
		out = append(out, &c)
	}
	return out
}

func tail(s string, n int) string {
	r := []rune(strings.TrimSpace(s))
	if len(r) <= n {
		return string(r)
	}
	return "…" + string(r[len(r)-n:])
}
