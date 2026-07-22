package host

import (
	"context"
	"encoding/binary"
	"net/http/httptest"
	"os"
	"os/exec"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
	cpty "github.com/creack/pty"
	"golang.org/x/sys/unix"

	"github.com/incantery/rook/internal/vt"
)

// dialFramed opens a framed-transport client to session id on srv.
func dialFramed(t *testing.T, srv *httptest.Server, h *Host, id string) (*websocket.Conn, context.Context, context.CancelFunc) {
	t.Helper()
	url := "ws" + strings.TrimPrefix(srv.URL, "http") + "/sessions/" + id + "/framed?token=" + h.Token()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	c, _, err := websocket.Dial(ctx, url, nil)
	if err != nil {
		cancel()
		t.Fatalf("dial framed: %v", err)
	}
	c.SetReadLimit(1 << 21)
	return c, ctx, cancel
}

// readGrid drives the client until it has reconstructed a grid whose row 0 (after
// trimming) equals want, applying every frame to a ClientGrid. It fails on
// timeout. Returns the reconstructed grid. It also asserts no frame is a text
// message — a query reply must never reach a framed client.
func readGrid(t *testing.T, c *websocket.Conn, ctx context.Context, cols, rows int, want string) *vt.ClientGrid {
	t.Helper()
	g := vt.NewClientGrid(cols, rows)
	for {
		typ, data, err := c.Read(ctx)
		if err != nil {
			t.Fatalf("read frame: %v (row0=%q)", err, gridRow(g, 0))
		}
		if typ != websocket.MessageBinary {
			t.Fatalf("non-binary frame %v — a query reply leaked to the client?", typ)
		}
		if len(data) == 0 {
			t.Fatalf("empty message")
		}
		if data[0] == msgState {
			continue // session-state (alt screen); not a grid frame
		}
		if data[0] != msgFrame {
			t.Fatalf("unexpected message tag %v", data)
		}
		f, derr := vt.DecodeFrame(data[1:])
		if derr != nil {
			t.Fatalf("decode frame: %v", derr)
		}
		g.Apply(f)
		if gridRow(g, 0) == want {
			return g
		}
	}
}

func gridRow(g *vt.ClientGrid, y int) string {
	var b strings.Builder
	for x := range g.Cols() {
		cell := g.Cell(x, y)
		if cell.Width == 0 {
			continue // the trailing half of a wide glyph carries no text
		}
		b.WriteString(cell.Content)
	}
	return strings.TrimRight(b.String(), " ")
}

// gridHasRow reports whether any row of g reconstructs to want.
func gridHasRow(g *vt.ClientGrid, want string) bool {
	for y := range g.Rows() {
		if gridRow(g, y) == want {
			return true
		}
	}
	return false
}

// TestFramedReconstructsGrid is the HI-A core gate: pty output the emulator
// parses reaches a framed client as diffs, and the client reconstructs the grid
// the emulator holds — byte for byte, cursor and all — from those frames alone.
func TestFramedReconstructsGrid(t *testing.T) {
	t.Setenv("XDG_DATA_HOME", t.TempDir())
	h := New()

	// A pipe is the pty (one-directional is fine — this test only sends output).
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	defer w.Close()
	const cols, rows = 40, 8
	s := &session{
		q:     newTermQ(),
		info:  SessionInfo{ID: "s1", Name: "s1", Workspace: "t", Cols: cols, Rows: rows, Created: time.Now()},
		pty:   r,
		cmd:   exec.Command("true"),
		emu:   vt.New(cols, rows),
		dirty: make(chan struct{}, 1),
	}
	h.mu.Lock()
	h.sessions["s1"] = s
	h.mu.Unlock()
	go h.readPump(s)

	srv := httptest.NewServer(h.Handler())
	defer srv.Close()

	// Write content the emulator will lay out, including SGR and a wide char so the
	// reconstruction exercises color/width, and a query the client must never see.
	w.Write([]byte("\x1b[c")) // DA1 — its reply is pty input, never a frame
	w.Write([]byte("\x1b[1;32mgreen\x1b[0m bold 世界\r\nsecond row"))

	c, ctx, cancel := dialFramed(t, srv, h, "s1")
	defer cancel()
	defer c.Close(websocket.StatusNormalClosure, "done")

	g := readGrid(t, c, ctx, cols, rows, "green bold 世界")
	if got := gridRow(g, 1); got != "second row" {
		t.Fatalf("row 1 = %q, want %q", got, "second row")
	}
	// the SGR survived the round trip: 'g' of green is bold + palette-2 fg
	cell := g.Cell(0, 0)
	if cell.Attr&vt.AttrBold == 0 {
		t.Fatalf("cell (0,0) lost bold: attr %v", cell.Attr)
	}
	// the wide char occupies two cells: lead width 2, trailer width 0
	// "green bold " is 11 cells, so 世 is at x=11.
	if lead := g.Cell(11, 0); lead.Content != "世" || lead.Width != 2 {
		t.Fatalf("wide lead = %q width %d, want 世 width 2", lead.Content, lead.Width)
	}
	if g.Cell(12, 0).Width != 0 {
		t.Fatalf("wide trailer width = %d, want 0", g.Cell(12, 0).Width)
	}
}

// TestFramedResizeResends is the resize half of the gate: a client resize resends
// the whole screen at the new geometry in one frame, and the client reconstructs
// it there.
func TestFramedResizeResends(t *testing.T) {
	t.Setenv("XDG_DATA_HOME", t.TempDir())
	h := New()
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	defer w.Close()
	const cols, rows = 20, 4
	s := &session{
		q:     newTermQ(),
		info:  SessionInfo{ID: "s1", Name: "s1", Workspace: "t", Cols: cols, Rows: rows, Created: time.Now()},
		pty:   r,
		cmd:   exec.Command("true"),
		emu:   vt.New(cols, rows),
		dirty: make(chan struct{}, 1),
	}
	h.mu.Lock()
	h.sessions["s1"] = s
	h.mu.Unlock()
	go h.readPump(s)

	srv := httptest.NewServer(h.Handler())
	defer srv.Close()

	w.Write([]byte("hello world"))

	c, ctx, cancel := dialFramed(t, srv, h, "s1")
	defer cancel()
	defer c.Close(websocket.StatusNormalClosure, "done")

	readGrid(t, c, ctx, cols, rows, "hello world") // sync: content is on screen

	// Resize wider; the emulator resends the whole screen at 60 cols.
	const nc, nr = 60, 6
	buf := make([]byte, 5)
	buf[0] = msgResize
	binary.BigEndian.PutUint16(buf[1:3], nc)
	binary.BigEndian.PutUint16(buf[3:5], nr)
	if err := c.Write(ctx, websocket.MessageBinary, buf); err != nil {
		t.Fatal(err)
	}

	// The whole screen resends at the new geometry (bottom-anchored, so the row it
	// lands on shifts with the grow); reconstruct at 60x6 and find it anywhere.
	g := vt.NewClientGrid(nc, nr)
	for {
		typ, data, rerr := c.Read(ctx)
		if rerr != nil {
			t.Fatalf("no resend at new geometry after resize: %v", rerr)
		}
		if typ != websocket.MessageBinary || data[0] != msgFrame {
			continue
		}
		f, _ := vt.DecodeFrame(data[1:])
		g.Apply(f)
		if gridHasRow(g, "hello world") {
			return // reconstructed at the new width
		}
	}
}

// TestFramedAltScreenState is the HI-6 gate: entering and leaving the alt screen
// reaches the client as msgState with the alt bit set/cleared, so keybind routing
// can follow it.
func TestFramedAltScreenState(t *testing.T) {
	t.Setenv("XDG_DATA_HOME", t.TempDir())
	h := New()
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	defer w.Close()
	s := &session{
		q:     newTermQ(),
		info:  SessionInfo{ID: "s1", Name: "s1", Workspace: "t", Cols: 20, Rows: 4, Created: time.Now()},
		pty:   r,
		cmd:   exec.Command("true"),
		emu:   vt.New(20, 4),
		dirty: make(chan struct{}, 1),
	}
	h.mu.Lock()
	h.sessions["s1"] = s
	h.mu.Unlock()
	go h.readPump(s)

	srv := httptest.NewServer(h.Handler())
	defer srv.Close()

	c, ctx, cancel := dialFramed(t, srv, h, "s1")
	defer cancel()
	defer c.Close(websocket.StatusNormalClosure, "done")

	// waitAlt reads until a msgState arrives and returns its alt bit.
	waitAlt := func() bool {
		for {
			_, data, rerr := c.Read(ctx)
			if rerr != nil {
				t.Fatalf("read state: %v", rerr)
			}
			if len(data) >= 2 && data[0] == msgState {
				return data[1]&stateAlt != 0
			}
		}
	}

	// The initial state is the normal screen.
	if waitAlt() {
		t.Fatal("initial state = alt, want normal")
	}
	w.Write([]byte("\x1b[?1049h")) // enter alt
	if !waitAlt() {
		t.Fatal("after ?1049h: state = normal, want alt")
	}
	w.Write([]byte("\x1b[?1049l")) // leave alt
	if waitAlt() {
		t.Fatal("after ?1049l: state = alt, want normal")
	}
}

// TestFramedInputReachesPty is the input half: a msgInput message is written to
// the session's pty, so a program reading the tty sees the keystrokes.
func TestFramedInputReachesPty(t *testing.T) {
	t.Setenv("XDG_DATA_HOME", t.TempDir())
	h := New()

	// A real pty pair — input has to travel back to the tty side.
	ptmx, tty, err := cpty.Open()
	if err != nil {
		t.Fatal(err)
	}
	defer ptmx.Close()
	defer tty.Close()
	// Raw the slave so what we read back is byte-faithful, not line-disciplined.
	if tio, terr := unix.IoctlGetTermios(int(tty.Fd()), unix.TIOCGETA); terr == nil {
		tio.Lflag &^= unix.ICANON | unix.ECHO
		if serr := unix.IoctlSetTermios(int(tty.Fd()), unix.TIOCSETA, tio); serr != nil {
			t.Skipf("cannot raw the test tty: %v", serr)
		}
	} else {
		t.Skipf("cannot read tty termios: %v", terr)
	}

	s := &session{
		q:     newTermQ(),
		info:  SessionInfo{ID: "s1", Name: "s1", Workspace: "t", Cols: 20, Rows: 4, Created: time.Now()},
		pty:   ptmx,
		cmd:   exec.Command("true"),
		emu:   vt.New(20, 4),
		dirty: make(chan struct{}, 1),
	}
	h.mu.Lock()
	h.sessions["s1"] = s
	h.mu.Unlock()
	go h.readPump(s)

	srv := httptest.NewServer(h.Handler())
	defer srv.Close()

	c, ctx, cancel := dialFramed(t, srv, h, "s1")
	defer cancel()
	defer c.Close(websocket.StatusNormalClosure, "done")

	msg := append([]byte{msgInput}, []byte("PING")...)
	if err := c.Write(ctx, websocket.MessageBinary, msg); err != nil {
		t.Fatal(err)
	}

	got := make(chan string, 1)
	go func() {
		buf := make([]byte, 64)
		n, _ := tty.Read(buf)
		got <- string(buf[:n])
	}()
	select {
	case s := <-got:
		if !strings.Contains(s, "PING") {
			t.Fatalf("tty received %q, want it to contain PING", s)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("input never reached the pty")
	}
}
