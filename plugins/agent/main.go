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
//
// Any OpenAI-compatible server works via --api-base — ollama, LM
// Studio, llama.cpp all speak the same wire — and a non-default base
// needs no key. Costs are only reported for models the price table
// knows; a local model shows no cost rather than a made-up one.
//
// Digests are journaled to --log (default: rook's state home) and the
// ring is restored from there at launch — a digest that dies with a
// relaunch cannot follow you anywhere, and other plugins (the cloud
// bridge) read the journal to put headlines on the phone. The journal
// stays on the machine; what leaves is its readers' decision.
package main

import (
	"bufio"
	"encoding/json"
	"errors"
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

	"github.com/incantery/rook/plugins/internal/digestlog"
	"github.com/incantery/rook/plugins/internal/nowfile"
	"github.com/incantery/rook/plugins/internal/transcript"
)

const version = "0.1.0"

func main() {
	dir := flag.String("dir", "", "projects directory (default ~/.claude/projects)")
	poll := flag.Duration("poll", 5*time.Second, "watch interval")
	window := flag.Duration("window", 48*time.Hour, "how far back sessions are watched")
	minWords := flag.Int("min-words", 120, "shortest reply worth compressing")
	model := flag.String("model", "gpt-5-mini", "OpenAI model")
	apiBase := flag.String("api-base", defaultAPIBase, "API base URL (any OpenAI-compatible server)")
	effort := flag.String("effort", "low", "reasoning effort (empty omits the field)")
	keyFile := flag.String("key-file", "", "API key file (default ~/.config/rook/openai_key)")
	keep := flag.Int("keep", 100, "digests remembered")
	maxChars := flag.Int("max-chars", 16000, "input cap per reply, in bytes")
	logPath := flag.String("log", digestlog.DefaultPath(), "digest journal, jsonl (empty disables persistence)")
	nowEvery := flag.Duration("now-every", 20*time.Second, "screen-watcher interval for live now-lines (0 disables)")
	nowPath := flag.String("now-file", nowfile.DefaultPath(), "ephemeral now-line file (empty disables)")
	nowNames := flag.String("claude-names", "claude,node", "foreground program names that count as Claude Code")
	flag.Parse()

	home, _ := os.UserHomeDir()
	if *dir == "" {
		if home == "" {
			fmt.Fprintln(os.Stderr, "no home directory and no --dir")
			os.Exit(1)
		}
		*dir = filepath.Join(home, ".claude", "projects")
	}
	explicitKeyFile := *keyFile != ""
	if *keyFile == "" && home != "" {
		*keyFile = filepath.Join(home, ".config", "rook", "openai_key")
	}
	// rook launches plugins directly, with no shell in between, so a
	// tilde in a flag is a literal directory named "~" and the read
	// fails into an empty key — which presents as a 401 from whatever
	// the key was for, several layers from the cause.
	*keyFile = expandHome(*keyFile, home)

	sc := &transcript.Scanner{
		Dir:    *dir,
		Window: *window,
		Idle:   10 * time.Minute,
		Quiet:  60 * time.Second,
		Max:    20,
	}
	st := newStore(*keep, expandHome(*logPath, home), *window, time.Now())
	key := apiKey(*keyFile, explicitKeyFile)
	c := &conn{out: os.Stdout}
	var sum *Summarizer
	if notice := nokeyNotice(key, *apiBase, *keyFile); notice != "" {
		st.nokey = notice
	} else {
		sum = &Summarizer{
			Client:   &http.Client{Timeout: 90 * time.Second},
			Base:     *apiBase,
			Key:      key,
			Model:    *model,
			Effort:   *effort,
			MaxChars: *maxChars,
		}
		go watch(sc, st, sum, *poll, *minWords)
		if *nowEvery > 0 && *nowPath != "" {
			// Its own scanner: Scanner keeps per-file state and the
			// watch goroutine must not share one.
			nsc := &transcript.Scanner{
				Dir:    *dir,
				Window: *window,
				Idle:   10 * time.Minute,
				Quiet:  60 * time.Second,
				Max:    20,
			}
			go nowLoop(c, nsc, st, sum, *nowEvery,
				strings.Split(*nowNames, ","), expandHome(*nowPath, home))
		}
	}
	serve(c, st, sum)
}

const defaultAPIBase = "https://api.openai.com/v1"

// nokeyNotice: a missing key is a standing notice only where the
// default API lives. A non-default base is a local server (ollama,
// LM Studio) or someone's proxy — those want no auth, and demanding a
// key they would ignore turns "works out of the box" into false
// weather. If a custom base DOES want auth, its 401 shows up as an
// honest error row instead.
func nokeyNotice(key, base, keyFile string) string {
	if key != "" || base != defaultAPIBase {
		return ""
	}
	return "no OpenAI key — set $OPENAI_API_KEY or write " + keyFile
}

// apiKey: the environment when there is one, a file when there is not —
// rook launched from the Dock inherits launchd's environment, and no
// shell profile ran there.
//
// An EXPLICIT --key-file overturns that order. $OPENAI_API_KEY is
// ambient and a named file is a decision, and the case that matters is
// borrowing the fleet's key: a developer with OPENAI_API_KEY exported
// who points the agent at rook-cloud would otherwise send their OpenAI
// key as the machine bearer, and meet a 401 that names neither the key
// they sent nor the one they meant to.
func apiKey(path string, explicit bool) string {
	if !explicit {
		if k := strings.TrimSpace(os.Getenv("OPENAI_API_KEY")); k != "" {
			return k
		}
	}
	b, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(b))
}

// expandHome resolves a leading ~ the way a shell would, which is the
// only place one can appear: rook execs plugins directly.
func expandHome(path, home string) string {
	if home == "" || path == "~" {
		if path == "~" && home != "" {
			return home
		}
		return path
	}
	if strings.HasPrefix(path, "~/") {
		return filepath.Join(home, path[2:])
	}
	return path
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
			if spent(done, st, s.ID, h) {
				continue
			}
			// Marked spent BEFORE the call: a call that fails lands as an
			// error row, not as a bill that grows by one attempt per tick.
			done[s.ID] = h
			d := sum.Summarize(s, now)
			recordSpend(d.CostUSD)
			st.add(d)
		}
		prev = cur
		first = false
		time.Sleep(poll)
	}
}

// spent reports whether this exact reply was already paid for: the
// in-memory map covers this run, the restored store covers prior runs
// — a relaunch must not re-bill a turn the journal already holds. A
// digest id is sessionID:hash, which is why the store can answer.
func spent(done map[string]string, st *store, sessionID, h string) bool {
	return done[sessionID] == h || st.has(sessionID+":"+h)
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

// store is the digest ring: newest first, bounded, in memory — with a
// journal underneath so the ring survives a relaunch and other plugins
// can read it. Still not a database: the log is replayed, never
// queried, and losing it costs history, not correctness.
type store struct {
	mu    sync.Mutex
	ds    []Digest
	keep  int
	nokey string         // standing notice when there is no API key
	log   *digestlog.Log // nil when persistence is off
}

// newStore restores the ring from the journal — a digest that dies
// with a relaunch cannot follow anyone anywhere. A log that cannot
// open degrades to the old in-memory-only behavior; persistence is
// comfort, not correctness.
func newStore(keep int, logPath string, window time.Duration, now time.Time) *store {
	st := &store{keep: keep}
	if logPath == "" {
		return st
	}
	l, err := digestlog.Open(logPath, window, now)
	if err != nil {
		return st
	}
	st.log = l
	st.ds = digestlog.Load(logPath, window, now)
	if keep > 0 && len(st.ds) > keep {
		st.ds = st.ds[:keep]
	}
	return st
}

// persist journals one state under the store lock, so log order is the
// order the panel saw. Failures are dropped: the ring is the truth for
// this run, the journal only for the next one.
func (st *store) persist(d Digest) {
	if st.log != nil {
		st.log.Append(d)
	}
}

func (st *store) add(d Digest) {
	st.mu.Lock()
	defer st.mu.Unlock()
	st.ds = append([]Digest{d}, st.ds...)
	if st.keep > 0 && len(st.ds) > st.keep {
		st.ds = st.ds[:st.keep]
	}
	st.persist(d)
}

func (st *store) has(id string) bool {
	st.mu.Lock()
	defer st.mu.Unlock()
	for i := range st.ds {
		if st.ds[i].ID == id {
			return true
		}
	}
	return false
}

// update runs f on the digest with this id under the lock. False when
// it is gone — which a caller racing a dismissal must treat as the
// dismissal winning, never as a reason to re-add.
func (st *store) update(id string, f func(*Digest)) bool {
	st.mu.Lock()
	defer st.mu.Unlock()
	for i := range st.ds {
		if st.ds[i].ID == id {
			f(&st.ds[i])
			st.persist(st.ds[i])
			return true
		}
	}
	return false
}

func (st *store) dismiss(id string) bool {
	st.mu.Lock()
	defer st.mu.Unlock()
	for i, d := range st.ds {
		if d.ID == id {
			st.ds = slices.Delete(st.ds, i, i+1)
			// The tombstone is stamped for the record; the Dismissed
			// flag alone is what drops it from every reader.
			st.persist(Digest{ID: id, Dismissed: true, At: time.Now()})
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
// The protocol boilerplate below is the claude plugin's — the second
// in-repo copy of this shape is the argument for a shared wire package;
// the third copy should be the one that writes it.

type conn struct {
	mu      sync.Mutex
	out     io.Writer
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

// call asks rook for something (clipboard.set) and waits for the
// verdict. MUST NOT run on the serve goroutine: serve is what delivers
// the reply, so a handler that called this inline would wait on itself.
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

// deliver hands rook's answer to whoever is waiting on it. Split out of
// serve so a test can play rook's half of the conversation.
func (c *conn) deliver(id uint64, ok bool, errText string, raw json.RawMessage) {
	c.mu.Lock()
	ch := c.pending[id]
	delete(c.pending, id)
	c.mu.Unlock()
	if ch != nil {
		ch <- callResult{ok, errText, raw}
	}
}

// serve answers rook until stdin closes, which is how a plugin ends.
func serve(c *conn, st *store, sum *Summarizer) {
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
			// rook answering one of our requests.
			var rep struct {
				ID     uint64          `json:"id"`
				OK     bool            `json:"ok"`
				Error  string          `json:"error"`
				Result json.RawMessage `json:"result"`
			}
			if json.Unmarshal(in.Bytes(), &rep) == nil {
				c.deliver(rep.ID, rep.OK, rep.Error, rep.Result)
			}
			continue
		}
		switch req.Op {
		case "describe":
			c.send(reply{1, req.ID, true, map[string]any{
				"name":         "agent",
				"version":      version,
				"capabilities": []string{"items.list", "items.act", "clipboard.set", "panes.activity", "pane.read"},
				"surfaces":     []string{"LIST"},
			}, ""})
		case "items.list":
			c.send(reply{1, req.ID, true, map[string]any{
				"items":     items(st, time.Now()),
				"truncated": false,
			}, ""})
		case "items.act":
			c.send(act(c, st, sum, req.ID, req.Params))
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
	Input string `json:"input,omitempty"`
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
			Title:    transcript.Snip(d.Headline, 250),
			Subtitle: transcript.Snip(d.SessionTitle, 40) + " · " + transcript.RelAge(now.Sub(d.At)),
			State:    d.ReplyState,
		}
		// The action order is the menu order: the likeliest next act
		// first. A drafted reply's next act is copying it; expand takes
		// the rough reply you type and writes the one you mean.
		if d.Reply != "" {
			it.Actions = append(it.Actions, wireAction{ID: "copy", Label: "copy reply"})
			it.Actions = append(it.Actions, wireAction{ID: "expand", Label: "expand my reply…", Input: "INPUT_TEXT"})
			it.Actions = append(it.Actions, wireAction{ID: "draft", Label: "redraft"})
		} else if d.ReplyState != "drafting" {
			it.Actions = append(it.Actions, wireAction{ID: "draft", Label: "draft a reply"})
			it.Actions = append(it.Actions, wireAction{ID: "expand", Label: "expand my reply…", Input: "INPUT_TEXT"})
		}
		it.Actions = append(it.Actions, wireAction{ID: "dismiss", Label: "dismiss"})
		for i, b := range d.Bullets {
			it.Children = append(it.Children, wireChild{
				ID:    fmt.Sprintf("%s:b%d", d.ID, i),
				Title: transcript.Snip(b, 250),
			})
		}
		if d.ReplyErr != "" {
			it.Children = append(it.Children, wireChild{
				ID:    d.ID + ":rerr",
				Title: transcript.Snip(d.ReplyErr, 250),
			})
		}
		if d.Reply != "" {
			// The reply rides as children so the wrap renders it; the
			// marker row keeps it visually apart from the bullets. Chunks
			// stay under the wire's title cap — the clipboard carries the
			// uncut text, the panel only has to show it.
			it.Children = append(it.Children, wireChild{ID: d.ID + ":rhead", Title: "↩ suggested reply:"})
			for i, chunk := range chunkText(d.Reply, 240) {
				it.Children = append(it.Children, wireChild{
					ID:    fmt.Sprintf("%s:r%d", d.ID, i),
					Title: chunk,
				})
			}
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

func act(c *conn, st *store, sum *Summarizer, id uint64, params json.RawMessage) reply {
	var p struct {
		ItemID   string `json:"itemId"`
		ActionID string `json:"actionId"`
		Input    string `json:"input"`
	}
	if json.Unmarshal(params, &p) != nil {
		return reply{1, id, false, nil, "params did not parse"}
	}
	// A child's id is its parent's plus one ":suffix" (bullets, reply
	// chunks, the marker row); acting on any of them acts on the digest
	// it belongs to. Exact match first — a digest id contains a colon of
	// its own, so blind stripping would eat the hash.
	itemID := p.ItemID
	if !st.has(itemID) {
		if i := strings.LastIndex(itemID, ":"); i > 0 {
			itemID = itemID[:i]
		}
	}
	switch p.ActionID {
	case "dismiss":
		if !st.dismiss(itemID) {
			return reply{1, id, false, nil, "that digest is gone"}
		}
		return reply{1, id, true, map[string]string{"message": "dismissed"}, ""}

	case "draft", "expand":
		if sum == nil {
			return reply{1, id, false, nil, "no OpenAI key, nothing to draft with"}
		}
		if p.ActionID == "expand" && strings.TrimSpace(p.Input) == "" {
			return reply{1, id, false, nil, "say roughly what you want to reply"}
		}
		var seed Digest
		if !st.update(itemID, func(d *Digest) {
			d.ReplyState = "drafting"
			seed = *d
		}) {
			return reply{1, id, false, nil, "that digest is gone"}
		}
		// The call takes seconds and this is the serve goroutine, so the
		// draft lands via the store and the panel's own refresh — the
		// answer here is only "started". A dismissal mid-draft wins:
		// update() on a gone digest is a no-op, not a resurrection.
		guidance := strings.TrimSpace(p.Input)
		go func() {
			text, cost, err := sum.Draft(seed, guidance)
			recordSpend(cost)
			st.update(itemID, func(d *Digest) {
				d.CostUSD += cost
				if err != nil {
					d.ReplyState = "draft failed"
					d.ReplyErr = err.Error()
					return
				}
				d.Reply = text
				d.ReplyState = "ready"
				d.ReplyErr = ""
			})
		}()
		return reply{1, id, true, map[string]string{"message": "drafting…"}, ""}

	case "copy":
		var text string
		if !st.update(itemID, func(d *Digest) { text = d.Reply }) {
			return reply{1, id, false, nil, "that digest is gone"}
		}
		if text == "" {
			return reply{1, id, false, nil, "no reply drafted yet"}
		}
		// Same shape as draft, same reason: call() waits for rook's
		// verdict and serve is the goroutine that delivers it. The
		// refusal is worth waiting for — "copied" on a missing grant
		// would be the panel lying about the pasteboard.
		go func() {
			_, err := c.call("clipboard.set", map[string]string{"text": text}, 3*time.Second)
			st.update(itemID, func(d *Digest) {
				if err != nil {
					d.ReplyState = "clip refused"
					d.ReplyErr = err.Error()
				} else {
					d.ReplyState = "copied"
					d.ReplyErr = ""
				}
			})
		}()
		return reply{1, id, true, map[string]string{"message": "sending to the clipboard…"}, ""}
	}
	return reply{1, id, false, nil, "no such action: " + p.ActionID}
}
