// Package nowfile is the membrane's ephemeral channel: one small JSON
// file holding the latest "what is happening RIGHT NOW" line per
// working session, written by the agent plugin's screen-watcher and
// read by whoever folds status snapshots (the link and cloud bridges).
//
// Deliberately not the digest journal: a digest is a durable artifact
// of a finished turn, replayed at launch and worth keeping. A now-line
// is true for twenty seconds — persistence would only preserve
// staleness. Latest wins, whole file per write, atomic rename so a
// half-written file can never be read.
package nowfile

import (
	"encoding/json"
	"os"
	"path/filepath"
	"time"
)

// Now is one session's live line: what the screen says is happening,
// as of At. CostUSD is what the line cost to write — the membrane
// prints its own bill, even on the ephemeral rail.
type Now struct {
	SessionID string    `json:"sessionId"`
	Line      string    `json:"line"`
	At        time.Time `json:"at"`
	CostUSD   float64   `json:"costUsd,omitempty"`
}

// DefaultPath is beside the digest journal: rook's state home.
func DefaultPath() string {
	if x := os.Getenv("XDG_STATE_HOME"); x != "" {
		return filepath.Join(x, "rook", "now.json")
	}
	home, err := os.UserHomeDir()
	if err != nil || home == "" {
		return ""
	}
	return filepath.Join(home, ".local", "state", "rook", "now.json")
}

// Write replaces the file with m, atomically. An empty map writes an
// empty object — "nothing is happening" is a statement, not an error.
func Write(path string, m map[string]Now) error {
	if path == "" {
		return nil
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	b, err := json.Marshal(m)
	if err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, b, 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

// Read returns the fresh entries: anything older than maxAge is
// dropped at the reader, so a crashed writer's last words age out
// instead of impersonating the present.
func Read(path string, maxAge time.Duration, now time.Time) map[string]Now {
	if path == "" {
		return nil
	}
	b, err := os.ReadFile(path)
	if err != nil {
		return nil
	}
	var m map[string]Now
	if json.Unmarshal(b, &m) != nil {
		return nil
	}
	out := map[string]Now{}
	for id, n := range m {
		if n.Line == "" || now.Sub(n.At) > maxAge {
			continue
		}
		out[id] = n
	}
	if len(out) == 0 {
		return nil
	}
	return out
}
