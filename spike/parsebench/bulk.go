// bulk is the OPTIMIZED-Go ceiling: a hand-written parser that bulk-scans
// printable ASCII runs and blasts them into the grid a row-segment at a time,
// instead of x/ansi's byte-at-a-time state machine with a closure call per
// rune. This is the technique fast terminals use — the common case (plain text
// between escape sequences) never touches the state machine.
//
// Same packed grid as emu.go. Escape handling is minimal but consumes the
// right bytes (so text is never misparsed) and does real SGR/cursor work, so
// the throughput reflects the hot path honestly rather than by skipping work.
package parsebench

import (
	"unicode/utf8"

	"github.com/mattn/go-runewidth"
)

type bulk struct {
	noWrite bool
	w, h    int
	cx, cy  int
	top     int
	fg, bg  uint32
	attr    uint8
	grid    []pcell
}

func newBulk(w, h int) *bulk { return &bulk{w: w, h: h, grid: make([]pcell, w*h)} }

func (e *bulk) idx(x, y int) int {
	py := e.top + y
	if py >= e.h {
		py -= e.h
	}
	return py*e.w + x
}

func (e *bulk) lineFeed() {
	if e.cy < e.h-1 {
		e.cy++
		return
	}
	e.top++
	if e.top >= e.h {
		e.top = 0
	}
	base := e.idx(0, e.h-1)
	for i := base; i < base+e.w; i++ {
		e.grid[i] = pcell{}
	}
}

func (e *bulk) Write(b []byte) {
	n := len(b)
	for i := 0; i < n; {
		c := b[i]
		switch {
		case c >= 0x20 && c < 0x7f: // printable ASCII: the fast path
			start := i
			i++
			for i < n && b[i] >= 0x20 && b[i] < 0x7f {
				i++
			}
			e.printASCII(b[start:i])
		case c >= 0x80: // UTF-8 multibyte
			r, sz := utf8.DecodeRune(b[i:])
			e.printRune(r)
			i += sz
		case c == 0x1b: // ESC
			i = e.escape(b, i)
		default: // C0 control
			e.ctrl(c)
			i++
		}
	}
}

// printASCII places a run of single-width cells, writing straight into the
// row slice and only recomputing the row base on a wrap. This is where the
// speed is: no per-byte dispatch, no closure, no idx() per cell.
func (e *bulk) printASCII(run []byte) {
	cell := pcell{fg: e.fg, bg: e.bg, attr: e.attr}
	for j := 0; j < len(run); {
		if e.cx >= e.w {
			e.cx = 0
			e.lineFeed()
		}
		base := e.idx(0, e.cy)
		k := e.w - e.cx
		if rem := len(run) - j; rem < k {
			k = rem
		}
		if !e.noWrite {
			row := e.grid[base+e.cx : base+e.cx+k]
			for m := 0; m < k; m++ {
				cell.r = rune(run[j+m])
				row[m] = cell
			}
		}
		e.cx += k
		j += k
	}
}

func (e *bulk) printRune(r rune) {
	wd := runewidth.RuneWidth(r)
	if wd == 0 {
		return
	}
	if e.cx >= e.w {
		e.cx = 0
		e.lineFeed()
	}
	e.grid[e.idx(e.cx, e.cy)] = pcell{r: r, fg: e.fg, bg: e.bg, attr: e.attr}
	e.cx += wd
}

func (e *bulk) ctrl(c byte) {
	switch c {
	case '\n':
		e.lineFeed()
	case '\r':
		e.cx = 0
	case '\b':
		if e.cx > 0 {
			e.cx--
		}
	case '\t':
		e.cx = (e.cx/8 + 1) * 8
		if e.cx >= e.w {
			e.cx = e.w - 1
		}
	}
}

// escape consumes one ESC-prefixed sequence starting at i (b[i]==0x1b) and
// returns the index just past it.
func (e *bulk) escape(b []byte, i int) int {
	n := len(b)
	i++ // past ESC
	if i >= n {
		return i
	}
	switch b[i] {
	case '[': // CSI: params/intermediates until a final byte 0x40..0x7e
		i++
		start := i
		for i < n && (b[i] < 0x40 || b[i] > 0x7e) {
			i++
		}
		if i < n {
			e.csi(b[start:i], b[i])
			i++
		}
		return i
	case ']': // OSC: to BEL or ST (ESC \)
		i++
		for i < n {
			if b[i] == 0x07 {
				return i + 1
			}
			if b[i] == 0x1b && i+1 < n && b[i+1] == '\\' {
				return i + 2
			}
			i++
		}
		return i
	default: // ESC ( B, ESC =, etc. — consume the one following byte
		return i + 1
	}
}

func (e *bulk) csi(params []byte, final byte) {
	var ps [16]int
	np := 0
	cur := 0
	private := false
	for _, c := range params {
		switch {
		case c >= '0' && c <= '9':
			cur = cur*10 + int(c-'0')
		case c == ';':
			if np < len(ps) {
				ps[np] = cur
				np++
			}
			cur = 0
		case c == '?':
			private = true
		}
	}
	if np < len(ps) {
		ps[np] = cur
		np++
	}
	if private {
		return // ?-prefixed modes: not part of this throughput path
	}
	p := func(i, def int) int {
		if i < np && ps[i] != 0 {
			return ps[i]
		}
		return def
	}
	switch final {
	case 'H', 'f':
		e.cy = clamp(p(0, 1)-1, 0, e.h-1)
		e.cx = clamp(p(1, 1)-1, 0, e.w-1)
	case 'A':
		e.cy = clamp(e.cy-p(0, 1), 0, e.h-1)
	case 'B':
		e.cy = clamp(e.cy+p(0, 1), 0, e.h-1)
	case 'C':
		e.cx = clamp(e.cx+p(0, 1), 0, e.w-1)
	case 'D':
		e.cx = clamp(e.cx-p(0, 1), 0, e.w-1)
	case 'G':
		e.cx = clamp(p(0, 1)-1, 0, e.w-1)
	case 'd':
		e.cy = clamp(p(0, 1)-1, 0, e.h-1)
	case 'm':
		e.sgr(ps[:np])
	case 'J', 'K':
		// erase — cheap, and rare relative to print; clear current line
		base := e.idx(0, e.cy)
		for x := 0; x < e.w; x++ {
			e.grid[base+x] = pcell{}
		}
	}
}

func (e *bulk) sgr(ps []int) {
	if len(ps) == 0 {
		e.fg, e.bg, e.attr = 0, 0, 0
		return
	}
	for i := 0; i < len(ps); i++ {
		n := ps[i]
		switch {
		case n == 0:
			e.fg, e.bg, e.attr = 0, 0, 0
		case n == 1:
			e.attr |= 1
		case n == 3:
			e.attr |= 2
		case n == 4:
			e.attr |= 4
		case n == 7:
			e.attr |= 8
		case n >= 30 && n <= 37:
			e.fg = 0x80000000 | uint32(n-30)
		case n >= 90 && n <= 97:
			e.fg = 0x80000000 | uint32(n-90+8)
		case n == 39:
			e.fg = 0
		case n >= 40 && n <= 47:
			e.bg = 0x80000000 | uint32(n-40)
		case n >= 100 && n <= 107:
			e.bg = 0x80000000 | uint32(n-100+8)
		case n == 49:
			e.bg = 0
		case n == 38 || n == 48:
			var pk uint32 = 0x80000000
			if i+1 < len(ps) && ps[i+1] == 5 && i+2 < len(ps) {
				pk |= uint32(ps[i+2])
				i += 2
			} else if i+1 < len(ps) && ps[i+1] == 2 && i+4 < len(ps) {
				pk |= uint32(ps[i+2]&0xff)<<16 | uint32(ps[i+3]&0xff)<<8 | uint32(ps[i+4]&0xff)
				i += 4
			}
			if n == 38 {
				e.fg = pk
			} else {
				e.bg = pk
			}
		}
	}
}
