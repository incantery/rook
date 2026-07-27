package host

import (
	"context"
	"fmt"
	"net/http/httptest"
	"os"
	"os/exec"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
	cpty "github.com/creack/pty"

	"github.com/incantery/rook/internal/vt"
)

// Keystroke echo latency measured through the REAL framed loop — pty, readPump,
// emulator, frameInterval coalescer, websocket — with no browser in it.
//
// This exists because the browser harness cannot answer the question. Headless
// e2e has no GPU and lies about anything whose cost is pixels; headed, the
// probe is display-bound (both renderers land on the 8.3ms frame clock, see
// docs/PERF.md 2026-07-27). Neither can see a millisecond spent on the host.
// This can, and it is deterministic.
//
// The condition that matters is the one the browser sweep never built: typing
// into a session that is ITSELF producing output. framedRenderLoop coalesces to
// one frame per frameInterval and escapes that wait only after an idle gap
// (termframe.go) — so an echo that lands mid-stream waits for the tick, and an
// echo at a quiet prompt does not. A split with a firehose in the OTHER pane
// does not exercise this: that is a different session with its own loop, idle
// on this side. Typing into a busy Claude pane exercises it every keystroke.
//
//	go test ./internal/host/ -run TestEchoLatency -v

// echoRig is a live session on a real pty with a framed client attached.
type echoRig struct {
	t   *testing.T
	h   *Host
	s   *session
	c   *websocket.Conn
	ctx context.Context
	ptm *os.File
	tty *os.File
	g   *vt.ClientGrid
}

func newEchoRig(t *testing.T, cols, rows int) *echoRig {
	t.Helper()
	t.Setenv("XDG_DATA_HOME", t.TempDir())
	h := New()

	ptm, tty, err := cpty.Open()
	if err != nil {
		t.Fatal(err)
	}
	cpty.Setsize(ptm, &cpty.Winsize{Cols: uint16(cols), Rows: uint16(rows)})

	s := &session{
		info:  SessionInfo{ID: "s1", Name: "s1", Workspace: "t", Cols: cols, Rows: rows, Created: time.Now()},
		pty:   ptm,
		cmd:   exec.Command("true"),
		emu:   newTerminal(cols, rows),
		dirty: make(chan struct{}, 1),
	}
	h.mu.Lock()
	h.sessions["s1"] = s
	h.mu.Unlock()
	go h.readPump(s)

	srv := httptest.NewServer(h.Handler())
	t.Cleanup(srv.Close)

	// Not dialFramed: its ctx expires after 10s, and a sweep at comfortable
	// typing speed runs longer than that — the read ctx dying takes the
	// connection with it (coder/websocket), which reads as a write failure
	// several frames later.
	url := "ws" + strings.TrimPrefix(srv.URL, "http") + "/sessions/s1/framed?token=" + h.Token()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	t.Cleanup(cancel)
	c, _, err := websocket.Dial(ctx, url, nil)
	if err != nil {
		t.Fatalf("dial framed: %v", err)
	}
	c.SetReadLimit(1 << 21)
	t.Cleanup(func() { c.Close(websocket.StatusNormalClosure, "done") })

	rig := &echoRig{t: t, h: h, s: s, c: c, ctx: ctx, ptm: ptm, tty: tty, g: vt.NewClientGrid(cols, rows)}
	t.Cleanup(func() { ptm.Close(); tty.Close() })
	return rig
}

// echo sends one keystroke the way a client does (msgInput) and returns how long
// until a frame carrying its echo reaches the client. The pty's line discipline
// does the echoing, exactly as it does for a shell.
func (r *echoRig) echo(ch byte) time.Duration {
	r.t.Helper()
	want := string(ch)
	t0 := time.Now()
	if err := r.c.Write(r.ctx, websocket.MessageBinary, []byte{msgInput, ch}); err != nil {
		r.t.Fatalf("write input: %v", err)
	}
	for {
		typ, data, err := r.c.Read(r.ctx)
		if err != nil {
			r.t.Fatalf("read frame: %v", err)
		}
		if typ != websocket.MessageBinary || len(data) == 0 || data[0] != msgFrame {
			continue
		}
		f, derr := vt.DecodeFrame(data[1:])
		if derr != nil {
			r.t.Fatalf("decode frame: %v", derr)
		}
		// Look for the echoed character in the frame's own cells rather than
		// the reconstructed grid: under a firehose the grid holds every
		// character in the alphabet already, so only "this frame carried it"
		// is an honest t1.
		carried := false
		for _, row := range f.Rows {
			for _, run := range row.Runs {
				for _, cell := range run.Cells {
					if cell.Content == want {
						carried = true
					}
				}
			}
		}
		r.g.Apply(f)
		if carried {
			return time.Since(t0)
		}
	}
}

// settle consumes the attach snapshot so a measurement starts from rest.
//
// Deliberately NOT "read with a short timeout until it errors": a coder/
// websocket read whose ctx expires kills the whole connection, which is a
// rook-wide gotcha and cost this file one debugging round. Nothing else
// produces output here — the session's command is never started — so the
// snapshot is the only thing to consume.
func (r *echoRig) settle() {
	r.t.Helper()
	for {
		typ, data, err := r.c.Read(r.ctx)
		if err != nil {
			r.t.Fatalf("settle: %v", err)
		}
		if typ == websocket.MessageBinary && len(data) > 0 && data[0] == msgFrame {
			return
		}
	}
}

func pct(d []time.Duration, p float64) time.Duration {
	if len(d) == 0 {
		return 0
	}
	i := int(p * float64(len(d)))
	if i >= len(d) {
		i = len(d) - 1
	}
	return d[i]
}

func report(t *testing.T, label string, lat []time.Duration) {
	sort.Slice(lat, func(i, j int) bool { return lat[i] < lat[j] })
	ms := func(d time.Duration) string { return fmt.Sprintf("%.2fms", float64(d.Microseconds())/1000) }
	t.Logf("HOST-ECHO %-22s n=%d p50=%s p95=%s p99=%s min=%s max=%s",
		label, len(lat), ms(pct(lat, 0.5)), ms(pct(lat, 0.95)), ms(pct(lat, 0.99)),
		ms(lat[0]), ms(lat[len(lat)-1]))
}

func TestEchoLatency(t *testing.T) {
	const cols, rows = 316, 61 // an ultrawide pane, the reported geometry
	const n = 120

	// Keystroke spacing is part of the measurement, not a detail. The loop
	// escapes its coalescing wait only when the LAST frame is already older
	// than frameInterval, so a lone keystroke at a quiet prompt goes straight
	// out while a burst pays the remainder of the tick. 90ms is comfortable
	// typing (the browser harness's rate); 20ms is a fast run or a held key.
	cases := []struct {
		label   string
		spacing time.Duration
		stream  bool
	}{
		{"quiet, 90ms apart", 90 * time.Millisecond, false},
		{"quiet, 20ms apart", 20 * time.Millisecond, false},
		{"streaming, 90ms apart", 90 * time.Millisecond, true},
		{"streaming, 20ms apart", 20 * time.Millisecond, true},
	}

	for _, tc := range cases {
		t.Run(tc.label, func(t *testing.T) {
			r := newEchoRig(t, cols, rows)
			r.settle()

			if tc.stream {
				// The same session produces output while we type into it — a
				// build, a test run, an agent printing. Paced, not a firehose:
				// the point is that the loop never sees an idle gap, not that
				// the pty saturates.
				stop := make(chan struct{})
				done := make(chan struct{})
				go func() {
					defer close(done)
					// '#' so the noise can never be mistaken for an echoed letter
					line := []byte(strings.Repeat("#", cols-1) + "\r\n")
					tick := time.NewTicker(2 * time.Millisecond)
					defer tick.Stop()
					for {
						select {
						case <-stop:
							return
						case <-tick.C:
							r.tty.Write(line)
						}
					}
				}()
				defer func() { close(stop); <-done }()
			}

			lat := make([]time.Duration, 0, n)
			for i := range n {
				lat = append(lat, r.echo(byte('a'+i%26)))
				time.Sleep(tc.spacing)
			}
			report(t, tc.label, lat)
		})
	}
}
