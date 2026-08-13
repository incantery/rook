package drive

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/incantery/rook/plugins/internal/transcript"
)

// world is the fake transcript: tests mutate the session and the loop
// reads it back through Scan, the same one-way glass the real loop
// looks through.
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

// scriptDriver replies to a session on delivery: the prompt lands and,
// a beat later, the scripted reply appears as a finished turn.
type scriptDriver struct {
	w       *world
	replies []string
	sent    []string
	fail    error
}

func (d *scriptDriver) Deliver(ctx context.Context, sessionID, prompt string) error {
	if d.fail != nil {
		return d.fail
	}
	d.sent = append(d.sent, prompt)
	reply := "reply " + prompt
	if n := len(d.sent) - 1; n < len(d.replies) {
		reply = d.replies[n]
	}
	d.w.set(func(s *transcript.Session) {
		s.Prompt = prompt
		s.LastText = reply
		s.State = transcript.StateNeedsYou
	})
	return nil
}

// scriptJudge hands out verdicts in order and remembers what it saw.
type scriptJudge struct {
	verdicts []Verdict
	err      error
	seen     [][]Exchange
}

func (j *scriptJudge) Judge(ctx context.Context, goal string, history []Exchange) (Verdict, error) {
	j.seen = append(j.seen, append([]Exchange(nil), history...))
	if j.err != nil {
		return Verdict{}, j.err
	}
	n := len(j.seen) - 1
	if n >= len(j.verdicts) {
		return Verdict{Done: true, Reason: "script ran out"}, nil
	}
	return j.verdicts[n], nil
}

func testLoop(w *world, d Driver, j Judge) *Loop {
	return &Loop{
		Driver: d, Judge: j, Scan: w.scan,
		Poll: 2 * time.Millisecond, TurnTimeout: 500 * time.Millisecond, MaxTurns: 3,
	}
}

func TestRunMeetsTheGoalFirstTurn(t *testing.T) {
	w := newWorld(transcript.StateNeedsYou, "old turn")
	d := &scriptDriver{w: w, replies: []string{"three hypotheses, as asked"}}
	j := &scriptJudge{verdicts: []Verdict{{Done: true, Reason: "it hypothesized"}}}
	res, err := testLoop(w, d, j).Run(context.Background(), "s1", "get a hypothesis")
	if err != nil || !res.Done || res.Reason != "it hypothesized" {
		t.Fatalf("res=%+v err=%v", res, err)
	}
	if len(res.Turns) != 1 || res.Turns[0].Prompt != "get a hypothesis" || res.Turns[0].Reply != "three hypotheses, as asked" {
		t.Fatalf("turns: %+v", res.Turns)
	}
}

func TestRunRepromptsUntilTheJudgeIsSatisfied(t *testing.T) {
	w := newWorld(transcript.StateNeedsYou, "old turn")
	d := &scriptDriver{w: w, replies: []string{"I don't have access to that", "fine: here are three hypotheses"}}
	j := &scriptJudge{verdicts: []Verdict{
		{Prompt: "You do not need access — give your best hypothesis anyway."},
		{Done: true, Reason: "hypotheses delivered"},
	}}
	res, err := testLoop(w, d, j).Run(context.Background(), "s1", "get a hypothesis")
	if err != nil || !res.Done {
		t.Fatalf("res=%+v err=%v", res, err)
	}
	if len(res.Turns) != 2 || d.sent[1] != "You do not need access — give your best hypothesis anyway." {
		t.Fatalf("turns=%+v sent=%v", res.Turns, d.sent)
	}
	// The judge saw the whole history on the second look, not just the
	// latest round.
	if len(j.seen[1]) != 2 {
		t.Fatalf("judge saw %d rounds", len(j.seen[1]))
	}
}

func TestRunSpendsTheBudgetAndSaysSo(t *testing.T) {
	w := newWorld(transcript.StateNeedsYou, "old turn")
	d := &scriptDriver{w: w}
	j := &scriptJudge{verdicts: []Verdict{
		{Prompt: "again, once"}, {Prompt: "again, twice"}, {Prompt: "again, thrice"},
	}}
	res, err := testLoop(w, d, j).Run(context.Background(), "s1", "goal")
	if err != nil {
		t.Fatalf("budget exhaustion is not an error: %v", err)
	}
	if res.Done || !strings.Contains(res.Reason, "turn budget") || len(res.Turns) != 3 {
		t.Fatalf("res=%+v", res)
	}
}

func TestRunWaitsForAWorkingSessionBeforeTyping(t *testing.T) {
	w := newWorld(transcript.StateWorking, "mid-turn text")
	d := &scriptDriver{w: w}
	j := &scriptJudge{verdicts: []Verdict{{Done: true}}}
	go func() {
		time.Sleep(20 * time.Millisecond)
		w.set(func(s *transcript.Session) { s.State = transcript.StateNeedsYou })
	}()
	res, err := testLoop(w, d, j).Run(context.Background(), "s1", "goal")
	if err != nil || !res.Done {
		t.Fatalf("res=%+v err=%v", res, err)
	}
}

func TestRunStopsWhenTheDeskTakesOver(t *testing.T) {
	w := newWorld(transcript.StateNeedsYou, "old turn")
	// A driver whose delivery lands, but whose turn ends on somebody
	// else's prompt: the human typed their own question first.
	d := &scriptDriver{w: w}
	j := &scriptJudge{}
	loop := testLoop(w, d, j)
	loop.Driver = deliverFunc(func(ctx context.Context, id, prompt string) error {
		w.set(func(s *transcript.Session) {
			s.Prompt = "something the human asked"
			s.LastText = "an answer to the human"
			s.State = transcript.StateNeedsYou
		})
		return nil
	})
	_, err := loop.Run(context.Background(), "s1", "goal")
	if err == nil || !strings.Contains(err.Error(), "desk wins") {
		t.Fatalf("err=%v", err)
	}
}

type deliverFunc func(ctx context.Context, sessionID, prompt string) error

func (f deliverFunc) Deliver(ctx context.Context, sessionID, prompt string) error {
	return f(ctx, sessionID, prompt)
}

func TestRunReportsAVanishedSession(t *testing.T) {
	w := newWorld(transcript.StateNeedsYou, "old")
	w.vanish()
	_, err := testLoop(w, &scriptDriver{w: w}, &scriptJudge{}).Run(context.Background(), "s1", "goal")
	if err == nil || !strings.Contains(err.Error(), "gone") {
		t.Fatalf("err=%v", err)
	}
}

func TestRunSurfacesARefusedDelivery(t *testing.T) {
	w := newWorld(transcript.StateNeedsYou, "old")
	d := &scriptDriver{w: w, fail: errors.New("the keyboard's gates refused")}
	_, err := testLoop(w, d, &scriptJudge{}).Run(context.Background(), "s1", "goal")
	if err == nil || !strings.Contains(err.Error(), "delivery refused") {
		t.Fatalf("err=%v", err)
	}
}

func TestRunStopsOnCancel(t *testing.T) {
	w := newWorld(transcript.StateWorking, "busy forever")
	ctx, cancel := context.WithCancel(context.Background())
	go func() { time.Sleep(10 * time.Millisecond); cancel() }()
	loop := testLoop(w, &scriptDriver{w: w}, &scriptJudge{})
	loop.TurnTimeout = 10 * time.Second
	_, err := loop.Run(ctx, "s1", "goal")
	if err == nil || !strings.Contains(err.Error(), "stopped") {
		t.Fatalf("err=%v", err)
	}
}

func TestRunTimesOutAReplyThatNeverComes(t *testing.T) {
	w := newWorld(transcript.StateNeedsYou, "old")
	// Delivery "lands" but the transcript never moves.
	loop := testLoop(w, deliverFunc(func(context.Context, string, string) error { return nil }), &scriptJudge{})
	loop.TurnTimeout = 20 * time.Millisecond
	_, err := loop.Run(context.Background(), "s1", "goal")
	if err == nil || !strings.Contains(err.Error(), "timeout") {
		t.Fatalf("err=%v", err)
	}
}

// ---- the TUI driver ----

// fakeCaller plays rook's half of the wire: records every op, grants
// everything (or refuses everything).
type fakeCaller struct {
	mu     sync.Mutex
	ops    []string
	params []map[string]any
	refuse string
}

func (f *fakeCaller) Call(op string, params any, _ time.Duration) (json.RawMessage, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	raw, _ := json.Marshal(params)
	var p map[string]any
	json.Unmarshal(raw, &p)
	f.ops = append(f.ops, op)
	f.params = append(f.params, p)
	if f.refuse != "" {
		return nil, errors.New(f.refuse)
	}
	return json.RawMessage(`{}`), nil
}

func tuiWorld() (func(time.Time) []transcript.Session, func() []transcript.PaneActivity) {
	sessions := []transcript.Session{
		{ID: "old", Cwd: "/repo", Title: "yesterday", Mtime: time.Now().Add(-time.Hour)},
		{ID: "s1", Cwd: "/repo", Title: "today", Mtime: time.Now()},
	}
	panes := []transcript.PaneActivity{
		{ID: 7, Cwd: "/repo", Fg: "claude"},
		{ID: 8, Cwd: "/elsewhere", Fg: "zsh"},
	}
	return func(time.Time) []transcript.Session { return sessions },
		func() []transcript.PaneActivity { return panes }
}

func TestTUIDeliversAsPasteThenSubmit(t *testing.T) {
	scan, panes := tuiWorld()
	c := &fakeCaller{}
	d := &TUI{C: c, Scan: scan, Panes: panes, Names: []string{"claude"}}
	if err := d.Deliver(context.Background(), "s1", "the prompt"); err != nil {
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
	scan, panes := tuiWorld()
	d := &TUI{C: &fakeCaller{}, Scan: scan, Panes: panes, Names: []string{"claude"}}
	err := d.Deliver(context.Background(), "old", "the prompt")
	if err == nil || !strings.Contains(err.Error(), "history in its directory") {
		t.Fatalf("err=%v", err)
	}
}

func TestTUIRefusesAPanelessSession(t *testing.T) {
	scan, _ := tuiWorld()
	d := &TUI{C: &fakeCaller{}, Scan: scan,
		Panes: func() []transcript.PaneActivity { return nil }, Names: []string{"claude"}}
	err := d.Deliver(context.Background(), "s1", "the prompt")
	if err == nil || !strings.Contains(err.Error(), "not on a pane") {
		t.Fatalf("err=%v", err)
	}
}
