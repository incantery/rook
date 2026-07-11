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

func TestCorrelate(t *testing.T) {
	now := time.Now()
	states := []*AgentStatus{
		{SessionID: "old", Project: "/tmp/x", State: "working", LastEvent: now.Add(-time.Minute)},
		{SessionID: "new", Project: "/tmp/x", State: "needs_input", LastEvent: now},
		{SessionID: "cwd-only", CWD: "/tmp/y", State: "working", LastEvent: now},
	}
	sessions := []sessionStatus{
		{Fg: "claude", Cwd: "/tmp/x"},
		{Fg: "zsh", Cwd: "/tmp/x"},   // not claude — never correlated
		{Fg: "claude", Cwd: "/tmp/x"}, // second claude in same dir gets the older state
		{Fg: "claude", Cwd: "/tmp/y"}, // matches by exact cwd
	}
	correlate(sessions, states)

	if sessions[0].Agent == nil || sessions[0].Agent.SessionID != "new" {
		t.Errorf("first claude window should get the most recent state, got %+v", sessions[0].Agent)
	}
	if sessions[1].Agent != nil {
		t.Error("zsh window must not get an agent state")
	}
	if sessions[2].Agent == nil || sessions[2].Agent.SessionID != "old" {
		t.Errorf("second claude window should get the remaining state, got %+v", sessions[2].Agent)
	}
	if sessions[3].Agent == nil || sessions[3].Agent.SessionID != "cwd-only" {
		t.Errorf("exact-cwd match failed, got %+v", sessions[3].Agent)
	}
}
