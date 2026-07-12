package host

import (
	"context"
	"fmt"
	"net/http/httptest"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/coder/websocket"
)

// TestAttachReplayGapFree hammers the replay-to-live handoff: a writer
// floods the session's pty while clients attach, read, and detach in a
// loop. Each round reads PAST the replayed ring into live output (records
// numbered higher than the writer's counter at attach time) — the seam
// between replay and live is exactly where the old handleAttach (ring
// copy → replay → THEN set attach) dropped whatever arrived in between.
func TestAttachReplayGapFree(t *testing.T) {
	t.Setenv("XDG_DATA_HOME", t.TempDir())
	h := New()

	// A pipe stands in for the pty: readPump only needs an *os.File to
	// read, and a pipe lets the test be the shell.
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	defer w.Close()
	s := &session{
		info: SessionInfo{ID: "s1", Name: "s1", Workspace: "t", Created: time.Now()},
		pty:  r,
		cmd:  exec.Command("true"), // never started; Wait() just errors on EOF
	}
	h.mu.Lock()
	h.sessions["s1"] = s
	h.mu.Unlock()
	go h.readPump(s)

	srv := httptest.NewServer(h.Handler())
	defer srv.Close()

	// Writer: numbered 10-byte records, flat out — the replay window must
	// always have fresh bytes landing in it.
	var written atomic.Int64
	var stop atomic.Bool
	defer stop.Store(true)
	go func() {
		for i := int64(0); !stop.Load(); i++ {
			if _, err := fmt.Fprintf(w, "%09d\n", i); err != nil {
				return
			}
			written.Store(i)
		}
	}()

	// Let the ring fill so every replay takes multiple chunked writes.
	for written.Load() < 60_000 {
		time.Sleep(time.Millisecond)
	}

	url := "ws" + strings.TrimPrefix(srv.URL, "http") + "/sessions/s1/attach?token=" + h.Token()
	for round := range 12 {
		atAttach := written.Load()
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		c, _, err := websocket.Dial(ctx, url, nil)
		if err != nil {
			cancel()
			t.Fatalf("round %d: dial: %v", round, err)
		}
		c.SetReadLimit(1 << 21)
		var buf []byte
		// Read until we've provably crossed the seam: a record produced
		// well after this attach began.
		for {
			_, data, rerr := c.Read(ctx)
			if rerr != nil {
				t.Fatalf("round %d: read: %v (got %d bytes)", round, rerr, len(buf))
			}
			buf = append(buf, data...)
			if last := lastRecord(buf); last > atAttach+20_000 {
				break
			}
		}
		c.Close(websocket.StatusNormalClosure, "done")
		cancel()
		checkContiguous(t, round, buf)
	}
}

// lastRecord parses the most recent complete 10-byte record in buf.
func lastRecord(buf []byte) int64 {
	s := string(buf)
	start := strings.IndexByte(s, '\n') + 1
	n := int64(-1)
	if rem := (len(s) - start) / 10; rem > 0 {
		rec := s[start+(rem-1)*10 : start+rem*10]
		if v, err := strconv.ParseInt(rec[:9], 10, 64); err == nil {
			n = v
		}
	}
	return n
}

// checkContiguous parses the 10-byte records ("%09d\n") and requires each
// number to be exactly previous+1. The head may be torn by the ring
// boundary; everything after must be seamless.
func checkContiguous(t *testing.T, round int, buf []byte) {
	t.Helper()
	sbuf := string(buf)
	start := strings.IndexByte(sbuf, '\n') + 1
	prev := int64(-1)
	count := 0
	for i := start; i+10 <= len(sbuf); i += 10 {
		rec := sbuf[i : i+10]
		if rec[9] != '\n' {
			t.Fatalf("round %d: misaligned record %q at offset %d", round, rec, i)
		}
		n, err := strconv.ParseInt(rec[:9], 10, 64)
		if err != nil {
			t.Fatalf("round %d: bad record %q: %v", round, rec, err)
		}
		if prev >= 0 && n != prev+1 {
			t.Fatalf("round %d: GAP: %d → %d (%d records lost at the seam)", round, prev, n, n-prev-1)
		}
		prev = n
		count++
	}
	if count < 1000 {
		t.Fatalf("round %d: only %d records parsed — test not exercising the stream", round, count)
	}
}
