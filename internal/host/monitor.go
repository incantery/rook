package host

import (
	"context"
	"encoding/json"
	"net/http"
	"path/filepath"
	"runtime"
	"strings"
	"time"

	"github.com/incantery/rook/internal/config"
)

// The monitor samples what rook costs the machine, on the process table the
// fg sensor already pays for (procsample.go). Two things drove the shape:
//
//   - RSS is the wrong leak detector. Real leaks here are small — a map that
//     never evicts is kilobytes against a WebContent process holding half a
//     gig — so an aggregate hides them under GC noise. Map cardinality is the
//     gauge that names the leak instead of burying it.
//   - The interesting memory is not rook's. A coder session runs ~500-600MB;
//     rook-host runs ~25MB. What the user wants to see is the agents.
//
// Series are stored in the Prometheus data model (metric + labels + float +
// timestamp) rather than as a struct-per-sample, so shipping them to the
// Loki/Grafana pipeline agentmon already feeds is a formatting change, not a
// rewrite. Nothing here crosses a wire today.
const (
	monitorTick  = 30 * time.Second
	monitorPrune = time.Hour // how often the retention sweeper runs
)

// sample is one gauge reading. Labels stay deliberately low-cardinality:
// per-session labels would mint a new series per window and grow the table
// without bound — the live per-session view is /sessions, not this.
type sample struct {
	Metric string            `json:"metric"`
	Labels map[string]string `json:"labels,omitempty"`
	Value  float64           `json:"value"`
}

func (s sample) labelJSON() string {
	if len(s.Labels) == 0 {
		return ""
	}
	b, err := json.Marshal(s.Labels) // Marshal sorts map keys — stable series identity
	if err != nil {
		return ""
	}
	return string(b)
}

// storedSample is a sample read back with its timestamp.
type storedSample struct {
	At     time.Time         `json:"at"`
	Metric string            `json:"metric"`
	Labels map[string]string `json:"labels,omitempty"`
	Value  float64           `json:"value"`
}

// roleOf buckets a process into what rook calls it, "" for everything else
// on the machine. WebKit content/GPU/networking processes are XPC-launched
// with ppid 1 and carry identical argv to every other app's, so they cannot
// be attributed to their owning app from the process table — this counts all
// of them. That is sound here because rook is the only WebKit consumer on a
// dev box, and the orphan signal does not need attribution anyway: the
// webkit count staying high while the app count drops to zero is the leak,
// and it reads off a chart without ever naming a pid.
func roleOf(comm, coder string) string {
	if strings.Contains(comm, "WebKit.framework") {
		return "webkit"
	}
	base := filepath.Base(comm)
	switch base {
	case "rook":
		return "app"
	case "rook-host":
		return "host"
	case "rook-agent":
		return "agent"
	}
	if coder != "" && base == coder {
		return "coder"
	}
	return ""
}

// mapSizes reports the host's long-lived maps. These are the leak gauges:
// sessions/claims/binds/drafts should track live windows and fall back to
// zero, cwd_cache should track live shells. Any of them climbing monotonic
// while the others sawtooth is a missing delete, named.
func (h *Host) mapSizes() map[string]int {
	h.mu.Lock()
	sessions := len(h.sessions)
	h.mu.Unlock()
	h.cwdMu.Lock()
	cwd := len(h.cwdCache)
	h.cwdMu.Unlock()
	h.bindMu.Lock()
	claims, binds := len(h.claims), len(h.binds)
	h.bindMu.Unlock()
	h.draftMu.Lock()
	drafts := len(h.drafts)
	h.draftMu.Unlock()
	return map[string]int{
		"sessions":  sessions,
		"cwd_cache": cwd,
		"claims":    claims,
		"binds":     binds,
		"drafts":    drafts,
	}
}

// gather takes one reading of everything.
func (h *Host) gather() []sample {
	tbl := h.pt.current()
	coder := config.Load().Coder

	type agg struct {
		rss int64
		cpu float64
		n   int
	}
	byRole := map[string]*agg{}
	for _, p := range tbl {
		role := roleOf(p.Comm, coder)
		if role == "" {
			continue
		}
		a := byRole[role]
		if a == nil {
			a = &agg{}
			byRole[role] = a
		}
		a.rss += p.RSS
		a.cpu += p.CPU
		a.n++
	}

	out := make([]sample, 0, 24)
	for role, a := range byRole {
		l := map[string]string{"role": role}
		out = append(out,
			sample{"rook_process_rss_bytes", l, float64(a.rss)},
			sample{"rook_process_cpu_percent", l, a.cpu},
			sample{"rook_process_count", l, float64(a.n)},
		)
	}

	var ms runtime.MemStats
	runtime.ReadMemStats(&ms) // stops the world; negligible at this cadence
	out = append(out,
		sample{"rook_host_goroutines", nil, float64(runtime.NumGoroutine())},
		sample{"rook_host_heap_bytes", nil, float64(ms.HeapAlloc)},
		sample{"rook_host_heap_objects", nil, float64(ms.HeapObjects)},
		sample{"rook_host_sys_bytes", nil, float64(ms.Sys)},
	)
	for name, n := range h.mapSizes() {
		out = append(out, sample{"rook_map_entries", map[string]string{"map": name}, float64(n)})
	}
	return out
}

// WatchMonitor runs the sampler; call it once, in a goroutine, after the
// host is listening. Same posture as WatchUsage — it never fails loudly,
// because diagnostics must not be able to take the daemon down.
func (h *Host) WatchMonitor(ctx context.Context) {
	t := time.NewTicker(monitorTick)
	defer t.Stop()
	lastPrune := time.Now()
	for {
		select {
		case <-ctx.Done():
			return
		case now := <-t.C:
			h.reg.addSamples(now, h.gather())
			if now.Sub(lastPrune) >= monitorPrune {
				h.reg.pruneSamples(now.Add(-sampleRetention))
				lastPrune = now
			}
		}
	}
}

// handleRuntime is GET /runtime: live gauges, or ?since=6h for the stored
// series behind the detail panel.
func (h *Host) handleRuntime(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if q := r.URL.Query().Get("since"); q != "" {
		d, err := time.ParseDuration(q)
		if err != nil || d <= 0 {
			http.Error(w, "bad since", http.StatusBadRequest)
			return
		}
		if d > sampleRetention {
			d = sampleRetention
		}
		writeJSON(w, map[string]any{"series": h.reg.samplesSince(time.Now().Add(-d))})
		return
	}
	writeJSON(w, map[string]any{"at": time.Now(), "gauges": h.gather()})
}
