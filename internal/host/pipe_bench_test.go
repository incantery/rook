package host

import (
	"os/exec"
	"strings"
	"sync"
	"testing"
	"time"

	cpty "github.com/creack/pty"
)

// The full host pipeline (real pty -> gather -> parse ->
// 16ms render ticks) at the 6K-fullscreen geometry, without zsh or a browser.
// The e2e `time cat 150MB` gate, inside a profiler's reach.
func benchPipe(b *testing.B, line string) {
	benchPipeWith(b, line, newTerminal)
}

// benchPipeWith runs the pipeline against any Terminal backend — the seam is
// what makes "which emulator?" a benchmark flag instead of a debate.
func benchPipeWith(b *testing.B, line string, mk func(cols, rows int) Terminal) {
	b.Setenv("XDG_DATA_HOME", b.TempDir())
	h := New()
	ptm, tty, err := cpty.Open()
	if err != nil {
		b.Fatal(err)
	}
	defer ptm.Close()
	defer tty.Close()
	const cols, rows = 405, 113
	cpty.Setsize(ptm, &cpty.Winsize{Cols: cols, Rows: rows})
	s := &session{
		info: SessionInfo{ID: "s1", Name: "s1", Workspace: "t", Cols: cols, Rows: rows, Created: time.Now()},
		pty:  ptm,
		cmd:  exec.Command("true"),
		emu:  mk(cols, rows),
	}
	h.mu.Lock()
	h.sessions["s1"] = s
	h.mu.Unlock()
	go h.readPump(s)

	// the render loop's cost shape, sans websocket
	stop := make(chan struct{})
	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		surface := func() Surface {
			s.emuMu.Lock()
			defer s.emuMu.Unlock()
			return s.emu.NewSurface()
		}()
		t := time.NewTicker(16 * time.Millisecond)
		defer t.Stop()
		for {
			select {
			case <-stop:
				return
			case <-t.C:
				s.emuMu.Lock()
				f := s.emu.Render(surface)
				s.emuMu.Unlock()
				if !f.Empty() {
					_ = f.Encode()
				}
			}
		}
	}()

	data := []byte(strings.Repeat(line, (8<<20)/len(line)))
	b.SetBytes(int64(len(data)))
	b.ResetTimer()
	for b.Loop() {
		for off := 0; off < len(data); {
			n, werr := tty.Write(data[off:])
			if werr != nil {
				b.Fatal(werr)
			}
			off += n
		}
	}
	b.StopTimer()
	close(stop)
	wg.Wait()
}

func BenchmarkPipeAscii(b *testing.B) {
	benchPipe(b, "the quick brown fox jumps over the lazy dog while carrying a load\n")
}

func BenchmarkPipeUnicode(b *testing.B) {
	benchPipe(b, "こんにちは世界 Привет мир مرحبا بالعالم 你好世界 Γειά σου Κόσμε हैलो वर्ल्ड héllo wörld\n")
}
