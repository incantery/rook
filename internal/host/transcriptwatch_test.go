package host

import (
	"encoding/json"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/incantery/rook/internal/transcript"
)

// mustParse parses a real transcript line, or fails the test.
func mustParse(t *testing.T, line string) *transcript.Record {
	t.Helper()
	rec, err := transcript.Parse([]byte(line))
	if err != nil {
		t.Fatalf("Parse(%s): %v", line, err)
	}
	return rec
}

// lineOf wraps a record at a byte offset, the way a Tail hands it over.
func lineOf(t *testing.T, rec *transcript.Record, offset int64) transcript.Line {
	t.Helper()
	return transcript.Line{SessionID: "s", Record: rec, Offset: offset}
}

// rline parses a real transcript line and feeds it in as a live append.
func rline(t *testing.T, sessionID, line string) transcript.Line {
	t.Helper()
	return transcript.Line{SessionID: sessionID, Record: mustParse(t, line), Live: true}
}

func backlog(ln transcript.Line) transcript.Line {
	ln.Live = false
	return ln
}

// The shapes Claude Code actually writes.
func assistantText(text string) string {
	b, _ := json.Marshal(map[string]any{
		"type": "assistant", "timestamp": "2026-07-15T12:00:00.000Z", "cwd": "/tmp/x",
		"message": map[string]any{
			"id": "msg_1", "role": "assistant", "model": "claude-fable-5",
			"content": []map[string]any{{"type": "text", "text": text}},
		},
	})
	return string(b)
}

func toolUse(name string, input any) string {
	b, _ := json.Marshal(map[string]any{
		"type": "assistant", "timestamp": "2026-07-15T12:00:01.000Z", "cwd": "/tmp/x",
		"message": map[string]any{
			"id": "msg_2", "role": "assistant", "model": "claude-fable-5",
			"content": []map[string]any{{"type": "tool_use", "id": "toolu_1", "name": name, "input": input}},
		},
	})
	return string(b)
}

const (
	turnDone   = `{"type":"system","subtype":"turn_duration","durationMs":1000,"messageCount":4,"timestamp":"2026-07-15T12:00:02.000Z","cwd":"/tmp/x"}`
	userTyped  = `{"type":"user","timestamp":"2026-07-15T12:00:03.000Z","cwd":"/tmp/x","message":{"role":"user","content":"go ahead"}}`
	toolResult = `{"type":"user","timestamp":"2026-07-15T12:00:04.000Z","cwd":"/tmp/x","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"done"}]}}`
)

// startSession establishes a session and its cwd the way the first record of
// a real transcript does. Every record type carries cwd; a mode record is the
// quietest one — it fires no hooks and touches no ask.
func startSession(t *testing.T, a *agentWatch, id, cwd string) {
	t.Helper()
	b, _ := json.Marshal(map[string]any{
		"type": "mode", "mode": "normal", "cwd": cwd,
		"timestamp": "2026-07-15T12:00:00.000Z",
	})
	a.applyRecord(rline(t, id, string(b)))
}

// userMsg is something a human typed: content as a bare string, which is how
// Claude Code writes a prompt.
func userMsg(text string) string {
	b, _ := json.Marshal(map[string]any{
		"type": "user", "timestamp": "2026-07-15T12:00:03.000Z", "cwd": "/tmp/x",
		"message": map[string]any{"role": "user", "content": text},
	})
	return string(b)
}

// assistantMsg is assistantText with a caller-chosen message id, so a test
// can write several distinct API responses.
func assistantMsg(id, text string) string {
	b, _ := json.Marshal(map[string]any{
		"type": "assistant", "timestamp": "2026-07-15T12:00:00.000Z", "cwd": "/tmp/x",
		"message": map[string]any{
			"id": id, "role": "assistant", "model": "claude-fable-5",
			"content": []map[string]any{{"type": "text", "text": text}},
		},
	})
	return string(b)
}

func TestRecordAskSeq(t *testing.T) {
	a := newAgentWatch()
	id := "s-seq"
	var hookSeqs []int
	a.onTurnCompleted = func(sid string, seq int) {
		if sid == id {
			hookSeqs = append(hookSeqs, seq)
		}
	}

	a.applyRecord(rline(t, id, assistantMsg("m1", "first?")))
	if a.states[id].AskSeq != 0 {
		t.Fatalf("AskSeq before any turn = %d, want 0", a.states[id].AskSeq)
	}
	a.applyRecord(rline(t, id, turnDone))
	a.applyRecord(rline(t, id, userTyped))
	a.applyRecord(rline(t, id, assistantMsg("m2", "second?")))
	a.applyRecord(rline(t, id, turnDone))

	if got := a.states[id].AskSeq; got != 2 {
		t.Errorf("AskSeq after two turns = %d, want 2", got)
	}
	if len(hookSeqs) != 2 || hookSeqs[0] != 1 || hookSeqs[1] != 2 {
		t.Errorf("onTurnCompleted seqs = %v, want [1 2]", hookSeqs)
	}
}

// onTurnFinished is the genuine turn-completion signal, and its
// whole contract is discipline: genuine turn ends ONLY. AskUserQuestion and
// permission notifies also invalidate asks (onTurnCompleted fires for them —
// that's ITS contract), but an agent asking a question has not finished its
// stage.
func TestRecordOnTurnFinishedDiscipline(t *testing.T) {
	a := newAgentWatch()
	id := "s-wf"
	var finished, completed int
	a.onTurnFinished = func(string) { finished++ }
	a.onTurnCompleted = func(string, int) { completed++ }

	a.applyRecord(rline(t, id, userTyped))
	a.applyRecord(rline(t, id, toolUse("AskUserQuestion", map[string]any{
		"questions": []map[string]any{{"question": "which?", "options": []map[string]string{{"label": "a"}, {"label": "b"}}}},
	})))
	if finished != 0 {
		t.Fatalf("AskUserQuestion fired onTurnFinished %d time(s) — a question is not a finished stage", finished)
	}
	if completed != 1 {
		t.Fatalf("AskUserQuestion must still invalidate prior asks, completed=%d", completed)
	}

	// permission prompt (Notification hook) mid-turn: same rule. notify()
	// is source-independent, but the discipline has to hold on this path too.
	a.applyRecord(rline(t, id, toolResult))
	a.applyRecord(rline(t, id, toolUse("Bash", map[string]string{"command": "rm -rf build"})))
	a.notify(id, "Claude needs your permission to use Bash")
	if finished != 0 {
		t.Fatalf("permission notify fired onTurnFinished %d time(s)", finished)
	}

	a.applyRecord(rline(t, id, toolResult))
	a.applyRecord(rline(t, id, turnDone))
	if finished != 1 {
		t.Fatalf("turn_duration must fire onTurnFinished exactly once, got %d", finished)
	}
}

// The history ring: bounded at histCap, oldest dropped first, text capped,
// and the onUserReply hook sees what the user actually typed.
func TestRecordHistoryRing(t *testing.T) {
	a := newAgentWatch()
	id := "s-hist"
	var replies []string
	a.onUserReply = func(_, text string) { replies = append(replies, text) }

	long := strings.Repeat("x", 800)
	b, _ := json.Marshal(map[string]any{
		"type": "user", "timestamp": "2026-07-15T12:00:00.000Z", "cwd": "/tmp/x",
		"message": map[string]any{"role": "user", "content": long},
	})
	a.applyRecord(rline(t, id, string(b)))
	for i := range 15 {
		a.applyRecord(rline(t, id, assistantMsg(fmt.Sprintf("m%d", i), fmt.Sprintf("msg-%d", i))))
	}
	a.applyRecord(rline(t, id, toolUse("Bash", map[string]string{"command": "go test"})))

	_, hist, ok := a.context(id)
	if !ok {
		t.Fatal("context: session missing")
	}
	if len(hist) != histCap {
		t.Fatalf("ring len = %d, want %d", len(hist), histCap)
	}
	last := hist[len(hist)-1]
	if last.Role != "tool" || !strings.HasPrefix(last.Text, "Bash ") {
		t.Errorf("last entry = %+v, want a tool entry for Bash", last)
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
		t.Errorf("onUserReply got %d replies — the hook must carry the full text uncapped", len(replies))
	}

	// an assistant record with no text (tool calls only) must not pollute
	// the ring with a blank entry
	before := len(hist)
	a.applyRecord(rline(t, id, assistantMsg("m-empty", "")))
	_, hist, _ = a.context(id)
	if len(hist) != before {
		t.Error("empty assistant text must not be recorded")
	}
}

func TestRecordStateMachine(t *testing.T) {
	a := newAgentWatch()
	id := "s-abc"

	a.applyRecord(rline(t, id, assistantText("Should I delete the old migration?")))
	if st := a.states[id]; st.State != "working" {
		t.Fatalf("mid-turn state = %q, want working", st.State)
	}
	a.applyRecord(rline(t, id, turnDone))

	st := a.states[id]
	if st.State != "needs_input" {
		t.Fatalf("after turn_duration: state = %q, want needs_input", st.State)
	}
	if st.Ask != "Should I delete the old migration?" {
		t.Errorf("Ask = %q", st.Ask)
	}
	if st.AskSeq != 1 {
		t.Errorf("AskSeq = %d, want 1", st.AskSeq)
	}
	if st.Model != "claude-fable-5" {
		t.Errorf("Model = %q", st.Model)
	}
	// Reading from zero means the cwd-bearing first record is always seen.
	if st.CWD != "/tmp/x" || st.Project != "/tmp/x" {
		t.Errorf("CWD = %q, Project = %q, want /tmp/x", st.CWD, st.Project)
	}
}

func TestRecordUserPromptClearsAsk(t *testing.T) {
	a := newAgentWatch()
	id := "s1"
	var replies []string
	a.onUserReply = func(_, text string) { replies = append(replies, text) }

	a.applyRecord(rline(t, id, assistantText("well?")))
	a.applyRecord(rline(t, id, turnDone))
	a.applyRecord(rline(t, id, userTyped))

	st := a.states[id]
	if st.State != "working" {
		t.Errorf("state = %q, want working", st.State)
	}
	if st.Ask != "" {
		t.Errorf("Ask = %q, want cleared", st.Ask)
	}
	if len(replies) != 1 || replies[0] != "go ahead" {
		t.Errorf("onUserReply got %v, want [go ahead]", replies)
	}
}

// A tool result is the session talking to itself, not the user replying.
func TestRecordToolResultIsNotAUserReply(t *testing.T) {
	a := newAgentWatch()
	id := "s1"
	fired := 0
	a.onUserReply = func(_, _ string) { fired++ }

	a.applyRecord(rline(t, id, toolUse("Bash", map[string]string{"command": "ls"})))
	a.applyRecord(rline(t, id, toolResult))

	if fired != 0 {
		t.Errorf("onUserReply fired %d times for a tool result", fired)
	}
	if st := a.states[id]; st.State != "working" {
		t.Errorf("state = %q, want working", st.State)
	}
}

func TestRecordPickerBecomesInteractiveAsk(t *testing.T) {
	a := newAgentWatch()
	id := "s1"
	a.applyRecord(rline(t, id, toolUse("AskUserQuestion", map[string]any{
		"questions": []map[string]any{{
			"question": "Which framing?",
			"options": []map[string]string{
				{"label": "Agent workspace"}, {"label": "Terminal emulator"},
			},
		}},
	})))

	st := a.states[id]
	if st.State != "needs_input" {
		t.Fatalf("state = %q, want needs_input", st.State)
	}
	if !st.Interactive {
		t.Error("Interactive = false; a picker wants a selection, not typed text")
	}
	if st.AskSeq != 1 {
		t.Errorf("AskSeq = %d, want 1", st.AskSeq)
	}

	// the picker's answer ends the ask
	a.applyRecord(rline(t, id, toolResult))
	st = a.states[id]
	if st.Interactive || st.Ask != "" {
		t.Errorf("after the answer: Interactive=%v Ask=%q, want cleared", st.Interactive, st.Ask)
	}
}

// The payoff. agentmon caps tool input at 2KB, which is smaller than a real
// picker, so pickerAsk degraded to its generic fallback. Whole input means
// the actual question and options reach the ask.
func TestRecordPickerSurvivesPastAgentmonsCap(t *testing.T) {
	var opts []map[string]string
	for i := range 8 {
		opts = append(opts, map[string]string{
			"label":       fmt.Sprintf("Option %d", i),
			"description": strings.Repeat("y", 300),
		})
	}
	line := toolUse("AskUserQuestion", map[string]any{
		"questions": []map[string]any{{"question": "Which one?", "options": opts}},
	})
	if len(line) <= 2048 {
		t.Fatalf("fixture is %d bytes; it must exceed 2KB to be a test", len(line))
	}

	a := newAgentWatch()
	a.applyRecord(rline(t, "s1", line))

	ask := a.states["s1"].Ask
	if strings.Contains(ask, "interactive prompt") {
		t.Fatalf("Ask fell back to the generic line: %q", ask)
	}
	if !strings.HasPrefix(ask, "Which one?") {
		t.Errorf("Ask = %q, want the real question", ask)
	}
	if !strings.Contains(ask, "8) Option 7") {
		t.Errorf("Ask = %q, want every option rendered", ask)
	}
}

// Backlog rebuilds state but must not fire side effects: replaying a
// discovered file would otherwise signal turn completion for turns that
// ended hours ago.
func TestRecordBacklogReducesStateButFiresNoHooks(t *testing.T) {
	a := newAgentWatch()
	id := "s1"
	var turns, finished, replies int
	a.onTurnCompleted = func(string, int) { turns++ }
	a.onTurnFinished = func(string) { finished++ }
	a.onUserReply = func(string, string) { replies++ }

	a.applyRecord(backlog(rline(t, id, userTyped)))
	a.applyRecord(backlog(rline(t, id, assistantText("historical answer"))))
	a.applyRecord(backlog(rline(t, id, turnDone)))

	st := a.states[id]
	if st.State != "needs_input" {
		t.Errorf("state = %q — backlog must still reduce", st.State)
	}
	if st.Ask != "historical answer" {
		t.Errorf("Ask = %q — backlog must still reduce", st.Ask)
	}
	if turns != 0 || finished != 0 || replies != 0 {
		t.Errorf("backlog fired hooks: turns=%d finished=%d replies=%d", turns, finished, replies)
	}

	// and a live turn afterwards still fires
	a.applyRecord(rline(t, id, assistantText("live answer")))
	a.applyRecord(rline(t, id, turnDone))
	if turns != 1 || finished != 1 {
		t.Errorf("live turn: turns=%d finished=%d, want 1 and 1", turns, finished)
	}
}

// One API response is written as several lines repeating the same id and
// usage. Naive summing roughly doubles the bill.
func TestRecordCostDedupesOnMessageID(t *testing.T) {
	line := func(id, text string) string {
		b, _ := json.Marshal(map[string]any{
			"type": "assistant", "timestamp": "2026-07-15T12:00:00.000Z",
			"message": map[string]any{
				"id": id, "role": "assistant", "model": "claude-haiku-4-5",
				"usage":   map[string]any{"output_tokens": 1_000_000},
				"content": []map[string]any{{"type": "text", "text": text}},
			},
		})
		return string(b)
	}
	a := newAgentWatch()
	// same response, two lines (one per content block)
	a.applyRecord(rline(t, "s1", line("msg_dup", "first block")))
	a.applyRecord(rline(t, "s1", line("msg_dup", "second block")))

	if got := a.states["s1"].CostUSD; got != 5 {
		t.Errorf("CostUSD = %v, want 5 — the repeated usage object was billed twice", got)
	}

	// a genuinely different response does bill again
	a.applyRecord(rline(t, "s1", line("msg_other", "next")))
	if got := a.states["s1"].CostUSD; got != 10 {
		t.Errorf("CostUSD = %v, want 10", got)
	}
}

func TestRecordUnknownModelIsUnpricedNotFree(t *testing.T) {
	b, _ := json.Marshal(map[string]any{
		"type": "assistant", "timestamp": "2026-07-15T12:00:00.000Z",
		"message": map[string]any{
			"id": "m1", "role": "assistant", "model": "claude-unknown-9",
			"usage":   map[string]any{"output_tokens": 1_000_000},
			"content": []map[string]any{{"type": "text", "text": "hi"}},
		},
	})
	a := newAgentWatch()
	a.applyRecord(rline(t, "s1", string(b)))

	st := a.states["s1"]
	if st.CostUSD != 0 {
		t.Errorf("CostUSD = %v, want 0 for an unpriced model", st.CostUSD)
	}
	if st.Model != "claude-unknown-9" {
		t.Errorf("Model = %q — an unpriced model is still a model", st.Model)
	}
}

func TestRecordSidechainIgnored(t *testing.T) {
	a := newAgentWatch()
	line := `{"type":"assistant","isSidechain":true,"timestamp":"2026-07-15T12:00:00.000Z","message":{"role":"assistant","content":[{"type":"text","text":"subagent chatter"}]}}`
	a.applyRecord(rline(t, "s1", line))
	if len(a.states) != 0 {
		t.Errorf("sidechain traffic created state: %+v", a.states)
	}
}

func TestRecordTitle(t *testing.T) {
	a := newAgentWatch()
	a.applyRecord(rline(t, "s1", assistantText("x")))
	a.applyRecord(rline(t, "s1", `{"type":"ai-title","aiTitle":"Rewriting the sensor"}`))
	if got := a.states["s1"].Title; got != "Rewriting the sensor" {
		t.Errorf("Title = %q", got)
	}
}

// ai-title and permission-mode carry no timestamp; the reducer carries the
// last one forward rather than stamping now.
func TestRecordTimestampCarry(t *testing.T) {
	a := newAgentWatch()
	a.applyRecord(rline(t, "s1", assistantText("x")))
	want := a.states["s1"].LastEvent

	a.applyRecord(rline(t, "s1", `{"type":"permission-mode","permissionMode":"auto"}`))
	if got := a.states["s1"].LastEvent; !got.Equal(want) {
		t.Errorf("LastEvent = %v, want it carried at %v", got, want)
	}
	if want.IsZero() {
		t.Fatal("setup: timestamp should have parsed")
	}
}

func TestSweepMarksQuietThenEnds(t *testing.T) {
	a := newAgentWatch()
	id := "s1"
	a.applyRecord(rline(t, id, assistantText("working on it")))
	base := a.states[id].LastEvent

	// still inside the idle window
	a.sweepTranscript(base.Add(10 * time.Second))
	if got := a.states[id].State; got != "working" {
		t.Errorf("state = %q, want working", got)
	}

	// silent mid-turn: a long tool run, or a permission prompt
	a.sweepTranscript(base.Add(transcriptIdleAfter + time.Second))
	if got := a.states[id].State; got != "quiet" {
		t.Errorf("state = %q, want quiet", got)
	}

	// silent long enough to be over
	a.sweepTranscript(base.Add(transcriptEndedAfter + time.Second))
	if _, ok := a.states[id]; ok {
		t.Error("session should be gone after the ended-after window")
	}
}

// A session waiting on a human is not idle — it is waiting, and it must not
// be downgraded to quiet.
func TestSweepLeavesNeedsInputAlone(t *testing.T) {
	a := newAgentWatch()
	id := "s1"
	a.applyRecord(rline(t, id, assistantText("well?")))
	a.applyRecord(rline(t, id, turnDone))
	base := a.states[id].LastEvent

	a.sweepTranscript(base.Add(transcriptIdleAfter + time.Second))
	if got := a.states[id].State; got != "needs_input" {
		t.Errorf("state = %q, want needs_input", got)
	}
}
