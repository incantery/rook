// Package spendfile is the membrane's bill: a small file of per-day
// spend totals for the rook agent's model calls (digests, drafts,
// expands, now-lines). The agent plugin adds to it after every call;
// the status bridges read today's and the week's totals to publish.
// The membrane's economics stay legible — pennies supervising dollars,
// with the pennies on the record.
package spendfile

import (
	"encoding/json"
	"os"
	"path/filepath"
	"time"
)

type ledger struct {
	Days map[string]float64 `json:"days"` // "2026-08-11" -> USD
}

// DefaultPath is beside the digest journal: rook's state home.
func DefaultPath() string {
	if x := os.Getenv("XDG_STATE_HOME"); x != "" {
		return filepath.Join(x, "rook", "agentspend.json")
	}
	home, err := os.UserHomeDir()
	if err != nil || home == "" {
		return ""
	}
	return filepath.Join(home, ".local", "state", "rook", "agentspend.json")
}

const day = "2006-01-02"

// Add folds one call's cost into its day and prunes anything older
// than two weeks. Read-modify-write with atomic rename; the ONE
// writer is the agent plugin, which serializes its own calls.
func Add(path string, at time.Time, usd float64) error {
	if path == "" || usd <= 0 {
		return nil
	}
	l := read(path)
	if l.Days == nil {
		l.Days = map[string]float64{}
	}
	l.Days[at.Format(day)] += usd
	for d := range l.Days {
		if t, err := time.Parse(day, d); err != nil || at.Sub(t) > 14*24*time.Hour {
			delete(l.Days, d)
		}
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	b, err := json.Marshal(l)
	if err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, b, 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

// Totals is today's spend and the trailing 7 days' (today included).
func Totals(path string, now time.Time) (today, week float64) {
	l := read(path)
	for d, usd := range l.Days {
		t, err := time.Parse(day, d)
		if err != nil {
			continue
		}
		age := now.Sub(t)
		if age < 0 || age > 7*24*time.Hour {
			continue
		}
		week += usd
		if d == now.Format(day) {
			today = usd
		}
	}
	return today, week
}

func read(path string) ledger {
	var l ledger
	if b, err := os.ReadFile(path); err == nil {
		_ = json.Unmarshal(b, &l)
	}
	return l
}
