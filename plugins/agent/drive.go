// The drive half of the agent: one goal in, a supervised conversation
// out. A digest row offers "drive to a goal…"; the goal becomes a
// prompt typed into the session's own pane, the transcript says when
// the turn ends, and the judge — the same OpenAI-compatible wire the
// digests ride — reads the reply against the goal and either stops or
// says the next thing.
//
// Neither the loop nor the judge's brief is written here any more.
// Both are vera's (github.com/incantery/vera/drive), and this file is
// what the agent plugin adds around them: rook's wire under the judge,
// rook's spend meter, the book of runs, and their panel rows. What
// rook contributes to the shared loop is the MECHANISM —
// plugins/internal/drive's TUI turner, which types — while vera
// contributes the supervision. A drive therefore means the same thing
// in a rook pane as it does in vera's engine, including when it stops
// and asks.
//
// The mechanics are deliberately the phone's: prompts reach the
// session as TYPED TEXT through session.send's gates, so a human at
// the keyboard always outranks the drive — a human typing blocks the
// delivery, and a human's own prompt mid-drive ends it ("the desk
// wins"). Nothing here runs headless; ADR 0002's TUI-only rule stands.
package main

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"sync"
	"time"

	"github.com/incantery/rook/plugins/internal/transcript"
	veradrive "github.com/incantery/vera/drive"
)

// driveJudge is veradrive.Judge on the summarizer's wire: goal plus
// the whole conversation in, DONE-CONTINUE-or-ESCALATE out. The brief
// and the transcript format are vera's exports — what rook adds is the
// wire it already has a key for and the spend meter that key feeds.
type driveJudge struct {
	z     *Summarizer
	spend func(cost float64)
}

func (j driveJudge) Judge(ctx context.Context, goal string, history []veradrive.Exchange) (veradrive.Verdict, error) {
	content, cost, err := j.z.complete([]chatMsg{
		{"system", veradrive.JudgeSysPrompt},
		{"user", veradrive.JudgePrompt(goal, history, 12000)},
	})
	j.spend(cost)
	if err != nil {
		return veradrive.Verdict{}, err
	}
	return veradrive.ParseVerdict(content)
}

// driveRun is one drive's row-worth of truth, live or finished.
type driveRun struct {
	id           string
	sessionID    string
	sessionTitle string
	goal         string
	status       string // the loop's live line, while running
	finished     bool
	done         bool   // finished && the judge called the goal met
	escalated    bool   // finished && the judge handed the wheel back
	ask          string // when escalated: the question for the owner
	reason       string
	lastReply    string
	turns        int
	cost         float64
	at           time.Time
	cancel       context.CancelFunc
}

// driveBook is the ring of runs, newest first — in memory only. A
// drive is a live conversation; one that dies with a relaunch is over,
// and pretending otherwise would be a row lying about a loop that no
// longer exists.
type driveBook struct {
	mu   sync.Mutex
	runs []*driveRun
	seq  int
}

func (b *driveBook) add(sessionID, sessionTitle, goal string, cancel context.CancelFunc, now time.Time) *driveRun {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.seq++
	r := &driveRun{
		id: fmt.Sprintf("drive:%d", b.seq), sessionID: sessionID,
		sessionTitle: sessionTitle, goal: goal,
		status: "starting", at: now, cancel: cancel,
	}
	b.runs = append([]*driveRun{r}, b.runs...)
	return r
}

func (b *driveBook) activeFor(sessionID string) bool {
	b.mu.Lock()
	defer b.mu.Unlock()
	for _, r := range b.runs {
		if r.sessionID == sessionID && !r.finished {
			return true
		}
	}
	return false
}

// update runs f on the run with this id under the lock; false when the
// row was dismissed, which a finishing loop treats as the dismissal
// winning.
func (b *driveBook) update(id string, f func(*driveRun)) bool {
	b.mu.Lock()
	defer b.mu.Unlock()
	for _, r := range b.runs {
		if r.id == id {
			f(r)
			return true
		}
	}
	return false
}

func (b *driveBook) setStatus(id, line string) {
	b.update(id, func(r *driveRun) { r.status = line; r.at = time.Now() })
}

func (b *driveBook) addCost(id string, cost float64) {
	b.update(id, func(r *driveRun) { r.cost += cost })
}

func (b *driveBook) finish(id string, res veradrive.Result, err error) {
	b.update(id, func(r *driveRun) {
		r.finished = true
		r.at = time.Now()
		r.turns = len(res.Turns)
		if n := len(res.Turns); n > 0 {
			r.lastReply = res.Turns[n-1].Reply
		}
		if err != nil {
			r.reason = err.Error()
			return
		}
		r.done = res.Done
		r.reason = res.Reason
		// An escalation is not a failure and must not read as one: the
		// judge stopped ON PURPOSE because the next move is the owner's.
		// The Ask is the whole point of stopping, so it becomes the row's
		// sentence — "escalated to the owner" tells nobody anything.
		if res.Escalated {
			r.escalated, r.ask = true, res.Ask
			if res.Ask != "" {
				r.reason = res.Ask
			}
		}
	})
}

// stop cancels a live run. The loop notices between polls and finishes
// with "stopped" on the record; the row stays until dismissed.
func (b *driveBook) stop(id string) bool {
	b.mu.Lock()
	defer b.mu.Unlock()
	for _, r := range b.runs {
		if r.id == id && !r.finished {
			r.cancel()
			return true
		}
	}
	return false
}

// dismiss removes a FINISHED run's row. A live run must be stopped
// first — a dismissed row over a still-typing loop would be machinery
// with no witness.
func (b *driveBook) dismiss(id string) bool {
	b.mu.Lock()
	defer b.mu.Unlock()
	for i, r := range b.runs {
		if r.id == id && r.finished {
			b.runs = append(b.runs[:i], b.runs[i+1:]...)
			return true
		}
	}
	return false
}

func (b *driveBook) has(id string) bool {
	b.mu.Lock()
	defer b.mu.Unlock()
	for _, r := range b.runs {
		if r.id == id {
			return true
		}
	}
	return false
}

// items renders the book for the panel: live drives first (they are
// the machinery running right now), then finished ones until someone
// dismisses them. The final reply rides as children on a finished
// drive — the deliverable, readable where the goal was given.
func (b *driveBook) items(now time.Time) []wireItem {
	b.mu.Lock()
	runs := make([]driveRun, 0, len(b.runs))
	for _, r := range b.runs {
		runs = append(runs, *r)
	}
	b.mu.Unlock()

	var out []wireItem
	for _, r := range runs {
		it := wireItem{
			ID:       r.id,
			Subtitle: transcript.Snip(r.sessionTitle, 40) + " · " + transcript.RelAge(now.Sub(r.at)),
		}
		switch {
		case !r.finished:
			it.Title = "driving — " + transcript.Snip(r.status, 200)
			it.State = "driving"
			it.Actions = []wireAction{{ID: "stop", Label: "stop driving"}}
		case r.done:
			it.Title = "drive done — " + transcript.Snip(r.reason, 200)
			it.State = "done"
			it.Actions = []wireAction{{ID: "dismiss", Label: "dismiss"}}
		case r.escalated:
			it.Title = "drive needs you — " + transcript.Snip(r.reason, 200)
			it.State = string(transcript.StateNeedsYou)
			it.Actions = []wireAction{{ID: "dismiss", Label: "dismiss"}}
		default:
			it.Title = "drive ended — " + transcript.Snip(r.reason, 200)
			it.State = "error"
			it.Actions = []wireAction{{ID: "dismiss", Label: "dismiss"}}
		}
		it.Children = append(it.Children, wireChild{ID: r.id + ":goal", Title: "⛿ goal: " + transcript.Snip(r.goal, 240)})
		if r.finished && r.lastReply != "" {
			it.Children = append(it.Children, wireChild{ID: r.id + ":rhead", Title: "↩ final reply:"})
			chunks := chunkText(r.lastReply, 240)
			const maxChunks = 12
			trimmed := false
			if len(chunks) > maxChunks {
				chunks, trimmed = chunks[:maxChunks], true
			}
			for i, chunk := range chunks {
				it.Children = append(it.Children, wireChild{ID: fmt.Sprintf("%s:r%d", r.id, i), Title: chunk})
			}
			if trimmed {
				it.Children = append(it.Children, wireChild{ID: r.id + ":rmore", Title: "… the rest is in the session"})
			}
		}
		if r.turns > 0 {
			it.Fields = append(it.Fields, wireField{"turns", "TEXT", fmt.Sprintf("%d", r.turns)})
		}
		if r.cost > 0 {
			it.Fields = append(it.Fields, wireField{"cost", "MONEY", fmt.Sprintf("$%.4f", r.cost)})
		}
		out = append(out, it)
	}
	return out
}

// driveHost is what main hands the wire so acts can start drives: the
// book, the judge's wire, and the makings of a driver. newDriver is a
// seam so tests drive without a rook.
type driveHost struct {
	book      driveBook
	sum       *Summarizer
	maxTurns  int
	newScan   func() func(now time.Time) []transcript.Session
	newDriver func(scan func(now time.Time) []transcript.Session, progress func(string)) veradrive.Turner
}

// start begins one drive against one session's live pane. The answer
// is only "driving…" — the loop runs beside serve and lands its result
// through the book, the same shape draft takes.
func (dv *driveHost) start(sessionID, sessionTitle, goal string) (string, error) {
	if dv == nil || dv.sum == nil {
		return "", errors.New("no OpenAI key, nothing to judge with")
	}
	if strings.TrimSpace(goal) == "" {
		return "", errors.New("say what the drive should achieve")
	}
	if dv.book.activeFor(sessionID) {
		return "", errors.New("already driving that session — stop that drive first")
	}
	ctx, cancel := context.WithCancel(context.Background())
	r := dv.book.add(sessionID, sessionTitle, goal, cancel, time.Now())
	scan := dv.newScan()
	status := func(line string) { dv.book.setStatus(r.id, line) }
	// The loop reports the round it is on; the turner reports what it is
	// waiting for inside that round. Both write the one status line,
	// because the row has one place to say what is happening and the
	// loop's "asking claude" is a lie for the eleven minutes the pane
	// spends thinking.
	loop := &veradrive.Loop{
		Turner:   dv.newDriver(scan, status),
		Judge:    driveJudge{z: dv.sum, spend: func(c float64) { recordSpend(c); dv.book.addCost(r.id, c) }},
		MaxTurns: dv.maxTurns,
		Progress: status,
	}
	go func() {
		defer cancel()
		res, err := loop.Run(ctx, sessionID, goal)
		dv.book.finish(r.id, res, err)
	}()
	return "driving…", nil
}
