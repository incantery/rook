package vt

// screen is one cell buffer: the packed grid, the cursor, and the scroll
// region. A terminal has two — the primary buffer (with scrollback, later) and
// the alt-screen buffer a full-screen program like nvim owns — each with its
// own cursor, which is why cursor state lives here and not on the emulator.
//
// The grid is a flat []Cell of exactly w*h, addressed through a ring offset
// `top`: logical row 0 is physical row `top`, wrapping. A full-screen scroll is
// then O(1) (advance top, clear one row) instead of an h-row copy — the hot
// path during any firehose of output. A scroll *region* smaller than the screen
// can't ride the ring, so it falls back to moving rows in place; still zero
// allocation, just O(region) memmove.
type screen struct {
	w, h       int
	cells      []Cell
	top        int         // physical row that logical row 0 currently maps to
	cx, cy     int         // cursor, logical coordinates, always in range
	stop, sbot int         // scroll region, inclusive logical rows; default 0..h-1
	wrapNext   bool        // deferred autowrap: cursor printed to the last column
	sb         *scrollback // lines scrolled off the top; nil on the alt screen
	scrolled   int         // full-screen lines scrolled off since the last Render
}

func newScreen(w, h int) *screen {
	s := &screen{w: w, h: h, cells: make([]Cell, w*h), sbot: h - 1}
	for i := range s.cells {
		s.cells[i] = blank
	}
	return s
}

// idx maps a logical (x,y) to its physical index through the ring offset. y is
// always in [0,h) and top in [0,h), so one conditional subtract normalizes.
func (s *screen) idx(x, y int) int {
	py := s.top + y
	if py >= s.h {
		py -= s.h
	}
	return py*s.w + x
}

// rowBase is the physical index of logical row y's first cell. A logical row is
// always one physically-contiguous run of w cells, so a whole row is a slice.
func (s *screen) rowBase(y int) int { return s.idx(0, y) }

func (s *screen) at(x, y int) *Cell { return &s.cells[s.idx(x, y)] }

// put writes a cell, guarding the bounds so a stray cursor can't corrupt memory.
func (s *screen) put(x, y int, c Cell) {
	if x < 0 || x >= s.w || y < 0 || y >= s.h {
		return
	}
	s.cells[s.idx(x, y)] = c
}

// fullRegion reports whether the scroll region is the whole screen — the case
// the ring fast path handles.
func (s *screen) fullRegion() bool { return s.stop == 0 && s.sbot == s.h-1 }

// clearRow fills one logical row with fill.
func (s *screen) clearRow(y int, fill Cell) {
	base := s.rowBase(y)
	row := s.cells[base : base+s.w]
	for i := range row {
		row[i] = fill
	}
}

// clearRows fills logical rows [y0,y1] inclusive.
func (s *screen) clearRows(y0, y1 int, fill Cell) {
	for y := y0; y <= y1; y++ {
		s.clearRow(y, fill)
	}
}

// copyRow copies logical row src onto logical row dst (whole width).
func (s *screen) copyRow(dst, src int) {
	if dst == src {
		return
	}
	db, sb := s.rowBase(dst), s.rowBase(src)
	copy(s.cells[db:db+s.w], s.cells[sb:sb+s.w])
}

// scrollUpN moves the scroll region up by n rows (content scrolls off the top
// of the region, n blank rows appear at the bottom). A line feed at the bottom
// margin, DL, and the SU sequence all request this.
func (s *screen) scrollUpN(n int, fill Cell) {
	if n <= 0 {
		return
	}
	rows := s.sbot - s.stop + 1
	// A full-screen scroll pushes the departing lines to scrollback (at most the
	// whole screen). A scroll *region* smaller than the screen is a redraw within
	// margins (less, htop) — not history — so it retains nothing.
	if s.fullRegion() && s.sb != nil {
		for k := 0; k < n && k < s.h; k++ {
			base := s.rowBase(k)
			s.sb.push(s.cells[base : base+s.w])
		}
		s.scrolled += n // the wire coalesces this into one scroll-op per Render
	}
	if n >= rows {
		s.clearRows(s.stop, s.sbot, fill)
		return
	}
	if s.fullRegion() {
		// Ring fast path: rotate the whole grid up by advancing top, then clear
		// the n rows that rotated around to the bottom. No row copy.
		s.top += n
		if s.top >= s.h {
			s.top -= s.h
		}
		s.clearRows(s.h-n, s.h-1, fill)
		return
	}
	for y := s.stop; y <= s.sbot-n; y++ {
		s.copyRow(y, y+n)
	}
	s.clearRows(s.sbot-n+1, s.sbot, fill)
}

// scrollDownN scrolls the region down by n rows (content moves toward the
// bottom, n blank rows appear at the top). Reverse index at the top margin and
// IL request this.
func (s *screen) scrollDownN(n int, fill Cell) {
	if n <= 0 {
		return
	}
	rows := s.sbot - s.stop + 1
	if n >= rows {
		s.clearRows(s.stop, s.sbot, fill)
		return
	}
	if s.fullRegion() {
		s.top -= n
		if s.top < 0 {
			s.top += s.h
		}
		s.clearRows(0, n-1, fill)
		return
	}
	for y := s.sbot; y >= s.stop+n; y-- {
		s.copyRow(y, y-n)
	}
	s.clearRows(s.stop, s.stop+n-1, fill)
}

// lineFeed advances the cursor one row, scrolling the region if it is on the
// bottom margin. Column is unchanged (index, not newline).
func (s *screen) lineFeed(fill Cell) {
	if s.cy == s.sbot {
		s.scrollUpN(1, fill)
		return
	}
	if s.cy < s.h-1 {
		s.cy++
	}
}

// reverseIndex moves the cursor up one row, scrolling the region down if it is
// on the top margin (ESC M).
func (s *screen) reverseIndex(fill Cell) {
	if s.cy == s.stop {
		s.scrollDownN(1, fill)
		return
	}
	if s.cy > 0 {
		s.cy--
	}
}

// insertLines opens n blank lines at the cursor row, pushing lines below down
// and off the bottom margin (IL). Only acts inside the scroll region.
func (s *screen) insertLines(n int, fill Cell) {
	if s.cy < s.stop || s.cy > s.sbot {
		return
	}
	saved := s.stop
	s.stop = s.cy
	s.scrollDownN(n, fill)
	s.stop = saved
	s.cx = 0
}

// deleteLines removes n lines at the cursor row, pulling lines below up and
// opening blanks at the bottom margin (DL).
func (s *screen) deleteLines(n int, fill Cell) {
	if s.cy < s.stop || s.cy > s.sbot {
		return
	}
	saved := s.stop
	s.stop = s.cy
	s.scrollUpN(n, fill)
	s.stop = saved
	s.cx = 0
}

// insertChars shifts the cursor row right by n from the cursor, opening n blank
// cells (ICH). Cells pushed past the right edge fall off.
func (s *screen) insertChars(n int, fill Cell) {
	if n <= 0 {
		return
	}
	if n > s.w-s.cx {
		n = s.w - s.cx
	}
	base := s.rowBase(s.cy)
	row := s.cells[base : base+s.w]
	copy(row[s.cx+n:], row[s.cx:s.w-n])
	for i := s.cx; i < s.cx+n; i++ {
		row[i] = fill
	}
}

// deleteChars shifts the cursor row left by n from the cursor, pulling cells in
// from the right and filling the vacated right end (DCH).
func (s *screen) deleteChars(n int, fill Cell) {
	if n <= 0 {
		return
	}
	if n > s.w-s.cx {
		n = s.w - s.cx
	}
	base := s.rowBase(s.cy)
	row := s.cells[base : base+s.w]
	copy(row[s.cx:], row[s.cx+n:s.w])
	for i := s.w - n; i < s.w; i++ {
		row[i] = fill
	}
}

// eraseChars clears n cells from the cursor without moving anything (ECH).
func (s *screen) eraseChars(n int, fill Cell) {
	for i := 0; i < n && s.cx+i < s.w; i++ {
		s.put(s.cx+i, s.cy, fill)
	}
}

// eraseLine clears part of the cursor row: 0 cursor→end, 1 start→cursor, 2 all.
func (s *screen) eraseLine(mode int, fill Cell) {
	switch mode {
	case 0:
		for x := s.cx; x < s.w; x++ {
			s.put(x, s.cy, fill)
		}
	case 1:
		for x := 0; x <= s.cx && x < s.w; x++ {
			s.put(x, s.cy, fill)
		}
	default:
		s.clearRow(s.cy, fill)
	}
}

// eraseDisplay clears part of the screen: 0 cursor→end, 1 start→cursor, 2/3 all.
func (s *screen) eraseDisplay(mode int, fill Cell) {
	switch mode {
	case 0:
		s.eraseLine(0, fill)
		s.clearRows(s.cy+1, s.h-1, fill)
	case 1:
		s.clearRows(0, s.cy-1, fill)
		s.eraseLine(1, fill)
	default:
		s.clearRows(0, s.h-1, fill)
	}
}

// resize changes the screen geometry to newW×newH without reflow (reflow is a
// v1 non-goal — see D7 in the server-terminal design). Each row is clipped on
// the right or padded with blanks; content is never rewrapped. The vertical
// anchor is asymmetric, as terminals do it: a SHRINK bottom-anchors (rows scroll
// off the top into scrollback, keeping the cursor line and recent output), while
// a GROW top-anchors (content stays put and blank rows fill the bottom) — so a
// shell's prompt keeps its place instead of sliding to the middle when the pane
// grows. The ring offset is flattened (top=0) and the scroll region reset.
func (s *screen) resize(newW, newH int) {
	if newW == s.w && newH == s.h {
		return
	}
	oldW, oldH, oldTop, old := s.w, s.h, s.top, s.cells
	// logical returns old logical row y as its physical slice, through the ring.
	logical := func(y int) []Cell {
		py := oldTop + y
		if py >= oldH {
			py -= oldH
		}
		return old[py*oldW : py*oldW+oldW]
	}

	// shift>0 drops that many top rows (a shrink, bottom-anchored). A grow keeps
	// shift 0 (top-anchored), so old row y stays at new row y and the new rows
	// open up blank at the bottom.
	shift := 0
	if newH < oldH {
		shift = oldH - newH
	}

	// Rebuild scrollback at the new width (clip/pad per row via push's copy, never
	// reflow), then push the rows that fell off the top of a shrink, in order — so
	// history stays chronological: oldest retained line first, departing rows last.
	if s.sb != nil {
		nsb := newScrollback(newW, s.sb.cap)
		for i := range s.sb.count {
			nsb.push(s.sb.row(i))
		}
		for y := range shift {
			nsb.push(logical(y))
		}
		s.sb = nsb
	}

	cells := make([]Cell, newW*newH)
	for i := range cells {
		cells[i] = blank
	}
	for ny := range newH {
		oy := ny + shift
		if oy < 0 || oy >= oldH {
			continue // a blank row: the extra space a grow opened up
		}
		src := logical(oy)
		dst := cells[ny*newW : ny*newW+newW]
		for x := 0; x < newW && x < oldW; x++ {
			dst[x] = src[x]
		}
	}

	s.w, s.h = newW, newH
	s.cells = cells
	s.top = 0
	s.stop, s.sbot = 0, newH-1
	s.scrolled = 0
	s.wrapNext = false // a pending autowrap doesn't survive a geometry change
	s.cy -= shift      // move the cursor with the bottom-anchored content
	s.clampCursor()
}

// clampCursor keeps the cursor inside the grid after any move.
func (s *screen) clampCursor() {
	if s.cx < 0 {
		s.cx = 0
	}
	if s.cx >= s.w {
		s.cx = s.w - 1
	}
	if s.cy < 0 {
		s.cy = 0
	}
	if s.cy >= s.h {
		s.cy = s.h - 1
	}
}
