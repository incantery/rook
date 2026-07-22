package vt

// escape consumes one ESC-prefixed sequence starting at b[i] (== 0x1b). It
// returns the index just past the sequence, or (i, true) if the sequence is cut
// off at the end of b and must be carried to the next Write.
func (e *Emulator) escape(b []byte, i int) (int, bool) {
	n := len(b)
	if i+1 >= n {
		return i, true // lone ESC — wait for the rest
	}
	switch b[i+1] {
	case '[':
		return e.escCSI(b, i)
	case ']':
		return e.escOSC(b, i)
	case 'P', 'X', '^', '_': // DCS / SOS / PM / APC — consumed, not rendered
		return e.escString(b, i)
	default:
		return e.escSingle(b, i)
	}
}

// escCSI parses a CSI: ESC [ , parameter/intermediate bytes (0x20–0x3f), then a
// final byte (0x40–0x7e).
func (e *Emulator) escCSI(b []byte, i int) (int, bool) {
	n := len(b)
	j := i + 2
	start := j
	for j < n && b[j] >= 0x20 && b[j] < 0x40 {
		j++
	}
	if j >= n {
		return i, true // no final byte yet
	}
	e.csi(b[start:j], b[j])
	return j + 1, false
}

// escOSC parses an OSC: ESC ] ... terminated by BEL or ST (ESC \).
func (e *Emulator) escOSC(b []byte, i int) (int, bool) {
	n := len(b)
	for j := i + 2; j < n; j++ {
		switch {
		case b[j] == 0x07:
			e.osc(b[i+2 : j])
			return j + 1, false
		case b[j] == 0x1b:
			if j+1 >= n {
				return i, true // ST possibly split across writes
			}
			if b[j+1] == '\\' {
				e.osc(b[i+2 : j])
				return j + 2, false
			}
		}
	}
	return i, true
}

// escString consumes a DCS/SOS/PM/APC string (through ST or BEL) and ignores it.
// These carry sixel, DECRQSS replies, kitty graphics — none change the grid here.
func (e *Emulator) escString(b []byte, i int) (int, bool) {
	n := len(b)
	for j := i + 2; j < n; j++ {
		if b[j] == 0x07 {
			return j + 1, false
		}
		if b[j] == 0x1b {
			if j+1 >= n {
				return i, true
			}
			if b[j+1] == '\\' {
				return j + 2, false
			}
		}
	}
	return i, true
}

// escSingle handles the short ESC-prefixed sequences: index/reverse-index,
// save/restore cursor, keypad modes, charset designation, and full reset.
func (e *Emulator) escSingle(b []byte, i int) (int, bool) {
	c := b[i+1]
	switch c {
	case '7': // DECSC — save cursor
		e.saved = e.snapshotCursor()
	case '8': // DECRC — restore cursor
		e.restore(e.saved)
	case 'D': // IND — index (line feed, no CR)
		e.cur.lineFeed(e.fill())
	case 'M': // RI — reverse index
		e.cur.reverseIndex(e.fill())
	case 'E': // NEL — next line
		e.cur.cx = 0
		e.cur.wrapNext = false
		e.cur.lineFeed(e.fill())
	case 'c': // RIS — reset to initial state
		e.reset()
	case '(', ')', '*', '+': // charset designation — needs one more byte
		if i+2 >= len(b) {
			return i, true
		}
		return i + 3, false // charset ignored (assume UTF-8/ASCII)
	case '=', '>', 'F', 'G', 'l', 'm', 'n', 'o', '|', '}', '~':
		// keypad modes, locking shifts, etc. — no grid effect
	}
	return i + 2, false
}

// csi dispatches a parsed CSI sequence. params is the raw parameter bytes
// (digits, ';', an optional private-marker prefix); final is the command byte.
func (e *Emulator) csi(params []byte, final byte) {
	var ps [32]int
	np := 0
	cur := 0
	var prefix byte // '?', '>', '=' for private/device forms; 0 otherwise
	for _, ch := range params {
		switch {
		case ch >= '0' && ch <= '9':
			cur = cur*10 + int(ch-'0')
		case ch == ';' || ch == ':': // ':' subparams folded into ';' (approximate)
			if np < len(ps) {
				ps[np] = cur
				np++
			}
			cur = 0
		case ch == '?' || ch == '>' || ch == '=':
			prefix = ch
		}
	}
	if np < len(ps) {
		ps[np] = cur
		np++
	}

	if prefix == '?' {
		e.csiPrivate(ps[:np], final)
		return
	}
	if prefix != 0 {
		return // '>'/'=' device-attribute requests: replies are Phase 2
	}

	// param, treating 0 (and absent) as the default — the convention for the
	// cursor/count commands, which is all that reach here.
	p := func(idx, def int) int {
		if idx < np && ps[idx] != 0 {
			return ps[idx]
		}
		return def
	}
	s := e.cur
	switch final {
	case 'H', 'f': // CUP — cursor position
		e.moveTo(p(1, 1)-1, p(0, 1)-1)
	case 'A': // CUU
		e.moveTo(s.cx, s.cy-p(0, 1))
	case 'B', 'e': // CUD
		e.moveTo(s.cx, s.cy+p(0, 1))
	case 'C', 'a': // CUF
		e.moveTo(s.cx+p(0, 1), s.cy)
	case 'D': // CUB
		e.moveTo(s.cx-p(0, 1), s.cy)
	case 'E': // CNL
		e.moveTo(0, s.cy+p(0, 1))
	case 'F': // CPL
		e.moveTo(0, s.cy-p(0, 1))
	case 'G', '`': // CHA / HPA — column
		e.moveTo(p(0, 1)-1, s.cy)
	case 'd': // VPA — row
		e.moveTo(s.cx, p(0, 1)-1)
	case 'J': // ED — erase in display
		s.eraseDisplay(p(0, 0), e.fill())
	case 'K': // EL — erase in line
		s.eraseLine(p(0, 0), e.fill())
	case 'L': // IL — insert lines
		s.insertLines(p(0, 1), e.fill())
	case 'M': // DL — delete lines
		s.deleteLines(p(0, 1), e.fill())
	case '@': // ICH — insert blank chars
		s.insertChars(p(0, 1), e.fill())
	case 'P': // DCH — delete chars
		s.deleteChars(p(0, 1), e.fill())
	case 'X': // ECH — erase chars
		s.eraseChars(p(0, 1), e.fill())
	case 'S': // SU — scroll up
		s.scrollUpN(p(0, 1), e.fill())
	case 'T': // SD — scroll down
		s.scrollDownN(p(0, 1), e.fill())
	case 'r': // DECSTBM — set scroll region
		e.setScrollRegion(p(0, 1), p(1, s.h))
	case 'm': // SGR
		e.sgr(ps[:np])
	case 's': // SCOSC — save cursor (ANSI.SYS)
		e.saved = e.snapshotCursor()
	case 'u': // SCORC — restore cursor
		e.restore(e.saved)
	case 'h', 'l', 'n', 'c', 't', 'g', 'q', 'p':
		// ANSI mode set/reset, device reports, window ops, tab clear, cursor
		// style — no visible-grid effect here, or a Phase-2 reply.
	}
}

// moveTo places the cursor, honoring origin mode (which confines it to the
// scroll region) and clearing any pending wrap.
func (e *Emulator) moveTo(x, y int) {
	s := e.cur
	if e.originMode {
		y += s.stop
		if y < s.stop {
			y = s.stop
		}
		if y > s.sbot {
			y = s.sbot
		}
	}
	s.cx, s.cy = x, y
	s.wrapNext = false
	s.clampCursor()
}

// setScrollRegion sets the top/bottom margins (DECSTBM) and homes the cursor.
func (e *Emulator) setScrollRegion(top, bot int) {
	s := e.cur
	top--
	bot--
	if top < 0 {
		top = 0
	}
	if bot >= s.h {
		bot = s.h - 1
	}
	if top >= bot {
		top, bot = 0, s.h-1 // invalid region resets to full screen
	}
	s.stop, s.sbot = top, bot
	e.moveTo(0, 0) // cursor to region home (origin-mode aware)
}

// csiPrivate handles DEC private mode set/reset (ESC [ ? Pm h/l) and private
// requests. Only the modes that affect the grid are acted on; the rest are
// tracked-as-ignored so they don't corrupt the stream.
func (e *Emulator) csiPrivate(ps []int, final byte) {
	if final != 'h' && final != 'l' {
		return // '?...$p' DECRQM and friends: replies are Phase 2
	}
	set := final == 'h'
	for _, m := range ps {
		switch m {
		case 6: // DECOM — origin mode
			e.originMode = set
			e.moveTo(0, 0)
		case 7: // DECAWM — autowrap
			e.autowrap = set
		case 47, 1047: // alt screen buffer (no cursor save)
			e.switchAlt(set, false)
		case 1049: // alt screen + save/restore cursor + clear
			e.switchAlt(set, true)
		}
	}
}

// switchAlt enters or leaves the alt-screen buffer. saveCursor selects the
// ?1049 form, which stashes and restores the cursor and clears the alt buffer
// on entry — what full-screen apps like nvim use.
func (e *Emulator) switchAlt(enter, saveCursor bool) {
	if enter {
		if e.onAlt {
			return
		}
		if saveCursor {
			e.savedAlt = e.snapshotCursor()
		}
		e.onAlt = true
		e.cur = e.alt
		e.alt.top = 0
		e.alt.stop, e.alt.sbot = 0, e.h-1
		e.alt.cx, e.alt.cy, e.alt.wrapNext = 0, 0, false
		e.alt.clearRows(0, e.h-1, blank)
		return
	}
	if !e.onAlt {
		return
	}
	e.onAlt = false
	e.cur = e.primary
	if saveCursor {
		e.restore(e.savedAlt)
	}
}

// sgr applies a Select Graphic Rendition sequence to the pen.
func (e *Emulator) sgr(ps []int) {
	if len(ps) == 0 {
		e.fg, e.bg, e.attr = DefaultColor, DefaultColor, 0
		return
	}
	for i := 0; i < len(ps); i++ {
		n := ps[i]
		switch {
		case n == 0:
			e.fg, e.bg, e.attr = DefaultColor, DefaultColor, 0
		case n == 1:
			e.attr |= AttrBold
		case n == 2:
			e.attr |= AttrDim
		case n == 3:
			e.attr |= AttrItalic
		case n == 4:
			e.attr |= AttrUnderline
		case n == 5, n == 6:
			e.attr |= AttrBlink
		case n == 7:
			e.attr |= AttrReverse
		case n == 8:
			e.attr |= AttrHidden
		case n == 9:
			e.attr |= AttrStrike
		case n == 22:
			e.attr &^= AttrBold | AttrDim
		case n == 23:
			e.attr &^= AttrItalic
		case n == 24:
			e.attr &^= AttrUnderline
		case n == 25:
			e.attr &^= AttrBlink
		case n == 27:
			e.attr &^= AttrReverse
		case n == 28:
			e.attr &^= AttrHidden
		case n == 29:
			e.attr &^= AttrStrike
		case n >= 30 && n <= 37:
			e.fg = Palette(uint8(n - 30))
		case n == 38:
			if c, adv, ok := extColor(ps, i); ok {
				e.fg = c
				i += adv
			}
		case n == 39:
			e.fg = DefaultColor
		case n >= 40 && n <= 47:
			e.bg = Palette(uint8(n - 40))
		case n == 48:
			if c, adv, ok := extColor(ps, i); ok {
				e.bg = c
				i += adv
			}
		case n == 49:
			e.bg = DefaultColor
		case n >= 90 && n <= 97:
			e.fg = Palette(uint8(n - 90 + 8))
		case n >= 100 && n <= 107:
			e.bg = Palette(uint8(n - 100 + 8))
		}
	}
}

// extColor decodes an SGR 38/48 extended-color argument at ps[i], returning the
// color and how many extra params it consumed. "5;n" is a palette index, "2;r;g;b"
// is truecolor.
func extColor(ps []int, i int) (c Color, adv int, ok bool) {
	if i+1 >= len(ps) {
		return 0, 0, false
	}
	switch ps[i+1] {
	case 5:
		if i+2 < len(ps) {
			return Palette(uint8(ps[i+2])), 2, true
		}
	case 2:
		if i+4 < len(ps) {
			return RGB(uint8(ps[i+2]), uint8(ps[i+3]), uint8(ps[i+4])), 4, true
		}
	}
	return 0, 0, false
}

// osc handles Operating System Command strings (window title, palette, etc.).
// None change the grid, so they are consumed and dropped for now.
func (e *Emulator) osc(_ []byte) {}
