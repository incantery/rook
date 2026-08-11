// The screen-watcher: the membrane's answer to "what is happening RIGHT
// NOW?" A digest tells the story of a finished turn; while the agent is
// mid-turn the only honest witness is the terminal itself. Every tick
// this loop reads the screen of each WORKING session's pane (the same
// pane.read the phone's terminal view uses), hands the visible text
// plus the last digest to the summarizer, and publishes one
// present-tense line per session to the ephemeral now-file — which
// statusfold folds into the snapshot both rails carry.
//
// Cost discipline, because this loop runs unattended: a pane whose
// outBytes has not moved is skipped before any read; a screen whose
// text has not changed is skipped before any model call; an idle fleet
// costs zero calls. The bill per line rides in the file.
package main

import (
	"encoding/json"
	"hash/fnv"
	"strings"
	"time"

	"github.com/incantery/rook/plugins/internal/nowfile"
	"github.com/incantery/rook/plugins/internal/transcript"
)

// nowLoop runs beside watch() with its own scanner (Scanner keeps
// per-file state; two goroutines must not share one).
func nowLoop(c *conn, sc *transcript.Scanner, st *store, sum *Summarizer, every time.Duration, names []string, path string) {
	type mark struct {
		outBytes uint64
		screen   uint64
	}
	seen := map[string]mark{}
	lines := map[string]nowfile.Now{}
	for {
		time.Sleep(every)
		now := time.Now()

		working := map[string]transcript.Session{}
		for _, s := range sc.Scan(now) {
			if s.State == transcript.StateWorking {
				working[s.ID] = s
			}
		}

		// A session that stopped working takes its line with it — the
		// digest owns the story from here.
		changed := false
		for id := range lines {
			if _, ok := working[id]; !ok {
				delete(lines, id)
				changed = true
			}
		}
		if len(working) == 0 {
			if changed {
				_ = nowfile.Write(path, lines)
			}
			continue
		}

		panes := nowPanes(c)
		for id, s := range working {
			p := findWorkingPane(panes, s.Cwd, names)
			if p == nil {
				continue
			}
			m := seen[id]
			if p.OutBytes == m.outBytes {
				continue // nothing new on screen; the old line stands
			}
			screen := nowScreen(c, p.ID)
			if screen == "" {
				continue
			}
			h := hashScreen(screen)
			if h == m.screen {
				seen[id] = mark{p.OutBytes, h}
				continue
			}
			line, cost, err := sum.NowLine(screen, st.headlineFor(id))
			if err != nil {
				continue // transient; the next tick retries
			}
			seen[id] = mark{p.OutBytes, h}
			lines[id] = nowfile.Now{SessionID: id, Line: line, At: now, CostUSD: cost}
			changed = true
		}
		if changed {
			_ = nowfile.Write(path, lines)
		}
	}
}

// nowPanes asks rook who is drawing — the same panes.activity answer
// every watcher reads.
func nowPanes(c *conn) []transcript.PaneActivity {
	raw, err := c.call("panes.activity", struct{}{}, 1500*time.Millisecond)
	if err != nil {
		return nil
	}
	var rep struct {
		Panes []transcript.PaneActivity `json:"panes"`
	}
	if json.Unmarshal(raw, &rep) != nil {
		return nil
	}
	return rep.Panes
}

// findWorkingPane mirrors the link plugin's resolution: same cwd, a
// Claude-like foreground. Panes are resolved fresh per tick — they are
// rook's private geometry and move under us by design.
func findWorkingPane(panes []transcript.PaneActivity, cwd string, names []string) *transcript.PaneActivity {
	for i := range panes {
		if panes[i].Cwd == cwd && transcript.ClaudeLike(panes[i], names) {
			return &panes[i]
		}
	}
	return nil
}

// nowScreen reads one pane's viewport and flattens it to plain text —
// styles are the terminal view's business, the summarizer reads words.
func nowScreen(c *conn, pane int) string {
	raw, err := c.call("pane.read", map[string]int{"pane": pane}, 1500*time.Millisecond)
	if err != nil {
		return ""
	}
	var rep struct {
		Lines []struct {
			T string `json:"t"`
		} `json:"lines"`
	}
	if json.Unmarshal(raw, &rep) != nil {
		return ""
	}
	out := make([]string, 0, len(rep.Lines))
	for _, l := range rep.Lines {
		out = append(out, l.T)
	}
	return strings.TrimRight(strings.Join(out, "\n"), "\n ")
}

func hashScreen(s string) uint64 {
	h := fnv.New64a()
	h.Write([]byte(s))
	return h.Sum64()
}

// headlineFor is the newest digest headline for a session — the
// context that keeps a now-line anchored ("still on the migration",
// not a cold read of forty ambiguous lines).
func (st *store) headlineFor(sessionID string) string {
	st.mu.Lock()
	defer st.mu.Unlock()
	for _, d := range st.ds { // newest first; add() prepends
		if d.SessionID == sessionID && d.Headline != "" {
			return d.Headline
		}
	}
	return ""
}
