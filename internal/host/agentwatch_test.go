package host

import (
	"testing"
	"time"
)

// The Notification hook: a permission prompt becomes an interactive ask;
// the 60s idle reminder for an already-surfaced ask is a no-op; the
// granted permission (tool_result) dissolves it.
func TestNotify(t *testing.T) {
	a := newAgentWatch()
	id := "s-notify"
	var staled []int
	a.onTurnCompleted = func(_ string, seq int) { staled = append(staled, seq) }

	// mid-turn permission prompt — transcript says "working", hook knows better
	startSession(t, a, id, "/repo")
	a.applyRecord(rline(t, id, userMsg("go")))
	a.applyRecord(rline(t, id, toolUse("Bash", map[string]string{"command": "rm -rf build"})))
	a.notify(id, "Claude needs your permission to use Bash")

	st := a.states[id]
	if st.State != "needs_input" || !st.Interactive || st.AskSeq != 1 {
		t.Fatalf("permission prompt: state=%q interactive=%v seq=%d", st.State, st.Interactive, st.AskSeq)
	}
	if st.Ask != "Claude needs your permission to use Bash" {
		t.Errorf("ask = %q", st.Ask)
	}
	if len(staled) != 1 {
		t.Errorf("notify must fire the stale hook, got %v", staled)
	}

	// idle reminder while already surfaced: no new ask identity
	a.notify(id, "Claude is waiting for your input")
	if st.AskSeq != 1 || st.Ask != "Claude needs your permission to use Bash" {
		t.Errorf("idle reminder must not remint the ask: seq=%d ask=%q", st.AskSeq, st.Ask)
	}

	// permission granted → tool runs → result clears the ask
	a.applyRecord(rline(t, id, toolResult))
	if st.State != "working" || st.Interactive || st.Ask != "" {
		t.Errorf("after grant: state=%q interactive=%v ask=%q", st.State, st.Interactive, st.Ask)
	}

	// a session the transcript reader hasn't seen yet still surfaces via the hook
	a.notify("s-unseen", "Claude needs your permission to use Edit")
	if un := a.states["s-unseen"]; un == nil || un.State != "needs_input" || !un.Interactive {
		t.Errorf("unseen session: %+v", a.states["s-unseen"])
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
