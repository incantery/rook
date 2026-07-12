package host

import (
	"context"
	"encoding/json"
	"log"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"sync"
	"time"
)

// usageMon tracks Claude subscription limits by probing `claude -p /usage`
// (headless: zero tokens, zero cost, ~1s) and scraping the "N% used ·
// resets …" lines. The cadence is cost-weighted: agentwatch already knows
// each session's raw-inference cost, so accumulated cost deltas — what the
// burn would cost per token — decide when the answer is stale. Heavy use
// re-probes within minutes; an idle machine probes hourly.
//
// The probe runs from its own directory (usageProbeDir) because claude -p
// drops a transcript stub in ~/.claude/projects for every run — agentwatch
// filters that project out (apply), and the stub is deleted after parsing.

const (
	usageTick     = 30 * time.Second // burn sampling, not probing
	usageMinGap   = 2 * time.Minute  // probe rate floor under heavy burn
	usageMaxStale = time.Hour        // probe even when nothing is burning
	usageBurnUSD  = 0.25             // raw-inference $ that makes the number stale
	usageCooldown = 10 * time.Minute // after a failed probe
)

// UsageWindow is one "Current …: N% used · resets …" line, label kept
// verbatim (Anthropic renames windows; we don't hardcode them).
type UsageWindow struct {
	Label  string `json:"label"`
	Pct    int    `json:"pct"`
	Resets string `json:"resets"`
}

type UsageSnapshot struct {
	Windows    []UsageWindow `json:"windows"`
	CapturedAt time.Time     `json:"capturedAt"`
}

type usageMon struct {
	mu        sync.Mutex
	snap      *UsageSnapshot
	lastProbe time.Time          // last successful probe
	cooldown  time.Time          // no probes before this
	burn      float64            // raw-inference $ accumulated since lastProbe
	perSess   map[string]float64 // sessionID → last seen cumulative cost
}

func newUsageMon() *usageMon {
	return &usageMon{perSess: make(map[string]float64)}
}

// accumulate folds the latest agentwatch costs into the burn counter and
// returns the delta it added — the caller persists that into the daily
// costs ledger. Deltas are per-session and monotonic; a session first seen
// mid-flight is baselined, not counted (its past burn predates our last
// probe's answer, and predates this host's ledger watch).
func (m *usageMon) accumulate(states []*AgentStatus) float64 {
	m.mu.Lock()
	defer m.mu.Unlock()
	var delta float64
	live := make(map[string]bool, len(states))
	for _, s := range states {
		live[s.SessionID] = true
		if prev, seen := m.perSess[s.SessionID]; seen && s.CostUSD > prev {
			delta += s.CostUSD - prev
		}
		m.perSess[s.SessionID] = s.CostUSD
	}
	for id := range m.perSess {
		if !live[id] {
			delete(m.perSess, id)
		}
	}
	m.burn += delta
	return delta
}

// due says whether the cached answer is stale enough to spend a probe on.
func (m *usageMon) due(now time.Time) bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	if now.Before(m.cooldown) {
		return false
	}
	if m.snap == nil {
		return true
	}
	if now.Sub(m.lastProbe) >= usageMaxStale {
		return true
	}
	return m.burn >= usageBurnUSD
}

func (m *usageMon) current() UsageSnapshot {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.snap == nil {
		return UsageSnapshot{Windows: []UsageWindow{}}
	}
	return *m.snap
}

// WatchUsage runs the usage monitor; call it once, in a goroutine, after
// the host is listening. Absent claude binary just means the feature is
// off — same posture as agentmon.
func (h *Host) WatchUsage(ctx context.Context) {
	t := time.NewTicker(usageTick)
	defer t.Stop()
	for first := true; ; first = false {
		if !first {
			select {
			case <-ctx.Done():
				return
			case <-t.C:
			}
		}
		// first iteration runs immediately: a fresh start should have
		// usage on screen in seconds, not after a tick
		now := time.Now()
		if delta := h.um.accumulate(h.aw.snapshot()); delta > 0 {
			// one shared sampler: the same deltas that pace the usage
			// probes are the durable daily cost ledger
			h.reg.addDailyCost(now.Format("2006-01-02"), delta)
		}
		if h.um.due(now) {
			h.um.probe(ctx)
		}
	}
}

// handleCosts is GET /costs: what claude usage would have cost on API
// billing — the number the subscription absorbs. today/week come from the
// daily ledger (host-observed: burn while the host is down is not seen);
// live is the running total per workspace across live transcript sessions.
func (h *Host) handleCosts(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	now := time.Now()
	midnight := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, now.Location())
	drafter, _ := h.reg.spendSince(midnight)
	type wsCost struct {
		Workspace string  `json:"workspace"` // "" = not in a rook window
		USD       float64 `json:"usd"`
	}
	perWS := make(map[string]float64)
	for _, st := range h.aw.snapshot() {
		if st.CostUSD <= 0 {
			continue
		}
		ws := ""
		if s := h.pairedSession(st.SessionID, false); s != nil {
			ws = s.info.Workspace
		}
		perWS[ws] += st.CostUSD
	}
	live := []wsCost{}
	for ws, usd := range perWS {
		live = append(live, wsCost{ws, usd})
	}
	sort.Slice(live, func(i, j int) bool { return live[i].USD > live[j].USD })
	writeJSON(w, map[string]any{
		"todayUsd":        h.reg.costSince(now.Format("2006-01-02")),
		"weekUsd":         h.reg.costSince(now.AddDate(0, 0, -6).Format("2006-01-02")),
		"drafterTodayUsd": drafter,
		"live":            live,
	})
}

func (m *usageMon) probe(ctx context.Context) {
	now := time.Now()
	bin := findClaude()
	if bin == "" {
		m.mu.Lock()
		m.cooldown = now.Add(usageCooldown)
		m.mu.Unlock()
		return
	}
	dir := usageProbeDir()
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return
	}
	cctx, cancel := context.WithTimeout(ctx, 60*time.Second)
	defer cancel()
	cmd := exec.CommandContext(cctx, bin, "-p", "/usage", "--output-format", "json")
	cmd.Dir = dir
	out, err := cmd.Output()
	if err != nil {
		log.Printf("usage: probe: %v", err)
		m.fail(now)
		return
	}
	var env struct {
		IsError   bool   `json:"is_error"`
		Result    string `json:"result"`
		SessionID string `json:"session_id"`
	}
	if err := json.Unmarshal(out, &env); err != nil || env.IsError {
		log.Printf("usage: probe envelope: err=%v is_error=%v", err, env.IsError)
		m.fail(now)
		return
	}
	removeProbeTranscript(env.SessionID)
	ws := parseUsageWindows(env.Result)
	if len(ws) == 0 {
		// format drift, or an API-billed account with no windows to report
		log.Printf("usage: no windows parsed (API billing, or /usage format changed)")
		m.fail(now)
		return
	}
	m.mu.Lock()
	m.snap = &UsageSnapshot{Windows: ws, CapturedAt: now}
	m.lastProbe, m.cooldown = now, now.Add(usageMinGap)
	m.burn = 0
	m.mu.Unlock()
}

func (m *usageMon) fail(now time.Time) {
	m.mu.Lock()
	m.cooldown = now.Add(usageCooldown)
	m.mu.Unlock()
}

var usageLine = regexp.MustCompile(`(?m)^Current (.+?): (\d+)% used · resets (.+?)\s*$`)

func parseUsageWindows(text string) []UsageWindow {
	var out []UsageWindow
	for _, match := range usageLine.FindAllStringSubmatch(text, -1) {
		pct, err := strconv.Atoi(match[2])
		if err != nil {
			continue
		}
		out = append(out, UsageWindow{Label: match[1], Pct: pct, Resets: match[3]})
	}
	return out
}

// usageProbeDir is where probes run, so their transcript stubs all land in
// one ~/.claude/projects entry that agentwatch can ignore wholesale.
var usageProbeDir = sync.OnceValue(func() string {
	return filepath.Join(StateDir(), "usage-probe")
})

// removeProbeTranscript deletes the stub the headless probe leaves in
// ~/.claude/projects — it is our own artifact, and at probe cadence the
// stubs would otherwise pile up by the hundreds per day.
func removeProbeTranscript(sessionID string) {
	if sessionID == "" {
		return
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return
	}
	matches, _ := filepath.Glob(filepath.Join(home, ".claude", "projects", "*", sessionID+".jsonl"))
	for _, p := range matches {
		os.Remove(p)
	}
}

// findClaude resolves the claude CLI the same way findAgentmon resolves
// agentmon: PATH first, then the conventional install spots.
func findClaude() string {
	if p, err := exec.LookPath("claude"); err == nil {
		return p
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	for _, p := range []string{
		filepath.Join(home, ".claude", "local", "claude"),
		filepath.Join(home, ".local", "bin", "claude"),
		"/opt/homebrew/bin/claude",
		"/usr/local/bin/claude",
	} {
		if st, err := os.Stat(p); err == nil && st.Mode()&0o111 != 0 {
			return p
		}
	}
	return ""
}
