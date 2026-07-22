package vt

import "testing"

// content is a test helper: the displayed string of the cell at (x,y).
func content(e *Emulator, x, y int) string { return e.Content(e.CellAt(x, y)) }

// line reads a whole logical row as a string, trailing blanks trimmed.
func line(e *Emulator, y int) string {
	out := []rune{}
	for x := range e.Cols() {
		out = append(out, []rune(content(e, x, y))...)
	}
	// trim trailing spaces
	i := len(out)
	for i > 0 && out[i-1] == ' ' {
		i--
	}
	return string(out[:i])
}

func TestNewGridIsBlank(t *testing.T) {
	e := New(10, 3)
	for y := range 3 {
		for x := range 10 {
			c := e.CellAt(x, y)
			if e.Content(c) != " " || c.Width != 1 {
				t.Fatalf("(%d,%d): want blank space width 1, got %q width %d", x, y, e.Content(c), c.Width)
			}
		}
	}
}

func TestPrintAndCursor(t *testing.T) {
	e := New(20, 3)
	e.Write([]byte("hello"))
	if got := line(e, 0); got != "hello" {
		t.Fatalf("line 0 = %q, want %q", got, "hello")
	}
	if x, y := e.Cursor(); x != 5 || y != 0 {
		t.Fatalf("cursor = (%d,%d), want (5,0)", x, y)
	}
}

func TestDeferredAutowrap(t *testing.T) {
	e := New(5, 3)
	e.Write([]byte("ABCDE")) // exactly fills row 0; cursor should pend at the edge
	if x, y := e.Cursor(); y != 0 || x != 4 {
		t.Fatalf("after filling row: cursor (%d,%d), want (4,0) with pending wrap", x, y)
	}
	e.Write([]byte("F")) // now it wraps
	if got := line(e, 1); got != "F" {
		t.Fatalf("row 1 = %q, want %q (F wrapped)", got, "F")
	}
	if line(e, 0) != "ABCDE" {
		t.Fatalf("row 0 corrupted: %q", line(e, 0))
	}
}

func TestAutowrapOffPilesOnLastColumn(t *testing.T) {
	e := New(5, 3)
	e.Write([]byte("\x1b[?7l")) // DECAWM off
	e.Write([]byte("ABCDEFGH"))
	if got := line(e, 0); got != "ABCDH" {
		t.Fatalf("row 0 = %q, want %q (F,G,H overwrite last col)", got, "ABCDH")
	}
	if line(e, 1) != "" {
		t.Fatalf("row 1 should be empty, got %q", line(e, 1))
	}
}

func TestTabStops(t *testing.T) {
	e := New(20, 2)
	e.Write([]byte("a\tb\tc"))
	if got := line(e, 0); got != "a       b       c" {
		t.Fatalf("tabs: %q", got)
	}
}

func TestCarriageReturnAndBackspace(t *testing.T) {
	e := New(10, 2)
	e.Write([]byte("hello\rH"))
	if got := line(e, 0); got != "Hello" {
		t.Fatalf("CR overwrite: %q", got)
	}
	e.Write([]byte("\x1b[2;1Hxy\bZ"))
	if got := line(e, 1); got != "xZ" {
		t.Fatalf("backspace: %q", got)
	}
}

func TestSGRPenAndReset(t *testing.T) {
	e := New(10, 2)
	e.Write([]byte("\x1b[1;31mR\x1b[0mN"))
	r := e.CellAt(0, 0)
	if r.Attr&AttrBold == 0 || r.FG != Palette(1) {
		t.Fatalf("R cell: attr %q fg %s, want bold + palette 1", r.Attr.Token(), r.FG.Token())
	}
	n := e.CellAt(1, 0)
	if n.Attr != 0 || !n.FG.IsDefault() {
		t.Fatalf("N cell: attr %q fg %s, want reset", n.Attr.Token(), n.FG.Token())
	}
}

func TestTruecolor(t *testing.T) {
	e := New(10, 2)
	e.Write([]byte("\x1b[38;2;255;100;0mX"))
	if got := e.CellAt(0, 0).FG.Token(); got != "#ff6400" {
		t.Fatalf("truecolor fg = %s, want #ff6400", got)
	}
}

func TestBackgroundColorErase(t *testing.T) {
	e := New(10, 2)
	e.Write([]byte("\x1b[44m\x1b[2J")) // blue bg, then clear whole display
	if got := e.CellAt(3, 1).BG.Token(); got != "p4" {
		t.Fatalf("erased cell bg = %s, want p4 (BCE)", got)
	}
}

func TestScrollOnBottomLineFeed(t *testing.T) {
	e := New(10, 3)
	e.Write([]byte("one\r\ntwo\r\nthree\r\nfour"))
	if line(e, 0) != "two" || line(e, 1) != "three" || line(e, 2) != "four" {
		t.Fatalf("scroll: rows = %q,%q,%q", line(e, 0), line(e, 1), line(e, 2))
	}
}

func TestScrollRegionConfinesScroll(t *testing.T) {
	e := New(10, 5)
	// Region rows 2..4 (1-based 2..4 -> logical 1..3). Row 0 must never move.
	e.Write([]byte("\x1b[HTOP"))
	e.Write([]byte("\x1b[2;4r"))     // DECSTBM 2..4
	e.Write([]byte("\x1b[4;1Ha\r\n")) // cursor to bottom of region, feed
	e.Write([]byte("b\r\nc\r\nd"))    // force scrolling within the region
	if line(e, 0) != "TOP" {
		t.Fatalf("row 0 moved: %q (scroll region leaked)", line(e, 0))
	}
}

func TestAltScreenIsolation(t *testing.T) {
	e := New(20, 3)
	e.Write([]byte("primary\r\n"))
	e.Write([]byte("\x1b[?1049h"))      // enter alt
	if line(e, 0) != "" {
		t.Fatalf("alt screen not cleared on entry: %q", line(e, 0))
	}
	e.Write([]byte("\x1b[HALT"))
	if line(e, 0) != "ALT" {
		t.Fatalf("alt content: %q", line(e, 0))
	}
	e.Write([]byte("\x1b[?1049l")) // leave -> primary restored
	if line(e, 0) != "primary" {
		t.Fatalf("primary not restored: %q", line(e, 0))
	}
	// cursor was on row 1 col 0 when we entered alt; it must be restored there
	if x, y := e.Cursor(); x != 0 || y != 1 {
		t.Fatalf("cursor after alt = (%d,%d), want (0,1)", x, y)
	}
}

func TestWideCharOccupiesTwoCells(t *testing.T) {
	e := New(10, 2)
	e.Write([]byte("世界"))
	lead := e.CellAt(0, 0)
	trail := e.CellAt(1, 0)
	if e.Content(lead) != "世" || lead.Width != 2 {
		t.Fatalf("lead cell = %q width %d, want 世 width 2", e.Content(lead), lead.Width)
	}
	if trail.Width != 0 {
		t.Fatalf("trailing cell width = %d, want 0", trail.Width)
	}
	if e.Content(e.CellAt(2, 0)) != "界" {
		t.Fatalf("second wide char misplaced: %q", e.Content(e.CellAt(2, 0)))
	}
}

func TestCombiningMark(t *testing.T) {
	e := New(10, 2)
	e.Write([]byte("é")) // e + combining acute
	c := e.CellAt(0, 0)
	if e.Content(c) != "é" {
		t.Fatalf("combining: cell content = %q, want %q", e.Content(c), "é")
	}
	if e.Content(e.CellAt(1, 0)) != " " {
		t.Fatalf("combining should not advance an extra cell")
	}
}

func TestEscapeSplitAcrossWrites(t *testing.T) {
	e := New(10, 2)
	// A CSI cut mid-sequence must be carried, not misparsed as text.
	e.Write([]byte("A\x1b[3"))
	e.Write([]byte("CB")) // completes CSI 3 C (cursor forward 3), then prints B
	if got := line(e, 0); got != "A   B" {
		t.Fatalf("split escape: %q, want %q", got, "A   B")
	}
}

func TestUTF8SplitAcrossWrites(t *testing.T) {
	e := New(10, 2)
	world := []byte("世") // 3 bytes
	e.Write(world[:2])    // first two bytes of the codepoint
	e.Write(world[2:])    // the rest
	if got := content(e, 0, 0); got != "世" {
		t.Fatalf("split utf8: %q, want 世", got)
	}
}
