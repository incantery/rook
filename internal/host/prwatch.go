package host

import (
	"context"
	"strings"
	"sync"
	"time"

	"github.com/incantery/rook/internal/config"
	"github.com/incantery/rook/sdk/provider"
)

// PR watching closes the loop after issue work (issue #3): the host polls
// PR state for every worktree workspace — the PR is resolved from the
// branch, so this works whether or not the tree carries issue provenance —
// and the workspace list carries the answer. Merged is the signal the
// cleanup nudge hangs off. READ, NEVER MIRROR: this map is the only state,
// gone with the process.
//
// The answer comes from the github PROVIDER (pulls.status), the same
// process the issue queue asks — one gh, one lifecycle, one place the
// code host is reached from.

const (
	prTick = 60 * time.Second
	// prTimeout bounds one branch's lookup. The poll is serial across
	// workspaces (the provider takes one request at a time), so this is
	// also the per-workspace share of a tick.
	prTimeout = 15 * time.Second
)

// PRSnapshot is one worktree's close-the-loop picture. State "none" means
// checked and no PR exists — distinct from absent (unknown: gh missing,
// network down, non-GitHub remote), where no snapshot is stored at all and
// the frontend shows nothing.
type PRSnapshot struct {
	State  string `json:"state"` // none | open | merged | closed
	Number int    `json:"number,omitempty"`
	URL    string `json:"url,omitempty"`
	// Conflicts: the open PR can't merge as-is (gh says CONFLICTING).
	// Strict equality on the gh answer = fail open — UNKNOWN, empty, or a
	// gh too old to report mergeability never reads as conflicted.
	Conflicts bool `json:"conflicts,omitempty"`
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
		// workflow reconciliation rides the poll: a running stage whose
		// window died must not spin forever
		h.reconcileStage(ws.Name)
		if gitInfo(ws.Root) == nil {
			continue // checkout gone or broken; keep any last-known snapshot
		}
		pr, err := h.pullStatus(ws.Root, ws.Branch)
		if err != nil {
			// Unknown is not "none": gh missing, offline, a non-GitHub
			// remote, or no provider installed. Say nothing rather than
			// something wrong — the last-known snapshot (if any) stands.
			continue
		}
		snap := PRSnapshot{State: "none", CheckedAt: time.Now()}
		if pr.Found {
			snap.State = strings.ToLower(pr.State)
			snap.Number = pr.Number
			snap.URL = pr.URL
			snap.Conflicts = snap.State == "open" && pr.Mergeable == "CONFLICTING"
		}
		// Unknown risk reads as 0 here — this feeds a nudge, not the
		// deletion guard, which re-derives risk itself at delete time.
		snap.Dirty, snap.Ahead, _ = worktreeRisk(ws.Root, ws.Branch)
		prev := h.prm.get(ws.Name)
		h.prm.set(ws.Name, snap)
		// The staged-workflow trigger: coding is done when the PR appears.
		// OBSERVED transition only — after a restart prm is empty, so
		// already-open PRs never mass-trigger on upgrade. (A PR opened
		// while the host was down never auto-starts; accepted.)
		if prev != nil && prev.State == "none" && snap.State == "open" {
			go h.maybeStartWorkflow(ws)
		}
	}
	h.prm.keepOnly(seen)
}

// pullStatus asks the github provider about one branch. An error here is
// always "unknown", never "no PR" — pullsStatus reports the absence of a
// PR as a result, so anything that arrives as an error genuinely means
// this device could not look.
func (h *Host) pullStatus(root, branch string) (provider.PullsStatusResult, error) {
	ctx, cancel := context.WithTimeout(h.ctx, prTimeout)
	defer cancel()
	var res provider.PullsStatusResult
	err := providerClient("github", config.Load().Providers["github"]).
		Call(ctx, provider.OpPullsStatus, provider.PullsStatusParams{Root: root, Branch: branch}, &res)
	return res, err
}
