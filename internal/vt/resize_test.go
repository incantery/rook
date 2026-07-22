package vt

import "testing"

func TestResizeGrowKeepsContent(t *testing.T) {
	e := New(10, 3)
	e.Write([]byte("hello\r\nworld"))
	e.Resize(20, 5)
	if e.Cols() != 20 || e.Rows() != 5 {
		t.Fatalf("geometry = %dx%d, want 20x5", e.Cols(), e.Rows())
	}
	// Top-anchored on grow: content stays where it was (rows 0,1) and the extra
	// height opens as blank rows below — a shell prompt keeps its place.
	if line(e, 0) != "hello" || line(e, 1) != "world" {
		t.Fatalf("grow: rows 0,1 = %q,%q, want hello,world", line(e, 0), line(e, 1))
	}
	if line(e, 2) != "" || line(e, 3) != "" || line(e, 4) != "" {
		t.Fatalf("grow: rows 2,3,4 should be blank, got %q,%q,%q", line(e, 2), line(e, 3), line(e, 4))
	}
}

func TestResizeShrinkWidthClipsNoReflow(t *testing.T) {
	e := New(10, 2)
	e.Write([]byte("abcdefghij"))
	e.Resize(5, 2)
	if line(e, 0) != "abcde" {
		t.Fatalf("width shrink: row 0 = %q, want abcde (clipped, not reflowed)", line(e, 0))
	}
	if line(e, 1) != "" {
		t.Fatalf("no reflow: row 1 should stay empty, got %q", line(e, 1))
	}
}

func TestResizeShrinkHeightKeepsCursorLine(t *testing.T) {
	e := New(10, 4)
	e.Write([]byte("r0\r\nr1\r\nr2\r\nr3")) // cursor ends on row 3
	e.Resize(10, 2)
	// bottom-anchored: the last two rows survive on the visible screen.
	if line(e, 0) != "r2" || line(e, 1) != "r3" {
		t.Fatalf("height shrink: rows = %q,%q, want r2,r3", line(e, 0), line(e, 1))
	}
	if _, cy := e.Cursor(); cy != 1 {
		t.Fatalf("cursor row after shrink = %d, want 1 (moved with content)", cy)
	}
}

func TestResizeShrinkPushesRowsToScrollback(t *testing.T) {
	e := New(10, 4)
	e.Write([]byte("r0\r\nr1\r\nr2\r\nr3"))
	e.Resize(10, 2) // r0,r1 fall off the top into history
	if e.ScrollbackLen() != 2 {
		t.Fatalf("scrollback len = %d, want 2", e.ScrollbackLen())
	}
	if sbLine(e, 0) != "r0" || sbLine(e, 1) != "r1" {
		t.Fatalf("scrollback = %q,%q, want r0,r1 (chronological)", sbLine(e, 0), sbLine(e, 1))
	}
}

func TestResizePreservesExistingScrollback(t *testing.T) {
	e := New(6, 2)
	// Feed enough lines that some scroll off into history.
	e.Write([]byte("L0\r\nL1\r\nL2\r\nL3\r\nL4"))
	before := e.ScrollbackLen()
	if before == 0 {
		t.Fatalf("precondition: expected some scrollback, got 0")
	}
	e.Resize(4, 2)
	if e.ScrollbackLen() < before {
		t.Fatalf("resize lost history: len %d < %d", e.ScrollbackLen(), before)
	}
	// history is clipped to the new width, not reflowed.
	if got := sbLine(e, 0); got != "L0" {
		t.Fatalf("migrated history[0] = %q, want L0", got)
	}
}

func TestResizeAltScreenReshapes(t *testing.T) {
	e := New(10, 3)
	e.Write([]byte("\x1b[?1049h")) // enter alt
	e.Write([]byte("\x1b[HALT"))
	e.Resize(20, 5)
	if e.Cols() != 20 || e.Rows() != 5 {
		t.Fatalf("alt geometry = %dx%d, want 20x5", e.Cols(), e.Rows())
	}
	// alt content bottom-anchors like the primary; the alt screen has no history.
	if e.ScrollbackLen() != 0 {
		t.Fatalf("alt screen must not produce scrollback, got %d", e.ScrollbackLen())
	}
	e.Write([]byte("\x1b[?1049l")) // back to primary — must still be 20x5
	if e.Cols() != 20 || e.Rows() != 5 {
		t.Fatalf("primary geometry after alt = %dx%d, want 20x5", e.Cols(), e.Rows())
	}
}

func TestResizeTriggersFullResend(t *testing.T) {
	e := New(10, 3)
	e.Write([]byte("hello\r\nworld"))
	s := e.NewSurface()
	e.Render(s) // client now knows the 10x3 screen

	e.Resize(20, 4)
	f := e.Render(s)
	// geometry changed, so the whole non-blank screen must resend in one frame.
	if f.Scroll != 0 {
		t.Fatalf("resize frame should not carry a scroll-op, got Scroll=%d", f.Scroll)
	}
	got := map[int]string{}
	for _, row := range f.Rows {
		s := ""
		for _, run := range row.Runs {
			for _, c := range run.Cells {
				s += c.Content
			}
		}
		got[row.Y] = trimTrailSpace(s)
	}
	// Top-anchored on grow: hello,world stay on rows 0,1.
	if got[0] != "hello" || got[1] != "world" {
		t.Fatalf("resend rows = %q, want row0=hello row1=world", got)
	}

	// and the client reconstructs the resized grid exactly from that one frame.
	cg := NewClientGrid(20, 4)
	cg.Apply(f)
	if rowString(cg, 0) != "hello" || rowString(cg, 1) != "world" {
		t.Fatalf("client after resize resend: row0=%q row1=%q", rowString(cg, 0), rowString(cg, 1))
	}
}

// trimTrailSpace drops trailing spaces from a reconstructed row string.
func trimTrailSpace(s string) string {
	i := len(s)
	for i > 0 && s[i-1] == ' ' {
		i--
	}
	return s[:i]
}

// rowString reads a ClientGrid row as a trailing-trimmed string.
func rowString(g *ClientGrid, y int) string {
	s := ""
	for x := range g.cols {
		s += g.Cell(x, y).Content
	}
	return trimTrailSpace(s)
}
