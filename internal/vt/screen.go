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

	// used is a per-PHYSICAL-row high-water mark: cells at and beyond used[py]
	// are blank. Writers maintain it (a compare per print run, not per cell);
	// the scroll path consumes it, so pushing a departing row to scrollback and
	// blanking the exposed row cost the CONTENT width, not the terminal width.
	// On wide grids that is most of the firehose cost: a 72-char log line on a
	// 405-column screen copies 72 cells, not 405 — and the mark comes from what
	// writers already know, never from scanning (a branchy trailing-blank scan
	// costs more than the memcpy it saves; measured, not guessed).
	// The bound is conservative: styled fills and blank overwrites may inflate
	// it, which costs speed, never correctness.
	used []int

	// protected: a protected cell (SPA/DECSCA) may exist somewhere on this
	// screen — erase ops take the per-cell path. Never set in normal
	// sessions, so the erase fast paths stay branch-free.
	protected bool
}

func newScreen(w, h int) *screen {
	s := &screen{w: w, h: h, cells: make([]Cell, w*h), sbot: h - 1, used: make([]int, h)}
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
	i := s.idx(x, y)
	s.cells[i] = c
	if py := i / s.w; x >= s.used[py] {
		s.used[py] = x + 1
	}
}

// fullRegion reports whether the scroll region is the whole screen — the case
// the ring fast path handles.
func (s *screen) fullRegion() bool { return s.stop == 0 && s.sbot == s.h-1 }

// clearRow fills one logical row with fill. Blank fill — the common case —
// clears only the used prefix (everything beyond is blank by invariant).
func (s *screen) clearRow(y int, fill Cell) {
	base := s.rowBase(y)
	py := base / s.w
	if fill == blank {
		row := s.cells[base : base+s.used[py]]
		for i := range row {
			row[i] = blank
		}
		s.used[py] = 0
		return
	}
	row := s.cells[base : base+s.w]
	for i := range row {
		row[i] = fill
	}
	s.used[py] = s.w
}

// clearRows fills logical rows [y0,y1] inclusive.
func (s *screen) clearRows(y0, y1 int, fill Cell) {
	for y := y0; y <= y1; y++ {
		s.clearRow(y, fill)
	}
}

// copyRow copies logical row src onto logical row dst — the src's used prefix,
// plus blanking whatever longer content dst held.
func (s *screen) copyRow(dst, src int) {
	if dst == src {
		return
	}
	db, sb := s.rowBase(dst), s.rowBase(src)
	dpy, spy := db/s.w, sb/s.w
	us := s.used[spy]
	copy(s.cells[db:db+us], s.cells[sb:sb+us])
	for i := db + us; i < db+s.used[dpy]; i++ {
		s.cells[i] = blank
	}
	s.used[dpy] = us
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
			s.sb.push(s.cells[base : base+s.used[base/s.w]])
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
	s.wrapNext = false // edit ops cancel a pending wrap (xterm/ghostty)
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
	s.wrapNext = false // edit ops cancel a pending wrap (xterm/ghostty)
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
	s.wrapNext = false // edit ops cancel a pending wrap (xterm/ghostty)
	if n <= 0 {
		return
	}
	if n > s.w-s.cx {
		n = s.w - s.cx
	}
	base := s.rowBase(s.cy)
	row := s.cells[base : base+s.w]
	// inserting AT a spacer splits its pair (the lead stays put, the spacer
	// shifts); inserting at a lead moves the pair intact — spacer-side only
	if row[s.cx].Width == 0 && s.cx > 0 && row[s.cx-1].Width == 2 {
		row[s.cx-1] = blank
	}
	copy(row[s.cx+n:], row[s.cx:s.w-n])
	for i := s.cx; i < s.cx+n; i++ {
		row[i] = fill
	}
	// a lead shifted against the right edge loses its (pushed-off) spacer
	if row[s.w-1].Width == 2 {
		row[s.w-1] = blank
	}
	if s.cx+n < s.w && row[s.cx+n].Width == 0 {
		row[s.cx+n] = blank // the shifted head was a spacer; its lead is gone
	}
	py := base / s.w
	if s.used[py] > s.cx { // shifted content moved the mark right
		s.used[py] = min(s.used[py]+n, s.w)
	}
	if fill != blank && s.cx+n > s.used[py] {
		s.used[py] = s.cx + n
	}
}

// deleteChars shifts the cursor row left by n from the cursor, pulling cells in
// from the right and filling the vacated right end (DCH).
func (s *screen) deleteChars(n int, fill Cell) {
	s.wrapNext = false // edit ops cancel a pending wrap (xterm/ghostty)
	if n <= 0 {
		return
	}
	if n > s.w-s.cx {
		n = s.w - s.cx
	}
	s.dissolveBoundary(s.cy, s.cx, min(s.cx+n-1, s.w-1))
	base := s.rowBase(s.cy)
	row := s.cells[base : base+s.w]
	copy(row[s.cx:], row[s.cx+n:s.w])
	for i := s.w - n; i < s.w; i++ {
		row[i] = fill
	}
	if row[s.cx].Width == 0 {
		row[s.cx] = blank // the pulled-in head was a spacer; its lead is gone
	}
	// content only moved left, so the old mark still bounds it — unless the
	// vacated right end was filled with something visible
	if fill != blank {
		s.used[base/s.w] = s.w
	}
}

// dissolveBoundary repairs wide pairs torn at the edges of an operation
// touching [lo,hi] on logical row y: a spacer at lo loses its lead, a lead
// at hi loses its spacer — two glyphs never overlap and spacers never
// orphan (the differential fuzzer found ECH slicing a wide glyph in half).
func (s *screen) dissolveBoundary(y, lo, hi int) {
	base := s.rowBase(y)
	row := s.cells[base : base+s.w]
	if lo > 0 && lo < s.w && row[lo].Width == 0 && row[lo-1].Width == 2 {
		row[lo-1] = blank
	}
	if hi >= 0 && hi < s.w-1 && row[hi].Width == 2 && row[hi+1].Width == 0 {
		row[hi+1] = blank
	}
}

// protErase clears [lo,hi] on logical row y, skipping protected cells — the
// slow path erase ops take once a screen has ever held protection.
func (s *screen) protErase(y, lo, hi int, fill Cell) {
	base := s.rowBase(y)
	py := base / s.w
	for x := max(lo, 0); x <= hi && x < s.w; x++ {
		if s.cells[base+x].Attr&AttrProtected == 0 {
			s.cells[base+x] = fill
		}
	}
	if fill != blank && hi >= s.used[py] {
		s.used[py] = min(hi+1, s.w)
	}
	// blank fills leave used untouched: protected cells may remain, and the
	// old mark stays a valid (conservative) bound either way
}

// eraseChars clears n cells from the cursor without moving anything (ECH).
func (s *screen) eraseChars(n int, fill Cell) {
	s.wrapNext = false // edit ops cancel a pending wrap (xterm/ghostty)
	s.dissolveBoundary(s.cy, s.cx, min(s.cx+n-1, s.w-1))
	if s.protected {
		s.protErase(s.cy, s.cx, s.cx+n-1, fill)
		return
	}
	for i := 0; i < n && s.cx+i < s.w; i++ {
		s.put(s.cx+i, s.cy, fill)
	}
}

// eraseLine clears part of the cursor row: 0 cursor→end, 1 start→cursor, 2 all.
func (s *screen) eraseLine(mode int, fill Cell) {
	s.wrapNext = false // edit ops cancel a pending wrap (xterm/ghostty)
	switch mode {
	case 0:
		s.dissolveBoundary(s.cy, s.cx, s.w-1)
	case 1:
		s.dissolveBoundary(s.cy, 0, s.cx)
	}
	if s.protected {
		switch mode {
		case 0:
			s.protErase(s.cy, s.cx, s.w-1, fill)
		case 1:
			s.protErase(s.cy, 0, s.cx, fill)
		default:
			s.protErase(s.cy, 0, s.w-1, fill)
		}
		return
	}
	switch mode {
	case 0:
		// erase-to-end is the shell redraw workhorse: with a blank fill only
		// the used tail needs writing, and the mark retreats to the cursor
		base := s.rowBase(s.cy)
		py := base / s.w
		if fill == blank {
			for x := s.cx; x < s.used[py]; x++ {
				s.cells[base+x] = blank
			}
			if s.cx < s.used[py] {
				s.used[py] = s.cx
			}
			return
		}
		for x := s.cx; x < s.w; x++ {
			s.cells[base+x] = fill
		}
		s.used[py] = s.w
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
	s.wrapNext = false // edit ops cancel a pending wrap (xterm/ghostty)
	if s.protected {
		switch mode {
		case 0:
			s.eraseLine(0, fill)
			for y := s.cy + 1; y <= s.h-1; y++ {
				s.protErase(y, 0, s.w-1, fill)
			}
		case 1:
			for y := 0; y < s.cy; y++ {
				s.protErase(y, 0, s.w-1, fill)
			}
			s.eraseLine(1, fill)
		default:
			for y := 0; y <= s.h-1; y++ {
				s.protErase(y, 0, s.w-1, fill)
			}
		}
		return
	}
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
	used := make([]int, newH)
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
		opy := oldTop + oy
		if opy >= oldH {
			opy -= oldH
		}
		used[ny] = min(s.used[opy], newW)
	}

	s.w, s.h = newW, newH
	s.cells = cells
	s.used = used
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
