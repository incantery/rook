package host

import (
	"context"
	"log"
	"strings"
	"time"

	"github.com/incantery/rook/internal/transcript"
)

// transcriptwatch is the record-fed half of the sensor layer: the same
// AgentStatus state machine as apply(), driven by Claude Code's transcripts
// read directly instead of by agentmon's derived events (docs/agent.md,
// amendment 2026-07-15).
//
// AgentStatus is the seam. Both paths fill the same map with the same
// fields, so the two can run side by side and be diffed before either is
// deleted. Where they differ, they differ upward: an ask built from an
// untruncated tool input is the whole point, not a regression.
//
// Deliberately duplicated rather than refactored into a shared helper.
// apply() is the reference being diffed against, and a reference that moves
// while you compare against it is not a reference. This file's twin goes
// away at cutover, and the duplication with it.

const (
	// transcriptIdleAfter matches the --idle-after rook passes agentmon.
	transcriptIdleAfter = 20 * time.Second
	// transcriptEndedAfter matches agentmon's EndedAfter default (30m).
	// Rook never passes --ended-after, so this is the threshold it has been
	// getting all along: a session goes off the dashboard 30 minutes after
	// its last record, not at the hour snapshot() would otherwise allow.
	transcriptEndedAfter = 30 * time.Minute
	// transcriptSweep is how often the two synthetic states are recomputed.
	transcriptSweep = 5 * time.Second
)

// runTranscript follows the transcript tree and reduces it, forever. The
// watcher failing is never fatal: it is retried, because rook without the
// attention layer still works, and rook that exits does not.
func (a *agentWatch) runTranscript(ctx context.Context) {
	lines := make(chan transcript.Line, 256)
	go func() {
		// MaxAge tracks EndedAfter: a session rook still shows is a session
		// still worth tailing, and one it has forgotten costs nothing to
		// re-read from zero if it wakes.
		w := &transcript.Watcher{MaxAge: transcriptEndedAfter}
		for {
			err := w.Run(ctx, lines)
			if ctx.Err() != nil {
				return
			}
			log.Printf("transcriptwatch: %v; retrying in 15s", err)
			select {
			case <-ctx.Done():
				return
			case <-time.After(15 * time.Second):
			}
		}
	}()

	ticker := time.NewTicker(transcriptSweep)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case ln := <-lines:
			a.applyRecord(ln)
		case <-ticker.C:
			a.sweepTranscript(time.Now())
		}
	}
}

// applyRecord reduces one transcript record into its session's state.
//
// State is reduced from every record, including backlog — that is how a
// session discovered mid-flight gets a correct state. Side effects fire
// only for records we watched land: replaying a file from zero would
// otherwise invalidate asks and signal turn completion for turns that
// ended hours ago.
func (a *agentWatch) applyRecord(ln transcript.Line) {
	rec := ln.Record
	if rec == nil || rec.IsSidechain {
		return // subagent traffic never changes the parent session's state
	}

	a.mu.Lock()

	st := a.states[ln.SessionID]

	// Claude Code writes permission-mode, mode, ai-title and last-prompt
	// without a timestamp. The parser refuses to invent one, so the carry
	// lives here.
	now := rec.Timestamp
	if now.IsZero() && st != nil {
		now = st.LastEvent
	}
	if now.IsZero() {
		now = time.Now()
	}

	if st == nil {
		st = &AgentStatus{
			SessionID: ln.SessionID,
			State:     "working",
			Since:     now,
			seenMsg:   map[string]bool{},
		}
		a.states[ln.SessionID] = st
	}
	// Reading from zero means the first record — the one carrying cwd — is
	// always seen, so CWD is populated where agentmon's fast-forward left
	// only Project to correlate on.
	if rec.CWD != "" {
		st.CWD, st.Project = rec.CWD, rec.CWD
	}
	st.LastEvent = now

	setState := func(s string) {
		if st.State != s {
			st.State, st.Since = s, now
		}
	}
	record := func(role, text string) {
		if text == "" {
			return
		}
		if r := []rune(text); len(r) > histMaxText {
			text = string(r[:histMaxText]) + "…"
		}
		st.history = append(st.history, histMsg{Role: role, Text: text, TS: now})
		if len(st.history) > histCap {
			st.history = st.history[len(st.history)-histCap:]
		}
	}

	// deferred so hooks run after the lock drops — they call back into host
	// state that must never nest inside agentwatch's mutex
	var userReplied, turnDone, turnFinished bool
	var userReply string

	switch rec.Type {
	case transcript.TypeAITitle:
		if rec.AITitle != "" {
			st.Title = rec.AITitle
		}

	case transcript.TypeUser:
		// A user record is either something typed or the results of tool
		// calls. Only the first is a reply; tool results are the session
		// talking to itself.
		if text := rec.Message.Text(); text != "" {
			setState("working")
			st.Ask, st.askDraft, st.Tool = "", "", ""
			st.Interactive = false
			record("user", text)
			userReplied, userReply = true, text
		}
		for range rec.Message.ToolResults() {
			// for a picker, the result IS the user's answer — the ask is over
			setState("working")
			if st.Interactive {
				st.Ask, st.Interactive = "", false
			}
		}

	case transcript.TypeAssistant:
		m := rec.Message
		if m == nil {
			break
		}
		setState("working")
		if m.Model != "" {
			st.Model = m.Model
		}
		// One API response is written as several lines, each repeating the
		// same id and usage object. Bill the first and only the first —
		// naive summing roughly doubles the cost. The usage outbox rides
		// the same dedupe: one queued event per response, cost zero when
		// the model isn't in the price table (the tokens still travel).
		if m.ID == "" || !st.seenMsg[m.ID] {
			if m.ID != "" {
				st.seenMsg[m.ID] = true
			}
			usd, priced := transcript.Cost(m.Model, m.Usage)
			if priced {
				st.CostUSD += usd
			}
		}
		text := m.Text()
		if text != "" {
			st.askDraft = tail(text, 200)
		}
		record("assistant", text)
		for _, b := range m.ToolCalls() {
			st.Tool = b.Name
			record("tool", strings.TrimSpace(b.Name+" "+string(b.Input)))
			// The one mid-turn prompt a transcript can identify on its own:
			// claude's question picker. No turn_completed will come while
			// it is up, so it becomes an ask here — flagged interactive,
			// because the window wants a selection, not typed text.
			//
			// Input arrives whole here. agentmon capped it at 2KB, which is
			// smaller than a real picker, so pickerAsk was routinely
			// degrading to its generic fallback line.
			if b.Name == "AskUserQuestion" {
				setState("needs_input")
				st.Ask, st.Interactive = pickerAsk(string(b.Input)), true
				st.AskSeq++
				turnDone = true
			}
		}

	case transcript.TypeSystem:
		if rec.Subtype != transcript.SubtypeTurnDuration {
			break
		}
		setState("needs_input")
		st.Ask, st.Tool = st.askDraft, ""
		st.Interactive = false
		st.AskSeq++
		turnDone = true
		turnFinished = true
	}

	askSeq := st.AskSeq
	a.mu.Unlock()

	if !ln.Live {
		return // backlog: the state is now right, but nothing just happened
	}
	if userReplied && a.onUserReply != nil {
		a.onUserReply(ln.SessionID, userReply)
	}
	if turnDone && a.onTurnCompleted != nil {
		a.onTurnCompleted(ln.SessionID, askSeq)
	}
	if turnFinished && a.onTurnFinished != nil {
		a.onTurnFinished(ln.SessionID)
	}
}

// sweepTranscript synthesises the two states no record can carry, because
// both are defined by the absence of records: a session gone silent
// mid-turn, and one silent long enough to be over. agentmon's watcher emits
// these as session_idle and session_ended; here they are just a clock.
func (a *agentWatch) sweepTranscript(now time.Time) {
	a.mu.Lock()
	defer a.mu.Unlock()
	for id, st := range a.states {
		idle := now.Sub(st.LastEvent)
		switch {
		case idle >= transcriptEndedAfter:
			delete(a.states, id)
		case st.State == "working" && idle >= transcriptIdleAfter:
			// A long tool run, or a permission prompt. The transcript
			// cannot tell them apart, so report the tool and the silence
			// rather than guessing.
			st.State, st.Since = "quiet", now
		}
	}
}
