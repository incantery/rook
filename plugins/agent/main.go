// rook-plugin-agent — the rook agent, an OpenAI-backed worker riding the
// plugin protocol (man 7 rook-plugin). Its first job: compress Claude
// Code's finished replies into STE-style digests, because the core of an
// eight-paragraph answer is usually three bullets, and the human should
// read the three bullets first and the eight paragraphs by choice.
//
// It watches the same transcripts the claude watcher does (the shared
// scanner in plugins/internal/transcript), and when a turn finishes past
// a word threshold it spends one model call turning the reply into a
// headline plus bullets. The full reply stays in the session where it
// belongs — this makes the READING terse, never the writing.
//
// The API key comes from $OPENAI_API_KEY or --key-file. Without one the
// plugin still serves its panel and says exactly what is missing: a
// plugin that exits on a missing key is indistinguishable from a broken
// one, and this failure is configuration, not damage.
package main

import (
	"bufio"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"time"

	"github.com/incantery/rook/plugins/internal/transcript"
)

const version = "0.1.0"

func main() {
	dir := flag.String("dir", "", "projects directory (default ~/.claude/projects)")
	poll := flag.Duration("poll", 5*time.Second, "watch interval")
	window := flag.Duration("window", 48*time.Hour, "how far back sessions are watched")
	minWords := flag.Int("min-words", 120, "shortest reply worth compressing")
	model := flag.String("model", "gpt-5-mini", "OpenAI model")
	apiBase := flag.String("api-base", "https://api.openai.com/v1", "API base URL")
	effort := flag.String("effort", "low", "reasoning effort (empty omits the field)")
	keyFile := flag.String("key-file", "", "API key file (default ~/.config/rook/openai_key)")
	keep := flag.Int("keep", 100, "digests remembered")
	maxChars := flag.Int("max-chars", 16000, "input cap per reply, in bytes")
	flag.Parse()

	home, _ := os.UserHomeDir()
	if *dir == "" {
		if home == "" {
			fmt.Fprintln(os.Stderr, "no home directory and no --dir")
			os.Exit(1)
		}
		*dir = filepath.Join(home, ".claude", "projects")
	}
	if *keyFile == "" && home != "" {
		*keyFile = filepath.Join(home, ".config", "rook", "openai_key")
	}

	sc := &transcript.Scanner{
		Dir:    *dir,
		Window: *window,
		Idle:   10 * time.Minute,
		Quiet:  60 * time.Second,
		Max:    20,
	}
	st := &store{keep: *keep}
	key := apiKey(*keyFile)
	if key == "" {
		st.nokey = "no OpenAI key — set $OPENAI_API_KEY or write " + *keyFile
	} else {
		sum := &Summarizer{
			Client:   &http.Client{Timeout: 90 * time.Second},
			Base:     *apiBase,
			Key:      key,
			Model:    *model,
			Effort:   *effort,
			MaxChars: *maxChars,
		}
		go watch(sc, st, sum, *poll, *minWords)
	}
	serve(&conn{out: os.Stdout}, st)
}

// apiKey: the environment when there is one, a file when there is not —
// rook launched from the Dock inherits launchd's environment, and no
// shell profile ran there.
func apiKey(path string) string {
	if k := strings.TrimSpace(os.Getenv("OPENAI_API_KEY")); k != "" {
		return k
	}
	b, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(b))
}

// watch turns state transitions into digests, the same edge the claude
// watcher turns into attention: a turn is DONE when its session crosses
// from working (or blocked — an approval granted mid-turn still ends
// somewhere) to needing a human. The first pass is baseline only, for
// the watcher's own reason: summarizing yesterday at launch would spend
// real money teaching the human to ignore the panel.
func watch(sc *transcript.Scanner, st *store, sum *Summarizer, poll time.Duration, minWords int) {
	prev := map[string]transcript.State{}
	done := map[string]string{} // session -> hash of the reply last spent on
	first := true
	for {
		now := time.Now()
		cur := map[string]transcript.State{}
		for _, s := range sc.Scan(now) {
			cur[s.ID] = s.State
			old, seen := prev[s.ID]
			if !shouldSummarize(first || !seen, old, s.State, wordCount(s.LastText), minWords) {
				continue
			}
			h := shortHash(s.LastText)
			if done[s.ID] == h {
				continue
			}
			// Marked spent BEFORE the call: a call that fails lands as an
			// error row, not as a bill that grows by one attempt per tick.
			done[s.ID] = h
			st.add(sum.Summarize(s, now))
		}
		prev = cur
		first = false
		time.Sleep(poll)
	}
}

// shouldSummarize is the trigger edge, alone so a test can walk it.
func shouldSummarize(baseline bool, old, cur transcript.State, words, minWords int) bool {
	if baseline || cur != transcript.StateNeedsYou {
		return false
	}
	if old != transcript.StateWorking && old != transcript.StateBlocked {
		return false
	}
	return words >= minWords
}

// store is the digest ring: newest first, bounded, in memory only — a
// digest is a reading aid, and a reading aid that needs a database has
// misunderstood its job.
type store struct {
	mu    sync.Mutex
	ds    []Digest
	keep  int
	nokey string // standing notice when there is no API key
}

func (st *store) add(d Digest) {
	st.mu.Lock()
	defer st.mu.Unlock()
	st.ds = append([]Digest{d}, st.ds...)
	if st.keep > 0 && len(st.ds) > st.keep {
		st.ds = st.ds[:st.keep]
	}
}

func (st *store) dismiss(id string) bool {
	st.mu.Lock()
	defer st.mu.Unlock()
	for i, d := range st.ds {
		if d.ID == id {
			st.ds = slices.Delete(st.ds, i, i+1)
			return true
		}
	}
	return false
}

func (st *store) list() []Digest {
	st.mu.Lock()
	defer st.mu.Unlock()
	out := make([]Digest, len(st.ds))
	copy(out, st.ds)
	return out
}

// ---- the wire ----
//
// The protocol boilerplate below is the claude plugin's, trimmed: this
// plugin never calls rook back, so there is no pending-reply demux. The
// second in-repo copy of this shape is the argument for a shared wire
// package; the third copy should be the one that writes it.

type conn struct {
	mu  sync.Mutex
	out io.Writer
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

// serve answers rook until stdin closes, which is how a plugin ends.
func serve(c *conn, st *store) {
	in := bufio.NewScanner(os.Stdin)
	in.Buffer(make([]byte, 64*1024), 2*1024*1024)
	for in.Scan() {
		var req struct {
			ID     uint64          `json:"id"`
			Op     string          `json:"op"`
			Params json.RawMessage `json:"params"`
		}
		if json.Unmarshal(in.Bytes(), &req) != nil || req.Op == "" {
			continue
		}
		switch req.Op {
		case "describe":
			c.send(reply{1, req.ID, true, map[string]any{
				"name":         "agent",
				"version":      version,
				"capabilities": []string{"items.list", "items.act"},
				"surfaces":     []string{"LIST"},
			}, ""})
		case "items.list":
			c.send(reply{1, req.ID, true, map[string]any{
				"items":     items(st, time.Now()),
				"truncated": false,
			}, ""})
		case "items.act":
			c.send(act(st, req.ID, req.Params))
		default:
			c.send(reply{1, req.ID, false, nil, "agent does not do " + req.Op})
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

type wireChild struct {
	ID    string `json:"id"`
	Title string `json:"title"`
}

type wireItem struct {
	ID       string       `json:"id"`
	Title    string       `json:"title"`
	Subtitle string       `json:"subtitle,omitempty"`
	State    string       `json:"state,omitempty"`
	Fields   []wireField  `json:"fields,omitempty"`
	Actions  []wireAction `json:"actions,omitempty"`
	Children []wireChild  `json:"children,omitempty"`
}

// items shapes the ring for the panel: headline as the row, bullets as
// its children — STE's caps are what make a digest fit this model at
// all, which is the whole reason the format was chosen.
func items(st *store, now time.Time) []wireItem {
	var out []wireItem
	if st.nokey != "" {
		out = append(out, wireItem{
			ID:    "agent:nokey",
			Title: st.nokey,
			State: "error",
		})
	}
	for _, d := range st.list() {
		if d.Err != "" {
			out = append(out, wireItem{
				ID:       d.ID,
				Title:    "summarize failed — " + transcript.Snip(d.Err, 90),
				Subtitle: transcript.Snip(d.SessionTitle, 40) + " · " + transcript.RelAge(now.Sub(d.At)),
				State:    "error",
				Actions:  []wireAction{{ID: "dismiss", Label: "dismiss"}},
			})
			continue
		}
		it := wireItem{
			ID:       d.ID,
			Title:    transcript.Snip(d.Headline, 120),
			Subtitle: transcript.Snip(d.SessionTitle, 40) + " · " + transcript.RelAge(now.Sub(d.At)),
			Actions:  []wireAction{{ID: "dismiss", Label: "dismiss"}},
		}
		for i, b := range d.Bullets {
			it.Children = append(it.Children, wireChild{
				ID:    fmt.Sprintf("%s:b%d", d.ID, i),
				Title: transcript.Snip(b, 140),
			})
		}
		// Least important first: the panel sheds fields off the left of
		// the row when width runs out, so the last field survives longest.
		it.Fields = append(it.Fields, wireField{"model", "TEXT", d.Model})
		it.Fields = append(it.Fields, wireField{"len", "TEXT", fmt.Sprintf("%dw → %dw", d.InWords, d.OutWords)})
		if d.CostUSD > 0 {
			it.Fields = append(it.Fields, wireField{"cost", "MONEY", fmt.Sprintf("$%.4f", d.CostUSD)})
		}
		out = append(out, it)
	}
	return out
}

func act(st *store, id uint64, params json.RawMessage) reply {
	var p struct {
		ItemID   string `json:"itemId"`
		ActionID string `json:"actionId"`
	}
	if json.Unmarshal(params, &p) != nil {
		return reply{1, id, false, nil, "params did not parse"}
	}
	// A bullet's id is its parent's plus a suffix; acting on a child acts
	// on the digest it belongs to.
	itemID := p.ItemID
	if i := strings.LastIndex(itemID, ":b"); i > 0 {
		itemID = itemID[:i]
	}
	if p.ActionID != "dismiss" {
		return reply{1, id, false, nil, "no such action: " + p.ActionID}
	}
	if !st.dismiss(itemID) {
		return reply{1, id, false, nil, "that digest is gone"}
	}
	return reply{1, id, true, map[string]string{"message": "dismissed"}, ""}
}
