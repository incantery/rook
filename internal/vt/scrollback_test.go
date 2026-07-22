package vt

import (
	"fmt"
	"strings"
	"testing"
)

// sbLine reads scrollback line i as a string, trailing blanks trimmed.
func sbLine(e *Emulator, i int) string {
	var b strings.Builder
	for x := range e.Cols() {
		b.WriteString(e.Content(e.ScrollbackCell(x, i)))
	}
	return strings.TrimRight(b.String(), " ")
}

func TestScrollbackCapturesScrolledLines(t *testing.T) {
	e := New(10, 3)
	e.Write([]byte("aaa\r\nbbb\r\nccc")) // fills three rows, nothing scrolled yet
	if e.ScrollbackLen() != 0 {
		t.Fatalf("scrollback = %d before any scroll, want 0", e.ScrollbackLen())
	}

	e.Write([]byte("\r\nddd")) // pushes aaa off the top
	if e.ScrollbackLen() != 1 || sbLine(e, 0) != "aaa" {
		t.Fatalf("after one scroll: len=%d line0=%q, want 1 / aaa", e.ScrollbackLen(), sbLine(e, 0))
	}
	if line(e, 0) != "bbb" || line(e, 2) != "ddd" {
		t.Fatalf("visible after scroll: %q..%q, want bbb..ddd", line(e, 0), line(e, 2))
	}

	e.Write([]byte("\r\neee")) // pushes bbb off
	if e.ScrollbackLen() != 2 || sbLine(e, 0) != "aaa" || sbLine(e, 1) != "bbb" {
		t.Fatalf("after two scrolls: len=%d [%q,%q], want 2 / aaa,bbb", e.ScrollbackLen(), sbLine(e, 0), sbLine(e, 1))
	}
}

func TestScrollbackRingEvictsOldest(t *testing.T) {
	e := NewWithScrollback(10, 2, 3) // cap 3 lines
	for i := 1; i <= 8; i++ {
		e.Write(fmt.Appendf(nil, "L%d", i))
		if i < 8 {
			e.Write([]byte("\r\n"))
		}
	}
	// 8 lines into 2 rows scrolls L1..L6 off; cap 3 keeps the last three.
	if e.ScrollbackLen() != 3 {
		t.Fatalf("scrollback len = %d, want 3 (capped)", e.ScrollbackLen())
	}
	if sbLine(e, 0) != "L4" || sbLine(e, 1) != "L5" || sbLine(e, 2) != "L6" {
		t.Fatalf("ring = [%q,%q,%q], want L4,L5,L6", sbLine(e, 0), sbLine(e, 1), sbLine(e, 2))
	}
	if line(e, 0) != "L7" || line(e, 1) != "L8" {
		t.Fatalf("visible = [%q,%q], want L7,L8", line(e, 0), line(e, 1))
	}
}

func TestAltScreenHasNoScrollback(t *testing.T) {
	e := New(10, 3)
	e.Write([]byte("aaa\r\nbbb\r\nccc\r\nddd")) // one line (aaa) scrolls off
	if e.ScrollbackLen() != 1 {
		t.Fatalf("primary scrollback = %d, want 1", e.ScrollbackLen())
	}
	e.Write([]byte("\x1b[?1049h"))           // enter alt
	e.Write([]byte("p\r\nq\r\nr\r\ns\r\nt")) // scroll heavily on the alt screen
	if e.ScrollbackLen() != 1 {
		t.Fatalf("alt-screen scrolling changed scrollback to %d, want 1", e.ScrollbackLen())
	}
	e.Write([]byte("\x1b[?1049l")) // back to primary
	if e.ScrollbackLen() != 1 || sbLine(e, 0) != "aaa" {
		t.Fatalf("after leaving alt: len=%d line0=%q, want 1 / aaa", e.ScrollbackLen(), sbLine(e, 0))
	}
}

func TestScrollRegionAddsNoScrollback(t *testing.T) {
	e := New(10, 5)
	e.Write([]byte("\x1b[2;4r"))                 // scroll region rows 2..4
	e.Write([]byte("\x1b[4;1Ha\r\nb\r\nc\r\nd")) // scroll within the region
	if e.ScrollbackLen() != 0 {
		t.Fatalf("region scroll added %d scrollback lines, want 0", e.ScrollbackLen())
	}
}

func TestScrollbackPushIsZeroAlloc(t *testing.T) {
	e := New(10, 3)
	data := []byte("a line of text\r\n") // scrolls once past the third row
	allocs := testing.AllocsPerRun(500, func() { e.Write(data) })
	if allocs != 0 {
		t.Errorf("scrollback push allocated %.1f/op, want 0", allocs)
	}
}
