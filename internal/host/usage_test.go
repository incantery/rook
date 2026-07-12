package host

import (
	"testing"
	"time"
)

// Verbatim from a real `claude -p /usage` on 2026-07-12 — the parser's
// ground truth.
const usageSample = `You are currently using your subscription to power your Claude Code usage

Current session: 3% used · resets Jul 12 at 1:49pm (America/New_York)
Current week (all models): 19% used · resets Jul 18 at 7:59am (America/New_York)
Current week (Fable): 36% used · resets Jul 18 at 7:59am (America/New_York)

What's contributing to your limits usage?
Approximate, based on local sessions on this machine — does not include other devices or claude.ai.

Last 24h · 1239 requests · 14 sessions
  75% of your usage came from subagent-heavy sessions`

func TestParseUsageWindows(t *testing.T) {
	ws := parseUsageWindows(usageSample)
	if len(ws) != 3 {
		t.Fatalf("windows = %d, want 3: %+v", len(ws), ws)
	}
	want := []UsageWindow{
		{Label: "session", Pct: 3, Resets: "Jul 12 at 1:49pm (America/New_York)"},
		{Label: "week (all models)", Pct: 19, Resets: "Jul 18 at 7:59am (America/New_York)"},
		{Label: "week (Fable)", Pct: 36, Resets: "Jul 18 at 7:59am (America/New_York)"},
	}
	for i, w := range want {
		if ws[i] != w {
			t.Errorf("window %d = %+v, want %+v", i, ws[i], w)
		}
	}
}

func TestParseUsageWindowsGarbage(t *testing.T) {
	if ws := parseUsageWindows("API billing: no windows here.\nCurrent mood: fine"); len(ws) != 0 {
		t.Fatalf("parsed windows from garbage: %+v", ws)
	}
}

func TestUsageBurnAccumulation(t *testing.T) {
	m := newUsageMon()

	// First sight baselines — a session already $2 deep is not fresh burn.
	m.accumulate([]*AgentStatus{{SessionID: "a", CostUSD: 2.00}})
	if m.burn != 0 {
		t.Fatalf("baseline counted as burn: %v", m.burn)
	}
	// Growth counts.
	m.accumulate([]*AgentStatus{{SessionID: "a", CostUSD: 2.10}})
	m.accumulate([]*AgentStatus{{SessionID: "a", CostUSD: 2.30}})
	if m.burn < 0.299 || m.burn > 0.301 {
		t.Fatalf("burn = %v, want 0.30", m.burn)
	}
	// A dead session is pruned; its return (host restart) re-baselines.
	m.accumulate(nil)
	m.accumulate([]*AgentStatus{{SessionID: "a", CostUSD: 5.00}})
	if m.burn > 0.301 {
		t.Fatalf("re-baselined session counted as burn: %v", m.burn)
	}
}

func TestUsageDueCadence(t *testing.T) {
	m := newUsageMon()
	now := time.Now()

	// No snapshot yet → due immediately.
	if !m.due(now) {
		t.Fatal("fresh monitor should be due")
	}

	// Fresh snapshot, no burn → not due.
	m.snap = &UsageSnapshot{CapturedAt: now}
	m.lastProbe, m.cooldown = now, now.Add(usageMinGap)
	if m.due(now.Add(time.Minute)) {
		t.Fatal("due 1min after a probe with no burn")
	}

	// Burn crosses the threshold → due, but never inside the min gap.
	m.burn = usageBurnUSD + 0.01
	if m.due(now.Add(usageMinGap - time.Second)) {
		t.Fatal("due inside the min gap despite burn")
	}
	if !m.due(now.Add(usageMinGap + time.Second)) {
		t.Fatal("not due after min gap with burn over threshold")
	}

	// No burn at all → still due once the answer is an hour old.
	m.burn = 0
	if m.due(now.Add(30 * time.Minute)) {
		t.Fatal("due at 30min with no burn")
	}
	if !m.due(now.Add(usageMaxStale + time.Second)) {
		t.Fatal("not due past max staleness")
	}

	// A failed probe's cooldown suppresses even a stale answer.
	m.cooldown = now.Add(2 * time.Hour)
	if m.due(now.Add(90 * time.Minute)) {
		t.Fatal("due during failure cooldown")
	}
}
