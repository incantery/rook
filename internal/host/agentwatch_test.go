package host

import (
	"encoding/json"
	"testing"
	"time"
)

func ev(t *testing.T, typ, sessionID, project string, payload any) *agentmonEvent {
	t.Helper()
	raw, err := json.Marshal(payload)
	if err != nil {
		t.Fatal(err)
	}
	return &agentmonEvent{SessionID: sessionID, Project: project, Type: typ, TS: time.Now(), Payload: raw}
}

func TestAgentStateMachine(t *testing.T) {
	a := newAgentWatch()
	id := "s-abc"

	a.apply(ev(t, "session_started", id, "/tmp/x", map[string]string{"cwd": "/tmp/x"}))
	a.apply(ev(t, "assistant_message", id, "", map[string]any{"model": "claude-fable-5", "text": "Should I delete the old migration?"}))
	a.apply(ev(t, "turn_completed", id, "", map[string]any{"duration_ms": 1000}))

	st := a.states[id]
	if st.State != "needs_input" {
		t.Fatalf("after turn_completed: state = %q, want needs_input", st.State)
	}
	if st.Ask != "Should I delete the old migration?" {
		t.Errorf("Ask = %q — the question must survive the turn boundary", st.Ask)
	}
	if st.CWD != "/tmp/x" || st.Project != "/tmp/x" {
		t.Errorf("identity fields: cwd=%q project=%q", st.CWD, st.Project)
	}

	// the user answers: back to working, stale ask gone
	a.apply(ev(t, "user_prompt", id, "", map[string]any{"chars": 3}))
	if st.State != "working" || st.Ask != "" {
		t.Errorf("after user_prompt: state=%q ask=%q, want working/empty", st.State, st.Ask)
	}

	// idle mid-turn → quiet, with the running tool named
	a.apply(ev(t, "tool_call", id, "", map[string]string{"name": "Bash"}))
	a.apply(ev(t, "session_idle", id, "", map[string]any{"idle_seconds": 20}))
	if st.State != "quiet" || st.Tool != "Bash" {
		t.Errorf("after session_idle: state=%q tool=%q, want quiet/Bash", st.State, st.Tool)
	}

	// idle must NOT demote needs_input — waiting on the user stays loud
	a.apply(ev(t, "turn_completed", id, "", map[string]any{}))
	a.apply(ev(t, "session_idle", id, "", map[string]any{"idle_seconds": 20}))
	if st.State != "needs_input" {
		t.Errorf("session_idle demoted needs_input to %q", st.State)
	}

	// subagent events are invisible to the main session's state
	sub := ev(t, "user_prompt", id, "", map[string]any{"chars": 1})
	sub.AgentID = "agent-1"
	a.apply(sub)
	if st.State != "needs_input" {
		t.Errorf("subagent event changed state to %q", st.State)
	}

	a.apply(ev(t, "session_ended", id, "", map[string]string{"reason": "inactive"}))
	if a.states[id] != nil {
		t.Error("session_ended did not drop the state")
	}
}

// The field bug this guards: two claude windows in one repo (plus a third
// claude session in the same dir that isn't in rook at all), needs_input
// fires in the later window — and recency-based pairing pulsed the earlier
// one. The ask text on the window's own PTY is the tiebreaker.
func TestCorrelateByRingContent(t *testing.T) {
	now := time.Now()
	ask := "Should I delete the old migration or keep it for the rollback path?"
	mkStates := func() []*AgentStatus {
		return []*AgentStatus{
			// most recent: a claude session outside any rook window
			{SessionID: "ghostty", Project: "/repo", State: "working", LastEvent: now},
			{SessionID: "asker", Project: "/repo", State: "needs_input", Ask: ask, LastEvent: now.Add(-time.Second)},
			{SessionID: "worker", Project: "/repo", State: "working", LastEvent: now.Add(-2 * time.Second)},
		}
	}
	sessions := []sessionStatus{
		{SessionInfo: SessionInfo{ID: "w2"}, Fg: "claude", Cwd: "/repo"},
		{SessionInfo: SessionInfo{ID: "w3"}, Fg: "claude", Cwd: "/repo"},
		{SessionInfo: SessionInfo{ID: "w4"}, Fg: "zsh", Cwd: "/repo"},
	}
	// w3's PTY shows the ask the way a TUI renders it: colored, wrapped,
	// markdown stripped differently than the transcript text
	live := []*session{
		{ring: []byte("\x1b[32mCompiling…\x1b[0m done\r\n$ ")},
		{ring: []byte("\x1b[38;5;153mShould I delete the old\r\nmigration \x1b[1mor keep it\x1b[22m for the\r\nrollback path?\x1b[0m\r\n❯ ")},
		{ring: []byte("irrelevant shell output")},
	}

	h := &Host{binds: make(map[string]string)}
	h.correlate(sessions, live, mkStates())

	if sessions[1].Agent == nil || sessions[1].Agent.SessionID != "asker" {
		t.Fatalf("w3 should get the needs_input state (its PTY shows the ask), got %+v", sessions[1].Agent)
	}
	if sessions[0].Agent != nil && sessions[0].Agent.SessionID == "asker" {
		t.Error("w2 must not get the needs_input state")
	}
	if sessions[2].Agent != nil {
		t.Error("zsh window must not get an agent state")
	}
	if h.binds["asker"] != "w3" {
		t.Errorf("ring match should bind asker→w3, binds = %v", h.binds)
	}

	// sticky: the ask has scrolled out of the ring, the pairing holds
	sessions[0].Agent, sessions[1].Agent = nil, nil
	live[1].ring = []byte("$ make test\r\nok\r\n")
	h.correlate(sessions, live, mkStates())
	if sessions[1].Agent == nil || sessions[1].Agent.SessionID != "asker" {
		t.Fatalf("binding should keep asker on w3, got %+v", sessions[1].Agent)
	}

	// the bound window dies → unpin, recency fallback resumes
	sessions[0].Agent, sessions[1].Agent = nil, nil
	h.correlate(sessions[:1], live[:1], mkStates())
	if h.binds["asker"] != "" {
		t.Errorf("binding to a dead window should be dropped, binds = %v", h.binds)
	}
	if sessions[0].Agent == nil {
		t.Error("lone claude window should still get a state by recency")
	}
}

// A claim (SessionStart hook) outranks every heuristic — even a ring
// match pointing the other way — and a claimed transcript never drifts to
// another window while its own isn't claude-foreground.
func TestCorrelateClaims(t *testing.T) {
	now := time.Now()
	ask := "Want me to also update the integration test fixtures to match?"
	sessions := []sessionStatus{
		{SessionInfo: SessionInfo{ID: "w2"}, Fg: "claude", Cwd: "/repo"},
		{SessionInfo: SessionInfo{ID: "w3"}, Fg: "zsh", Cwd: "/repo"}, // its claude is suspended
	}
	// w2's ring happens to contain the ask text (user catted a log, say)
	live := []*session{{ring: []byte(ask)}, {ring: []byte("")}}
	states := []*AgentStatus{
		{SessionID: "t-claimed", Project: "/repo", State: "needs_input", Ask: ask, LastEvent: now},
		{SessionID: "t-other", Project: "/repo", State: "working", LastEvent: now.Add(-time.Second)},
	}
	h := &Host{claims: map[string]string{"t-claimed": "w3"}, binds: map[string]string{}}
	h.correlate(sessions, live, states)

	if sessions[0].Agent == nil || sessions[0].Agent.SessionID != "t-other" {
		t.Errorf("w2 should get the unclaimed state despite the ring match, got %+v", sessions[0].Agent)
	}
	if sessions[1].Agent != nil {
		t.Errorf("w3 isn't claude-fg; its claimed state must wait, not display: %+v", sessions[1].Agent)
	}
	if sessions[1].AgentSession != "t-claimed" {
		t.Errorf("w3 should surface its claim, got %q", sessions[1].AgentSession)
	}
	if h.binds["t-claimed"] != "" {
		t.Errorf("claimed transcript must not acquire heuristic binds: %v", h.binds)
	}

	// claude back in the foreground on w3 → its state comes home
	sessions[0].Agent, sessions[1].Agent = nil, nil
	sessions[1].Fg = "claude"
	h.correlate(sessions, live, states)
	if sessions[1].Agent == nil || sessions[1].Agent.SessionID != "t-claimed" {
		t.Errorf("claimed state should land on w3, got %+v", sessions[1].Agent)
	}
}

// Ambiguous evidence must not bind: identical text on two windows.
func TestCorrelateAmbiguousRing(t *testing.T) {
	ask := "Ready for the next step whenever you are, just say the word."
	ring := []byte("Ready for the next step whenever you are, just say the word.")
	sessions := []sessionStatus{
		{SessionInfo: SessionInfo{ID: "a"}, Fg: "claude", Cwd: "/repo"},
		{SessionInfo: SessionInfo{ID: "b"}, Fg: "claude", Cwd: "/repo"},
	}
	live := []*session{{ring: ring}, {ring: ring}}
	states := []*AgentStatus{
		{SessionID: "s1", Project: "/repo", State: "needs_input", Ask: ask, LastEvent: time.Now()},
	}
	h := &Host{binds: make(map[string]string)}
	h.correlate(sessions, live, states)
	if len(h.binds) != 0 {
		t.Errorf("ambiguous match must not bind, binds = %v", h.binds)
	}
	if sessions[0].Agent == nil {
		t.Error("state should still land somewhere via recency fallback")
	}
}
