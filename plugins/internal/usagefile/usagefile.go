// Package usagefile carries account-level Claude usage from the one
// process that collects it (the claude plugin, shelling out to
// `claude /usage -p` every few minutes) to the processes that fold
// status snapshots (the link and cloud bridges). Same discipline as
// nowfile: ephemeral, latest-wins, atomic rename, staleness decided at
// the reader — a collector that died must not have its last words
// mistaken for the present.
package usagefile

import (
	"encoding/json"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

// Usage is the parsed shape of the CLI's report: subscription rate-limit
// percentages, per window. Mode says which billing world the account
// lives in — "subscription" carries the percentages; a future "api"
// mode will carry token economics instead.
type Usage struct {
	Mode string `json:"mode"` // "subscription"
	// The 5-hour session block.
	SessionPct    int    `json:"sessionPct"`
	SessionResets string `json:"sessionResets,omitempty"`
	// The weekly all-models window.
	WeekAllPct    int    `json:"weekAllPct"`
	WeekAllResets string `json:"weekAllResets,omitempty"`
	// The weekly per-model window (the CLI names the model, e.g. "Fable").
	WeekModelName   string    `json:"weekModelName,omitempty"`
	WeekModelPct    int       `json:"weekModelPct"`
	WeekModelResets string    `json:"weekModelResets,omitempty"`
	At              time.Time `json:"at"`
}

// DefaultPath is beside the now-file: rook's state home.
func DefaultPath() string {
	if x := os.Getenv("XDG_STATE_HOME"); x != "" {
		return filepath.Join(x, "rook", "usage.json")
	}
	home, err := os.UserHomeDir()
	if err != nil || home == "" {
		return ""
	}
	return filepath.Join(home, ".local", "state", "rook", "usage.json")
}

var (
	reSession   = regexp.MustCompile(`Current session:\s*(\d+)% used(?: · resets ([^\n(]+))?`)
	reWeekAll   = regexp.MustCompile(`Current week \(all models\):\s*(\d+)% used(?: · resets ([^\n(]+))?`)
	reWeekModel = regexp.MustCompile(`Current week \(([^)]+)\):\s*(\d+)% used(?: · resets ([^\n(]+))?`)
)

// Parse reads `claude /usage -p` output. Absence of the subscription
// banner (an API-billed account prints a different report) or of the
// session line is an honest miss, not an error — the caller simply has
// no usage to publish this tick.
func Parse(out string, now time.Time) (Usage, bool) {
	u := Usage{Mode: "subscription", At: now}
	m := reSession.FindStringSubmatch(out)
	if m == nil {
		return Usage{}, false
	}
	u.SessionPct = atoi(m[1])
	u.SessionResets = strings.TrimSpace(m[2])
	if m := reWeekAll.FindStringSubmatch(out); m != nil {
		u.WeekAllPct = atoi(m[1])
		u.WeekAllResets = strings.TrimSpace(m[2])
	}
	// The per-model line is any "Current week (X)" that is NOT the
	// all-models one; the CLI prints the model's display name.
	for _, m := range reWeekModel.FindAllStringSubmatch(out, -1) {
		if strings.EqualFold(m[1], "all models") {
			continue
		}
		u.WeekModelName = m[1]
		u.WeekModelPct = atoi(m[2])
		u.WeekModelResets = strings.TrimSpace(m[3])
		break
	}
	return u, true
}

func atoi(s string) int {
	n := 0
	for _, c := range s {
		if c < '0' || c > '9' {
			return n
		}
		n = n*10 + int(c-'0')
	}
	return n
}

// Write replaces the file, atomically.
func Write(path string, u Usage) error {
	if path == "" {
		return nil
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	b, err := json.Marshal(u)
	if err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, b, 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

// Read returns the usage when fresh, or nil: the collector refreshes
// every ~5 minutes, so anything older than maxAge is a dead collector's
// last words.
func Read(path string, maxAge time.Duration, now time.Time) *Usage {
	if path == "" {
		return nil
	}
	b, err := os.ReadFile(path)
	if err != nil {
		return nil
	}
	var u Usage
	if json.Unmarshal(b, &u) != nil || u.Mode == "" || now.Sub(u.At) > maxAge {
		return nil
	}
	return &u
}
