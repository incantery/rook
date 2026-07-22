package host

import (
	"path/filepath"
	"sort"
)

// baseComm shortens a comm to its basename (darwin ps reports the full path).
func baseComm(comm string) string { return filepath.Base(comm) }

// Workload attribution: separating what rook costs from what the user's own
// processes cost. The host spawned every session's shell, so the process tree
// answers it — a process descended from a session's shell (the shell included)
// is the user's workload: the migration, the build, the coder they ran by hand.
// Tree beats name: a coder binary running INSIDE a shell is workload, while the
// same binary spawned by rook (the drafter) stays in rook's ledger.
//
// The aggregate feeds the stored series (one low-cardinality "workload" role —
// per-session labels would mint a series per window, monitor.go's rule); the
// per-session split is live-only, served by /runtime?detail=1 for the monitor
// pane.

// workloadProc is one process in a session's subtree, for the live top list.
type workloadProc struct {
	PID  int     `json:"pid"`
	Comm string  `json:"comm"` // basename, not the full path
	RSS  int64   `json:"rss"`
	CPU  float64 `json:"cpu"`
}

// sessionLoad is one session's live footprint: the shell and everything under it.
type sessionLoad struct {
	ID        string         `json:"id"`
	Name      string         `json:"name"`
	Workspace string         `json:"workspace"`
	RSS       int64          `json:"rss"`
	CPU       float64        `json:"cpu"`
	Procs     []workloadProc `json:"procs"`
}

// maxLoadProcs caps the per-session top list — the pane wants the story
// ("the migration is the 4G"), not the whole tree.
const maxLoadProcs = 8

// childIndex inverts the process table into parent -> children.
func childIndex(tbl map[int]procSnap) map[int][]int {
	kids := make(map[int][]int, len(tbl))
	for pid, p := range tbl {
		kids[p.PPID] = append(kids[p.PPID], pid)
	}
	return kids
}

// descendants returns the pids of roots plus everything below them.
func descendants(tbl map[int]procSnap, kids map[int][]int, roots ...int) map[int]bool {
	out := make(map[int]bool, 32)
	stack := append([]int(nil), roots...)
	for len(stack) > 0 {
		pid := stack[len(stack)-1]
		stack = stack[:len(stack)-1]
		if out[pid] {
			continue
		}
		if _, live := tbl[pid]; !live {
			continue
		}
		out[pid] = true
		stack = append(stack, kids[pid]...)
	}
	return out
}

// shellRoots snapshots the live sessions' shell pids (with their session, for
// the per-session view).
func (h *Host) shellRoots() map[int]*session {
	h.mu.Lock()
	defer h.mu.Unlock()
	roots := make(map[int]*session, len(h.sessions))
	for _, s := range h.sessions {
		if s.cmd != nil && s.cmd.Process != nil {
			roots[s.cmd.Process.Pid] = s
		}
	}
	return roots
}

// workloadPids is the set of every process in any session's subtree.
func (h *Host) workloadPids(tbl map[int]procSnap) map[int]bool {
	roots := h.shellRoots()
	pids := make([]int, 0, len(roots))
	for pid := range roots {
		pids = append(pids, pid)
	}
	return descendants(tbl, childIndex(tbl), pids...)
}

// sessionLoads is the live per-session breakdown: each session's subtree
// summed, with its top processes by RSS. Ordered by session id (creation
// order) so rows don't reshuffle under the reader every poll.
func (h *Host) sessionLoads() []sessionLoad {
	tbl := h.pt.current()
	kids := childIndex(tbl)
	roots := h.shellRoots()

	out := make([]sessionLoad, 0, len(roots))
	for pid, s := range roots {
		sub := descendants(tbl, kids, pid)
		load := sessionLoad{ID: s.info.ID, Name: s.info.Name, Workspace: s.info.Workspace}
		for p := range sub {
			row := tbl[p]
			load.RSS += row.RSS
			load.CPU += row.CPU
			load.Procs = append(load.Procs, workloadProc{
				PID: row.PID, Comm: baseComm(row.Comm), RSS: row.RSS, CPU: row.CPU,
			})
		}
		sort.Slice(load.Procs, func(i, j int) bool { return load.Procs[i].RSS > load.Procs[j].RSS })
		if len(load.Procs) > maxLoadProcs {
			load.Procs = load.Procs[:maxLoadProcs]
		}
		out = append(out, load)
	}
	sort.Slice(out, func(i, j int) bool { return sessionNum(out[i].ID) < sessionNum(out[j].ID) })
	return out
}

// sessionNum extracts the numeric part of a session id ("s12" -> 12) for a
// stable creation-order sort; malformed ids sort last.
func sessionNum(id string) int {
	n := 0
	ok := false
	for i := 1; i < len(id); i++ {
		c := id[i]
		if c < '0' || c > '9' {
			return 1 << 30
		}
		n = n*10 + int(c-'0')
		ok = true
	}
	if !ok {
		return 1 << 30
	}
	return n
}
