// Package drive delivers a supervised conversation to a live Claude
// Code session by TYPING into its pane: the prompt reaches the session
// as text through session.send's gates, so a human at the keyboard
// always outranks the machine (ADR 0002's TUI-only rule, rook-host).
//
// The LOOP is not here. Goal in, judged conversation out — the turn
// budget, the judge's vocabulary, the circling guard, the spend cap —
// lives once, in github.com/incantery/vera/drive, and this package is
// one implementation of that loop's Turner: the mechanism, not the
// supervision. rook and vera's engine now run the same loop over two
// mechanisms (typed keystrokes here, `claude -p --resume` there), which
// is what makes a drive mean one thing in both places.
//
// The seam is narrow on purpose. vera's Turner is "prompt in, reply
// out"; typing into a live TUI yields no return value, so RunTurn
// earns the reply the only way this mechanism can — wait for the
// session to go quiet, type, then watch the transcript until that
// turn ends. The transcript is the only witness either mechanism
// believes.
package drive

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/incantery/rook/plugins/internal/transcript"
	veradrive "github.com/incantery/vera/drive"
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

// TUI is the typed-keystrokes Turner: one turn is the prompt reaching
// the session's own pane as text, under the same gates and the same
// one-pane-one-session heuristic `say` delivers by, and then the turn
// it starts running to its end.
type TUI struct {
	C     Caller
	Scan  func(now time.Time) []transcript.Session
	Panes func() []transcript.PaneActivity
	Names []string // foreground names that count as Claude Code

	Poll        time.Duration // how often the transcript is re-read (default 5s)
	TurnTimeout time.Duration // how long one turn may run (default 15m)

	// Progress reports what this mechanism is waiting on, between the
	// loop's own "asking claude" and "judging the reply". Typing into
	// somebody's terminal spends most of its time waiting, and a row
	// that says only "asking claude" for eleven minutes reads as hung.
	Progress func(line string)
}

func (t *TUI) poll() time.Duration {
	if t.Poll > 0 {
		return t.Poll
	}
	return 5 * time.Second
}

func (t *TUI) turnTimeout() time.Duration {
	if t.TurnTimeout > 0 {
		return t.TurnTimeout
	}
	return 15 * time.Minute
}

func (t *TUI) progress(line string) {
	if t.Progress != nil {
		t.Progress(line)
	}
}

// RunTurn is veradrive.Turner: one prompt typed into one session, and
// the reply it earns. The session id never changes — this mechanism
// continues the conversation in place rather than forking it, which is
// the whole difference between driving a terminal somebody is watching
// and driving a headless fork.
//
// Turn.CostUSD stays zero: a typed prompt is billed to whatever
// account the terminal is logged into, and rook is not told the
// number. Reporting a cost it cannot meter would be a lie the loop's
// spend cap would then act on.
func (t *TUI) RunTurn(ctx context.Context, sessionID, prompt string) (veradrive.Turn, error) {
	// The session must be quiet before anything is typed: text
	// delivered mid-turn queues behind work this loop did not ask for,
	// and the turn that then ends would be misread as the reply.
	// Waiting is honest; interrupting is not ours to do.
	t.progress("waiting for the session to go quiet")
	base, err := t.awaitQuiet(ctx, sessionID)
	if err != nil {
		return veradrive.Turn{}, err
	}
	t.progress("delivering the prompt")
	if err := t.Deliver(ctx, sessionID, prompt); err != nil {
		return veradrive.Turn{}, errors.New("delivery refused: " + err.Error())
	}
	t.progress("waiting on the reply")
	reply, err := t.awaitReply(ctx, sessionID, prompt, base)
	if err != nil {
		return veradrive.Turn{}, err
	}
	return veradrive.Turn{Reply: reply, SessionID: sessionID}, nil
}

// Deliver types one prompt into the session's pane. It does not wait
// for the reply — RunTurn does that, and a caller who only wants to
// say one thing (the cloud bridge, the link executor) wants exactly
// this half.
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

// awaitQuiet waits until the session is between turns and returns the
// baseline the next reply must differ from. Blocked counts as not
// quiet: a session sitting on an approval box needs a human's yes, not
// another prompt on top of it.
func (t *TUI) awaitQuiet(ctx context.Context, sessionID string) (baseline string, err error) {
	deadline := time.Now().Add(t.turnTimeout())
	for {
		s := findSession(t.Scan(time.Now()), sessionID)
		if s == nil {
			return "", errors.New("that session is gone")
		}
		if s.State != transcript.StateWorking && s.State != transcript.StateBlocked {
			return hash(s.LastText), nil
		}
		if time.Now().After(deadline) {
			// The clock ran out, not the goal: the session is busy with
			// somebody else's work and may well be free later. The mark
			// is what tells a caller this one is worth retrying.
			return "", veradrive.MarkTransient(fmt.Errorf("the session stayed %s past the turn timeout", s.State))
		}
		if err := sleep(ctx, t.poll()); err != nil {
			return "", err
		}
	}
}

// awaitReply watches the transcript until the delivered prompt's turn
// ends — the session needs a human again and the assistant's last word
// has changed — and returns that word. A turn ending on someone ELSE's
// prompt means a human took the keyboard mid-drive; the desk wins and
// the drive stops, the same both-settle rule every rail follows.
func (t *TUI) awaitReply(ctx context.Context, sessionID, prompt, baseline string) (string, error) {
	deadline := time.Now().Add(t.turnTimeout())
	for {
		s := findSession(t.Scan(time.Now()), sessionID)
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
			return "", veradrive.MarkTransient(errors.New("no reply within the turn timeout"))
		}
		if err := sleep(ctx, t.poll()); err != nil {
			return "", err
		}
	}
}

// sleep is a cancelable time.Sleep: a stopped drive stops between
// polls, not at the end of one. A stop is a decision, never a
// transient failure — retrying what a human halted is the one thing
// this loop must not do.
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
