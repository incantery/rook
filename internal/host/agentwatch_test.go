package host

import (
	"encoding/json"
	"fmt"
	"strings"
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

// AskSeq is the identity of "this ask": it must tick on every completed
// turn and never otherwise — drafts and notifications dedupe on it.
func TestAskSeq(t *testing.T) {
	a := newAgentWatch()
	id := "s-seq"
	var hookSeqs []int
	a.onTurnCompleted = func(sid string, seq int) {
		if sid == id {
			hookSeqs = append(hookSeqs, seq)
		}
	}

	a.apply(ev(t, "assistant_message", id, "/r", map[string]any{"text": "first?"}))
	if a.states[id].AskSeq != 0 {
		t.Fatalf("AskSeq before any turn = %d, want 0", a.states[id].AskSeq)
	}
	a.apply(ev(t, "turn_completed", id, "", map[string]any{}))
	a.apply(ev(t, "user_prompt", id, "", map[string]any{"text": "yes"}))
	a.apply(ev(t, "assistant_message", id, "", map[string]any{"text": "second?"}))
	a.apply(ev(t, "turn_completed", id, "", map[string]any{}))
	if got := a.states[id].AskSeq; got != 2 {
		t.Errorf("AskSeq after two turns = %d, want 2", got)
	}
	if len(hookSeqs) != 2 || hookSeqs[0] != 1 || hookSeqs[1] != 2 {
		t.Errorf("onTurnCompleted seqs = %v, want [1 2]", hookSeqs)
	}
}

// onTurnFinished is the workflow engine's stage-completion signal, and its
// whole contract is discipline: genuine turn ends ONLY. AskUserQuestion and
// permission notifies also invalidate asks (onTurnCompleted fires for
// them — that's ITS contract), but an agent asking a question has not
// finished its stage.
func TestOnTurnFinishedDiscipline(t *testing.T) {
	a := newAgentWatch()
	id := "s-wf"
	var finished, completed int
	a.onTurnFinished = func(string) { finished++ }
	a.onTurnCompleted = func(string, int) { completed++ }

	a.apply(ev(t, "user_prompt", id, "/r", map[string]any{"text": "go"}))
	a.apply(ev(t, "tool_call", id, "", map[string]any{
		"name":  "AskUserQuestion",
		"input": `{"questions":[{"question":"which?","options":[{"label":"a"},{"label":"b"}]}]}`,
	}))
	if finished != 0 {
		t.Fatalf("AskUserQuestion fired onTurnFinished %d time(s) — a question is not a finished stage", finished)
	}
	if completed != 1 {
		t.Fatalf("AskUserQuestion must still invalidate prior asks, completed=%d", completed)
	}

	// permission prompt (Notification hook) mid-turn: same rule
	a.apply(ev(t, "tool_result", id, "", map[string]any{"ok": true}))
	a.apply(ev(t, "tool_call", id, "", map[string]any{"name": "Bash", "input": "rm -rf build"}))
	a.notify(id, "Claude needs your permission to use Bash")
	if finished != 0 {
		t.Fatalf("permission notify fired onTurnFinished %d time(s)", finished)
	}

	a.apply(ev(t, "tool_result", id, "", map[string]any{"ok": true}))
	a.apply(ev(t, "turn_completed", id, "", map[string]any{}))
	if finished != 1 {
		t.Fatalf("turn_completed must fire onTurnFinished exactly once, got %d", finished)
	}
}

// The history ring: bounded at histCap, oldest dropped first, text capped,
// and the onUserReply hook sees what the user actually typed.
func TestHistoryRing(t *testing.T) {
	a := newAgentWatch()
	id := "s-hist"
	var replies []string
	a.onUserReply = func(_, text string) { replies = append(replies, text) }

	long := strings.Repeat("x", 800)
	a.apply(ev(t, "user_prompt", id, "/r", map[string]any{"text": long}))
	for i := range 15 {
		a.apply(ev(t, "assistant_message", id, "", map[string]any{"text": fmt.Sprintf("msg-%d", i)}))
	}
	a.apply(ev(t, "tool_call", id, "", map[string]any{"name": "Bash", "input": "go test"}))

	_, hist, ok := a.context(id)
	if !ok {
		t.Fatal("context: session missing")
	}
	if len(hist) != histCap {
		t.Fatalf("ring len = %d, want %d", len(hist), histCap)
	}
	last := hist[len(hist)-1]
	if last.Role != "tool" || last.Text != "Bash go test" {
		t.Errorf("last entry = %+v, want tool/Bash go test", last)
	}
	if hist[len(hist)-2].Text != "msg-14" {
		t.Errorf("ring must keep newest entries, got %q before tool", hist[len(hist)-2].Text)
	}
	for _, m := range hist {
		if n := len([]rune(m.Text)); n > histMaxText+1 {
			t.Errorf("entry text %d runes > cap %d", n, histMaxText)
		}
	}
	if len(replies) != 1 || len([]rune(replies[0])) != 800 {
		t.Errorf("onUserReply got %d replies (len %d) — hook must carry the full text", len(replies), len(replies))
	}

	// empty-text events (metadata level) must not pollute the ring
	before := len(hist)
	a.apply(ev(t, "assistant_message", id, "", map[string]any{"input_tokens": 5}))
	_, hist, _ = a.context(id)
	if len(hist) != before {
		t.Error("empty assistant text must not be recorded")
	}
}

// AskUserQuestion is the one mid-turn prompt the transcript can identify:
// it must surface as an interactive needs_input with the question and
// options as the ask — and dissolve when the tool result (the user's
// selection) lands.
func TestInteractivePicker(t *testing.T) {
	a := newAgentWatch()
	id := "s-picker"
	input := `{"questions":[{"question":"Should I implement both NOTES.md items now?","header":"Scope",` +
		`"options":[{"label":"Yes, both","description":"do it"},{"label":"No","description":"tell me"}],"multiSelect":false}]}`

	a.apply(ev(t, "user_prompt", id, "/repo", map[string]any{"text": "go"}))
	a.apply(ev(t, "tool_call", id, "", map[string]any{"name": "AskUserQuestion", "input": input}))

	st := a.states[id]
	if st.State != "needs_input" || !st.Interactive {
		t.Fatalf("picker: state=%q interactive=%v, want needs_input/true", st.State, st.Interactive)
	}
	if st.AskSeq != 1 {
		t.Errorf("picker must mint an askSeq, got %d", st.AskSeq)
	}
	want := "Should I implement both NOTES.md items now?  — 1) Yes, both 2) No"
	if st.Ask != want {
		t.Errorf("ask = %q\nwant %q", st.Ask, want)
	}

	// user picks an option → tool_result → the ask is over
	a.apply(ev(t, "tool_result", id, "", map[string]any{"ok": true, "content": "Yes, both"}))
	if st.State != "working" || st.Interactive || st.Ask != "" {
		t.Errorf("after selection: state=%q interactive=%v ask=%q, want working/false/empty", st.State, st.Interactive, st.Ask)
	}

	// a normal turn end afterwards is a fresh, non-interactive ask
	a.apply(ev(t, "assistant_message", id, "", map[string]any{"text": "Done. Ship it?"}))
	a.apply(ev(t, "turn_completed", id, "", map[string]any{}))
	if st.AskSeq != 2 || st.Interactive || st.Ask != "Done. Ship it?" {
		t.Errorf("post-picker turn: seq=%d interactive=%v ask=%q", st.AskSeq, st.Interactive, st.Ask)
	}

	// truncated/garbled input (agentmon caps at 2KB) degrades, not drops
	a.apply(ev(t, "tool_call", id, "", map[string]any{"name": "AskUserQuestion", "input": `{"questions":[{"quest`}))
	if st.State != "needs_input" || st.Ask == "" {
		t.Errorf("garbled picker input must still surface an ask, got state=%q ask=%q", st.State, st.Ask)
	}
}

// The Notification hook: a permission prompt becomes an interactive ask;
// the 60s idle reminder for an already-surfaced ask is a no-op; the
// granted permission (tool_result) dissolves it.
func TestNotify(t *testing.T) {
	a := newAgentWatch()
	id := "s-notify"
	var staled []int
	a.onTurnCompleted = func(_ string, seq int) { staled = append(staled, seq) }

	// mid-turn permission prompt — transcript says "working", hook knows better
	a.apply(ev(t, "user_prompt", id, "/repo", map[string]any{"text": "go"}))
	a.apply(ev(t, "tool_call", id, "", map[string]any{"name": "Bash", "input": "rm -rf build"}))
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
	a.apply(ev(t, "tool_result", id, "", map[string]any{"ok": true}))
	if st.State != "working" || st.Interactive || st.Ask != "" {
		t.Errorf("after grant: state=%q interactive=%v ask=%q", st.State, st.Interactive, st.Ask)
	}

	// a session agentmon hasn't seen yet still surfaces via the hook
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
