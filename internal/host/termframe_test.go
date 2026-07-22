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
		info:  SessionInfo{ID: "s1", Name: "s1", Workspace: "t", Cols: cols, Rows: rows, Created: time.Now()},
		pty:   r,
		cmd:   exec.Command("true"),
		emu:   newTerminal(cols, rows),
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
		info:  SessionInfo{ID: "s1", Name: "s1", Workspace: "t", Cols: cols, Rows: rows, Created: time.Now()},
		pty:   r,
		cmd:   exec.Command("true"),
		emu:   newTerminal(cols, rows),
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
		info:  SessionInfo{ID: "s1", Name: "s1", Workspace: "t", Cols: 20, Rows: 4, Created: time.Now()},
		pty:   r,
		cmd:   exec.Command("true"),
		emu:   newTerminal(20, 4),
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

// TestFramedCursorMoveIsSent guards the "space doesn't show" bug: a frame that
// moves the cursor with no cell change must still reach the client, or a space
// (or an arrow key at a prompt) leaves the cursor visually stuck.
func TestFramedCursorMoveIsSent(t *testing.T) {
	t.Setenv("XDG_DATA_HOME", t.TempDir())
	h := New()
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	defer w.Close()
	const cols, rows = 20, 4
	s := &session{
		info:  SessionInfo{ID: "s1", Name: "s1", Workspace: "t", Cols: cols, Rows: rows, Created: time.Now()},
		pty:   r,
		cmd:   exec.Command("true"),
		emu:   newTerminal(cols, rows),
		dirty: make(chan struct{}, 1),
	}
	h.mu.Lock()
	h.sessions["s1"] = s
	h.mu.Unlock()
	go h.readPump(s)

	srv := httptest.NewServer(h.Handler())
	defer srv.Close()

	w.Write([]byte("abc"))

	c, ctx, cancel := dialFramed(t, srv, h, "s1")
	defer cancel()
	defer c.Close(websocket.StatusNormalClosure, "done")

	g := vt.NewClientGrid(cols, rows)
	// waitCursorX applies frames until the client's cursor reaches x.
	waitCursorX := func(x int) {
		deadline := time.After(3 * time.Second)
		for {
			select {
			case <-deadline:
				t.Fatalf("cursor never reached x=%d (now %d)", x, g.CursorPos().X)
			default:
			}
			_, data, rerr := c.Read(ctx)
			if rerr != nil {
				t.Fatalf("read: %v", rerr)
			}
			if len(data) == 0 || data[0] != msgFrame {
				continue
			}
			f, _ := vt.DecodeFrame(data[1:])
			g.Apply(f)
			if g.CursorPos().X == x {
				return
			}
		}
	}
	waitCursorX(3) // after "abc"

	// Move the cursor to column 1 (x=0) — a pure cursor move, no cell changes.
	w.Write([]byte("\x1b[1G"))
	waitCursorX(0) // the frame that carries only the cursor must arrive
}

// TestFramedPaletteAnswersOSC proves the palette a client sends reaches the
// emulator and shapes its OSC answers: after msgPalette sets the background, a
// program's OSC 11 query gets that color back (the vim-background path).
func TestFramedPaletteAnswersOSC(t *testing.T) {
	t.Setenv("XDG_DATA_HOME", t.TempDir())
	h := New()

	ptmx, tty, err := cpty.Open()
	if err != nil {
		t.Fatal(err)
	}
	defer ptmx.Close()
	defer tty.Close()
	if tio, terr := unix.IoctlGetTermios(int(tty.Fd()), unix.TIOCGETA); terr == nil {
		tio.Lflag &^= unix.ICANON | unix.ECHO
		if serr := unix.IoctlSetTermios(int(tty.Fd()), unix.TIOCSETA, tio); serr != nil {
			t.Skipf("cannot raw the test tty: %v", serr)
		}
	} else {
		t.Skipf("cannot read tty termios: %v", terr)
	}

	s := &session{
		info:  SessionInfo{ID: "s1", Name: "s1", Workspace: "t", Cols: 20, Rows: 4, Created: time.Now()},
		pty:   ptmx,
		cmd:   exec.Command("true"),
		emu:   newTerminal(20, 4),
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

	// Set the background to 0x123456 via the palette message.
	pal := make([]byte, 1+paletteBytes)
	pal[0] = msgPalette
	pal[4], pal[5], pal[6] = 0x12, 0x34, 0x56 // bg is the 2nd RGB triple
	if err := c.Write(ctx, websocket.MessageBinary, pal); err != nil {
		t.Fatal(err)
	}

	// The palette (ws) and the query (tty) race across goroutines, so re-ask
	// until the answer reflects the set color. It applies within a message or two.
	replies := make(chan string, 8)
	go func() {
		buf := make([]byte, 128)
		for {
			n, rerr := tty.Read(buf)
			if n > 0 {
				replies <- string(buf[:n])
			}
			if rerr != nil {
				return
			}
		}
	}()

	deadline := time.After(3 * time.Second)
	want := "\x1b]11;rgb:1212/3434/5656\x1b\\"
	for {
		tty.Write([]byte("\x1b]11;?\x1b\\")) // program asks for the background
		select {
		case r := <-replies:
			if strings.Contains(r, want) {
				return
			}
		case <-deadline:
			t.Fatalf("OSC 11 never answered with the set palette (want %q)", want)
		}
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
		info:  SessionInfo{ID: "s1", Name: "s1", Workspace: "t", Cols: 20, Rows: 4, Created: time.Now()},
		pty:   ptmx,
		cmd:   exec.Command("true"),
		emu:   newTerminal(20, 4),
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

// TestFramedAnswersQueries proves the emulator answers terminal queries and the
// reply reaches the pty as input — the query answering that moved off the raw
// path (termquery.go) and xterm onto the host emulator. A program asks DA1; the
// answer must come back on the tty, and never as a frame (readGrid enforces
// that separately).
func TestFramedAnswersQueries(t *testing.T) {
	t.Setenv("XDG_DATA_HOME", t.TempDir())
	h := New()

	ptmx, tty, err := cpty.Open()
	if err != nil {
		t.Fatal(err)
	}
	defer ptmx.Close()
	defer tty.Close()
	if tio, terr := unix.IoctlGetTermios(int(tty.Fd()), unix.TIOCGETA); terr == nil {
		tio.Lflag &^= unix.ICANON | unix.ECHO
		if serr := unix.IoctlSetTermios(int(tty.Fd()), unix.TIOCSETA, tio); serr != nil {
			t.Skipf("cannot raw the test tty: %v", serr)
		}
	} else {
		t.Skipf("cannot read tty termios: %v", terr)
	}

	s := &session{
		info:  SessionInfo{ID: "s1", Name: "s1", Workspace: "t", Cols: 20, Rows: 4, Created: time.Now()},
		pty:   ptmx,
		cmd:   exec.Command("true"),
		emu:   newTerminal(20, 4),
		dirty: make(chan struct{}, 1),
	}
	h.mu.Lock()
	h.sessions["s1"] = s
	h.mu.Unlock()
	go h.readPump(s)
	// No attach needed: readPump answers whether or not a client is watching.

	// the "program" asks its terminal what it is (DA1)
	if _, err := tty.Write([]byte("\x1b[c")); err != nil {
		t.Fatal(err)
	}

	got := make(chan string, 1)
	go func() {
		buf := make([]byte, 64)
		n, _ := tty.Read(buf)
		got <- string(buf[:n])
	}()
	select {
	case reply := <-got:
		// xterm.js's answer, which the emulator mirrors: VT100 w/ AVO.
		if !strings.Contains(reply, "\x1b[?1;2c") {
			t.Fatalf("DA1 reply = %q, want it to contain \\x1b[?1;2c", reply)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("query was never answered to the pty")
	}
}

// TestFramedScrollbackFetch is the paging gate: a client asks for a page of
// history by absolute index (msgSbFetch) and gets it back as a chunk
// (msgSbChunk) — reverse-paginated virtualized scrolling's round trip. The
// server ring is the store; the client never held these lines.
func TestFramedScrollbackFetch(t *testing.T) {
	t.Setenv("XDG_DATA_HOME", t.TempDir())
	h := New()

	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	defer w.Close()
	const cols, rows = 20, 3
	s := &session{
		info:  SessionInfo{ID: "s1", Name: "s1", Workspace: "t", Cols: cols, Rows: rows, Created: time.Now()},
		pty:   r,
		cmd:   exec.Command("true"),
		emu:   newTerminal(cols, rows),
		dirty: make(chan struct{}, 1),
	}
	h.mu.Lock()
	h.sessions["s1"] = s
	h.mu.Unlock()
	go h.readPump(s)

	srv := httptest.NewServer(h.Handler())
	defer srv.Close()

	// ten lines through a 3-row screen: L1..L7 land in history at absolute 0..6
	for i := 1; i <= 10; i++ {
		if i > 1 {
			w.Write([]byte("\r\n"))
		}
		w.Write([]byte("L" + string(rune('0'+i%10))))
	}

	c, ctx, cancel := dialFramed(t, srv, h, "s1")
	defer cancel()
	defer c.Close(websocket.StatusNormalClosure, "done")
	readGrid(t, c, ctx, cols, rows, "L8") // sync: the screen is settled

	// fetch absolute lines [2,5) — a page from the middle of history
	req := []byte{msgSbFetch, 0, 0, 0, 2, 0, 3}
	if err := c.Write(ctx, websocket.MessageBinary, req); err != nil {
		t.Fatal(err)
	}
	for {
		_, data, rerr := c.Read(ctx)
		if rerr != nil {
			t.Fatalf("read chunk: %v", rerr)
		}
		if len(data) == 0 || data[0] != msgSbChunk {
			continue // frames/state keep flowing; skip to the chunk
		}
		ch, derr := vt.DecodeSbChunk(data[1:])
		if derr != nil {
			t.Fatalf("decode chunk: %v", derr)
		}
		if ch.Base != 0 || ch.Total != 7 || ch.Start != 2 || len(ch.Lines) != 3 {
			t.Fatalf("chunk = base %d total %d start %d n %d, want 0/7/2/3",
				ch.Base, ch.Total, ch.Start, len(ch.Lines))
		}
		for j, want := range []string{"L3", "L4", "L5"} {
			var b strings.Builder
			for _, cell := range ch.Lines[j] {
				b.WriteString(cell.Content)
			}
			if got := strings.TrimRight(b.String(), " "); got != want {
				t.Fatalf("chunk line %d = %q, want %q", j, got, want)
			}
		}
		return
	}
}

// TestFramedPauseResume is the pause-hidden-panes gate: a pane the client
// declared hidden (msgVis 0) gets NO frames while the emulator keeps parsing,
// and the reveal (msgVis 1) ships the net of everything missed as one frame —
// the Surface simply went stale and the resume render diffs against it.
func TestFramedPauseResume(t *testing.T) {
	t.Setenv("XDG_DATA_HOME", t.TempDir())
	h := New()

	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	defer w.Close()
	const cols, rows = 20, 3
	s := &session{
		info:  SessionInfo{ID: "s1", Name: "s1", Workspace: "t", Cols: cols, Rows: rows, Created: time.Now()},
		pty:   r,
		cmd:   exec.Command("true"),
		emu:   newTerminal(cols, rows),
		dirty: make(chan struct{}, 1),
	}
	h.mu.Lock()
	h.sessions["s1"] = s
	h.mu.Unlock()
	go h.readPump(s)

	srv := httptest.NewServer(h.Handler())
	defer srv.Close()

	w.Write([]byte("one"))
	c, ctx, cancel := dialFramed(t, srv, h, "s1")
	defer cancel()
	defer c.Close(websocket.StatusNormalClosure, "done")
	g := readGrid(t, c, ctx, cols, rows, "one")

	// From here on a goroutine reads: a timed-out direct Read would close the
	// whole websocket (coder/websocket semantics), so silence is asserted by
	// watching a channel instead.
	msgs := make(chan []byte, 16)
	go func() {
		defer close(msgs)
		for {
			_, data, rerr := c.Read(ctx)
			if rerr != nil {
				return
			}
			msgs <- data
		}
	}()

	// hide, then let the session produce
	if err := c.Write(ctx, websocket.MessageBinary, []byte{msgVis, 0}); err != nil {
		t.Fatal(err)
	}
	time.Sleep(100 * time.Millisecond) // the input loop processes the hide
	w.Write([]byte("\r\ntwo"))

	// silence: nothing may arrive while hidden
	select {
	case m := <-msgs:
		t.Fatalf("message %v arrived while hidden", m)
	case <-time.After(400 * time.Millisecond):
	}

	// reveal: the missed output lands as a diff against what we already have
	if err := c.Write(ctx, websocket.MessageBinary, []byte{msgVis, 1}); err != nil {
		t.Fatal(err)
	}
	for gridRow(g, 1) != "two" {
		data, ok := <-msgs
		if !ok {
			t.Fatalf("connection died before the reveal frame (row1=%q)", gridRow(g, 1))
		}
		if len(data) == 0 || data[0] != msgFrame {
			continue
		}
		f, derr := vt.DecodeFrame(data[1:])
		if derr != nil {
			t.Fatalf("decode frame: %v", derr)
		}
		g.Apply(f)
	}
	if gridRow(g, 0) != "one" {
		t.Fatalf("row 0 = %q after reveal, want %q untouched", gridRow(g, 0), "one")
	}
}
