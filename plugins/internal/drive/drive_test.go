package drive

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/incantery/rook/plugins/internal/transcript"
	veradrive "github.com/incantery/vera/drive"
)

// What is tested here is the MECHANISM: typing, and the two waits that
// turn typing into a turn. The loop that spends the turns and judges
// the replies is vera's and is tested there — what this file must not
// let rot is that rook's half still keeps its promises to it, and the
// last two tests run the real loop over this turner to prove the seam
// is not just a compiling signature.

// world is the fake transcript: tests mutate the session and the
// turner reads it back through Scan, the same one-way glass the real
// one looks through.
type world struct {
	mu sync.Mutex
	s  transcript.Session
	ok bool // false = the session is gone
}

func newWorld(state transcript.State, lastText string) *world {
	return &world{ok: true, s: transcript.Session{
		ID: "s1", Cwd: "/repo", Title: "the session",
		State: state, LastText: lastText,
	}}
}

func (w *world) scan(time.Time) []transcript.Session {
	w.mu.Lock()
	defer w.mu.Unlock()
	if !w.ok {
		return nil
	}
	return []transcript.Session{w.s}
}

func (w *world) set(f func(*transcript.Session)) {
	w.mu.Lock()
	defer w.mu.Unlock()
	f(&w.s)
}

func (w *world) vanish() {
	w.mu.Lock()
	defer w.mu.Unlock()
	w.ok = false
}

func (w *world) panes() []transcript.PaneActivity {
	return []transcript.PaneActivity{{ID: 7, Cwd: "/repo", Fg: "claude"}}
}

// fakeCaller plays rook's half of the wire: records every op, grants
// everything (or refuses everything). onSubmit is the session
// answering — it fires on the submit frame, which is the moment a
// prompt actually lands.
type fakeCaller struct {
	mu       sync.Mutex
	ops      []string
	params   []map[string]any
	lastText string
	refuse   string
	onSubmit func(typed string)
}

func (f *fakeCaller) Call(op string, params any, _ time.Duration) (json.RawMessage, error) {
	raw, _ := json.Marshal(params)
	var p map[string]any
	json.Unmarshal(raw, &p)

	f.mu.Lock()
	f.ops = append(f.ops, op)
	f.params = append(f.params, p)
	if t, ok := p["text"].(string); ok {
		f.lastText = t
	}
	typed, refuse, answer := f.lastText, f.refuse, f.onSubmit
	f.mu.Unlock()

	if refuse != "" {
		return nil, errors.New(refuse)
	}
	if p["submit_only"] == true && answer != nil {
		answer(typed)
	}
	return json.RawMessage(`{}`), nil
}

func (f *fakeCaller) count() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return len(f.ops)
}

// typed lists, in order, the text of every paste frame — what actually
// reached somebody's terminal.
func (f *fakeCaller) typed() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	var out []string
	for _, p := range f.params {
		if t, ok := p["text"].(string); ok {
			out = append(out, t)
		}
	}
	return out
}

// answering wires a caller whose session replies to whatever is typed,
// scripted in order, ending the turn the way a real one ends: needs
// you, with the assistant's last word changed and the prompt on the
// record as the one that was sent.
func answering(w *world, replies ...string) *fakeCaller {
	var n int
	c := &fakeCaller{}
	c.onSubmit = func(typed string) {
		reply := "reply to: " + typed
		if n < len(replies) {
			reply = replies[n]
		}
		n++
		w.set(func(s *transcript.Session) {
			s.Prompt = typed
			s.LastText = reply
			s.State = transcript.StateNeedsYou
		})
	}
	return c
}

func tuiFor(w *world, c Caller) *TUI {
	return &TUI{
		C: c, Scan: w.scan, Panes: w.panes, Names: []string{"claude"},
		Poll: 2 * time.Millisecond, TurnTimeout: 500 * time.Millisecond,
	}
}

// ---- the mechanism: typing ----

func TestTUIDeliversAsPasteThenSubmit(t *testing.T) {
	w := newWorld(transcript.StateNeedsYou, "old turn")
	c := &fakeCaller{}
	if err := tuiFor(w, c).Deliver(context.Background(), "s1", "the prompt"); err != nil {
		t.Fatalf("deliver: %v", err)
	}
	if len(c.ops) != 2 || c.ops[0] != "session.send" || c.ops[1] != "session.send" {
		t.Fatalf("ops: %v", c.ops)
	}
	first, second := c.params[0], c.params[1]
	if first["text"] != "the prompt" || first["no_submit"] != true || first["pane"] != float64(7) {
		t.Fatalf("paste frame: %v", first)
	}
	if second["submit_only"] != true {
		t.Fatalf("submit frame: %v", second)
	}
}

func TestTUIRefusesAStaleSession(t *testing.T) {
	// Two sessions in one directory: the pane there runs the newer one,
	// so typing at the older one would put words in a stranger's mouth.
	sessions := []transcript.Session{
		{ID: "old", Cwd: "/repo", Title: "yesterday", Mtime: time.Now().Add(-time.Hour)},
		{ID: "s1", Cwd: "/repo", Title: "today", Mtime: time.Now()},
	}
	w := newWorld(transcript.StateNeedsYou, "old turn")
	d := &TUI{C: &fakeCaller{}, Names: []string{"claude"}, Panes: w.panes,
		Scan: func(time.Time) []transcript.Session { return sessions }}
	err := d.Deliver(context.Background(), "old", "the prompt")
	if err == nil || !strings.Contains(err.Error(), "history in its directory") {
		t.Fatalf("err=%v", err)
	}
}

func TestTUIRefusesAPanelessSession(t *testing.T) {
	w := newWorld(transcript.StateNeedsYou, "old turn")
	d := tuiFor(w, &fakeCaller{})
	d.Panes = func() []transcript.PaneActivity { return nil }
	err := d.Deliver(context.Background(), "s1", "the prompt")
	if err == nil || !strings.Contains(err.Error(), "not on a pane") {
		t.Fatalf("err=%v", err)
	}
}

// ---- the mechanism: the two waits that make a turn ----

func TestRunTurnWaitsForAWorkingSessionBeforeTyping(t *testing.T) {
	w := newWorld(transcript.StateWorking, "mid-turn text")
	c := answering(w, "the answer")
	d := tuiFor(w, c)
	var lines []string
	var mu sync.Mutex
	d.Progress = func(l string) { mu.Lock(); lines = append(lines, l); mu.Unlock() }

	var typedEarly atomic.Bool
	go func() {
		time.Sleep(20 * time.Millisecond)
		typedEarly.Store(c.count() > 0)
		w.set(func(s *transcript.Session) { s.State = transcript.StateNeedsYou })
	}()

	turn, err := d.RunTurn(context.Background(), "s1", "the prompt")
	if err != nil || turn.Reply != "the answer" {
		t.Fatalf("turn=%+v err=%v", turn, err)
	}
	if typedEarly.Load() {
		t.Fatal("typed into a session that was still working — the prompt would queue behind somebody else's turn")
	}
	// The conversation stays where it is: this mechanism does not fork.
	if turn.SessionID != "s1" {
		t.Fatalf("session id moved to %q", turn.SessionID)
	}
	// A typed drive spends its time waiting; a row that cannot say what
	// it is waiting for reads as hung.
	mu.Lock()
	defer mu.Unlock()
	if len(lines) < 3 || !strings.Contains(lines[0], "quiet") || !strings.Contains(lines[len(lines)-1], "reply") {
		t.Fatalf("progress: %v", lines)
	}
}

func TestRunTurnStopsWhenTheDeskTakesOver(t *testing.T) {
	w := newWorld(transcript.StateNeedsYou, "old turn")
	c := &fakeCaller{}
	// The turn ends on somebody ELSE's prompt: the human typed their own
	// question while the drive was waiting.
	c.onSubmit = func(string) {
		w.set(func(s *transcript.Session) {
			s.Prompt = "something the human asked"
			s.LastText = "an answer to the human"
			s.State = transcript.StateNeedsYou
		})
	}
	_, err := tuiFor(w, c).RunTurn(context.Background(), "s1", "the prompt")
	if err == nil || !strings.Contains(err.Error(), "desk wins") {
		t.Fatalf("err=%v", err)
	}
	// Losing to the desk is a ruling, not a hiccup: retrying it would
	// type over the human who just took the keyboard.
	if veradrive.IsTransient(err) {
		t.Fatal("the desk winning must never be marked retryable")
	}
}

func TestRunTurnTimesOutAReplyThatNeverComesAndSaysItIsWorthRetrying(t *testing.T) {
	w := newWorld(transcript.StateNeedsYou, "old")
	// Delivery lands but the transcript never moves.
	d := tuiFor(w, &fakeCaller{})
	d.TurnTimeout = 20 * time.Millisecond
	_, err := d.RunTurn(context.Background(), "s1", "goal")
	if err == nil || !strings.Contains(err.Error(), "timeout") {
		t.Fatalf("err=%v", err)
	}
	if !veradrive.IsTransient(err) {
		t.Fatal("a clock running out is the machinery's failure, not the goal's — it must carry the transient mark")
	}
}

func TestRunTurnStopsOnCancelAndTheStopIsFinal(t *testing.T) {
	w := newWorld(transcript.StateWorking, "busy forever")
	ctx, cancel := context.WithCancel(context.Background())
	go func() { time.Sleep(10 * time.Millisecond); cancel() }()
	d := tuiFor(w, &fakeCaller{})
	d.TurnTimeout = 10 * time.Second
	_, err := d.RunTurn(ctx, "s1", "goal")
	if err == nil || !strings.Contains(err.Error(), "stopped") {
		t.Fatalf("err=%v", err)
	}
	// A human pressed stop. Retrying what somebody halted is the one
	// thing a drive must not do.
	if veradrive.IsTransient(err) {
		t.Fatal("a deliberate stop must not be marked retryable")
	}
}

func TestRunTurnReportsAVanishedSession(t *testing.T) {
	w := newWorld(transcript.StateNeedsYou, "old")
	w.vanish()
	_, err := tuiFor(w, &fakeCaller{}).RunTurn(context.Background(), "s1", "goal")
	if err == nil || !strings.Contains(err.Error(), "gone") {
		t.Fatalf("err=%v", err)
	}
}

func TestRunTurnSurfacesARefusedDelivery(t *testing.T) {
	w := newWorld(transcript.StateNeedsYou, "old")
	_, err := tuiFor(w, &fakeCaller{refuse: "the keyboard's gates refused"}).
		RunTurn(context.Background(), "s1", "goal")
	if err == nil || !strings.Contains(err.Error(), "delivery refused") {
		t.Fatalf("err=%v", err)
	}
}

// ---- the seam: vera's loop over rook's mechanism ----

// scriptJudge hands out verdicts in order and remembers what it saw.
type scriptJudge struct {
	verdicts []veradrive.Verdict
	seen     [][]veradrive.Exchange
}

func (j *scriptJudge) Judge(_ context.Context, _ string, history []veradrive.Exchange) (veradrive.Verdict, error) {
	j.seen = append(j.seen, append([]veradrive.Exchange(nil), history...))
	n := len(j.seen) - 1
	if n >= len(j.verdicts) {
		return veradrive.Verdict{Done: true, Reason: "script ran out"}, nil
	}
	return j.verdicts[n], nil
}

func TestTheLoopRepromptsThroughTheTurnerUntilTheJudgeIsSatisfied(t *testing.T) {
	w := newWorld(transcript.StateNeedsYou, "old turn")
	c := answering(w, "I don't have access to that", "fine: here are three hypotheses")
	j := &scriptJudge{verdicts: []veradrive.Verdict{
		{Prompt: "You do not need access — give your best hypothesis anyway."},
		{Done: true, Reason: "hypotheses delivered"},
	}}
	loop := &veradrive.Loop{Turner: tuiFor(w, c), Judge: j, MaxTurns: 3}
	res, err := loop.Run(context.Background(), "s1", "get a hypothesis")
	if err != nil || !res.Done || res.Reason != "hypotheses delivered" {
		t.Fatalf("res=%+v err=%v", res, err)
	}
	if len(res.Turns) != 2 {
		t.Fatalf("turns: %+v", res.Turns)
	}
	// The judge's next message is what reached the terminal — the whole
	// point of the mechanism being on the other side of the seam.
	typed := c.typed()
	if len(typed) != 2 || typed[0] != "get a hypothesis" || !strings.Contains(typed[1], "best hypothesis") {
		t.Fatalf("typed: %v", typed)
	}
	// The judge sees the whole conversation, not just the latest round.
	if len(j.seen[1]) != 2 {
		t.Fatalf("the judge saw %d rounds on its second look", len(j.seen[1]))
	}
}

func TestAnEscalationStopsTheDriveWithTheAskOnRecord(t *testing.T) {
	w := newWorld(transcript.StateNeedsYou, "old turn")
	c := answering(w, "I can do it but it means a force-push")
	j := &scriptJudge{verdicts: []veradrive.Verdict{
		{Escalate: true, Reason: "The worker wants to force-push; the goal grants no such thing. Allow it?"},
	}}
	loop := &veradrive.Loop{Turner: tuiFor(w, c), Judge: j, MaxTurns: 3}
	res, err := loop.Run(context.Background(), "s1", "land the release")
	if err != nil {
		t.Fatalf("an escalation is not an error: %v", err)
	}
	if !res.Escalated || !strings.Contains(res.Ask, "force-push") {
		t.Fatalf("res=%+v", res)
	}
	// Escalating means stopping. Nothing more may be typed at somebody
	// whose next move the machine just admitted it cannot make.
	if typed := c.typed(); len(typed) != 1 {
		t.Fatalf("typed after escalating: %v", typed)
	}
}
