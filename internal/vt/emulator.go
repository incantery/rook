package vt

import (
	"unicode/utf8"

	"github.com/mattn/go-runewidth"
)

// Emulator is the terminal: it parses a pty byte stream into a cell grid. It
// owns two screens (the primary buffer and the alt-screen buffer a full-screen
// program owns), the current SGR pen, terminal modes, and the combined-string
// side table. Feed it bytes with Write; read the grid with Cols/Rows/CellAt.
//
// It is not safe for concurrent use — one pty, one reader goroutine per
// Emulator. That is the intended shape: goroutine-per-session, no shared state.
type Emulator struct {
	w, h    int
	primary *screen
	alt     *screen
	cur     *screen
	onAlt   bool

	// pen: the current SGR state applied to printed cells.
	fg, bg Color
	attr   Attr

	saved    savedCursor // DECSC / ESC 7 slot
	savedAlt savedCursor // cursor stashed across the ?1049 alt-screen switch

	autowrap      bool // DECAWM (?7)
	originMode    bool // DECOM (?6)
	cursorVisible bool // DECTCEM (?25)

	combined    []string       // multi-codepoint cell contents, indexed by negative Content
	combinedIdx map[string]int // intern table: cluster -> index, dedups and bounds growth
	clusterBuf  []byte         // scratch for building a cluster without allocating to probe
	pendingZWJ  bool           // last combined rune was a ZWJ — fuse the next base into it

	carry   []byte // an escape sequence split across Write calls, held for the next
	scratch []byte // reusable carry+input concat buffer

	out       []byte       // replies to queries, to be written back to the pty as input
	decModes  map[int]bool // DEC private modes seen via CSI ? h/l — for DECRQM reports
	ansiModes map[int]bool // ANSI modes seen via CSI h/l
	sbLines   int          // scrollback depth, for reset
	sbEpoch   byte         // bumps when history's absolute indices stop meaning
	// anything (resize rebuilds the ring at the new width; RIS discards it) —
	// a client compares epochs and drops its cached pages wholesale instead
	// of reasoning about how a rebuild renumbered them.

	// The theme colors, for answering OSC palette queries (OSC 4/10/11/12) — the
	// residual query.go left to the client. 0xRRGGBB. Seeded to a dark default so
	// a program never hangs on an unanswered query; the client sends the real
	// theme (SetPalette) on attach and on every theme change.
	palette     [16]uint32
	fgColor     uint32
	bgColor     uint32
	cursorColor uint32
}

// defaultPalette is a conventional 16-colour ramp — a stand-in until the client
// sends the theme. The default background is dark, so a program that reads it
// (vim's background detection) guesses dark before the real palette lands.
var defaultPalette = [16]uint32{
	0x000000, 0xcd0000, 0x00cd00, 0xcdcd00, 0x1e90ff, 0xcd00cd, 0x00cdcd, 0xe5e5e5,
	0x7f7f7f, 0xff0000, 0x00ff00, 0xffff00, 0x5c5cff, 0xff00ff, 0x00ffff, 0xffffff,
}

type savedCursor struct {
	cx, cy     int
	fg, bg     Color
	attr       Attr
	wrapNext   bool
	originMode bool
}

// DefaultScrollback is how many lines the primary screen retains by default.
const DefaultScrollback = 1000

// New returns an emulator of the given size with a cleared primary screen and
// the default scrollback depth.
func New(w, h int) *Emulator { return NewWithScrollback(w, h, DefaultScrollback) }

// NewWithScrollback is New with an explicit scrollback depth (0 disables it).
func NewWithScrollback(w, h, scrollbackLines int) *Emulator {
	if w < 1 {
		w = 1
	}
	if h < 1 {
		h = 1
	}
	e := &Emulator{
		w:             w,
		h:             h,
		primary:       newScreen(w, h),
		alt:           newScreen(w, h),
		autowrap:      true,
		cursorVisible: true,
		combinedIdx:   map[string]int{},
		// Defaults that are not false: a mode report before any h/l must say
		// wraparound is on and the cursor is visible, as xterm.js does.
		decModes:    map[int]bool{7: true, 25: true},
		ansiModes:   map[int]bool{},
		sbLines:     scrollbackLines,
		palette:     defaultPalette,
		fgColor:     0xd6deeb, // light on a dark default
		bgColor:     0x0f111a,
		cursorColor: 0xd6deeb,
	}
	if scrollbackLines > 0 {
		e.primary.sb = newScrollback(w, scrollbackLines)
	}
	e.cur = e.primary
	return e
}

// Cols and Rows are the terminal geometry.
func (e *Emulator) Cols() int { return e.w }
func (e *Emulator) Rows() int { return e.h }

// Resize changes the terminal geometry, as a SIGWINCH would. Content is
// preserved without reflow (D7): rows are clipped or padded and bottom-anchored,
// so a shrink keeps the cursor line and rows that scroll off the top of the
// primary screen enter scrollback. Both the primary and alt screens resize, so
// the geometry is correct whichever is active. The first Render after a Resize
// resends the whole screen — the client's Surface geometry no longer matches — so
// a client reconstructs the resized grid from a single frame.
func (e *Emulator) Resize(w, h int) {
	if w < 1 {
		w = 1
	}
	if h < 1 {
		h = 1
	}
	if w == e.w && h == e.h {
		return
	}
	e.primary.resize(w, h)
	e.alt.resize(w, h)
	e.w, e.h = w, h
	e.sbEpoch++ // the rebuild renumbered history; cached pages are void
	// The DECSC / alt-switch cursor slots hold absolute coordinates that may now
	// be off the grid; clamp them so a later restore lands in range.
	e.saved.cx, e.saved.cy = clampToGrid(e.saved.cx, e.saved.cy, w, h)
	e.savedAlt.cx, e.savedAlt.cy = clampToGrid(e.savedAlt.cx, e.savedAlt.cy, w, h)
}

// clampToGrid clamps (x,y) into a w×h grid.
func clampToGrid(x, y, w, h int) (int, int) {
	if x < 0 {
		x = 0
	} else if x >= w {
		x = w - 1
	}
	if y < 0 {
		y = 0
	} else if y >= h {
		y = h - 1
	}
	return x, y
}

// Cursor is the visible cursor position (logical, on the active screen).
func (e *Emulator) Cursor() (x, y int) { return e.cur.cx, e.cur.cy }

// AltScreen reports whether the alt screen is active — a full-screen program
// (vim, less, htop) owns the viewport. The client uses this to route keybinds:
// ctrl+hjkl navigates panes on the normal screen but belongs to the program on
// the alt screen.
func (e *Emulator) AltScreen() bool { return e.onAlt }

// SetPalette sets the theme colors the emulator answers OSC palette queries
// with: the default foreground/background/cursor and the 16-colour ANSI ramp,
// each 0xRRGGBB. The client sends these from its theme on attach and on a theme
// change, so a program reading the terminal's colors (vim, delta) gets the
// palette the user actually sees.
func (e *Emulator) SetPalette(fg, bg, cursor uint32, ansi [16]uint32) {
	e.fgColor, e.bgColor, e.cursorColor = fg, bg, cursor
	e.palette = ansi
}

// MouseTracking reports the mouse-reporting mode a program has enabled: level
// 0 = off, 1 = X10 (?9), 2 = normal (?1000), 3 = button-event (?1002, drags),
// 4 = any-event (?1003); and whether SGR encoding (?1006/?1016) is on. The
// client reads this to decide whether the wheel and clicks belong to the
// program (forwarded as mouse reports) or to local scrollback and selection —
// the "scrolling in Claude Code" case, where the program drives the scroll.
func (e *Emulator) MouseTracking() (level int, sgr bool) {
	switch e.mouseProtocol() {
	case 9:
		level = 1
	case 1000:
		level = 2
	case 1002:
		level = 3
	case 1003:
		level = 4
	}
	enc := e.mouseEncoding()
	return level, enc == 1006 || enc == 1016
}

// CellAt returns a copy of the visible cell at (x,y) on the active screen.
func (e *Emulator) CellAt(x, y int) Cell {
	if x < 0 || x >= e.w || y < 0 || y >= e.h {
		return blank
	}
	return e.cur.cells[e.cur.idx(x, y)]
}

// Content resolves a cell's displayed text: a single rune, a multi-codepoint
// cluster from the side table, or a space for a blank / wide-trailing cell.
func (e *Emulator) Content(c Cell) string {
	if idx, ok := c.combinedLookup(); ok {
		if idx >= 0 && idx < len(e.combined) {
			return e.combined[idx]
		}
		return " "
	}
	if c.Content <= 0 {
		return " "
	}
	return string(c.Content)
}

// fill is the cell scroll and erase clear to: a blank carrying the current SGR
// background (background-color erase — programs that set a bg then clear expect
// the cleared area to take that color).
func (e *Emulator) fill() Cell { return Cell{BG: e.bg, Width: 1} }

// Write feeds pty output into the emulator, updating the grid. It never errors
// and always consumes all of p; the (int, error) signature is io.Writer.
func (e *Emulator) Write(p []byte) (int, error) {
	n := len(p)
	if len(e.carry) > 0 {
		e.scratch = append(e.scratch[:0], e.carry...)
		e.scratch = append(e.scratch, p...)
		p = e.scratch
		e.carry = e.carry[:0]
	}
	e.parse(p)
	return n, nil
}

// parse is the bulk-scan hot loop: a run of printable ASCII is blasted into the
// grid without per-byte dispatch; everything else (UTF-8, C0 controls, escape
// sequences) takes the slow path. An escape sequence cut off at the end of p is
// carried to the next Write rather than misparsed.
func (e *Emulator) parse(b []byte) {
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
		case c == 0x1b: // ESC
			adv, incomplete := e.escape(b, i)
			if incomplete {
				e.carry = append(e.carry[:0], b[i:]...)
				return
			}
			i = adv
		case c < 0x20: // C0 control
			e.ctrl(c)
			i++
		case c == 0x7f: // DEL: ignored
			i++
		default: // c >= 0x80: UTF-8 multibyte
			if !utf8.FullRune(b[i:]) { // a codepoint split across Write calls
				e.carry = append(e.carry[:0], b[i:]...)
				return
			}
			r, sz := utf8.DecodeRune(b[i:])
			e.printRune(r)
			i += sz
		}
	}
}

// ctrl handles a C0 control byte.
func (e *Emulator) ctrl(c byte) {
	s := e.cur
	switch c {
	case '\n', '\v', '\f': // LF, VT, FF all index down
		s.lineFeed(e.fill())
	case '\r':
		s.cx = 0
		s.wrapNext = false
	case '\b':
		if s.wrapNext {
			s.wrapNext = false
		} else if s.cx > 0 {
			s.cx--
		}
	case '\t':
		s.cx = (s.cx/8 + 1) * 8
		if s.cx >= s.w {
			s.cx = s.w - 1
		}
		s.wrapNext = false
	}
}

// printASCII places a run of single-width ASCII cells, writing straight into the
// row slice. This is where the throughput is: no per-byte dispatch, no width
// lookup (ASCII is always width 1), one row-base recompute per wrap.
func (e *Emulator) printASCII(run []byte) {
	s := e.cur
	fg, bg, attr := e.fg, e.bg, e.attr
	e.pendingZWJ = false
	for j := 0; j < len(run); {
		if s.wrapNext {
			if e.autowrap {
				s.cx = 0
				s.lineFeed(e.fill())
			}
			s.wrapNext = false
		}
		space := s.w - s.cx
		if space <= 0 { // no autowrap, cursor pinned at last column
			s.cx = s.w - 1
			space = 1
		}
		k := min(len(run)-j, space)
		base := s.rowBase(s.cy)
		row := s.cells[base : base+s.w]
		for m := range k {
			row[s.cx+m] = Cell{Content: rune(run[j+m]), FG: fg, BG: bg, Attr: attr, Width: 1}
		}
		s.cx += k
		j += k
		if s.cx >= s.w {
			s.cx = s.w - 1
			if e.autowrap {
				s.wrapNext = true
			}
		}
	}
}

// printRune places one non-ASCII glyph, handling width (wide CJK, zero-width
// combining) and the ZWJ-cluster fusion that keeps an emoji family in one cell.
func (e *Emulator) printRune(r rune) {
	wd := runewidth.RuneWidth(r)
	if wd == 0 {
		e.combine(r)
		return
	}
	if e.pendingZWJ { // fuse this base onto the ZWJ cluster instead of a new cell
		e.combine(r)
		e.pendingZWJ = false
		return
	}
	s := e.cur
	if s.wrapNext {
		if e.autowrap {
			s.cx = 0
			s.lineFeed(e.fill())
		}
		s.wrapNext = false
	}
	if s.cx+wd > s.w {
		if e.autowrap {
			s.cx = 0
			s.lineFeed(e.fill())
		} else {
			s.cx = max(s.w-wd, 0)
		}
	}
	s.put(s.cx, s.cy, Cell{Content: r, FG: e.fg, BG: e.bg, Attr: e.attr, Width: uint8(wd)})
	if wd == 2 {
		s.put(s.cx+1, s.cy, Cell{FG: e.fg, BG: e.bg, Attr: e.attr, Width: 0})
	}
	s.cx += wd
	if s.cx >= s.w {
		s.cx = s.w - 1
		if e.autowrap {
			s.wrapNext = true
		}
	}
}

// combine attaches a zero-width rune (a combining mark, variation selector, or
// ZWJ) to the cell the cursor last printed, growing the side table.
func (e *Emulator) combine(r rune) {
	s := e.cur
	tx := s.cx - 1
	if s.wrapNext {
		tx = s.cx // the printed glyph is still under the cursor
	}
	if tx < 0 {
		return
	}
	cell := s.at(tx, s.cy)
	// Build the new cluster (existing content + r) into a reused scratch buffer.
	e.clusterBuf = e.clusterBuf[:0]
	if idx, ok := cell.combinedLookup(); ok {
		e.clusterBuf = append(e.clusterBuf, e.combined[idx]...)
	} else if cell.Content > 0 {
		e.clusterBuf = utf8.AppendRune(e.clusterBuf, cell.Content)
	} else {
		return
	}
	e.clusterBuf = utf8.AppendRune(e.clusterBuf, r)
	e.pendingZWJ = r == 0x200d

	// Intern it. The map probe with string(scratch) does not allocate (compiler
	// special case); only a genuinely new cluster allocates its string once.
	if idx, ok := e.combinedIdx[string(e.clusterBuf)]; ok {
		cell.Content = combinedIndex(idx)
		return
	}
	s2 := string(e.clusterBuf)
	idx := len(e.combined)
	e.combined = append(e.combined, s2)
	e.combinedIdx[s2] = idx
	cell.Content = combinedIndex(idx)
}

func (e *Emulator) snapshotCursor() savedCursor {
	return savedCursor{
		cx: e.cur.cx, cy: e.cur.cy,
		fg: e.fg, bg: e.bg, attr: e.attr,
		wrapNext: e.cur.wrapNext, originMode: e.originMode,
	}
}

func (e *Emulator) restore(sc savedCursor) {
	e.cur.cx, e.cur.cy = sc.cx, sc.cy
	e.fg, e.bg, e.attr = sc.fg, sc.bg, sc.attr
	e.cur.wrapNext = sc.wrapNext
	e.originMode = sc.originMode
	e.cur.clampCursor()
}

// ScrollbackLen reports how many lines have scrolled off the primary screen.
func (e *Emulator) ScrollbackLen() int {
	if e.primary.sb == nil {
		return 0
	}
	return e.primary.sb.count
}

// History reports the absolute index window of retained scrollback: lines
// [base, total) are fetchable, lines below base have been evicted, and total is
// the absolute index of the live screen's top row. Absolute indices are stable
// within one epoch (SbEpoch), which is what lets a client page history on
// demand instead of holding a copy.
func (e *Emulator) History() (base, total uint64) {
	sb := e.primary.sb
	if sb == nil {
		return 0, 0
	}
	return sb.pushed - uint64(sb.count), sb.pushed
}

// SbEpoch identifies the current numbering of history's absolute indices; it
// changes when a resize or reset renumbers them (see the field).
func (e *Emulator) SbEpoch() byte { return e.sbEpoch }

// ScrollbackCell returns the cell at column x of scrollback line i, where i=0 is
// the oldest retained line. Out-of-range reads return a blank cell.
func (e *Emulator) ScrollbackCell(x, i int) Cell {
	sb := e.primary.sb
	if sb == nil || i < 0 || i >= sb.count || x < 0 || x >= e.w {
		return blank
	}
	return sb.row(i)[x]
}

// reset returns the emulator to power-on state (RIS / ESC c).
func (e *Emulator) reset() {
	e.primary = newScreen(e.w, e.h)
	e.alt = newScreen(e.w, e.h)
	if e.sbLines > 0 {
		e.primary.sb = newScrollback(e.w, e.sbLines)
	}
	e.sbEpoch++ // history discarded; a client's cached pages are void
	e.cur = e.primary
	e.onAlt = false
	e.fg, e.bg, e.attr = DefaultColor, DefaultColor, 0
	e.autowrap = true
	e.originMode = false
	e.cursorVisible = true
	e.combined = e.combined[:0]
	clear(e.combinedIdx)
	clear(e.decModes)
	clear(e.ansiModes)
	e.decModes[7] = true
	e.decModes[25] = true
	e.pendingZWJ = false
}

// TakeOutput returns and clears the emulator's pending replies to terminal
// queries (DA, DSR, DECRQM, DECRQSS, …). The host writes these back to the pty
// as input. Because they go here and never into the grid, they never reach a
// rendering client — the AUTO_REPLY filtering that xterm-in-the-browser needed
// has no counterpart here.
func (e *Emulator) TakeOutput() []byte {
	if len(e.out) == 0 {
		return nil
	}
	out := e.out
	e.out = nil
	return out
}
