// A minimal PACKED-cell emulator, to measure the ceiling of "build our own".
//
// Why x/vt (4-43 MiB/s) loses to xterm.js: x/vt stores each cell's content as a
// Go string and runs grapheme segmentation per cell, and its scrollback
// allocates a Go object per scrolled line — 13M allocations over 16 MiB of
// git output. xterm packs each cell into fixed ints with zero per-cell
// allocation. This does the same: a fixed-size cell in a preallocated grid,
// single rune + table width lookup, and a RING-BUFFER scroll (advance a top
// offset, clear one row) instead of copying the grid.
//
// It reuses x/ansi's parser — the fiddly, correctness-critical tokenizer our
// fidelity diff already validated at 100% — and owns only the grid, the
// mechanical part. Enough of print / cursor / SGR / erase / scroll that the
// throughput number reflects real work, not a toy.
package parsebench

import (
	"github.com/charmbracelet/x/ansi"
	"github.com/mattn/go-runewidth"
)

type pcell struct {
	r      rune
	fg, bg uint32 // 0 = default; high bit marks "has color"
	attr   uint8
}

type packed struct {
	w, h   int
	cx, cy int
	top    int // physical row of logical row 0 — the ring offset
	fg, bg uint32
	attr   uint8
	grid   []pcell // w*h, preallocated once
	parser *ansi.Parser
}

func newPacked(w, h int) *packed {
	e := &packed{w: w, h: h, grid: make([]pcell, w*h)}
	p := ansi.NewParser()
	p.SetHandler(ansi.Handler{Print: e.print, Execute: e.exec, HandleCsi: e.csi})
	e.parser = p
	return e
}

func (e *packed) Write(b []byte) { e.parser.Parse(b) }

// idx maps a logical (x,y) to a physical cell through the ring offset. y is
// always in [0,h) and top in [0,h), so one conditional subtract suffices.
func (e *packed) idx(x, y int) int {
	py := e.top + y
	if py >= e.h {
		py -= e.h
	}
	return py*e.w + x
}

func (e *packed) print(r rune) {
	wd := runewidth.RuneWidth(r) // table lookup — the cheap path xterm uses
	if wd == 0 {
		return // combining mark; a real emulator merges into prev cell
	}
	if e.cx >= e.w {
		e.cx = 0
		e.lineFeed()
	}
	e.grid[e.idx(e.cx, e.cy)] = pcell{r: r, fg: e.fg, bg: e.bg, attr: e.attr}
	e.cx += wd
}

func (e *packed) exec(b byte) {
	switch b {
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

func (e *packed) lineFeed() {
	if e.cy < e.h-1 {
		e.cy++
		return
	}
	// at the bottom: scroll up one row. Ring: advance top, clear the row that
	// becomes the new bottom — O(w), no grid copy.
	e.top++
	if e.top >= e.h {
		e.top = 0
	}
	base := e.idx(0, e.h-1)
	for i := base; i < base+e.w; i++ {
		e.grid[i] = pcell{}
	}
}

func (e *packed) csi(cmd ansi.Cmd, params ansi.Params) {
	p := func(i, def int) int {
		v, _, _ := params.Param(i, def)
		if v == 0 {
			return def
		}
		return v
	}
	switch cmd.Final() {
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
	case 'J':
		e.eraseDisplay(p(0, 0))
	case 'K':
		e.eraseLine(p(0, 0))
	case 'm':
		e.sgr(params)
	}
}

func (e *packed) sgr(params ansi.Params) {
	if len(params) == 0 {
		e.fg, e.bg, e.attr = 0, 0, 0
		return
	}
	for i := 0; i < len(params); i++ {
		n, _, _ := params.Param(i, 0)
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
			mode, _, _ := params.Param(i+1, 0)
			var pk uint32 = 0x80000000
			switch mode {
			case 5:
				v, _, _ := params.Param(i+2, 0)
				pk |= uint32(v)
				i += 2
			case 2:
				r, _, _ := params.Param(i+2, 0)
				g, _, _ := params.Param(i+3, 0)
				bl, _, _ := params.Param(i+4, 0)
				pk |= uint32(r&0xff)<<16 | uint32(g&0xff)<<8 | uint32(bl&0xff)
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

func (e *packed) eraseDisplay(mode int) {
	switch mode {
	case 0:
		e.clearRange(e.cx, e.cy, e.w-1, e.h-1)
	case 1:
		e.clearRange(0, 0, e.cx, e.cy)
	default:
		for i := range e.grid {
			e.grid[i] = pcell{}
		}
	}
}

func (e *packed) eraseLine(mode int) {
	switch mode {
	case 0:
		e.clearRange(e.cx, e.cy, e.w-1, e.cy)
	case 1:
		e.clearRange(0, e.cy, e.cx, e.cy)
	default:
		e.clearRange(0, e.cy, e.w-1, e.cy)
	}
}

// clearRange clears logical cells from (x0,y0) to (x1,y1) inclusive, in
// reading order — mapped through the ring so it stays correct after a scroll.
func (e *packed) clearRange(x0, y0, x1, y1 int) {
	for y := y0; y <= y1; y++ {
		xs, xe := 0, e.w-1
		if y == y0 {
			xs = x0
		}
		if y == y1 {
			xe = x1
		}
		for x := xs; x <= xe; x++ {
			e.grid[e.idx(x, y)] = pcell{}
		}
	}
}

func clamp(v, lo, hi int) int {
	if v < lo {
		return lo
	}
	if v > hi {
		return hi
	}
	return v
}
