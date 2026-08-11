// The executor — the seam rook-host's link server calls into when a
// paired device answers an ask or issues a command. This is the cloud
// bridge's delivery logic, adapted from an outbox it polls to an RPC
// it answers: the same journal keys, the same gates, the same
// at-most-once promise at the keyboard — but where the cloud rail
// retries on its next poll, this rail reports honestly NOW and lets
// the phone decide to try again. Every path returns a truthful
// Outcome; nothing is dropped silently.
package main

import (
	"context"
	"fmt"
	"path/filepath"
	"time"

	"github.com/incantery/rook-host/link"
	"github.com/incantery/rook-host/projection"

	"github.com/incantery/rook/plugins/internal/statusfold"
	"github.com/incantery/rook/plugins/internal/transcript"
)

func delivered() link.Outcome { return link.Outcome{Disposition: link.Delivered} }

func duplicate(note string) link.Outcome {
	return link.Outcome{Disposition: link.Duplicate, Note: note}
}

func dropped(note string) link.Outcome {
	return link.Outcome{Disposition: link.Dropped, Note: note}
}

// submitSettle is how long the paste is left to settle before the CR
// that submits it. An agent TUI that collapses a large paste into a
// placeholder draft eats a CR glued to the same burst — so type,
// let the TUI's event loop finish ingesting, then submit. Short
// enough to feel instant to the person watching their phone.
const submitSettle = 150 * time.Millisecond

// typeAndSubmit types text into a pane and submits it as two steps:
// the bracketed paste held open (no CR), a settle, then the CR alone.
// Both steps pass session.send's gates; the second is a bare submit.
func (h *lk) typeAndSubmit(pane int, text string) error {
	if _, err := h.c.call("session.send",
		map[string]any{"pane": pane, "text": text, "no_submit": true}, 5*time.Second); err != nil {
		return err
	}
	time.Sleep(submitSettle)
	_, err := h.c.call("session.send",
		map[string]any{"pane": pane, "submit_only": true}, 5*time.Second)
	return err
}

// findPane names the pane an answer types into: a Claude-looking
// foreground in the session's own directory — the same heuristic Fuse
// stands on, and the cloud bridge delivers by.
func findPane(panes []transcript.PaneActivity, cwd string, names []string) *transcript.PaneActivity {
	for i := range panes {
		if panes[i].Cwd == cwd && transcript.ClaudeLike(panes[i], names) {
			return &panes[i]
		}
	}
	return nil
}

// Answer delivers a device's reply to a pending ask. The verify step
// is the both-settle rule: the ask must STILL be the session's current
// one, or the desk won and the phone's answer is stale.
func (h *lk) Answer(ctx context.Context, a projection.Answer) link.Outcome {
	if h.journal.Delivered(a.AskID) {
		// Typed already — by this rail, the cloud rail, or a previous
		// life of either. Success, loudly; never type twice.
		return duplicate("already typed — the first delivery won")
	}
	sessions, panes := h.snapshot()
	var target *transcript.Session
	for i := range sessions {
		if statusfold.AskID(sessions[i]) == a.AskID {
			target = &sessions[i]
			break
		}
	}
	if target == nil {
		return dropped("stale — the ask moved on or was answered at the desk")
	}
	pane := findPane(panes, target.Cwd, h.names)
	if pane == nil {
		n := h.journal.Failed(a.AskID)
		return dropped(fmt.Sprintf("no agent pane for %s (try %d) — is the session on a screen?",
			transcript.Snip(target.Title, 40), n))
	}
	if err := h.typeAndSubmit(pane.ID, a.Text); err != nil {
		h.journal.Failed(a.AskID)
		return dropped("the keyboard's gates refused: " + err.Error())
	}
	// Typed. Mark BEFORE returning Delivered: a reply lost on the wire
	// makes the device retry, and the retry must find the journal, not
	// the keyboard.
	h.journal.MarkDelivered(a.AskID)
	h.note("answered " + transcript.Snip(target.Title, 40) + " from a paired device")
	return delivered()
}

// Execute runs one validated, allowlisted command. Keys and semantics
// are the cloud bridge's exactly — "cmd:"+ID in the shared journal —
// so a command that arrives over both rails is one command.
func (h *lk) Execute(ctx context.Context, c projection.Command) link.Outcome {
	key := "cmd:" + c.ID
	if h.journal.Delivered(key) {
		return duplicate("already done — the first delivery won")
	}
	sessions, panes := h.snapshot()
	switch c.Kind {
	case "compact":
		return h.execCompact(c, key, sessions, panes)
	case "resume":
		return h.execResume(c, key, sessions)
	case "spawn":
		return h.execSpawn(ctx, c, key, sessions, panes)
	case "say":
		return h.execSay(c, key, sessions, panes)
	}
	// The server validated Kind against the allowlist, so this is a
	// newer vocabulary than this binary: honestly refused, never
	// guessed at.
	return dropped("this rook does not know the command kind " + c.Kind)
}

func (h *lk) execCompact(c projection.Command, key string, sessions []transcript.Session, panes []transcript.PaneActivity) link.Outcome {
	target := findSession(sessions, c.SessionID)
	if target == nil {
		return dropped("that session is gone")
	}
	if target.State == transcript.StateWorking {
		// Held while working, but this rail cannot hold — it answers an
		// RPC. The shared budget still bounds a session that never goes
		// quiet, and the note tells the device what to do.
		n := h.journal.Failed(key)
		return dropped(fmt.Sprintf("%s is mid-turn (try %d) — try again when it goes quiet",
			transcript.Snip(target.Title, 40), n))
	}
	pane := findPane(panes, target.Cwd, h.names)
	if pane == nil {
		n := h.journal.Failed(key)
		return dropped(fmt.Sprintf("no agent pane for %s (try %d)", transcript.Snip(target.Title, 40), n))
	}
	if _, err := h.c.call("session.send",
		map[string]any{"pane": pane.ID, "text": "/compact"}, 5*time.Second); err != nil {
		h.journal.Failed(key)
		return dropped("the keyboard's gates refused: " + err.Error())
	}
	h.journal.MarkDelivered(key)
	h.note("compacted " + transcript.Snip(target.Title, 40) + " from a paired device")
	return delivered()
}

// execSay types a message into an ATTACHED session's pane — the verb a
// quiet-but-open session offers instead of resume. The attachment rule
// is the resume refusal inverted: the freshest transcript in a cwd
// with a Claude-like pane IS that pane's session, anything else is
// refused toward resume. The text reaches the pane as TYPED TEXT via
// session.send — settle, then submit — the same path answers ride.
func (h *lk) execSay(c projection.Command, key string, sessions []transcript.Session, panes []transcript.PaneActivity) link.Outcome {
	target := findSession(sessions, c.SessionID)
	if target == nil {
		return dropped("that session is gone")
	}
	if target.ID != freshestInCwd(sessions, target.Cwd) {
		return dropped("that session is history in its directory — resume it instead")
	}
	pane := findPane(panes, target.Cwd, h.names)
	if pane == nil {
		return dropped(transcript.Snip(target.Title, 40) + " is not on a pane — resume it instead")
	}
	if _, err := h.c.call("session.send",
		map[string]any{"pane": pane.ID, "text": c.Prompt}, 8*time.Second); err != nil {
		h.journal.Failed(key)
		return dropped("the keyboard's gates refused: " + err.Error())
	}
	h.journal.MarkDelivered(key)
	h.note("message sent to " + transcript.Snip(target.Title, 40) + " from a paired device")
	return delivered()
}

// execResume reopens a quiet session: a new pane running
// `claude --resume <id>` in the session's own directory. The command
// string is built from LOCAL data only — the id comes from this
// machine's transcript filename, never from the wire, and is charset-
// checked besides, because session.spawn hands its command to a shell.
func (h *lk) execResume(c projection.Command, key string, sessions []transcript.Session) link.Outcome {
	target := findSession(sessions, c.SessionID)
	if target == nil {
		return dropped("that session is gone")
	}
	if !shellSafeID(target.ID) {
		return dropped("refused — session id is not shell-safe")
	}
	// Already on a screen? A claude pane in this directory running the
	// directory's freshest session IS this session (the same heuristic
	// Fuse stands on); resuming it twice makes two instances fight over
	// one transcript.
	if target.ID == freshestInCwd(sessions, target.Cwd) {
		_, panes := h.snapshot()
		if findPane(panes, target.Cwd, h.names) != nil {
			return dropped("skipped — " + transcript.Snip(target.Title, 40) + " is already open here")
		}
	}
	if _, err := h.c.call("session.spawn",
		map[string]any{"command": "claude --resume " + target.ID, "cwd": target.Cwd}, 5*time.Second); err != nil {
		h.journal.Failed(key)
		return dropped("spawn refused: " + err.Error())
	}
	h.journal.MarkDelivered(key)
	h.note("resumed " + transcript.Snip(target.Title, 40) + " from a paired device")
	return delivered()
}

// execSpawn opens a fresh claude session in a named workspace. The
// workspace name maps to a directory through this machine's OWN
// sessions (the same vocabulary the snapshot spoke — the device can
// only name what the machine showed it), the spawned command is the
// literal string "claude", and the prompt goes in afterwards as TYPED
// TEXT through session.send's gates — wire words never touch a shell.
func (h *lk) execSpawn(ctx context.Context, c projection.Command, key string, sessions []transcript.Session, panes []transcript.PaneActivity) link.Outcome {
	cwd := ""
	var newest time.Time
	for _, s := range sessions {
		if filepath.Base(s.Cwd) == c.Workspace && (cwd == "" || s.Mtime.After(newest)) {
			cwd, newest = s.Cwd, s.Mtime
		}
	}
	if cwd == "" {
		return dropped("no workspace called " + transcript.Snip(c.Workspace, 40) + " in view")
	}
	// Which panes exist NOW: the new session is the claude pane that
	// appears in this directory afterwards and is not one of these.
	before := map[int]bool{}
	for _, p := range panes {
		before[p.ID] = true
	}
	if _, err := h.c.call("session.spawn",
		map[string]any{"command": "claude", "cwd": cwd}, 5*time.Second); err != nil {
		h.journal.Failed(key)
		return dropped("spawn refused: " + err.Error())
	}
	// Spawned exactly once — marked BEFORE the prompt hop, because a
	// redelivered spawn must never open a second pane. A prompt that
	// then fails to land costs a note, not a duplicate.
	h.journal.MarkDelivered(key)
	if c.Prompt == "" {
		h.note("started a session in " + c.Workspace + " from a paired device")
		return delivered()
	}
	for i := 0; i < h.spawnTries; i++ {
		select {
		case <-ctx.Done():
			// The RPC deadline beat the pane. The session is real; only
			// the prompt is owed, and the note says where.
			return link.Outcome{Disposition: link.Delivered,
				Note: "session started — the prompt did not land in time, type it there"}
		case <-time.After(h.spawnWait):
		}
		for _, p := range fetchActivity(h.c) {
			if before[p.ID] || p.Cwd != cwd || !transcript.ClaudeLike(p, h.names) {
				continue
			}
			if err := h.typeAndSubmit(p.ID, c.Prompt); err == nil {
				h.note("started a session in " + c.Workspace + " and handed it the prompt")
				return delivered()
			}
			break // found the pane but it is not ready — wait and retry
		}
	}
	h.note("started a session in " + c.Workspace + " — the prompt did not land, type it there")
	return link.Outcome{Disposition: link.Delivered,
		Note: "session started — the prompt did not land, type it there"}
}

func findSession(sessions []transcript.Session, id string) *transcript.Session {
	for i := range sessions {
		if sessions[i].ID == id {
			return &sessions[i]
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

// shellSafeID: session ids are transcript filenames (UUIDs in
// practice), but session.spawn's command reaches a shell, so anything
// beyond [A-Za-z0-9._-] is refused outright.
func shellSafeID(id string) bool {
	if id == "" {
		return false
	}
	for i := 0; i < len(id); i++ {
		c := id[i]
		switch {
		case c >= 'a' && c <= 'z', c >= 'A' && c <= 'Z', c >= '0' && c <= '9', c == '.', c == '_', c == '-':
		default:
			return false
		}
	}
	return true
}
