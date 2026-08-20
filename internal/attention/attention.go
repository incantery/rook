// Package attention is rook's inbound contract: anything that wants a
// say in rook's chrome — the status bar, the picker, the preview —
// writes items into the attention feed, and rook renders them without
// knowing who wrote them. Vera is the first publisher; it must not be
// the last.
//
// The feed lives at $XDG_STATE_HOME/rook/attention.jsonl (rook's state
// dir, so sandboxes get their own). The file IS the current attention
// set, not a log: a publisher rewrites the whole file atomically
// (write temp, rename), one JSON object per line:
//
//	{"session":"tmux","kind":"waiting","headline":"T-136 needs an answer","at":"2026-08-19T13:40:47-04:00","source":"vera"}
//
// session and/or dir say where the item points: session is a tmux
// session name on the rook server; dir is an absolute path rook maps
// to the session that directory would become. kind "waiting" means a
// human is needed and renders in accent; every other kind renders dim.
// at is RFC3339; items older than 24h are ignored, so a dead publisher
// cannot haunt the bar. Malformed lines are skipped, never fatal.
package attention

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/incantery/rook/internal/tmux"
)

// Item is one entry in the feed.
type Item struct {
	Session  string    `json:"session,omitempty"`
	Dir      string    `json:"dir,omitempty"`
	Kind     string    `json:"kind"`
	Headline string    `json:"headline"`
	At       time.Time `json:"at"`
	Source   string    `json:"source,omitempty"`
}

// Waiting says whether this item needs a human.
func (i Item) Waiting() bool { return i.Kind == "waiting" }

const maxAge = 24 * time.Hour

// Path returns where the feed lives, whether or not it exists.
func Path() (string, error) {
	dir := os.Getenv("XDG_STATE_HOME")
	if dir == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			return "", err
		}
		dir = filepath.Join(home, ".local", "state")
	}
	return filepath.Join(dir, "rook", "attention.jsonl"), nil
}

// Load reads the current attention set. A missing feed is an empty
// one; so is an unreadable line or a stale item.
func Load() []Item {
	path, err := Path()
	if err != nil {
		return nil
	}
	f, err := os.Open(path)
	if err != nil {
		return nil
	}
	defer f.Close()

	var items []Item
	cutoff := time.Now().Add(-maxAge)
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		var it Item
		if err := json.Unmarshal(sc.Bytes(), &it); err != nil {
			continue
		}
		if it.Headline == "" || it.At.Before(cutoff) {
			continue
		}
		items = append(items, it)
	}
	return items
}

// ForSession filters items pointing at a session, by name or by the
// session their dir would become.
func ForSession(items []Item, session string) []Item {
	var out []Item
	for _, it := range items {
		if it.Session == session || (it.Dir != "" && tmux.SessionName(it.Dir) == session) {
			out = append(out, it)
		}
	}
	return out
}

// ForDir filters items pointing at a directory.
func ForDir(items []Item, dir string) []Item {
	var out []Item
	for _, it := range items {
		if it.Dir == dir {
			out = append(out, it)
		}
	}
	return out
}

// AnyWaiting reports whether any item needs a human.
func AnyWaiting(items []Item) bool {
	for _, it := range items {
		if it.Waiting() {
			return true
		}
	}
	return false
}

// Bar renders the status-bar segment: only what needs a human, in
// tmux style tags, empty when nothing does. The bar shows attention
// debt, not activity.
func Bar(items []Item) string {
	waiting := 0
	for _, it := range items {
		if it.Waiting() {
			waiting++
		}
	}
	if waiting == 0 {
		return ""
	}
	return fmt.Sprintf("#[fg=yellow,bold]● %d waiting#[default]  ", waiting)
}
