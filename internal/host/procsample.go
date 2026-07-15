package host

import (
	"os"
	"os/exec"
	"strconv"
	"strings"
	"sync"
	"time"
)

// procTTL matches the fastest poller hitting /attention (2s): inside one
// tick every caller reads the same table.
const procTTL = 2 * time.Second

// procSnap is one row of the process table.
type procSnap struct {
	PID  int
	PPID int
	RSS  int64   // bytes (ps reports KB)
	CPU  float64 // percent of one core
	Comm string  // full path on darwin, short name on linux
}

// procTable is the host's one process sensor. fgOf used to fork `ps` per
// session per call, and three pollers hit /attention every 2-5s — so idle
// cost scaled with window count. One batched `ps -axo` behind a TTL costs
// one fork per tick no matter how many sessions are open, and it carries
// RSS/PPID the per-pid probe never asked for, which is what the monitor
// (monitor.go) samples.
//
// Refresh swaps in a new map rather than mutating the old one, so readers
// holding a previous table stay safe without copying it.
type procTable struct {
	mu    sync.Mutex
	at    time.Time
	byPID map[int]procSnap
}

func newProcTable() *procTable { return &procTable{byPID: map[int]procSnap{}} }

// current returns the table, refreshing it if the TTL has passed. The ps
// fork happens under the lock deliberately: concurrent callers (statusFor
// probes every session at once) queue on it and then all read one sample
// instead of forking a herd.
func (t *procTable) current() map[int]procSnap {
	t.mu.Lock()
	defer t.mu.Unlock()
	if time.Since(t.at) < procTTL && len(t.byPID) > 0 {
		return t.byPID
	}
	tbl, err := sampleProcs()
	if err != nil {
		// a failed sample keeps the stale table: naming a pid slightly late
		// beats blinding the dashboard and the attention router at once
		return t.byPID
	}
	t.byPID, t.at = tbl, time.Now()
	return t.byPID
}

// comm names a pid, "" if it is gone.
func (t *procTable) comm(pid int) string { return t.current()[pid].Comm }

func sampleProcs() (map[int]procSnap, error) {
	out, err := exec.Command(psPath(), "-axo", "pid=,ppid=,rss=,pcpu=,comm=").Output()
	if err != nil {
		return nil, err
	}
	tbl := make(map[int]procSnap, 512)
	for line := range strings.SplitSeq(string(out), "\n") {
		f := strings.Fields(line)
		if len(f) < 5 {
			continue
		}
		pid, err := strconv.Atoi(f[0])
		if err != nil {
			continue
		}
		ppid, _ := strconv.Atoi(f[1])
		rssKB, _ := strconv.ParseInt(f[2], 10, 64)
		cpu, _ := strconv.ParseFloat(f[3], 64)
		// comm is the last column and may contain spaces; rejoining the
		// remainder is lossy only for runs of whitespace inside a path,
		// which every caller here strips to the basename anyway
		tbl[pid] = procSnap{PID: pid, PPID: ppid, RSS: rssKB * 1024, CPU: cpu, Comm: strings.Join(f[4:], " ")}
	}
	return tbl, nil
}

// psPath prefers the absolute path: the daemon may run under launchd's
// minimal environment where PATH lookups are not to be trusted (same
// reasoning as cwd_darwin.go).
func psPath() string {
	if _, err := os.Stat("/bin/ps"); err == nil {
		return "/bin/ps"
	}
	if p, err := exec.LookPath("ps"); err == nil {
		return p
	}
	return "/bin/ps"
}
