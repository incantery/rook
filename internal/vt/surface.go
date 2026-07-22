package vt

// Surface is the emulator's record of what a given client currently knows: the
// last grid state sent to it. Rendering diffs the live grid against a Surface,
// emits the changed runs as a Frame, and advances the Surface to match — so the
// next Render is relative to what the client now has.
//
// A Surface holds Cell (the emulator-local encoding, including combined-cluster
// indices) rather than resolved strings, because Cell is comparable with == and
// the indices are stable for the life of the emulator — so the diff is a cheap
// value comparison, and content is resolved to a string only for cells that
// actually changed.
//
// Surfaces are per-client and live on the connection, not the emulator: a
// background session with no viewer keeps no Surface and pays nothing. This is
// the "only render the current viewed terminal" property, made concrete.
type Surface struct {
	cols, rows int
	cells      []Cell
	cursor     Cursor
}

// NewSurface returns a blank Surface matching the emulator's geometry — the
// state of a client that has seen nothing yet. Its first Render therefore
// carries the whole non-blank screen, which is the snapshot.
func (e *Emulator) NewSurface() *Surface {
	s := &Surface{cols: e.w, rows: e.h, cells: make([]Cell, e.w*e.h)}
	for i := range s.cells {
		s.cells[i] = blank
	}
	return s
}

// Render diffs the live grid against what the client knows (s), returns the
// Frame that brings the client up to date, and advances s to the current grid.
//
// It is called at frame cadence, not per Write: every write since the last
// Render has already folded into the live grid, so a firehose of intermediate
// states collapses to a single net diff. Cost is O(cols*rows) with no
// allocation for unchanged cells.
func (e *Emulator) Render(s *Surface) Frame {
	f := Frame{Cursor: Cursor{X: e.cur.cx, Y: e.cur.cy, Visible: e.cursorVisible}}
	if s.cols != e.w || s.rows != e.h {
		e.resyncSurface(s)     // geometry changed under us: full resend next
		e.primary.scrolled = 0 // scroll is moot when everything resends
	} else if e.cur == e.primary && e.primary.scrolled > 0 {
		// The primary screen scrolled since the last Render. Emit it as a scroll
		// op and shift the surface to match, so the diff below carries only the
		// newly-exposed rows, not the whole shifted screen. Capped at the screen
		// height: a burst larger than the screen replaced everything anyway (the
		// lines in between live only in the server-side scrollback ring).
		n := min(e.primary.scrolled, e.h)
		e.primary.scrolled = 0
		f.Scroll = n
		shiftSurfaceUp(s, n)
	}
	for y := range e.h {
		var runs []Run
		x := 0
		for x < e.w {
			cur := e.cellAtLogical(x, y)
			if cur == s.cells[y*e.w+x] {
				x++
				continue
			}
			start := x
			var cells []WCell
			for x < e.w {
				cur = e.cellAtLogical(x, y)
				if cur == s.cells[y*e.w+x] {
					break
				}
				cells = append(cells, e.wcell(cur))
				s.cells[y*e.w+x] = cur
				x++
			}
			runs = append(runs, Run{X: start, Cells: cells})
		}
		if len(runs) > 0 {
			f.Rows = append(f.Rows, RowRuns{Y: y, Runs: runs})
		}
	}
	s.cursor = f.Cursor
	return f
}

// cellAtLogical reads the live cell at logical (x,y) on the active screen,
// through the ring offset. Unlike CellAt it skips bounds checks (callers are
// in-range) so the diff loop stays tight.
func (e *Emulator) cellAtLogical(x, y int) Cell {
	return e.cur.cells[e.cur.idx(x, y)]
}

// wcell resolves a live Cell to its wire form, turning a combined-cluster index
// back into its string.
func (e *Emulator) wcell(c Cell) WCell {
	return WCell{Content: e.Content(c), FG: c.FG, BG: c.BG, Attr: c.Attr, Width: c.Width}
}

// shiftSurfaceUp mirrors a client scroll on the Surface: move rows up by n and
// blank the exposed bottom, so the diff that follows re-sends only what the
// client won't already have after it applies the same scroll.
func shiftSurfaceUp(s *Surface, n int) {
	if n >= s.rows {
		for i := range s.cells {
			s.cells[i] = blank
		}
		return
	}
	copy(s.cells, s.cells[n*s.cols:])
	for i := (s.rows - n) * s.cols; i < len(s.cells); i++ {
		s.cells[i] = blank
	}
}

// resyncSurface reallocates s to the current geometry and blanks it, forcing the
// next Render to resend the whole screen. Resize handling proper is a later
// slice; this keeps a stale-geometry Surface from corrupting the diff.
func (e *Emulator) resyncSurface(s *Surface) {
	s.cols, s.rows = e.w, e.h
	s.cells = make([]Cell, e.w*e.h)
	for i := range s.cells {
		s.cells[i] = blank
	}
}
