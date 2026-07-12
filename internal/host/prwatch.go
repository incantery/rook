package host

import (
	"context"
	"strings"
	"sync"
	"time"

	"github.com/incantery/rook/internal/tracker"
)

// PR watching closes the loop after issue work (issue #3): the host polls
// PR state for every worktree workspace — the PR is resolved from the
// branch, so this works whether or not the tree carries issue provenance —
// and the workspace list carries the answer. Merged is the signal the
// cleanup nudge hangs off. READ, NEVER MIRROR: this map is the only state,
// gone with the process.

const prTick = 60 * time.Second

// PRSnapshot is one worktree's close-the-loop picture. State "none" means
// checked and no PR exists — distinct from absent (unknown: gh missing,
// network down, non-GitHub remote), where no snapshot is stored at all and
// the frontend shows nothing.
type PRSnapshot struct {
	State  string `json:"state"` // none | open | merged | closed
	Number int    `json:"number,omitempty"`
	URL    string `json:"url,omitempty"`
	// Ahead/Dirty come from worktreeRisk: commits only this branch has and
	// uncommitted files — "work exists with no PR yet" is the nudge to open
	// one.
	Ahead     int       `json:"ahead,omitempty"`
	Dirty     int       `json:"dirty,omitempty"`
	CheckedAt time.Time `json:"checkedAt"`
}

type prMon struct {
	mu    sync.Mutex
	snaps map[string]PRSnapshot
}

func newPRMon() *prMon { return &prMon{snaps: map[string]PRSnapshot{}} }

func (m *prMon) get(name string) *PRSnapshot {
	m.mu.Lock()
	defer m.mu.Unlock()
	if s, ok := m.snaps[name]; ok {
		return &s
	}
	return nil
}

func (m *prMon) set(name string, s PRSnapshot) {
	m.mu.Lock()
	m.snaps[name] = s
	m.mu.Unlock()
}

func (m *prMon) forget(name string) {
	m.mu.Lock()
	delete(m.snaps, name)
	m.mu.Unlock()
}

// keepOnly drops snapshots for workspaces that no longer exist.
func (m *prMon) keepOnly(names map[string]bool) {
	m.mu.Lock()
	for name := range m.snaps {
		if !names[name] {
			delete(m.snaps, name)
		}
	}
	m.mu.Unlock()
}

// WatchPRs runs the PR-state poller; call it once, in a goroutine, after
// the host is listening. Absent gh just means the feature is off — same
// posture as agentmon and the usage monitor.
func (h *Host) WatchPRs(ctx context.Context) {
	t := time.NewTicker(prTick)
	defer t.Stop()
	for first := true; ; first = false {
		if !first {
			select {
			case <-ctx.Done():
				return
			case <-t.C:
			}
		}
		h.pollPRs()
	}
}

func (h *Host) pollPRs() {
	seen := map[string]bool{}
	for _, ws := range h.reg.list() {
		if ws.WorktreeOf == "" || ws.Branch == "" || ws.Root == "" {
			continue
		}
		seen[ws.Name] = true
		if gitInfo(ws.Root) == nil {
			continue // checkout gone or broken; keep any last-known snapshot
		}
		pr, err := tracker.PRStatus(ws.Root, ws.Branch)
		if err != nil {
			// Unknown is not "none": gh missing, offline, or a non-GitHub
			// remote. Say nothing rather than something wrong — the
			// last-known snapshot (if any) stands.
			continue
		}
		snap := PRSnapshot{State: "none", CheckedAt: time.Now()}
		if pr != nil {
			snap.State = strings.ToLower(pr.State)
			snap.Number = pr.Number
			snap.URL = pr.URL
		}
		// Unknown risk reads as 0 here — this feeds a nudge, not the
		// deletion guard, which re-derives risk itself at delete time.
		snap.Dirty, snap.Ahead, _ = worktreeRisk(ws.Root, ws.Branch)
		h.prm.set(ws.Name, snap)
	}
	h.prm.keepOnly(seen)
}
