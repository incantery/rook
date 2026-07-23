//go:build ghostty

package host

// The libghostty-vt backend (perf-strategy direction, 2026-07-22): Ghostty's
// terminal core behind our Terminal seam, for benchmarks and differential
// fuzzing against internal/vt. Built only under the `ghostty` tag so the
// normal build never needs Zig — `make ghostty-lib` produces the static
// library this links (bin/ghostty-vt, gitignored).
//
// ADAPTER V1 SCOPE: the read path renders the viewport grid and diffs it in
// Go (libghostty's per-row dirty flags arrive with a later slice), scrollback
// paging is punted (EncodeScrollback returns nil, Frame.Hist/Epoch stay 0),
// and pty query responses are not yet plumbed (TakeOutput returns nil — the
// WRITE_PTY effect needs a cgo callback registry). Enough Terminal for the
// pipeline benchmarks and the grid-level fuzz oracle; not yet a daily driver.

/*
#cgo CFLAGS: -I${SRCDIR}/../../bin/ghostty-vt/include
#cgo LDFLAGS: ${SRCDIR}/../../bin/ghostty-vt/lib/libghostty-vt.a
#include <stdlib.h>
#include <string.h>
#include <ghostty/vt.h>

// sized-struct init helpers (GHOSTTY_INIT_SIZED is a C macro cgo can't call)
static GhosttyStyle ghostty_style_sized() {
    GhosttyStyle s;
    memset(&s, 0, sizeof(s));
    s.size = sizeof(s);
    return s;
}
*/
import "C"

import (
	"runtime"
	"unicode/utf8"
	"unsafe"

	"github.com/incantery/rook/internal/vt"
)

// ghosttyTerminal adapts libghostty-vt to the Terminal seam.
type ghosttyTerminal struct {
	term  C.GhosttyTerminal
	rs    C.GhosttyRenderState
	it    C.GhosttyRenderStateRowIterator
	cells C.GhosttyRenderStateRowCells
	cols  int
	rows  int
}

// ghosttySurface is what one framed client has seen: the flat wire-cell grid
// of the last frame plus its cursor. The diff runs in Go, cell by cell.
type ghosttySurface struct {
	cells  []vt.WCell
	cursor vt.Cursor
	cols   int
	rows   int
	primed bool
}

func newGhosttyTerminal(cols, rows int) Terminal {
	t := &ghosttyTerminal{cols: cols, rows: rows}
	opts := C.GhosttyTerminalOptions{
		cols:           C.uint16_t(cols),
		rows:           C.uint16_t(rows),
		max_scrollback: C.size_t(vt.DefaultScrollback),
	}
	if C.ghostty_terminal_new(nil, &t.term, opts) != C.GHOSTTY_SUCCESS {
		panic("ghostty: terminal_new failed")
	}
	if C.ghostty_render_state_new(nil, &t.rs) != C.GHOSTTY_SUCCESS ||
		C.ghostty_render_state_row_iterator_new(nil, &t.it) != C.GHOSTTY_SUCCESS ||
		C.ghostty_render_state_row_cells_new(nil, &t.cells) != C.GHOSTTY_SUCCESS {
		panic("ghostty: render state alloc failed")
	}
	// The C-side allocations (terminal + scrollback + render state) are
	// invisible to Go's GC. The finalizer is the backstop; hot loops (the
	// differential fuzzer creates a terminal PER INPUT) must call free
	// explicitly — leaking these once OOMed the machine across hour-long
	// fuzz runs.
	runtime.SetFinalizer(t, func(t *ghosttyTerminal) { t.free() })
	return t
}

// free releases the C-side state. Safe to call more than once.
func (t *ghosttyTerminal) free() {
	if t.term == nil {
		return
	}
	C.ghostty_render_state_row_cells_free(t.cells)
	C.ghostty_render_state_row_iterator_free(t.it)
	C.ghostty_render_state_free(t.rs)
	C.ghostty_terminal_free(t.term)
	t.term, t.rs, t.it, t.cells = nil, nil, nil, nil
	runtime.SetFinalizer(t, nil)
}

func (t *ghosttyTerminal) Write(p []byte) (int, error) {
	if len(p) == 0 {
		return 0, nil
	}
	C.ghostty_terminal_vt_write(t.term, (*C.uint8_t)(unsafe.Pointer(&p[0])), C.size_t(len(p)))
	return len(p), nil
}

// TakeOutput: v1 punts pty query responses (needs a WRITE_PTY cgo callback).
func (t *ghosttyTerminal) TakeOutput() []byte { return nil }

func (t *ghosttyTerminal) Resize(cols, rows int) {
	t.cols, t.rows = cols, rows
	// nominal cell pixels — only surfaced in XTWINOPS size reports
	C.ghostty_terminal_resize(t.term, C.uint16_t(cols), C.uint16_t(rows), 8, 16)
}

func (t *ghosttyTerminal) SetPalette(fg, bg, cursor uint32, ansi [16]uint32) {
	toRgb := func(v uint32) C.GhosttyColorRgb {
		return C.GhosttyColorRgb{
			r: C.uint8_t(v >> 16),
			g: C.uint8_t(v >> 8),
			b: C.uint8_t(v),
		}
	}
	f, b2, cu := toRgb(fg), toRgb(bg), toRgb(cursor)
	C.ghostty_terminal_set(t.term, C.GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND, unsafe.Pointer(&f))
	C.ghostty_terminal_set(t.term, C.GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND, unsafe.Pointer(&b2))
	C.ghostty_terminal_set(t.term, C.GHOSTTY_TERMINAL_OPT_COLOR_CURSOR, unsafe.Pointer(&cu))
	var pal [256]C.GhosttyColorRgb
	for i, v := range ansi {
		pal[i] = toRgb(v)
	}
	for i := 16; i < 256; i++ {
		pal[i] = toRgb(xterm256(i))
	}
	C.ghostty_terminal_set(t.term, C.GHOSTTY_TERMINAL_OPT_COLOR_PALETTE, unsafe.Pointer(&pal))
}

// xterm256 computes the standard 256-color cube/grayscale for indices 16-255.
func xterm256(n int) uint32 {
	if n < 232 {
		v := func(i int) uint32 {
			if i == 0 {
				return 0
			}
			return uint32(55 + i*40)
		}
		i := n - 16
		return v(i/36)<<16 | v((i%36)/6)<<8 | v(i%6)
	}
	g := uint32(8 + (n-232)*10)
	return g<<16 | g<<8 | g
}

func (t *ghosttyTerminal) AltScreen() bool {
	var screen C.GhosttyTerminalScreen
	if C.ghostty_terminal_get(t.term, C.GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, unsafe.Pointer(&screen)) != C.GHOSTTY_SUCCESS {
		return false
	}
	return screen == C.GHOSTTY_TERMINAL_SCREEN_ALTERNATE
}

func (t *ghosttyTerminal) MouseTracking() (level int, sgr bool) {
	mode := func(n uint16) bool {
		var v C.bool
		if C.ghostty_terminal_mode_get(t.term, C.GhosttyMode(n&0x7fff), &v) != C.GHOSTTY_SUCCESS {
			return false
		}
		return bool(v)
	}
	switch {
	case mode(1003):
		level = 4
	case mode(1002):
		level = 3
	case mode(1000):
		level = 2
	case mode(9):
		level = 1
	}
	return level, mode(1006)
}

// EncodeScrollback: v1 punts history paging — the framed client sees an empty
// ring (no scrollback view on this backend yet).
func (t *ghosttyTerminal) EncodeScrollback(start uint64, count int) []byte { return nil }

func (t *ghosttyTerminal) NewSurface() Surface {
	return &ghosttySurface{cols: t.cols, rows: t.rows}
}

// Render snapshots the viewport through the render-state API, diffs against
// the surface in Go, and emits changed rows as whole-row runs. Scroll/Hist
// stay 0 in v1: a scrolled screen arrives as a full-viewport diff.
func (t *ghosttyTerminal) Render(s Surface) vt.Frame {
	surf := s.(*ghosttySurface)
	grid := t.snapshot()

	var f vt.Frame
	f.Cursor = t.cursorState()

	if surf.cols != t.cols || surf.rows != t.rows || !surf.primed {
		surf.cells = make([]vt.WCell, t.cols*t.rows)
		for i := range surf.cells {
			surf.cells[i] = vt.WCell{Content: " ", Width: 1}
		}
		surf.cols, surf.rows = t.cols, t.rows
		surf.primed = true
	}

	for y := 0; y < t.rows; y++ {
		base := y * t.cols
		row := grid[base : base+t.cols]
		prev := surf.cells[base : base+t.cols]
		changed := false
		for x := range row {
			if row[x] != prev[x] {
				changed = true
				break
			}
		}
		if !changed {
			continue
		}
		cells := make([]vt.WCell, t.cols)
		copy(cells, row)
		f.Rows = append(f.Rows, vt.RowRuns{Y: y, Runs: []vt.Run{{X: 0, Cells: cells}}})
		copy(prev, row)
	}
	surf.cursor = f.Cursor
	return f
}

func (t *ghosttyTerminal) cursorState() vt.Cursor {
	var cx, cy C.uint16_t
	var vis C.bool
	C.ghostty_terminal_get(t.term, C.GHOSTTY_TERMINAL_DATA_CURSOR_X, unsafe.Pointer(&cx))
	C.ghostty_terminal_get(t.term, C.GHOSTTY_TERMINAL_DATA_CURSOR_Y, unsafe.Pointer(&cy))
	C.ghostty_terminal_get(t.term, C.GHOSTTY_TERMINAL_DATA_CURSOR_VISIBLE, unsafe.Pointer(&vis))
	return vt.Cursor{X: int(cx), Y: int(cy), Visible: bool(vis)}
}

// snapshot reads the whole viewport into wire cells. Wide glyphs come back as
// a lead cell (width 2) plus a spacer (width 0), matching internal/vt.
func (t *ghosttyTerminal) snapshot() []vt.WCell {
	grid := make([]vt.WCell, t.cols*t.rows)
	for i := range grid {
		grid[i] = vt.WCell{Content: " ", Width: 1}
	}
	if C.ghostty_render_state_update(t.rs, t.term) != C.GHOSTTY_SUCCESS {
		return grid
	}
	if C.ghostty_render_state_get(t.rs, C.GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, unsafe.Pointer(&t.it)) != C.GHOSTTY_SUCCESS {
		return grid
	}
	y := 0
	for C.ghostty_render_state_row_iterator_next(t.it) && y < t.rows {
		if C.ghostty_render_state_row_get(t.it, C.GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, unsafe.Pointer(&t.cells)) != C.GHOSTTY_SUCCESS {
			y++
			continue
		}
		x := 0
		for C.ghostty_render_state_row_cells_next(t.cells) && x < t.cols {
			cell := &grid[y*t.cols+x]

			// raw cell for the wide property
			var raw C.GhosttyCell
			C.ghostty_render_state_row_cells_get(t.cells, C.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW, unsafe.Pointer(&raw))
			var wide C.GhosttyCellWide
			C.ghostty_cell_get(raw, C.GHOSTTY_CELL_DATA_WIDE, unsafe.Pointer(&wide))

			switch wide {
			case C.GHOSTTY_CELL_WIDE_SPACER_TAIL:
				// the trailing half of a wide glyph; internal/vt renders it
				// as a width-0 space
				*cell = vt.WCell{Content: " ", Width: 0}
				x++
				continue
			case C.GHOSTTY_CELL_WIDE_WIDE:
				cell.Width = 2
			default: // narrow or soft-wrap spacer head
				cell.Width = 1
			}

			var n C.uint32_t
			C.ghostty_render_state_row_cells_get(t.cells, C.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_LEN, unsafe.Pointer(&n))
			if n > 0 {
				cps := make([]C.uint32_t, n)
				C.ghostty_render_state_row_cells_get(t.cells, C.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_BUF, unsafe.Pointer(&cps[0]))
				var buf []byte
				for _, cp := range cps {
					buf = utf8.AppendRune(buf, rune(cp))
				}
				cell.Content = string(buf)
			} else {
				cell.Content = " "
			}

			st := C.ghostty_style_sized()
			C.ghostty_render_state_row_cells_get(t.cells, C.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE, unsafe.Pointer(&st))
			cell.FG = styleColor(st.fg_color)
			cell.BG = styleColor(st.bg_color)
			cell.Attr = styleAttr(&st)

			// A background-color-erased cell carries its bg in the CONTENT
			// tag, not the style (ghostty's BCE representation) — read it
			// with palette fidelity via the raw-cell queries.
			var tag C.GhosttyCellContentTag
			C.ghostty_cell_get(raw, C.GHOSTTY_CELL_DATA_CONTENT_TAG, unsafe.Pointer(&tag))
			switch tag {
			case C.GHOSTTY_CELL_CONTENT_BG_COLOR_PALETTE:
				var idx C.GhosttyColorPaletteIndex
				C.ghostty_cell_get(raw, C.GHOSTTY_CELL_DATA_COLOR_PALETTE, unsafe.Pointer(&idx))
				cell.BG = vt.Palette(uint8(idx))
			case C.GHOSTTY_CELL_CONTENT_BG_COLOR_RGB:
				var rgb C.GhosttyColorRgb
				C.ghostty_cell_get(raw, C.GHOSTTY_CELL_DATA_COLOR_RGB, unsafe.Pointer(&rgb))
				cell.BG = vt.RGB(uint8(rgb.r), uint8(rgb.g), uint8(rgb.b))
			}
			x++
		}
		y++
	}
	return grid
}

func styleColor(c C.GhosttyStyleColor) vt.Color {
	switch c.tag {
	case C.GHOSTTY_STYLE_COLOR_PALETTE:
		return vt.Palette(*(*uint8)(unsafe.Pointer(&c.value)))
	case C.GHOSTTY_STYLE_COLOR_RGB:
		rgb := (*C.GhosttyColorRgb)(unsafe.Pointer(&c.value))
		return vt.RGB(uint8(rgb.r), uint8(rgb.g), uint8(rgb.b))
	default:
		return vt.DefaultColor
	}
}

func styleAttr(st *C.GhosttyStyle) vt.Attr {
	var a vt.Attr
	if st.bold {
		a |= vt.AttrBold
	}
	if st.italic {
		a |= vt.AttrItalic
	}
	if st.underline != 0 {
		a |= vt.AttrUnderline
	}
	if st.inverse {
		a |= vt.AttrReverse
	}
	if st.faint {
		a |= vt.AttrDim
	}
	if st.strikethrough {
		a |= vt.AttrStrike
	}
	if st.blink {
		a |= vt.AttrBlink
	}
	if st.invisible {
		a |= vt.AttrHidden
	}
	return a
}
