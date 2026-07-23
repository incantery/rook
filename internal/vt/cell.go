// Package vt is rook's terminal emulator: it parses a pty byte stream into an
// authoritative cell grid on the host, so the browser can become a renderer of
// diffs rather than the owner of terminal state. See
// docs/superpowers/specs/2026-07-21-server-terminal-design.md.
//
// The design bet (D3) is a PACKED, zero-allocation grid: a fixed-size Cell in a
// preallocated buffer, ring-buffer scroll, and a single codepoint per cell with
// a table width lookup — xterm.js's data model, in Go. The rare cell that needs
// more than one codepoint (a combining mark, a ZWJ emoji cluster) is the only
// one that touches a side table, so normal text writes allocate nothing. That
// zero-alloc property is what lets N background agent sessions run without the
// GC pauses that sink an allocating emulator at scale.
package vt

import "strconv"

// Color is a packed terminal color. Zero is the default (unset) color, so a
// zeroed Cell is a blank default cell — which the ring-scroll clear relies on.
//
//	bit 31 set   → non-default
//	bit 30 set   → truecolor, low 24 bits are RGB
//	bit 30 clear → palette, low 8 bits are the index (0..255)
type Color uint32

const (
	colorSet Color = 1 << 31
	colorRGB Color = 1 << 30
)

// DefaultColor is the terminal's default fg/bg — the zero value.
const DefaultColor Color = 0

// Palette returns the Color for a palette index (0..255): the 16 ANSI colors,
// the 6x6x6 cube, and the grayscale ramp.
func Palette(n uint8) Color { return colorSet | Color(n) }

// RGB returns a 24-bit truecolor Color.
func RGB(r, g, b uint8) Color {
	return colorSet | colorRGB | Color(r)<<16 | Color(g)<<8 | Color(b)
}

// IsDefault reports whether c is the terminal's default color.
func (c Color) IsDefault() bool { return c&colorSet == 0 }

// Token renders the color the way the fidelity oracle (extract-xterm.js) does,
// so a grid can be compared against xterm cell for cell: "d" default, "p<n>"
// palette, "#rrggbb" truecolor.
func (c Color) Token() string {
	if c&colorSet == 0 {
		return "d"
	}
	if c&colorRGB != 0 {
		v := uint32(c) & 0xffffff
		const hex = "0123456789abcdef"
		buf := [7]byte{'#'}
		for i := range 6 {
			buf[6-i] = hex[v&0xf]
			v >>= 4
		}
		return string(buf[:])
	}
	return "p" + strconv.Itoa(int(uint32(c)&0xff))
}

// Attr is the set of on/off character attributes, a bitfield.
type Attr uint16

const (
	AttrBold Attr = 1 << iota
	AttrItalic
	AttrUnderline
	AttrReverse
	AttrDim // faint
	AttrStrike
	AttrBlink
	AttrHidden // concealed

	// AttrProtected marks a cell guarded from erasure (SPA/EPA, DECSCA).
	// Bit 8: above the wire's attr byte, so it never reaches a renderer —
	// protection changes what erases do, not what cells look like.
	AttrProtected
)

// Token renders the attributes the way the oracle does: one letter per set
// attribute, in a fixed order, over the subset xterm's extractor reports.
// Blink/Hidden are tracked for correctness but not part of the compared token.
func (a Attr) Token() string {
	if a == 0 {
		return ""
	}
	var buf [6]byte
	n := 0
	if a&AttrBold != 0 {
		buf[n] = 'B'
		n++
	}
	if a&AttrItalic != 0 {
		buf[n] = 'I'
		n++
	}
	if a&AttrUnderline != 0 {
		buf[n] = 'U'
		n++
	}
	if a&AttrReverse != 0 {
		buf[n] = 'R'
		n++
	}
	if a&AttrDim != 0 {
		buf[n] = 'D'
		n++
	}
	if a&AttrStrike != 0 {
		buf[n] = 'S'
		n++
	}
	return string(buf[:n])
}

// Cell is one grid cell, packed into 16 bytes so the grid is a flat, cache-
// friendly, zero-per-cell-allocation array.
//
// Content is the cell's codepoint. A negative Content is an index into the
// emulator's combined-string side table (-(Content+1)): the escape hatch for
// the rare cell holding more than one codepoint — a base plus combining marks,
// or a ZWJ emoji cluster — without paying a string per cell for the common case.
//
// Width is 1 for a normal cell, 2 for the lead cell of a double-width glyph, and
// 0 for the trailing cell that glyph occupies (and for a still-blank cell).
type Cell struct {
	Content rune
	FG, BG  Color
	Attr    Attr
	Width   uint8
	_       uint8 // pad to 16 bytes; keeps the grid array aligned
}

// blank is an empty default cell: a space, width 1. xterm reports an untouched
// cell as {c:" ", w:1}, so blanks carry Width 1 (Content 0 renders as a space);
// only the trailing half of a wide glyph gets Width 0. Scroll and erase clear to
// this, or to a background-color-erase variant carrying the current SGR bg.
var blank = Cell{Width: 1}

// combinedFlag turns a side-table index into the negative Content sentinel.
func combinedIndex(i int) rune { return rune(-(i + 1)) }

// combinedLookup reverses combinedIndex; ok is false for a literal codepoint.
func (c Cell) combinedLookup() (idx int, ok bool) {
	if c.Content < 0 {
		return int(-c.Content) - 1, true
	}
	return 0, false
}
