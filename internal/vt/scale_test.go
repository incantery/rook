package vt

import (
	"runtime"
	"sync"
	"testing"
	"time"
)

// TestScale is the scale gate: N emulators parsing concurrently, reporting
// aggregate throughput, bytes allocated, GC count, and total stop-the-world
// pause. The property that must hold is not raw speed but that alloc and GC
// pause stay near zero as N grows — the thing that lets many background
// agent sessions run cheaply. Run with -v to see the table.
//
//	go test -run TestScale -v ./internal/vt
func TestScale(t *testing.T) {
	raw, _ := loadCapture(t, "git-graph")
	data := grow(raw, 4<<20)

	run := func(n int) (allocMB float64, gc uint32, pauseMs float64) {
		// Create the emulators up front, outside the measured window: their
		// fixed footprint (two grids + a preallocated scrollback ring) is a
		// one-time per-session cost, not the thing under test. What must stay
		// near zero is the *parse* allocation — allocation that scales with
		// bytes processed, the x/vt failure mode that GC-thrashes at scale.
		emus := make([]*Emulator, n)
		for i := range emus {
			emus[i] = New(120, 40)
		}
		runtime.GC()
		var before, after runtime.MemStats
		runtime.ReadMemStats(&before)

		var wg sync.WaitGroup
		t0 := time.Now()
		for i := range n {
			wg.Add(1)
			go func() {
				defer wg.Done()
				emus[i].Write(data)
			}()
		}
		wg.Wait()
		dt := time.Since(t0)

		runtime.ReadMemStats(&after)
		allocMB = float64(after.TotalAlloc-before.TotalAlloc) / 1e6
		gc = after.NumGC - before.NumGC
		pauseMs = float64(after.PauseTotalNs-before.PauseTotalNs) / 1e6
		aggMBs := float64(n*len(data)) / 1e6 / dt.Seconds()
		t.Logf("n=%2d  %8.0f MB/s agg  %7.1f MB alloc  %2d GC  %6.2f ms STW",
			n, aggMBs, allocMB, gc, pauseMs)
		return
	}

	for _, n := range []int{1, 20} {
		allocMB, _, pauseMs := run(n)
		// A ~4 MiB parse per session must allocate almost nothing (that is the
		// x/vt failure mode: 8 GB over 20 sessions). Setup is excluded, so this
		// is parse allocation only; a small constant covers goroutine stacks and
		// MemStats jitter.
		if perSession := allocMB / float64(n); perSession > 0.5 {
			t.Errorf("n=%d: %.2f MB/session allocated during parse — not zero-alloc", n, perSession)
		}
		if pauseMs > 5.0 {
			t.Errorf("n=%d: %.2f ms STW pause — GC pressure at scale", n, pauseMs)
		}
	}
}
