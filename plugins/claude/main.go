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
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"time"
)

const version = "0.1.0"

func main() {
	dir := flag.String("dir", "", "projects directory (default ~/.claude/projects)")
	poll := flag.Duration("poll", 2*time.Second, "watch interval")
	minTurn := flag.Duration("min-turn", 30*time.Second, "shortest finished turn worth a banner")
	window := flag.Duration("window", 48*time.Hour, "how far back sessions are listed")
	flag.Parse()

	if *dir == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			fmt.Fprintln(os.Stderr, "no home directory and no --dir")
			os.Exit(1)
		}
		*dir = filepath.Join(home, ".claude", "projects")
	}
	sc := &Scanner{
		Dir:    *dir,
		Window: *window,
		Idle:   10 * time.Minute,
		Quiet:  60 * time.Second,
		Max:    20,
	}

	c := &conn{out: os.Stdout}
	go watch(c, sc, *poll, *minTurn)
	serve(c, sc)
}

// conn is the write half of the protocol: one goroutine answers rook,
// another raises attentions, and a torn frame would kill both.
type conn struct {
	mu     sync.Mutex
	out    *os.File
	nextID uint64
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

// request asks rook for something (attention.raise, session.spawn). The
// answer comes back on stdin and is discarded there — both verbs are
// fire-and-forget from this side.
func (c *conn) request(op string, params any) {
	c.mu.Lock()
	c.nextID++
	id := c.nextID
	c.mu.Unlock()
	c.send(struct {
		V      int    `json:"v"`
		ID     uint64 `json:"id"`
		Op     string `json:"op"`
		Params any    `json:"params"`
	}{1, id, op, params})
}

// serve answers rook until stdin closes, which is how a plugin ends.
func serve(c *conn, sc *Scanner) {
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
			continue // rook answering one of our requests; nothing to do
		}
		switch req.Op {
		case "describe":
			c.send(reply{1, req.ID, true, map[string]any{
				"name":         "claude",
				"version":      version,
				"capabilities": []string{"items.list", "items.act", "attention.raise", "session.spawn"},
				"surfaces":     []string{"LIST"},
			}, ""})
		case "items.list":
			c.send(reply{1, req.ID, true, map[string]any{
				"items":     items(sc.Scan(time.Now())),
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
// first.
func watch(c *conn, sc *Scanner, poll, minTurn time.Duration) {
	prev := map[string]State{}
	first := true
	for {
		now := time.Now()
		cur := map[string]State{}
		for _, s := range sc.Scan(now) {
			cur[s.ID] = s.State
			old, seen := prev[s.ID]
			if first || !seen || old == s.State {
				continue
			}
			switch s.State {
			case StateNeedsYou:
				// Only a turn that was RUNNING and took a while: a two-
				// second answer the human watched happen needs no banner,
				// and an interrupt was the human's own hand.
				if (old != StateWorking && old != StateBlocked) || s.TurnDur < minTurn {
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
				if old != StateWorking {
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
