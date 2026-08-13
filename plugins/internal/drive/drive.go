// Package drive turns one goal into a supervised conversation with a
// live Claude Code session: say something, wait for the turn to end,
// judge the reply against the goal, and either stop or say the next
// thing — a bounded number of times. It is the loop a human runs by
// hand when an agent needs three nudges to actually answer the
// question, made a verb.
//
// The package is also the seam the mechanics hide behind. A Driver is
// "one prompt reaches one session"; today's only implementation types
// keystrokes into the session's pane — the same session.send path
// answers ride, gates and all (the TUI-only rule, ADR 0002 in
// rook-host). A future headless driver (`claude -p --resume`) would
// implement the same interface and change nothing else: both
// mechanisms land their turns in the same transcript, and the
// transcript is the only witness the loop believes.
package drive

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/incantery/rook/plugins/internal/transcript"
)

// Caller is the sliver of the plugin wire a driver needs: ask rook for
// one verb, wait for the verdict. Every plugin's conn already has this
// shape; exporting the method is all it costs to hand it in.
type Caller interface {
	Call(op string, params any, timeout time.Duration) (json.RawMessage, error)
}

// submitSettle is how long a paste is left to settle before the CR
// that submits it. An agent TUI collapses a large or multi-line paste
// into a placeholder draft, and a CR glued to the same burst is eaten
// by that collapse instead of submitting — so type, let the TUI's
// event loop finish, then submit.
const submitSettle = 150 * time.Millisecond

// TypeAndSubmit types text into a pane and submits it in two steps:
// the bracketed paste held open (no CR), a settle, then the CR alone.
// Both steps pass session.send's gates; the second is a bare submit.
// This was the cloud bridge's and the link executor's private copy,
// twice — the shared seam is where the third caller found it.
func TypeAndSubmit(c Caller, pane int, text string) error {
	if _, err := c.Call("session.send",
		map[string]any{"pane": pane, "text": text, "no_submit": true}, 5*time.Second); err != nil {
		return err
	}
	time.Sleep(submitSettle)
	_, err := c.Call("session.send",
		map[string]any{"pane": pane, "submit_only": true}, 5*time.Second)
	return err
}

// A Driver delivers one prompt to one session, or says honestly why it
// could not. It does not wait for the reply — the transcript answers
// that for every driver alike.
type Driver interface {
	Deliver(ctx context.Context, sessionID, prompt string) error
}

// TUI is the typed-keystrokes driver: the prompt reaches the session
// as text in its pane, under the same gates and the same
// one-pane-one-session heuristic say delivers by.
type TUI struct {
	C     Caller
	Scan  func(now time.Time) []transcript.Session
	Panes func() []transcript.PaneActivity
	Names []string // foreground names that count as Claude Code
}

func (t *TUI) Deliver(ctx context.Context, sessionID, prompt string) error {
	sessions := t.Scan(time.Now())
	target := findSession(sessions, sessionID)
	if target == nil {
		return errors.New("that session is gone")
	}
	if target.ID != freshestInCwd(sessions, target.Cwd) {
		return errors.New(transcript.Snip(target.Title, 40) + " is history in its directory — the pane there runs a newer session")
	}
	pane := findPane(t.Panes(), target.Cwd, t.Names)
	if pane == nil {
		return errors.New(transcript.Snip(target.Title, 40) + " is not on a pane")
	}
	return TypeAndSubmit(t.C, pane.ID, prompt)
}

// A Judge reads the goal and the conversation so far and decides:
// done, or here is the next thing to say.
type Judge interface {
	Judge(ctx context.Context, goal string, history []Exchange) (Verdict, error)
}

// Exchange is one round of the drive's own conversation: what was said
// on the owner's behalf and what the session said back.
type Exchange struct {
	Prompt string
	Reply  string
}

type Verdict struct {
	Done   bool
	Prompt string // when not done: the exact next message to send
	Reason string // one line for the record
}

// Result is what a drive has to show for itself: every round it ran,
// and the last honest word on whether the goal was met.
type Result struct {
	Done   bool
	Reason string
	Turns  []Exchange
}

// Loop is one drive's machinery. Driver, Judge and Scan are required;
// the rest defaults to something sane.
type Loop struct {
	Driver Driver
	Judge  Judge
	Scan   func(now time.Time) []transcript.Session

	Poll        time.Duration // how often the transcript is re-read (default 5s)
	TurnTimeout time.Duration // how long one turn may run (default 15m)
	MaxTurns    int           // prompts sent before giving up (default 4)

	Progress func(line string) // optional: one live line for a panel row
}

func (l *Loop) poll() time.Duration {
	if l.Poll > 0 {
		return l.Poll
	}
	return 5 * time.Second
}

func (l *Loop) turnTimeout() time.Duration {
	if l.TurnTimeout > 0 {
		return l.TurnTimeout
	}
	return 15 * time.Minute
}

func (l *Loop) maxTurns() int {
	if l.MaxTurns > 0 {
		return l.MaxTurns
	}
	return 4
}

func (l *Loop) progress(format string, args ...any) {
	if l.Progress != nil {
		l.Progress(fmt.Sprintf(format, args...))
	}
}

// Run drives one session toward one goal. The returned error is an
// abnormal stop — session gone, delivery refused, a human taking over,
// the judge breaking — and the Result still carries whatever rounds
// ran. A goal honestly not met within the turn budget is not an error;
// it is Done=false with the reason on the record.
func (l *Loop) Run(ctx context.Context, sessionID, goal string) (Result, error) {
	var res Result
	prompt := goal
	for turn := 1; turn <= l.maxTurns(); turn++ {
		// The session must be quiet before anything is typed: text
		// delivered mid-turn queues behind work this loop did not ask
		// for, and the turn that then ends would be misread as the
		// reply. Waiting is honest; interrupting is not ours to do.
		l.progress("turn %d/%d: waiting for the session to go quiet", turn, l.maxTurns())
		base, err := l.awaitQuiet(ctx, sessionID)
		if err != nil {
			return res, err
		}
		l.progress("turn %d/%d: delivering the prompt", turn, l.maxTurns())
		if err := l.Driver.Deliver(ctx, sessionID, prompt); err != nil {
			return res, errors.New("delivery refused: " + err.Error())
		}
		l.progress("turn %d/%d: waiting on the reply", turn, l.maxTurns())
		reply, err := l.awaitReply(ctx, sessionID, prompt, base)
		if err != nil {
			return res, err
		}
		res.Turns = append(res.Turns, Exchange{Prompt: prompt, Reply: reply})
		l.progress("turn %d/%d: judging the reply", turn, l.maxTurns())
		v, err := l.Judge.Judge(ctx, goal, res.Turns)
		if err != nil {
			return res, errors.New("the judge failed: " + err.Error())
		}
		if v.Done {
			res.Done = true
			res.Reason = v.Reason
			if res.Reason == "" {
				res.Reason = "the goal is met"
			}
			return res, nil
		}
		if strings.TrimSpace(v.Prompt) == "" {
			return res, errors.New("the judge wanted to continue but had nothing to say")
		}
		prompt = v.Prompt
	}
	res.Reason = fmt.Sprintf("the turn budget (%d) is spent and the goal is not met", l.maxTurns())
	return res, nil
}

// awaitQuiet waits until the session is between turns and returns the
// baseline the next reply must differ from. Blocked counts as not
// quiet: a session sitting on an approval box needs a human's yes, not
// another prompt on top of it.
func (l *Loop) awaitQuiet(ctx context.Context, sessionID string) (baseline string, err error) {
	deadline := time.Now().Add(l.turnTimeout())
	for {
		s := findSession(l.Scan(time.Now()), sessionID)
		if s == nil {
			return "", errors.New("that session is gone")
		}
		if s.State != transcript.StateWorking && s.State != transcript.StateBlocked {
			return hash(s.LastText), nil
		}
		if time.Now().After(deadline) {
			return "", fmt.Errorf("the session stayed %s past the turn timeout", s.State)
		}
		if err := sleep(ctx, l.poll()); err != nil {
			return "", err
		}
	}
}

// awaitReply watches the transcript until the delivered prompt's turn
// ends — the session needs a human again and the assistant's last word
// has changed — and returns that word. A turn ending on someone ELSE's
// prompt means a human took the keyboard mid-drive; the desk wins and
// the drive stops, the same both-settle rule every rail follows.
func (l *Loop) awaitReply(ctx context.Context, sessionID, prompt, baseline string) (string, error) {
	deadline := time.Now().Add(l.turnTimeout())
	for {
		s := findSession(l.Scan(time.Now()), sessionID)
		if s == nil {
			return "", errors.New("that session is gone mid-turn")
		}
		if s.State == transcript.StateNeedsYou && hash(s.LastText) != baseline {
			if s.Prompt != "" && fold(s.Prompt) != fold(prompt) {
				return "", errors.New("a human took over the session — the desk wins")
			}
			return s.LastText, nil
		}
		if time.Now().After(deadline) {
			return "", errors.New("no reply within the turn timeout")
		}
		if err := sleep(ctx, l.poll()); err != nil {
			return "", err
		}
	}
}

// sleep is a cancelable time.Sleep: a stopped drive stops between
// polls, not at the end of one.
func sleep(ctx context.Context, d time.Duration) error {
	select {
	case <-ctx.Done():
		return errors.New("stopped")
	case <-time.After(d):
		return nil
	}
}

// fold collapses whitespace so a prompt survives the round trip
// through a TUI's paste handling and a transcript's meta line — the
// comparison is about words, not formatting.
func fold(s string) string { return strings.Join(strings.Fields(s), " ") }

// hash identifies a reply for the changed-since-baseline check. FNV-1a:
// an identity, not a defense.
func hash(s string) string {
	var h uint64 = 14695981039346656037
	for i := range len(s) {
		h ^= uint64(s[i])
		h *= 1099511628211
	}
	return fmt.Sprintf("%08x", uint32(h^(h>>32)))
}

func findSession(sessions []transcript.Session, id string) *transcript.Session {
	for i := range sessions {
		if sessions[i].ID == id {
			return &sessions[i]
		}
	}
	return nil
}

// findPane names the pane a prompt types into: a Claude-looking
// foreground in the session's own directory — the same heuristic Fuse
// stands on, and both bridges deliver by.
func findPane(panes []transcript.PaneActivity, cwd string, names []string) *transcript.PaneActivity {
	for i := range panes {
		if panes[i].Cwd == cwd && transcript.ClaudeLike(panes[i], names) {
			return &panes[i]
		}
	}
	return nil
}

// freshestInCwd names the newest session working in a directory — the
// one a claude pane there is presumed to run.
func freshestInCwd(sessions []transcript.Session, cwd string) string {
	id := ""
	var newest time.Time
	for _, s := range sessions {
		if s.Cwd == cwd && (id == "" || s.Mtime.After(newest)) {
			id, newest = s.ID, s.Mtime
		}
	}
	return id
}
