package parsebench

import (
	"os"
	"runtime"
	"sync"
	"testing"
	"time"

	"github.com/charmbracelet/x/vt"
)

// The scale question: not "faster than ghostty on one terminal" but "cheapest
// to run N background agent sessions at once". That workload is dominated by
// aggregate throughput (does it scale across cores?) and — the real killer —
// GC pressure: an allocating grid model creates stop-the-world pauses that
// stall EVERY session and the UI, and it gets worse with N. A zero-allocation
// grid gives the collector nothing to do regardless of N.
//
// This runs N emulators concurrently, each parsing ~4 MiB, and reports
// aggregate MB/s, bytes allocated, GC count, and total pause. Run with -v:
//
//	go test -run TestScale -v ./spike/parsebench
func TestScale(t *testing.T) {
	// ~4 MiB of git output per session
	data := make([]byte, 0, 4<<20)
	one, _ := os.ReadFile("../corpus/git-graph.raw")
	for len(data) < 4<<20 {
		data = append(data, one...)
	}

	run := func(name string, n int, work func([]byte)) {
		runtime.GC()
		var before runtime.MemStats
		runtime.ReadMemStats(&before)

		var wg sync.WaitGroup
		t0 := time.Now()
		for range n {
			wg.Add(1)
			go func() {
				defer wg.Done()
				work(data)
			}()
		}
		wg.Wait()
		dt := time.Since(t0)

		var after runtime.MemStats
		runtime.ReadMemStats(&after)
		aggMBs := float64(n*len(data)) / 1e6 / dt.Seconds()
		allocMB := float64(after.TotalAlloc-before.TotalAlloc) / 1e6
		gc := after.NumGC - before.NumGC
		pauseMs := float64(after.PauseTotalNs-before.PauseTotalNs) / 1e6
		t.Logf("%-10s n=%2d  %7.0f MB/s agg  %8.0f MB alloc  %3d GC  %7.1f ms STW pause",
			name, n, aggMBs, allocMB, gc, pauseMs)
	}

	bulkWork := func(d []byte) { newBulk(120, 40).Write(d) }
	xvtWork := func(d []byte) { e := vt.NewEmulator(120, 40); _, _ = e.Write(d); _ = e.Close() }

	for _, n := range []int{1, 20} {
		run("bulk", n, bulkWork)
	}
	for _, n := range []int{1, 20} {
		run("x/vt", n, xvtWork)
	}
}
