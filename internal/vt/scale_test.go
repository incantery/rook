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
		runtime.GC()
		var before, after runtime.MemStats
		runtime.ReadMemStats(&before)

		var wg sync.WaitGroup
		t0 := time.Now()
		for range n {
			wg.Add(1)
			go func() {
				defer wg.Done()
				e := New(120, 40)
				e.Write(data)
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
		// A ~4 MiB parse per session must not allocate on the order of the
		// input (that is the x/vt failure mode: 8 GB / 20 sessions). A few MB
		// of fixed grid+goroutine overhead per session is fine; scaling with
		// bytes-processed is not.
		if perSession := allocMB / float64(n); perSession > 2.0 {
			t.Errorf("n=%d: %.1f MB/session allocated — grid is not zero-alloc", n, perSession)
		}
		if pauseMs > 5.0 {
			t.Errorf("n=%d: %.2f ms STW pause — GC pressure at scale", n, pauseMs)
		}
	}
}
