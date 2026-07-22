package host

import (
	"os"
	"os/exec"
	"testing"
	"time"
)

// fakeProcs primes the shared process table so gather/sessionLoads read a
// deterministic tree instead of forking ps.
func fakeProcs(h *Host, rows ...procSnap) {
	tbl := make(map[int]procSnap, len(rows))
	for _, r := range rows {
		tbl[r.PID] = r
	}
	h.pt.mu.Lock()
	h.pt.byPID = tbl
	h.pt.at = time.Now()
	h.pt.mu.Unlock()
}

// fakeSession registers a session whose shell "runs" at pid.
func fakeSession(h *Host, id string, pid int) {
	s := &session{
		info: SessionInfo{ID: id, Name: id, Workspace: "t", Created: time.Now()},
		cmd:  &exec.Cmd{Process: &os.Process{Pid: pid}},
	}
	h.mu.Lock()
	h.sessions[id] = s
	h.mu.Unlock()
}

func gaugeValue(t *testing.T, samples []sample, metric, role string) float64 {
	t.Helper()
	for _, s := range samples {
		if s.Metric == metric && s.Labels["role"] == role {
			return s.Value
		}
	}
	return 0
}

// TestWorkloadTreeBeatsName is the attribution rule: everything under a
// session's shell — the shell, the migration, even a coder the user ran by
// hand — is workload; rook's own processes stay in their named roles.
func TestWorkloadTreeBeatsName(t *testing.T) {
	t.Setenv("XDG_DATA_HOME", t.TempDir())
	h := New()

	fakeProcs(h,
		procSnap{PID: 50, PPID: 1, RSS: 25 << 20, CPU: 1, Comm: "/usr/local/bin/rook-host"},
		procSnap{PID: 60, PPID: 1, RSS: 100 << 20, CPU: 2, Comm: "/Applications/rook.app/Contents/MacOS/rook"},
		// session s1: shell -> migration -> worker, plus a hand-run coder
		procSnap{PID: 100, PPID: 50, RSS: 10 << 20, CPU: 0.5, Comm: "/bin/zsh"},
		procSnap{PID: 200, PPID: 100, RSS: 4 << 30, CPU: 90, Comm: "/usr/bin/python3"},
		procSnap{PID: 300, PPID: 200, RSS: 1 << 30, CPU: 40, Comm: "/usr/bin/python3"},
		procSnap{PID: 400, PPID: 100, RSS: 500 << 20, CPU: 10, Comm: "/opt/bin/claude"},
		// a rook-spawned coder OUTSIDE any shell (the drafter): stays "coder"
		procSnap{PID: 500, PPID: 50, RSS: 300 << 20, CPU: 5, Comm: "/opt/bin/claude"},
		// unrelated machine noise: dropped
		procSnap{PID: 600, PPID: 1, RSS: 8 << 30, CPU: 50, Comm: "/Applications/Safari.app/Contents/MacOS/Safari"},
	)
	fakeSession(h, "s1", 100)

	// the config's coder binary is "claude" in tests only if configured; make the
	// name-based role check independent of config by asserting the tree side.
	got := h.gather()

	wantRSS := float64(10<<20 + 4<<30 + 1<<30 + 500<<20)
	if v := gaugeValue(t, got, "rook_process_rss_bytes", "workload"); v != wantRSS {
		t.Fatalf("workload rss = %v, want %v", v, wantRSS)
	}
	if v := gaugeValue(t, got, "rook_process_count", "workload"); v != 4 {
		t.Fatalf("workload count = %v, want 4 (shell+migration+worker+hand-run coder)", v)
	}
	if v := gaugeValue(t, got, "rook_process_rss_bytes", "host"); v != float64(25<<20) {
		t.Fatalf("host rss = %v, want %v", v, float64(25<<20))
	}
	if v := gaugeValue(t, got, "rook_process_rss_bytes", "app"); v != float64(100<<20) {
		t.Fatalf("app rss = %v, want %v", v, float64(100<<20))
	}
	// Safari must not be counted anywhere
	total := 0.0
	for _, s := range got {
		if s.Metric == "rook_process_rss_bytes" {
			total += s.Value
		}
	}
	if total >= float64(8<<30) {
		t.Fatalf("an unrelated process leaked into the gauges (total %v)", total)
	}
}

// TestSessionLoads is the live per-session view: each session's subtree summed,
// top processes by RSS, in creation order.
func TestSessionLoads(t *testing.T) {
	t.Setenv("XDG_DATA_HOME", t.TempDir())
	h := New()

	fakeProcs(h,
		procSnap{PID: 50, PPID: 1, RSS: 1 << 20, CPU: 0, Comm: "rook-host"},
		// s1: shell + migration
		procSnap{PID: 100, PPID: 50, RSS: 10 << 20, CPU: 1, Comm: "/bin/zsh"},
		procSnap{PID: 200, PPID: 100, RSS: 2 << 30, CPU: 80, Comm: "/usr/bin/python3"},
		// s2: just a shell
		procSnap{PID: 110, PPID: 50, RSS: 12 << 20, CPU: 0.5, Comm: "/bin/zsh"},
	)
	fakeSession(h, "s1", 100)
	fakeSession(h, "s2", 110)

	loads := h.sessionLoads()
	if len(loads) != 2 {
		t.Fatalf("got %d sessions, want 2", len(loads))
	}
	if loads[0].ID != "s1" || loads[1].ID != "s2" {
		t.Fatalf("order = %s,%s, want s1,s2 (creation order)", loads[0].ID, loads[1].ID)
	}
	s1 := loads[0]
	if s1.RSS != 10<<20+2<<30 {
		t.Fatalf("s1 rss = %d, want %d", s1.RSS, int64(10<<20+2<<30))
	}
	if len(s1.Procs) != 2 || s1.Procs[0].Comm != "python3" {
		t.Fatalf("s1 top procs = %+v, want python3 first (largest RSS)", s1.Procs)
	}
	if loads[1].RSS != 12<<20 {
		t.Fatalf("s2 rss = %d, want %d", loads[1].RSS, int64(12<<20))
	}
}
