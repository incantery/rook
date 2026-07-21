package host

import (
	"bytes"
	"os/exec"
	"strings"
	"sync"
	"testing"
	"time"

	cpty "github.com/creack/pty"
	"golang.org/x/sys/unix"
)

// The captured sequences are real: nvim's startup burst, taken off a
// websocket tap on the running app (see the frontend's manager.spec.ts).

func TestAnswersNvimStartupBurst(t *testing.T) {
	q := newTermQ()
	// what nvim actually asks, in the order it asks it
	out := "\x1b[?1049h\x1b[?1h\x1b=\x1b[H\x1b[2J\x1b[?2004h" +
		"\x1b[?69$p\x1b[?2026$p\x1b[?2027$p\x1b[?2031$p\x1b[?2048$p" +
		"\x1b[0m\x1b[4:3m\x1b[?u\x1b[c\x1b[5n\x1b[?25h"
	got := string(q.scan([]byte(out)))

	// Mode reports, mirroring xterm.js: 69/2027/2031/2048 are unknown to it,
	// 2026 is known and off.
	for _, want := range []string{
		"\x1b[?69;0$y", "\x1b[?2026;2$y", "\x1b[?2027;0$y",
		"\x1b[?2031;0$y", "\x1b[?2048;0$y",
		"\x1b[?1;2c", // DA1
		"\x1b[0n",    // DSR 5
	} {
		if !strings.Contains(got, want) {
			t.Errorf("missing %q in %q", want, got)
		}
	}
	// CPR and the kitty-keyboard query are NOT ours to answer
	if strings.Contains(got, "R") {
		t.Errorf("answered a cursor position report: %q", got)
	}
}

func TestTracksModesItReports(t *testing.T) {
	q := newTermQ()
	// bracketed paste on, then asked about
	q.scan([]byte("\x1b[?2004h"))
	if got := string(q.scan([]byte("\x1b[?2004$p"))); got != "\x1b[?2004;1$y" {
		t.Errorf("2004 after set = %q, want set", got)
	}
	q.scan([]byte("\x1b[?2004l"))
	if got := string(q.scan([]byte("\x1b[?2004$p"))); got != "\x1b[?2004;2$y" {
		t.Errorf("2004 after reset = %q, want reset", got)
	}
}

func TestDefaultsMatchXtermBeforeAnySet(t *testing.T) {
	q := newTermQ()
	// wraparound and cursor-visible start ON in xterm.js; a report before any
	// h/l has to say so or a program will "restore" a state it never had
	if got := string(q.scan([]byte("\x1b[?7$p"))); got != "\x1b[?7;1$y" {
		t.Errorf("wraparound default = %q, want set", got)
	}
	if got := string(q.scan([]byte("\x1b[?25$p"))); got != "\x1b[?25;1$y" {
		t.Errorf("cursor visible default = %q, want set", got)
	}
}

func TestAltScreenIsAnyOfItsModes(t *testing.T) {
	q := newTermQ()
	q.scan([]byte("\x1b[?1049h"))
	for _, m := range []string{"47", "1047", "1049"} {
		if got := string(q.scan([]byte("\x1b[?" + m + "$p"))); !strings.HasSuffix(got, ";1$y") {
			t.Errorf("mode %s in alt screen = %q, want set", m, got)
		}
	}
}

func TestMouseProtocolIsExclusive(t *testing.T) {
	q := newTermQ()
	q.scan([]byte("\x1b[?1002h\x1b[?1006h"))
	if got := string(q.scan([]byte("\x1b[?1002$p"))); got != "\x1b[?1002;1$y" {
		t.Errorf("active protocol = %q, want set", got)
	}
	// 1000 is not active even though 1002 implies dragging
	if got := string(q.scan([]byte("\x1b[?1000$p"))); got != "\x1b[?1000;2$y" {
		t.Errorf("inactive protocol = %q, want reset", got)
	}
}

// The load-bearing one for a 32KiB read boundary: a query split across two
// chunks is still a query, and a program that gets no answer hangs.
func TestReassemblesASequenceSplitAcrossReads(t *testing.T) {
	q := newTermQ()
	if got := q.scan([]byte("\x1b[?20")); len(got) != 0 {
		t.Errorf("answered a partial sequence: %q", got)
	}
	if got := string(q.scan([]byte("26$p"))); got != "\x1b[?2026;2$y" {
		t.Errorf("rejoined = %q, want the 2026 report", got)
	}
}

func TestIgnoresOrdinaryOutput(t *testing.T) {
	q := newTermQ()
	// colours, cursor moves, plain text and a bare ESC: nothing to answer
	out := "hello \x1b[38;2;1;2;3mworld\x1b[0m\x1b[10;20H\x1b[2K\x1b tail"
	if got := q.scan([]byte(out)); len(got) != 0 {
		t.Errorf("answered ordinary output with %q", got)
	}
}

func TestDoesNotAnswerACSIWithANonZeroParamBeforeC(t *testing.T) {
	q := newTermQ()
	// CSI 1 c is not a device attributes request
	if got := q.scan([]byte("\x1b[1c")); len(got) != 0 {
		t.Errorf("answered CSI 1 c with %q", got)
	}
}

func TestCarryDoesNotGrowUnbounded(t *testing.T) {
	q := newTermQ()
	q.scan(append([]byte("\x1b["), make([]byte, 200)...))
	if len(q.carry) > carryMax {
		t.Errorf("carry grew to %d", len(q.carry))
	}
}

// The headline claim, end to end through a real pty: a session with NOBODY
// attached still answers. Before this, replies came from xterm.js in the
// browser, so a program started in a detached session waited on a DA1 that
// was never coming — latent today only because rook attaches everything, and
// exactly what the detach work removes.
func TestAnswersWithNobodyAttached(t *testing.T) {
	t.Setenv("XDG_STATE_HOME", t.TempDir())
	t.Setenv("XDG_CONFIG_HOME", t.TempDir())
	t.Setenv("XDG_DATA_HOME", t.TempDir())
	h := New()

	// A real pty, because the reply has to travel BACK: the pipe fixture the
	// other tests use is one-directional by construction.
	ptmx, tty, err := cpty.Open()
	if err != nil {
		t.Fatal(err)
	}
	defer ptmx.Close()
	defer tty.Close()

	// Raw the slave, or this measures the line discipline instead of the
	// host: in canonical mode a read does not return until a newline, and a
	// device-attributes reply has none — the first version of this test
	// "failed" for three seconds on that alone.
	if tio, terr := unix.IoctlGetTermios(int(tty.Fd()), unix.TIOCGETA); terr == nil {
		tio.Lflag &^= unix.ICANON | unix.ECHO
		if serr := unix.IoctlSetTermios(int(tty.Fd()), unix.TIOCSETA, tio); serr != nil {
			t.Skipf("cannot raw the test tty: %v", serr)
		}
	} else {
		t.Skipf("cannot read tty termios: %v", terr)
	}

	s := &session{
		q:    newTermQ(),
		info: SessionInfo{ID: "s1", Name: "s1", Workspace: "t", Created: time.Now()},
		pty:  ptmx,
		cmd:  exec.Command("true"), // never started, as in attach_test
	}
	h.mu.Lock()
	h.sessions["s1"] = s
	h.mu.Unlock()
	go h.readPump(s)
	// no attach: h.Handler() is never dialled, s.attach stays nil

	// the "program" asks what its terminal is
	if _, err := tty.Write([]byte("\x1b[c")); err != nil {
		t.Fatal(err)
	}

	got := make(chan string, 1)
	go func() {
		buf := make([]byte, 256)
		for {
			n, err := tty.Read(buf)
			if n > 0 {
				// the tty echoes the query too; the answer is what we want
				if i := bytes.Index(buf[:n], []byte("\x1b[?1;2c")); i >= 0 {
					got <- string(buf[:n])
					return
				}
			}
			if err != nil {
				return
			}
		}
	}()

	select {
	case <-got: // answered
	case <-time.After(3 * time.Second):
		t.Fatal("no device-attributes reply with nobody attached — a program starting here would hang")
	}
}

// Concurrent writes to the pty do not interleave — the property readPump's
// query replies quietly depend on, since they race live keystrokes and the
// actuator paths (nudge, draft approve). The protection is NOT ours: an
// os.File on a pollable fd serializes every Write through the runtime poller's
// per-fd write lock (internal/poll.FD.writeLock), so two writers never split a
// third's bytes whatever their size. This guards that assumption — if s.pty
// ever became a plain io.Writer without that lock, a token would split here.
//
// (This started as a test for a mutex I added on a hypothesized interleave.
// The mutex was redundant with the runtime's lock and came back out; the test
// stayed, retargeted to the real guarantee.)
func TestConcurrentPTYWritesDoNotInterleave(t *testing.T) {
	ptmx, tty, err := cpty.Open()
	if err != nil {
		t.Fatal(err)
	}
	defer ptmx.Close()
	defer tty.Close()
	if tio, terr := unix.IoctlGetTermios(int(tty.Fd()), unix.TIOCGETA); terr == nil {
		tio.Lflag &^= unix.ICANON | unix.ECHO
		tio.Oflag &^= unix.OPOST // no \n → \r\n translation to confuse the check
		_ = unix.IoctlSetTermios(int(tty.Fd()), unix.TIOCSETA, tio)
	}
	write := func(b []byte) { _, _ = ptmx.Write(b) }

	const token = "<<TOKEN>"
	const rounds = 2000

	// reader first, concurrently, and it must drain the FULL total: if it
	// stops early the unread tail fills the pty buffer, the next Write blocks,
	// and the writers never finish (which hung two earlier drafts of this).
	const total = rounds*len(token) + rounds*len("....")
	read := make(chan []byte, 1)
	go func() {
		got := make([]byte, 0, total)
		buf := make([]byte, 4096)
		_ = tty.SetReadDeadline(time.Now().Add(30 * time.Second))
		for len(got) < total {
			n, rerr := tty.Read(buf)
			got = append(got, buf[:n]...)
			if rerr != nil {
				break
			}
		}
		read <- got
	}()

	var wg sync.WaitGroup
	wg.Add(2)
	go func() {
		defer wg.Done()
		for range rounds {
			write([]byte(token))
		}
	}()
	go func() {
		defer wg.Done()
		for range rounds {
			write([]byte("....")) // filler that must never split a token
		}
	}()
	wg.Wait()

	got := <-read
	if strings.Count(string(got), token) == 0 {
		t.Fatal("read nothing back")
	}
	// a filler byte inside a token would leave "<<" not followed by the rest
	for i := 0; i+2 <= len(got); i++ {
		if got[i] == '<' && got[i+1] == '<' {
			if i+len(token) > len(got) || string(got[i:i+len(token)]) != token {
				t.Fatalf("token split at %d: %q", i, got[max(0, i-2):min(len(got), i+12)])
			}
		}
	}
}
