package vt

import (
	"unicode"
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
	fg, bg  Color
	attr    Attr
	protect bool // SPA/DECSCA: printed cells are guarded from erasure

	saved    savedCursor // DECSC / ESC 7 slot
	savedAlt savedCursor // cursor stashed across the ?1049 alt-screen switch

	autowrap      bool // DECAWM (?7)
	originMode    bool // DECOM (?6)
	cursorVisible bool // DECTCEM (?25)
	insertMode    bool // IRM (ANSI mode 4): printing shifts, not overwrites
	newlineMode   bool // LNM (ANSI mode 20): LF implies CR

	// Charsets: G0..G3 designators (ESC ( ) * + X) and the GL locking shift
	// (SO/SI/LS2/LS3). Only 'B' (ASCII), '0' (DEC Special Graphics — the
	// ncurses ACS set) and 'A' (UK) are meaningful. Found by the libghostty
	// differential oracle: TUI borders drawn via smacs/rmacs printed as
	// literal "lqk" instead of box glyphs.
	g     [4]byte // charset designators; zero value means ASCII
	shift int     // which G-set GL maps to (0..3)
	ss    int     // single shift (SS2/SS3): the NEXT glyph uses g[ss]; 0 = none

	// tabs: custom tab stops (HTS/TBC). nil means the default every-8 stops —
	// the common case pays no allocation and no scan.
	tabs []bool

	// lastGlyph is the most recent graphic character placed, for REP (CSI b).
	lastGlyph rune

	// wrapOps counts control/escape operations that arrived while a wrap was
	// pending — the state where terminal implementations genuinely disagree
	// (the differential fuzzer skips such streams; see WrapOps).
	wrapOps int

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
	// DECSC also saves the charset state (found by the differential fuzzer:
	// DECRC left DEC graphics active). The zero value is ASCII/G0, so a
	// restore with no prior save resets to defaults, as xterm does.
	g       [4]byte
	shift   int
	protect bool
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
	// Custom tab stops keep their columns; new columns get the every-8 default.
	if e.tabs != nil {
		tabs := make([]bool, w)
		n := copy(tabs, e.tabs)
		for x := (n/8 + 1) * 8; x < w; x += 8 {
			tabs[x] = true
		}
		e.tabs = tabs
	}
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
		default: // c >= 0x80: a run of UTF-8 bytes, decoded and placed in bulk
			start := i
			i++
			for i < n && b[i] >= 0x80 {
				i++
			}
			run := b[start:i]
			if i == n {
				// The run ends the buffer: a trailing incomplete sequence is
				// carried to the next Write instead of misparsed. Find the
				// last lead byte within the final 3 bytes.
				j := len(run)
				for k := 1; k <= 3 && k <= len(run); k++ {
					if run[len(run)-k] >= 0xc0 {
						j = len(run) - k
						break
					}
				}
				if j < len(run) && !utf8.FullRune(run[j:]) {
					e.carry = append(e.carry[:0], run[j:]...)
					run = run[:j]
				}
			}
			e.printUTF8(run)
		}
	}
}

// printUTF8 decodes and places a run of non-ASCII bytes with the pen and row
// hoisted out of the per-rune path — the unicode counterpart of printASCII.
// Invalid sequences substitute one U+FFFD per maximal subpart (Unicode §3.9;
// pinned by the libghostty differential oracle).
func (e *Emulator) printUTF8(p []byte) {
	s := e.cur
	fg, bg, attr := e.fg, e.bg, e.attr
	if e.protect {
		attr |= AttrProtected
		s.protected = true
	}
	e.ss = 0 // a non-ASCII glyph consumes a pending single shift untranslated
	var row []Cell
	var py int // physical row index of `row`, for the high-water mark
	for len(p) > 0 {
		r, sz := utf8.DecodeRune(p)
		if r == utf8.RuneError && sz == 1 {
			sz = invalidUTF8Len(p)
		}
		p = p[sz:]
		wd := runeCellWidth(r)
		if wd == 0 {
			e.combine(r)
			continue
		}
		if e.pendingZWJ { // fuse this base onto the ZWJ cluster
			e.combine(r)
			e.pendingZWJ = false
			continue
		}
		e.lastGlyph = r
		if s.wrapNext {
			if e.autowrap {
				s.cx = 0
				s.lineFeed(e.fill())
				row = nil
			}
			s.wrapNext = false
		}
		if s.cx+wd > s.w {
			if e.autowrap {
				// a wide glyph that doesn't fit pads the abandoned tail with
				// pen-styled blanks (the xterm/ghostty spacer head), then wraps
				if row == nil {
					base := s.rowBase(s.cy)
					py = base / s.w
					row = s.cells[base : base+s.w]
				}
				for x := s.cx; x < s.w; x++ {
					row[x] = Cell{FG: fg, BG: bg, Attr: attr, Width: 1}
				}
				s.used[py] = s.w
				s.cx = 0
				s.lineFeed(e.fill())
				row = nil
			} else {
				s.cx = max(s.w-wd, 0)
			}
		}
		if e.insertMode { // IRM: shift the tail right, then overwrite
			s.insertChars(wd, blank)
			row = nil
		}
		if row == nil {
			base := s.rowBase(s.cy)
			py = base / s.w
			row = s.cells[base : base+s.w]
		}
		// repair any wide pair this write tears (boundary cells only)
		if row[s.cx].Width == 0 && s.cx > 0 && row[s.cx-1].Width == 2 {
			row[s.cx-1] = blank
		}
		if end := s.cx + wd - 1; end < s.w && row[end].Width == 2 && end+1 < s.w {
			row[end+1] = blank
		}
		row[s.cx] = Cell{Content: r, FG: fg, BG: bg, Attr: attr, Width: uint8(wd)}
		if wd == 2 && s.cx+1 < s.w {
			row[s.cx+1] = Cell{Width: 0}
		}
		if hw := s.cx + wd; hw > s.used[py] {
			s.used[py] = min(hw, s.w)
		}
		s.cx += wd
		if s.cx >= s.w {
			s.cx = s.w - 1
			if e.autowrap {
				s.wrapNext = true
			}
		}
	}
}

// invalidUTF8Len returns the length of the maximal subpart of an ill-formed
// UTF-8 sequence at the start of b (Unicode 15 §3.9 "U+FFFD Substitution of
// Maximal Subparts"): the longest prefix that could still begin a valid
// sequence, minimum 1. The WHATWG-table second-byte constraints matter — an
// overlong or out-of-range continuation ends the subpart at the lead byte.
func invalidUTF8Len(b []byte) int {
	lead := b[0]
	var lo, hi byte // valid range for the SECOND byte
	var want int    // continuation bytes a complete sequence needs
	switch {
	case lead >= 0xc2 && lead <= 0xdf:
		return 1 // a valid continuation would have decoded; the lead stands alone
	case lead == 0xe0:
		lo, hi, want = 0xa0, 0xbf, 2
	case lead >= 0xe1 && lead <= 0xec || lead == 0xee || lead == 0xef:
		lo, hi, want = 0x80, 0xbf, 2
	case lead == 0xed:
		lo, hi, want = 0x80, 0x9f, 2
	case lead == 0xf0:
		lo, hi, want = 0x90, 0xbf, 3
	case lead >= 0xf1 && lead <= 0xf3:
		lo, hi, want = 0x80, 0xbf, 3
	case lead == 0xf4:
		lo, hi, want = 0x80, 0x8f, 3
	default: // 0x80..0xc1, 0xf5..0xff: never a lead
		return 1
	}
	if len(b) < 2 || b[1] < lo || b[1] > hi {
		return 1
	}
	n := 2
	for n <= want && n < len(b) && b[n] >= 0x80 && b[n] <= 0xbf {
		n++
	}
	return n
}

// WrapOps reports how many control/escape operations executed while a wrap
// was pending — the pending-wrap interaction matrix differs per terminal
// (ghostty resolves tabs as a newline, clears on LF, erases through ECH…),
// so the differential oracle skips streams that enter it.
func (e *Emulator) WrapOps() int { return e.wrapOps }

// ctrl handles a C0 control byte.
func (e *Emulator) ctrl(c byte) {
	s := e.cur
	if s.wrapNext {
		e.wrapOps++
	}
	switch c {
	case '\n', '\v', '\f': // LF, VT, FF all index down — and cancel a pending
		// wrap (xterm/ghostty; found by the differential fuzzer)
		s.wrapNext = false
		if e.newlineMode { // LNM: LF implies CR
			s.cx = 0
		}
		s.lineFeed(e.fill())
	case '\r':
		s.cx = 0
		s.wrapNext = false
	case '\b':
		// BS from a pending wrap both cancels the wrap AND steps back
		// (xterm/ghostty — found by the differential fuzzer)
		s.wrapNext = false
		if s.cx > 0 {
			s.cx--
		}
	case '\t':
		// pending wrap survives a tab: at the margin the tab clamps in place
		// and the wrap still fires on the next glyph (xterm/ghostty — found
		// by the differential fuzzer on a tab-to-margin stream)
		s.cx = e.nextTabStop(s.cx)
	case 0x0e: // SO — shift GL to G1
		e.shift = 1
	case 0x0f: // SI — shift GL to G0
		e.shift = 0
	}
}

// materializeTabs switches from the implicit every-8 stops to an explicit
// table, so HTS/TBC edits have something to write into.
func (e *Emulator) materializeTabs() {
	if e.tabs != nil {
		return
	}
	e.tabs = make([]bool, e.w)
	for x := 8; x < e.w; x += 8 {
		e.tabs[x] = true
	}
}

// nextTabStop returns the column after x holding a tab stop, clamped to the
// last column (a tab never wraps).
func (e *Emulator) nextTabStop(x int) int {
	if e.tabs == nil {
		return min((x/8+1)*8, e.w-1)
	}
	for n := x + 1; n < e.w; n++ {
		if e.tabs[n] {
			return n
		}
	}
	return e.w - 1
}

// prevTabStop returns the column before x holding a tab stop, clamped to 0.
func (e *Emulator) prevTabStop(x int) int {
	if e.tabs == nil {
		return max((x-1)/8*8, 0)
	}
	for n := x - 1; n > 0; n-- {
		if e.tabs[n] {
			return n
		}
	}
	return 0
}

// printASCII places a run of single-width ASCII cells, writing straight into the
// row slice. This is where the throughput is: no per-byte dispatch, no width
// lookup (ASCII is always width 1), one row-base recompute per wrap.
func (e *Emulator) printASCII(run []byte) {
	s := e.cur
	fg, bg, attr := e.fg, e.bg, e.attr
	if e.protect {
		attr |= AttrProtected
		s.protected = true
	}
	e.pendingZWJ = false
	if e.ss != 0 { // single shift: the run's first glyph uses G2/G3
		d := e.g[e.ss]
		e.ss = 0
		ch := rune(run[0])
		if tab := tableFor(d); tab != nil {
			ch = tab[ch-0x20]
		}
		e.printRune(ch)
		if run = run[1:]; len(run) == 0 {
			return
		}
	}
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
		if e.insertMode { // IRM: shift the tail right, then overwrite
			s.insertChars(k, blank)
		}
		base := s.rowBase(s.cy)
		row := s.cells[base : base+s.w]
		// Only the run's boundary cells can tear a wide pair (the interior
		// is fully overwritten); inline checks on the row keep this off the
		// hot path's profile.
		if row[s.cx].Width == 0 && s.cx > 0 && row[s.cx-1].Width == 2 {
			row[s.cx-1] = blank
		}
		if end := s.cx + k - 1; row[end].Width == 2 && end+1 < s.w {
			row[end+1] = blank
		}
		if tab := e.charsetTable(); tab != nil {
			// a national/graphics charset is active (TUI borders) — translate
			for m := range k {
				row[s.cx+m] = Cell{Content: tab[run[j+m]-0x20], FG: fg, BG: bg, Attr: attr, Width: 1}
			}
			e.lastGlyph = row[s.cx+k-1].Content
		} else {
			for m := range k {
				row[s.cx+m] = Cell{Content: rune(run[j+m]), FG: fg, BG: bg, Attr: attr, Width: 1}
			}
			e.lastGlyph = rune(run[j+k-1])
		}
		// one high-water update per run, not per cell — the mark is what lets
		// the scroll path copy content width instead of terminal width
		if py := base / s.w; s.cx+k > s.used[py] {
			s.used[py] = s.cx + k
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

// combiningBMP is a bitmap of the BMP's Mn/Me (combining mark) codepoints,
// built from the stdlib unicode tables. go-runewidth's zero-width table
// misses hundreds of mark ranges (Hebrew, Arabic, the Indic scripts… —
// found by the libghostty differential fuzzer on U+0611), and correcting it
// with unicode.In cost 28% of unicode parse throughput; a bit test costs
// nothing.
// widthBMP is the resolved cell width of every BMP codepoint: 0 joins the
// preceding cell's cluster (combining marks, ignorable format chars, and
// go-runewidth's own zero-width set), 1 or 2 occupy cells. Built at init
// from go-runewidth PLUS the corrections the libghostty differential fuzzer
// forced (its zero-width table misses hundreds of Mn ranges — U+0611 broke
// real Arabic; U+302D is Mn but East-Asian-Wide; soft hyphen draws). One
// byte-load on the non-ASCII hot path — the per-rune binary search over
// runewidth's tables was the single largest unicode parse cost.
var widthBMP [0x10000]uint8

func init() {
	for r := rune(0); r < 0x10000; r++ {
		widthBMP[r] = uint8(runewidth.RuneWidth(r))
	}
	// Mc (SPACING combining marks — Devanagari matras, musical stems) occupy
	// a cell; go-runewidth zeroes some of them.
	for _, r := range unicode.Mc.R16 {
		for c := uint32(r.Lo); c <= uint32(r.Hi); c += uint32(r.Stride) {
			if widthBMP[c] == 0 {
				widthBMP[c] = 1
			}
		}
	}
	// Mn/Me (combining marks) and Cf (format chars) join the previous cell,
	// whatever the width tables say.
	for _, tab := range []*unicode.RangeTable{unicode.Mn, unicode.Me, unicode.Cf} {
		for _, r := range tab.R16 {
			for c := uint32(r.Lo); c <= uint32(r.Hi); c += uint32(r.Stride) {
				widthBMP[c] = 0
			}
		}
	}
	// The visible Cf exceptions: the prepended concatenation marks (Arabic
	// number signs & co.), the interlinear annotation controls, and — by
	// terminal convention rather than Unicode — the soft hyphen, which xterm
	// and ghostty draw as a glyph.
	for _, r := range [...][2]uint32{
		{0x00AD, 0x00AD}, {0x0600, 0x0605}, {0x06DD, 0x06DD}, {0x070F, 0x070F},
		{0x0890, 0x0891}, {0x08E2, 0x08E2}, {0xFFF9, 0xFFFB},
	} {
		for c := r[0]; c <= r[1]; c++ {
			widthBMP[c] = 1
		}
	}
	// Hangul: the conjoining medial/final jamo (U+1160–U+11FF, extended
	// D7B0–D7FF) join the preceding syllable block like combining marks, and
	// the invisible fillers (115F, 3164, FFA0) join like format chars.
	for _, r := range [...][2]uint32{
		{0x115F, 0x11FF}, {0xD7B0, 0xD7FF}, {0x3164, 0x3164}, {0xFFA0, 0xFFA0},
	} {
		for c := r[0]; c <= r[1]; c++ {
			widthBMP[c] = 0
		}
	}
}

// runeCellWidth resolves a codepoint's cell width: table lookup in the BMP,
// the slow classification path for astral planes (emoji are wide there via
// runewidth; combining/format corrections via the unicode tables).
func runeCellWidth(r rune) int {
	if r < 0x10000 {
		return int(widthBMP[r])
	}
	if r >= 0x1F1E6 && r <= 0x1F1FF {
		return 2 // regional indicators (flag halves) render wide
	}
	wd := runewidth.RuneWidth(r)
	if wd >= 1 && unicode.In(r, unicode.Mn, unicode.Me, unicode.Cf) {
		return 0
	}
	if wd == 0 && unicode.IsGraphic(r) && !unicode.In(r, unicode.Mn, unicode.Me) {
		return 1 // go-runewidth wrongly zeroes some spacing marks and letters
	}
	return wd
}

// printRune places one non-ASCII glyph, handling width (wide CJK, zero-width
// combining) and the ZWJ-cluster fusion that keeps an emoji family in one cell.
func (e *Emulator) printRune(r rune) {
	wd := runeCellWidth(r)
	if wd == 0 {
		e.combine(r)
		return
	}
	e.lastGlyph = r
	if e.pendingZWJ { // fuse this base onto the ZWJ cluster instead of a new cell
		e.combine(r)
		e.pendingZWJ = false
		return
	}
	s := e.cur
	attr := e.attr
	if e.protect {
		attr |= AttrProtected
		s.protected = true
	}
	if s.wrapNext {
		if e.autowrap {
			s.cx = 0
			s.lineFeed(e.fill())
		}
		s.wrapNext = false
	}
	if s.cx+wd > s.w {
		if e.autowrap {
			// pad the abandoned tail with pen-styled blanks (spacer head)
			for x := s.cx; x < s.w; x++ {
				s.put(x, s.cy, Cell{FG: e.fg, BG: e.bg, Attr: attr, Width: 1})
			}
			s.cx = 0
			s.lineFeed(e.fill())
		} else {
			s.cx = max(s.w-wd, 0)
		}
	}
	if e.insertMode { // IRM: shift the tail right, then overwrite
		s.insertChars(wd, blank)
	}
	// repair any wide pair this write tears (boundary cells only)
	{
		base := s.rowBase(s.cy)
		row := s.cells[base : base+s.w]
		if row[s.cx].Width == 0 && s.cx > 0 && row[s.cx-1].Width == 2 {
			row[s.cx-1] = blank
		}
		if end := s.cx + wd - 1; end < s.w && row[end].Width == 2 && end+1 < s.w {
			row[end+1] = blank
		}
	}
	s.put(s.cx, s.cy, Cell{Content: r, FG: e.fg, BG: e.bg, Attr: attr, Width: uint8(wd)})
	if wd == 2 {
		// the spacer carries no pen state — renderers never paint it, and
		// ghostty's stays default (the oracle compares cell-for-cell)
		s.put(s.cx+1, s.cy, Cell{Width: 0})
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
	if cell.Width == 0 && tx > 0 {
		// the cursor sits after a wide glyph: the mark belongs to the lead
		// cell, not the spacer (found by the differential fuzzer)
		tx--
		cell = s.at(tx, s.cy)
	}
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
		g: e.g, shift: e.shift, protect: e.protect,
	}
}

func (e *Emulator) restore(sc savedCursor) {
	e.cur.cx, e.cur.cy = sc.cx, sc.cy
	e.fg, e.bg, e.attr = sc.fg, sc.bg, sc.attr
	e.cur.wrapNext = sc.wrapNext
	e.originMode = sc.originMode
	e.g, e.shift = sc.g, sc.shift
	e.protect = sc.protect
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
	row := sb.row(i)
	if x >= len(row) { // beyond the stored prefix — trailing blank
		return blank
	}
	return row[x]
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
	e.g = [4]byte{}
	e.shift = 0
	e.ss = 0
	e.tabs = nil
	e.protect = false
	e.insertMode = false
	e.newlineMode = false
	e.lastGlyph = 0
	// the DECSC slots reset too: a restore after RIS lands on defaults
	e.saved = savedCursor{}
	e.savedAlt = savedCursor{}
}

// Charset translation tables cover the full GL range 0x20..0x7e, identity
// except where the set differs — the translated print loop indexes without a
// range check.
var charsetDEC, charsetUK [95]rune

func init() {
	for i := range charsetDEC {
		charsetDEC[i] = rune(i + 0x20)
		charsetUK[i] = rune(i + 0x20)
	}
	// DEC Special Graphics, bytes 0x5f..0x7e — the ncurses ACS set
	for i, r := range [...]rune{
		'_', '◆', '▒', '␉', '␌', '␍', '␊', '°', '±', '␤', '␋',
		'┘', '┐', '┌', '└', '┼', '⎺', '⎻', '─', '⎼', '⎽',
		'├', '┤', '┴', '┬', '│', '≤', '≥', 'π', '≠', '£', '·',
	} {
		charsetDEC[0x5f-0x20+i] = r
	}
	charsetUK['#'-0x20] = '£' // the UK national set's one difference
}

// tableFor maps a charset designator to its translation table (nil = ASCII).
func tableFor(d byte) *[95]rune {
	switch d {
	case '0':
		return &charsetDEC
	case 'A':
		return &charsetUK
	}
	return nil
}

// charsetTable returns the active GL translation table, or nil for plain
// ASCII — the nil check is one branch per print RUN, not per cell.
func (e *Emulator) charsetTable() *[95]rune {
	return tableFor(e.g[e.shift])
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
