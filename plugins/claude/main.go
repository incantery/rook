// rook-plugin-claude — the Claude Code session watcher, rook's first
// first-party plugin.
//
// It speaks the rook plugin protocol (man 7 rook-plugin) over stdio:
// items.list answers with every recent Claude Code session on the machine
// and what each is doing; a background watcher raises attention.raise the
// moment a session finishes a long turn or looks stuck on an approval —
// the "a session is waiting on you" banner from a pane you forgot is the
// whole point. Declare it eager: a watcher that only watches while its
// panel is open is not a watcher.
//
// Nothing is asked of Claude Code itself and nothing is stored; the
// transcripts it already writes are the entire source of truth.
package main

import (
	"bufio"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

const version = "0.1.0"

// Fusion knobs, set from flags. See fuse() for what they mean.
var (
	fuseNames    []string
	fuseBusyRate float64
	fusePresent  time.Duration
)

func main() {
	dir := flag.String("dir", "", "projects directory (default ~/.claude/projects)")
	poll := flag.Duration("poll", 2*time.Second, "watch interval")
	minTurn := flag.Duration("min-turn", 30*time.Second, "shortest finished turn worth a banner")
	window := flag.Duration("window", 48*time.Hour, "how far back sessions are listed")
	busyRate := flag.Float64("busy-rate", 200, "pane output above this (bytes/sec) proves the session is working")
	present := flag.Duration("present", 45*time.Second, "keyboard input younger than this means the human is watching")
	names := flag.String("claude-names", "claude,node", "foreground program names that count as Claude Code")
	flag.Parse()

	if *dir == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			fmt.Fprintln(os.Stderr, "no home directory and no --dir")
			os.Exit(1)
		}
		*dir = filepath.Join(home, ".claude", "projects")
	}
	fuseNames = strings.Split(*names, ",")
	fuseBusyRate = *busyRate
	fusePresent = *present
	sc := &Scanner{
		Dir:    *dir,
		Window: *window,
		Idle:   10 * time.Minute,
		Quiet:  60 * time.Second,
		Max:    20,
	}

	c := &conn{out: os.Stdout}
	cache := &activityCache{}
	go watch(c, sc, cache, *poll, *minTurn)
	serve(c, sc, cache)
}

// activityCache is the freshest `panes.activity` answer, fetched by the
// watch goroutine each tick. The serve loop reads it rather than asking
// rook itself, because serve is also the goroutine that would deliver
// the reply — asking from there would be waiting on itself.
type activityCache struct {
	mu    sync.Mutex
	panes []PaneActivity
}

func (a *activityCache) set(p []PaneActivity) {
	a.mu.Lock()
	a.panes = p
	a.mu.Unlock()
}

func (a *activityCache) get() []PaneActivity {
	a.mu.Lock()
	defer a.mu.Unlock()
	return a.panes
}

// paneSample remembers one tick's byte counter so the next tick can
// turn two counters into a rate.
type paneSample struct {
	bytes uint64
	at    time.Time
}

// computeRates fills each pane's RateBps from the previous tick's
// sample. The first sighting of a pane has no previous sample and gets
// rate 0 — one tick of patience beats one tick of guessing.
func computeRates(prev map[int]paneSample, panes []PaneActivity, now time.Time) {
	for i := range panes {
		p := &panes[i]
		if s, ok := prev[p.ID]; ok {
			if dt := now.Sub(s.at).Seconds(); dt > 0 && p.OutBytes >= s.bytes {
				p.RateBps = float64(p.OutBytes-s.bytes) / dt
			}
		}
		prev[p.ID] = paneSample{p.OutBytes, now}
	}
}

// fetchActivity asks rook who is redrawing and who is typing. Degrades
// to nil on refusal (the grant is the human's choice) or timeout —
// fusion simply switches off and the transcript's word stands alone.
func fetchActivity(c *conn) []PaneActivity {
	raw, err := c.call("panes.activity", struct{}{}, 1500*time.Millisecond)
	if err != nil {
		return nil
	}
	var rep struct {
		Panes []PaneActivity `json:"panes"`
	}
	if json.Unmarshal(raw, &rep) != nil {
		return nil
	}
	return rep.Panes
}

// conn is the write half of the protocol: one goroutine answers rook,
// another raises attentions, and a torn frame would kill both. It also
// tracks the requests THIS side has in flight, so `call` can wait for
// rook's answer while `serve` keeps pumping.
type conn struct {
	mu      sync.Mutex
	out     *os.File
	nextID  uint64
	pending map[uint64]chan callResult
}

type callResult struct {
	ok  bool
	err string
	raw json.RawMessage
}

func (c *conn) send(v any) {
	b, err := json.Marshal(v)
	if err != nil {
		return
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	c.out.Write(append(b, '\n'))
}

type reply struct {
	V      int    `json:"v"`
	ID     uint64 `json:"id"`
	OK     bool   `json:"ok"`
	Result any    `json:"result,omitempty"`
	Error  string `json:"error,omitempty"`
}

type request struct {
	V      int    `json:"v"`
	ID     uint64 `json:"id"`
	Op     string `json:"op"`
	Params any    `json:"params"`
}

// request asks rook for something and does not wait (attention.raise,
// session.spawn — effects whose answer changes nothing here).
func (c *conn) request(op string, params any) {
	c.mu.Lock()
	c.nextID++
	id := c.nextID
	c.mu.Unlock()
	c.send(request{1, id, op, params})
}

// call asks rook for something and waits for the data (panes.activity).
// MUST NOT run on the serve goroutine: serve is what delivers the reply.
func (c *conn) call(op string, params any, timeout time.Duration) (json.RawMessage, error) {
	ch := make(chan callResult, 1)
	c.mu.Lock()
	c.nextID++
	id := c.nextID
	if c.pending == nil {
		c.pending = map[uint64]chan callResult{}
	}
	c.pending[id] = ch
	c.mu.Unlock()
	c.send(request{1, id, op, params})
	select {
	case r := <-ch:
		if !r.ok {
			return nil, errors.New(r.err)
		}
		return r.raw, nil
	case <-time.After(timeout):
		c.mu.Lock()
		delete(c.pending, id)
		c.mu.Unlock()
		return nil, errors.New("timeout: " + op)
	}
}

// serve answers rook until stdin closes, which is how a plugin ends.
func serve(c *conn, sc *Scanner, cache *activityCache) {
	in := bufio.NewScanner(os.Stdin)
	in.Buffer(make([]byte, 64*1024), 2*1024*1024)
	for in.Scan() {
		var req struct {
			ID     uint64          `json:"id"`
			Op     string          `json:"op"`
			Params json.RawMessage `json:"params"`
		}
		if json.Unmarshal(in.Bytes(), &req) != nil {
			continue
		}
		if req.Op == "" {
			// rook answering one of our requests: hand it to whoever waits.
			var rep struct {
				ID     uint64          `json:"id"`
				OK     bool            `json:"ok"`
				Error  string          `json:"error"`
				Result json.RawMessage `json:"result"`
			}
			if json.Unmarshal(in.Bytes(), &rep) == nil {
				c.mu.Lock()
				ch := c.pending[rep.ID]
				delete(c.pending, rep.ID)
				c.mu.Unlock()
				if ch != nil {
					ch <- callResult{rep.OK, rep.Error, rep.Result}
				}
			}
			continue
		}
		switch req.Op {
		case "describe":
			c.send(reply{1, req.ID, true, map[string]any{
				"name":         "claude",
				"version":      version,
				"capabilities": []string{"items.list", "items.act", "attention.raise", "session.spawn", "panes.activity"},
				"surfaces":     []string{"LIST"},
			}, ""})
		case "items.list":
			sessions := sc.Scan(time.Now())
			fuse(sessions, cache.get(), fuseNames, fuseBusyRate, fusePresent)
			c.send(reply{1, req.ID, true, map[string]any{
				"items":     items(sessions),
				"truncated": false,
			}, ""})
		case "items.act":
			c.send(act(c, sc, req.ID, req.Params))
		default:
			c.send(reply{1, req.ID, false, nil, "claude does not do " + req.Op})
		}
	}
}

type wireField struct {
	Key   string `json:"key"`
	Kind  string `json:"kind"`
	Value string `json:"value"`
}

type wireAction struct {
	ID    string `json:"id"`
	Label string `json:"label"`
}

type wireItem struct {
	ID       string       `json:"id"`
	Title    string       `json:"title"`
	Subtitle string       `json:"subtitle,omitempty"`
	State    string       `json:"state,omitempty"`
	Fields   []wireField  `json:"fields,omitempty"`
	Actions  []wireAction `json:"actions,omitempty"`
}

func items(sessions []Session) []wireItem {
	now := time.Now()
	out := make([]wireItem, 0, len(sessions))
	for _, s := range sessions {
		it := wireItem{
			ID:       s.ID,
			Title:    snip(s.Title, 90),
			Subtitle: relAge(now.Sub(s.Mtime)) + " · " + filepath.Base(s.Cwd),
			State:    string(s.State),
			Actions: []wireAction{
				{ID: "open", Label: "open a pane here"},
				{ID: "peek", Label: "peek at last reply"},
			},
		}
		// Least important first: the panel sheds fields off the left of
		// the row when width runs out, so the last field survives longest.
		if s.Prompt != "" {
			it.Fields = append(it.Fields, wireField{"asked", "TEXT", snip(s.Prompt, 40)})
		}
		if s.Branch != "" {
			it.Fields = append(it.Fields, wireField{"branch", "TEXT", s.Branch})
		}
		where := filepath.Base(s.Cwd)
		if where == "." || where == "/" || where == "" {
			where = "?"
		}
		it.Fields = append(it.Fields, wireField{"where", "TEXT", where + " · " + relAge(now.Sub(s.Mtime))})
		out = append(out, it)
	}
	return out
}

func act(c *conn, sc *Scanner, id uint64, params json.RawMessage) reply {
	var p struct {
		ItemID   string `json:"itemId"`
		ActionID string `json:"actionId"`
	}
	if json.Unmarshal(params, &p) != nil {
		return reply{1, id, false, nil, "params did not parse"}
	}
	var target *Session
	for _, s := range sc.Scan(time.Now()) {
		if s.ID == p.ItemID {
			target = &s
			break
		}
	}
	if target == nil {
		return reply{1, id, false, nil, "that session is gone"}
	}
	switch p.ActionID {
	case "open":
		if target.Cwd == "" {
			return reply{1, id, false, nil, "the transcript never named a directory"}
		}
		shell := os.Getenv("SHELL")
		if shell == "" {
			shell = "/bin/zsh"
		}
		c.request("session.spawn", map[string]string{"command": shell, "cwd": target.Cwd})
		return reply{1, id, true, map[string]string{"message": "opened a pane at " + target.Cwd}, ""}
	case "peek":
		msg := snip(target.LastText, 150)
		if msg == "" {
			msg = "nothing said yet"
		}
		return reply{1, id, true, map[string]string{"message": msg}, ""}
	}
	return reply{1, id, false, nil, "no such action: " + p.ActionID}
}

// watch is the reason this plugin exists: state transitions become
// attentions. The first pass only records a baseline — twenty banners at
// launch describing yesterday would teach the human to ignore the twenty-
// first. Each tick also refreshes the substrate's view (panes.activity),
// which the fusion uses two ways: a still-redrawing pane keeps a quiet
// transcript honest ("working", not "blocked?"), and a human who just
// typed in the session's pane is watching it — the state stands, the
// banner is suppressed.
func watch(c *conn, sc *Scanner, cache *activityCache, poll, minTurn time.Duration) {
	prev := map[string]State{}
	samples := map[int]paneSample{}
	first := true
	for {
		now := time.Now()
		panes := fetchActivity(c)
		computeRates(samples, panes, now)
		cache.set(panes)
		sessions := sc.Scan(now)
		fuse(sessions, cache.get(), fuseNames, fuseBusyRate, fusePresent)
		cur := map[string]State{}
		for _, s := range sessions {
			cur[s.ID] = s.State
			old, seen := prev[s.ID]
			if first || !seen || old == s.State {
				continue
			}
			switch s.State {
			case StateNeedsYou:
				// Only a turn that was RUNNING and took a while: a two-
				// second answer the human watched happen needs no banner,
				// an interrupt was the human's own hand, and a human
				// present at the pane is already looking at the answer.
				if (old != StateWorking && old != StateBlocked) || s.TurnDur < minTurn || s.Present {
					continue
				}
				body := snip(s.LastText, 200)
				if body == "" {
					body = snip(s.Prompt, 200)
				}
				c.request("attention.raise", map[string]string{
					"title": snip(s.Title, 80) + " is waiting on you",
					"body":  body,
				})
			case StateBlocked:
				if old != StateWorking || s.Present {
					continue
				}
				c.request("attention.raise", map[string]string{
					"title": snip(s.Title, 80) + " may need an approval",
					"body":  snip(s.Prompt, 200),
				})
			}
		}
		prev = cur
		first = false
		time.Sleep(poll)
	}
}
