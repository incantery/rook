package usagefile

import (
	"path/filepath"
	"testing"
	"time"
)

const report = `You are currently using your subscription to power your Claude Code usage

Current session: 19% used · resets Aug 11 at 1:50pm (America/New_York)
Current week (all models): 17% used · resets Aug 15 at 7:59am (America/New_York)
Current week (Fable): 31% used · resets Aug 15 at 7:59am (America/New_York)

What's contributing to your limits usage?
`

func TestParseTheCLIReport(t *testing.T) {
	now := time.Now()
	u, ok := Parse(report, now)
	if !ok {
		t.Fatal("a subscription report must parse")
	}
	if u.SessionPct != 19 || u.WeekAllPct != 17 || u.WeekModelPct != 31 {
		t.Fatalf("percentages mangled: %+v", u)
	}
	if u.WeekModelName != "Fable" {
		t.Fatalf("model name: %q", u.WeekModelName)
	}
	if u.SessionResets != "Aug 11 at 1:50pm" {
		t.Fatalf("session resets: %q", u.SessionResets)
	}
	if _, ok := Parse("some unrelated output", now); ok {
		t.Fatal("a non-usage report must be a miss, not zeros")
	}
}

func TestWriteReadFreshness(t *testing.T) {
	path := filepath.Join(t.TempDir(), "usage.json")
	now := time.Now()
	u, _ := Parse(report, now)
	if err := Write(path, u); err != nil {
		t.Fatal(err)
	}
	got := Read(path, 15*time.Minute, now)
	if got == nil || got.SessionPct != 19 {
		t.Fatalf("fresh read failed: %+v", got)
	}
	if Read(path, 15*time.Minute, now.Add(time.Hour)) != nil {
		t.Fatal("a dead collector's last words must age out")
	}
}
