// Package digestlog is the membrane's journal: every digest the agent
// plugin makes, appended to one jsonl file that other plugins read.
//
// The file is the interface — the same pattern the transcript scanner
// stands on. The agent plugin writes it (and owns compaction); the
// cloud plugin reads it to put headlines on the phone; nobody holds a
// socket open to anybody. A line is a full snapshot of one digest, so
// the log is also the panel's persistence: replaying "last line per id"
// rebuilds the ring, drafts and all, after a relaunch.
//
// What is IN the file stays on the machine: full turn text rides along
// (drafting works from the full turn, and a draft must survive a
// relaunch too). Readers that export decide what leaves — the cloud
// plugin lifts headline and bullets, never the raw material.
package digestlog

import (
	"bufio"
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
	"sync"
	"time"
)

// Digest is one summarized turn — the same struct the agent plugin
// works with (it aliases this type), plus the tombstone flag only the
// log cares about.
type Digest struct {
	ID           string    `json:"id"`
	SessionID    string    `json:"sessionId,omitempty"`
	SessionTitle string    `json:"sessionTitle,omitempty"`
	Cwd          string    `json:"cwd,omitempty"`
	Headline     string    `json:"headline,omitempty"`
	Bullets      []string  `json:"bullets,omitempty"`
	InWords      int       `json:"inWords,omitempty"`  // the reply it compressed
	OutWords     int       `json:"outWords,omitempty"` // the digest
	CostUSD      float64   `json:"costUsd,omitempty"`
	Model        string    `json:"model,omitempty"`
	At           time.Time `json:"at,omitzero"`
	Err          string    `json:"err,omitempty"`

	// The raw material a draft works from — the digest is a reading
	// aid, and drafting from a summary would compound its lossiness.
	Prompt   string `json:"prompt,omitempty"`
	FullText string `json:"fullText,omitempty"`

	// The suggested-reply lifecycle: Reply once drafted; ReplyState is
	// the row's chip ("drafting", "ready", "copied", "draft failed",
	// "clip refused"); ReplyErr carries the reason when one failed.
	Reply      string `json:"reply,omitempty"`
	ReplyState string `json:"replyState,omitempty"`
	ReplyErr   string `json:"replyErr,omitempty"`

	// Dismissed marks the id dead: the last line for an id wins, and a
	// tombstone as that line drops the digest from every reader.
	Dismissed bool `json:"dismissed,omitempty"`
}

// DefaultPath is where the journal lives: rook's state home, beside
// the host's own logs. XDG_STATE_HOME is the override the rest of the
// app honors; an empty return means "no home, nowhere to write".
func DefaultPath() string {
	if x := os.Getenv("XDG_STATE_HOME"); x != "" {
		return filepath.Join(x, "rook", "digests.jsonl")
	}
	home, err := os.UserHomeDir()
	if err != nil || home == "" {
		return ""
	}
	return filepath.Join(home, ".local", "state", "rook", "digests.jsonl")
}

// maxBytes is the writer's compaction trigger. Digests carry full turn
// text (up to 16KB each), so the file grows for real; past this, Open
// rewrites it to the live window before appending anything new.
const maxBytes = 8 << 20

// Log is the writer's handle. One process writes the log (the agent
// plugin); the mutex serializes its own goroutines, not other
// processes — readers tolerate a torn tail line instead.
type Log struct {
	mu     sync.Mutex
	path   string
	window time.Duration
}

// Open prepares the journal for appending: the directory is made, and
// a file grown past maxBytes is compacted to the live window. A failed
// compaction is not fatal — an oversized journal still appends.
func Open(path string, window time.Duration, now time.Time) (*Log, error) {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return nil, err
	}
	l := &Log{path: path, window: window}
	if fi, err := os.Stat(path); err == nil && fi.Size() > maxBytes {
		l.compact(now)
	}
	return l, nil
}

// Append writes one snapshot line. Called on every add, update, and
// dismissal — the log is a history of states, and Load keeps the last.
func (l *Log) Append(d Digest) error {
	b, err := json.Marshal(d)
	if err != nil {
		return err
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	f, err := os.OpenFile(l.path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		return err
	}
	defer f.Close()
	_, err = f.Write(append(b, '\n'))
	return err
}

// compact rewrites the file to only the live window's survivors, one
// line per digest, via a temp file and rename — a reader mid-scan sees
// the old file or the new one, never half of either.
func (l *Log) compact(now time.Time) {
	l.mu.Lock()
	defer l.mu.Unlock()
	ds := Load(l.path, l.window, now)
	tmp := l.path + ".tmp"
	f, err := os.OpenFile(tmp, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o600)
	if err != nil {
		return
	}
	w := bufio.NewWriter(f)
	// Load returns newest-first; write oldest-first so the file stays
	// in append order and "last line per id" keeps meaning "newest".
	for i := len(ds) - 1; i >= 0; i-- {
		if b, err := json.Marshal(ds[i]); err == nil {
			w.Write(append(b, '\n'))
		}
	}
	if w.Flush() != nil || f.Close() != nil {
		os.Remove(tmp)
		return
	}
	if os.Rename(tmp, l.path) != nil {
		os.Remove(tmp)
	}
}

// Load replays the journal into the live digests, newest first: the
// last line for an id is its state, tombstones drop it, and anything
// older than the window stays in the file but out of the result. A
// line that does not parse — including a torn tail the writer is mid-
// append on — is skipped, never fatal.
func Load(path string, window time.Duration, now time.Time) []Digest {
	f, err := os.Open(path)
	if err != nil {
		return nil
	}
	defer f.Close()
	last := map[string]Digest{}
	var order []string // first-seen order, so replay stays stable
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 64*1024), 2*1024*1024)
	for sc.Scan() {
		var d Digest
		if json.Unmarshal(sc.Bytes(), &d) != nil || d.ID == "" {
			continue
		}
		if _, seen := last[d.ID]; !seen {
			order = append(order, d.ID)
		}
		last[d.ID] = d
	}
	var out []Digest
	for _, id := range order {
		d := last[id]
		if d.Dismissed {
			continue
		}
		if window > 0 && now.Sub(d.At) > window {
			continue
		}
		out = append(out, d)
	}
	sort.SliceStable(out, func(i, j int) bool { return out[i].At.After(out[j].At) })
	return out
}

// Latest maps each session to its newest presentable digest — the
// export view: a failed summarize has no headline to show, so errored
// digests do not count.
func Latest(ds []Digest) map[string]Digest {
	out := map[string]Digest{}
	for _, d := range ds {
		if d.Err != "" || d.Headline == "" || d.SessionID == "" {
			continue
		}
		if prev, ok := out[d.SessionID]; !ok || d.At.After(prev.At) {
			out[d.SessionID] = d
		}
	}
	return out
}
