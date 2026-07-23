package vt

import "unicode/utf8"

// escape consumes one ESC-prefixed sequence starting at b[i] (== 0x1b). It
// returns the index just past the sequence, or (i, true) if the sequence is cut
// off at the end of b and must be carried to the next Write.
func (e *Emulator) escape(b []byte, i int) (int, bool) {
	n := len(b)
	if i+1 >= n {
		return i, true // lone ESC — wait for the rest
	}
	if e.cur.wrapNext {
		e.wrapOps++ // see WrapOps
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
	sawInter := false
	malformed := false
	for j < n && b[j] >= 0x20 && b[j] < 0x40 {
		if b[j] < 0x30 {
			sawInter = true
		} else if sawInter {
			// a parameter byte after an intermediate: the state machine
			// drops to ignore — consume the sequence, dispatch nothing
			// (found by the libghostty differential fuzzer on "\x1b[2 0B")
			malformed = true
		}
		j++
	}
	if j >= n {
		return i, true // no final byte yet
	}
	if b[j] == 0x1b {
		// ESC mid-CSI restarts the sequence (VT state machine — found by
		// the libghostty differential fuzzer); the CSI is abandoned.
		return j, false
	}
	if malformed {
		return j + 1, false
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
			// any other ESC cancels the OSC (VT state machine); the string
			// is abandoned and parsing restarts at the ESC
			return j, false
		}
	}
	return i, true
}

// escString consumes a DCS/SOS/PM/APC string (through ST or BEL). Most carry
// sixel/kitty graphics that don't change the grid and are dropped; a DCS may be
// a DECRQSS request ("what is the current SGR / scroll region"), which the
// emulator can answer because it holds that state — so DCS payloads are routed
// to dcs().
func (e *Emulator) escString(b []byte, i int) (int, bool) {
	intro := b[i+1]
	n := len(b)
	for j := i + 2; j < n; j++ {
		if b[j] == 0x07 {
			e.stringPayload(intro, b[i+2:j])
			return j + 1, false
		}
		if b[j] == 0x1b {
			if j+1 >= n {
				return i, true
			}
			if b[j+1] == '\\' {
				e.stringPayload(intro, b[i+2:j])
				return j + 2, false
			}
			// any other ESC cancels the string (VT state machine)
			return j, false
		}
	}
	return i, true
}

// stringPayload dispatches a completed DCS/SOS/PM/APC body. Only DCS (intro 'P')
// carries anything we answer.
func (e *Emulator) stringPayload(intro byte, payload []byte) {
	if intro == 'P' {
		e.dcs(payload)
	}
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
		e.cur.wrapNext = false
		e.cur.lineFeed(e.fill())
	case 'M': // RI — reverse index (pending wrap survives, unlike LF —
		// both matched to ghostty by the differential fuzzer)
		e.cur.reverseIndex(e.fill())
	case 'E': // NEL — next line
		e.cur.cx = 0
		e.cur.wrapNext = false
		e.cur.lineFeed(e.fill())
	case 'H': // HTS — set a tab stop at the cursor column
		e.materializeTabs()
		if e.cur.cx < len(e.tabs) {
			e.tabs[e.cur.cx] = true
		}
	case 'V': // SPA — start protected area
		e.protect = true
	case 'W': // EPA — end protected area
		e.protect = false
	case 'c': // RIS — reset to initial state
		e.reset()
	case 'n': // LS2 — GL locking shift to G2
		e.shift = 2
	case 'o': // LS3 — GL locking shift to G3
		e.shift = 3
	case 'N': // SS2 — single shift: next glyph from G2
		e.ss = 2
	case 'O': // SS3 — single shift: next glyph from G3
		e.ss = 3
	case '=', '>', 'F', 'G', 'l', 'm', '|', '}', '~':
		// keypad modes, right-half shifts, etc. — no grid effect
	case 0x1b:
		// ESC ESC: the second ESC restarts the sequence (VT state machine —
		// found by the libghostty differential fuzzer). Drop the first.
		return i + 1, false
	default:
		if c >= 0x80 {
			// ESC + non-ASCII: swallow the WHOLE rune — consuming one byte
			// tore a UTF-8 sequence apart and rendered its tail as U+FFFD
			// (found by the libghostty differential fuzzer).
			if !utf8.FullRune(b[i+1:]) {
				return i, true
			}
			_, sz := utf8.DecodeRune(b[i+1:])
			return i + 1 + sz, false
		}
		if c >= 0x20 && c <= 0x2f {
			// Intermediate byte(s) then one final — ESC ( B, ESC # 8, ESC SP F…
			// One scan handles them all (the VT state machine's escape-
			// intermediate state); only the exact forms we know get effects.
			// Consuming less than the whole sequence printed the leftovers as
			// text (found by the libghostty differential fuzzer on "\x1b 0",
			// "\x1b( 0").
			j := i + 2
			for j < len(b) && b[j] >= 0x20 && b[j] <= 0x2f {
				j++
			}
			if j >= len(b) {
				return i, true
			}
			if b[j] == 0x1b { // ESC mid-sequence restarts (VT state machine)
				return j, false
			}
			if j == i+2 { // single intermediate: the dispatchable forms
				switch c {
				case '(', ')', '*', '+': // designate G0..G3 — unknown sets
					// are ignored (ghostty)
					if d := b[j]; d == 'B' || d == '0' || d == 'A' {
						e.g[c-'('] = d
					}
				case '#':
					if b[j] == '8' {
						e.decaln()
					}
				}
			}
			return j + 1, false
		}
	}
	return i + 2, false
}

// first returns ps[0], or 0 for an empty list.
func first(ps []int) int {
	if len(ps) == 0 {
		return 0
	}
	return ps[0]
}

// decaln is DECALN (ESC # 8), the screen alignment test: reset margins, home
// the cursor, fill the screen with E.
func (e *Emulator) decaln() {
	s := e.cur
	s.stop, s.sbot = 0, e.h-1
	s.cx, s.cy = 0, 0
	s.wrapNext = false
	e.fg, e.bg, e.attr = DefaultColor, DefaultColor, 0 // pen resets too (ghostty)
	s.clearRows(0, e.h-1, Cell{Content: 'E', Width: 1})
}

// csi dispatches a parsed CSI sequence. params is the raw parameter bytes
// (digits, ';', an optional private-marker prefix); final is the command byte.
func (e *Emulator) csi(params []byte, final byte) {
	var ps [32]int
	np := 0
	cur := 0
	var prefix byte    // '?', '>', '<', '=' for private/device forms; 0 otherwise
	var inter byte     // an intermediate byte (0x20–0x2f), e.g. '$' in DECRQM
	var colon uint32   // bit k set = ps[k] was joined to ps[k-1] by ':'
	nextColon := false // the separator that will introduce the NEXT param
	for pi, ch := range params {
		switch {
		case ch >= '0' && ch <= '9':
			// params saturate at 16 bits (ghostty/xterm convention; also
			// keeps a hostile 10^18 from overflowing int)
			if cur = cur*10 + int(ch-'0'); cur > 0xffff {
				cur = 0xffff
			}
		case ch == ';' || ch == ':':
			if np < len(ps) {
				ps[np] = cur
				if nextColon {
					colon |= 1 << np
				}
				np++
			}
			cur = 0
			nextColon = ch == ':'
		case ch == '?' || ch == '>' || ch == '<' || ch == '=':
			if pi != 0 {
				// a private marker anywhere but first is malformed — the
				// sequence is consumed and dispatches nothing (ghostty;
				// found by the differential fuzzer on "\x1b[0?1K")
				return
			}
			prefix = ch
		case ch >= 0x20 && ch <= 0x2f:
			inter = ch
		}
	}
	if np < len(ps) {
		ps[np] = cur
		if nextColon {
			colon |= 1 << np
		}
		np++
	}
	if colon != 0 && final != 'm' {
		// colon subparameters exist only in SGR — anywhere else the sequence
		// is malformed and dispatching it ran a command that shouldn't run
		// (found by the libghostty differential fuzzer on "\x1b[:1B")
		return
	}

	// Queries answer themselves into e.out and change nothing on screen, so they
	// are handled before the grid dispatch and never reach a rendering client.
	if e.answerQuery(ps[:np], prefix, inter, final) {
		return
	}
	if inter != 0 {
		if inter == '"' && final == 'q' {
			// DECSCA — select character protection attribute (1 = protect)
			e.protect = np > 0 && ps[0] == 1
			return
		}
		// Any other intermediate makes this a different command (CSI SP q is
		// not CSI q) — dispatching the bare final ran the wrong one (found
		// by the libghostty differential fuzzer on "\x1b[1 B").
		return
	}

	if prefix == '?' {
		e.csiPrivate(ps[:np], final)
		return
	}
	if prefix != 0 {
		return // '>'/'<'/'=' device forms we do not act on
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
	case 'j': // HPB — character position backward (ECMA-48)
		e.moveTo(s.cx-p(0, 1), s.cy)
	case 'k': // VPB — line position backward (ECMA-48)
		e.moveTo(s.cx, s.cy-p(0, 1))
	case 'E': // CNL
		e.moveTo(0, s.cy+p(0, 1))
	case 'F': // CPL
		e.moveTo(0, s.cy-p(0, 1))
	case 'G', '`': // CHA / HPA — column
		e.moveTo(p(0, 1)-1, s.cy)
	case 'd': // VPA — row
		e.moveTo(s.cx, p(0, 1)-1)
	case 'J': // ED — erase in display (params above 3 are undefined: ignore,
		// as xterm does; ghostty wraps them mod 10 — not worth matching)
		switch m := p(0, 0); {
		case m == 3: // xterm extension: clear SCROLLBACK, screen untouched
			if e.primary.sb != nil {
				e.primary.sb = newScrollback(e.w, e.sbLines)
			}
			e.sbEpoch++ // history discarded; cached pages are void
		case m <= 2:
			s.eraseDisplay(m, e.fill())
		}
	case 'K': // EL — erase in line (params above 2 are undefined: ignore —
		// found by the differential fuzzer on "\x1b[7K")
		if m := p(0, 0); m <= 2 {
			s.eraseLine(m, e.fill())
		}
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
		e.sgr(ps[:np], colon)
	case 's': // SCOSC — save cursor (ANSI.SYS). Parameter-less by definition:
		// with params this slot is DECSLRM (unimplemented), not a save.
		if len(params) == 0 {
			e.saved = e.snapshotCursor()
		}
	case 'u': // SCORC — restore cursor
		e.restore(e.saved)
	case 'h', 'l': // ANSI mode set/reset — tracked for DECRQM
		set := final == 'h'
		for _, m := range ps[:np] {
			e.ansiModes[m] = set
			switch m {
			case 4: // IRM — insert/replace mode
				e.insertMode = set
			case 20: // LNM — LF implies CR
				e.newlineMode = set
			}
		}
	case 'I': // CHT — cursor forward tab stops (pending wrap survives, like TAB)
		for range p(0, 1) {
			s.cx = e.nextTabStop(s.cx)
		}
	case 'b': // REP — repeat the preceding graphic character (ncurses runs;
		// found unimplemented by the libghostty differential fuzzer).
		// The param parser's 16-bit saturation bounds the loop.
		if e.lastGlyph != 0 {
			for range p(0, 1) {
				e.printRune(e.lastGlyph)
			}
		}
	case 'Z': // CBT — cursor backward tab stops
		for range p(0, 1) {
			s.cx = e.prevTabStop(s.cx)
		}
		s.wrapNext = false
	case 'g': // TBC — tab clear (0: at cursor, 3: all)
		switch p(0, 0) {
		case 0:
			e.materializeTabs()
			if s.cx < len(e.tabs) {
				e.tabs[s.cx] = false
			}
		case 3:
			e.tabs = make([]bool, s.w)
		}
	case 't', 'q':
		// window ops, cursor style — no visible-grid effect here.
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
		// a region under two lines is invalid: the whole command is IGNORED
		// (xterm/ghostty — resetting to full screen also moved the cursor,
		// found by the differential fuzzer on "\x1b[10r" at 10 rows)
		return
	}
	s.stop, s.sbot = top, bot
	e.moveTo(0, 0) // cursor to region home (origin-mode aware)
}

// csiPrivate handles DEC private mode set/reset (ESC [ ? Pm h/l) and private
// requests. Only the modes that affect the grid are acted on; the rest are
// tracked-as-ignored so they don't corrupt the stream.
func (e *Emulator) csiPrivate(ps []int, final byte) {
	s := e.cur
	switch final {
	case 'J': // DECSED — selective erase in display (honors DECSCA)
		if m := first(ps); m <= 2 {
			s.eraseDisplay(m, e.fill())
		}
		return
	case 'K': // DECSEL — selective erase in line
		if m := first(ps); m <= 2 {
			s.eraseLine(m, e.fill())
		}
		return
	}
	if final != 'h' && final != 'l' {
		return // '?...$p' DECRQM and friends: replies are Phase 2
	}
	set := final == 'h'
	for _, m := range ps {
		e.decModes[m] = set // recorded for DECRQM, whether or not it affects the grid
		switch m {
		case 6: // DECOM — origin mode
			e.originMode = set
			e.moveTo(0, 0)
		case 7: // DECAWM — autowrap
			e.autowrap = set
		case 25: // DECTCEM — cursor visibility
			e.cursorVisible = set
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
	// A buffer swap is a full-screen change on the client, not a scroll; drop
	// any pending scroll count so the next Render diffs the whole screen.
	e.primary.scrolled = 0
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
		// The cursor is a terminal property, not a buffer property: a swap
		// carries the position over (xterm; confirmed against libghostty by
		// the differential oracle — we used to home it here).
		e.alt.cx = min(e.primary.cx, e.alt.w-1)
		e.alt.cy = min(e.primary.cy, e.alt.h-1)
		e.alt.wrapNext = false
		e.alt.clearRows(0, e.h-1, blank)
		return
	}
	if !e.onAlt {
		return
	}
	e.onAlt = false
	e.cur = e.primary
	// carry the position back; the ?1049 restore below then overrides it
	e.primary.cx = min(e.alt.cx, e.primary.w-1)
	e.primary.cy = min(e.alt.cy, e.primary.h-1)
	e.primary.wrapNext = false
	if saveCursor {
		e.restore(e.savedAlt)
	}
}

// sgr applies a Select Graphic Rendition sequence to the pen. colon marks
// which params were ':'-joined subparameters of their predecessor: a param
// with unrecognized subparams is skipped as a whole group (kitty/ghostty
// semantics — folding ':' into ';' turned "\x1b[:1m" into bold).
func (e *Emulator) sgr(ps []int, colon uint32) {
	if len(ps) == 0 {
		e.fg, e.bg, e.attr = DefaultColor, DefaultColor, 0
		return
	}
	group := func(i int) int { // index just past ps[i]'s colon-joined subparams
		j := i + 1
		for j < len(ps) && j < 32 && colon&(1<<j) != 0 {
			j++
		}
		return j
	}
	for i := 0; i < len(ps); i++ {
		n := ps[i]
		if end := group(i); end > i+1 {
			// colon-attached subparams: only the forms we know act
			sub := ps[i+1 : end]
			switch {
			case n == 4: // underline style: 4:0 off, 4:1..5 on
				if sub[0] == 0 {
					e.attr &^= AttrUnderline
				} else {
					e.attr |= AttrUnderline
				}
			case (n == 38 || n == 48 || n == 58) && sub[0] == 5 && len(sub) >= 2:
				switch n {
				case 38:
					e.fg = Palette(uint8(sub[1]))
				case 48:
					e.bg = Palette(uint8(sub[1]))
					// 58 (underline color): consumed, not rendered
				}
			case (n == 38 || n == 48 || n == 58) && sub[0] == 5 && end < len(ps):
				// mixed-separator compat ("38:5;n") — the index rides the
				// next semicolon param
				switch n {
				case 38:
					e.fg = Palette(uint8(ps[end]))
				case 48:
					e.bg = Palette(uint8(ps[end]))
				}
				i = end
				continue
			case (n == 38 || n == 48 || n == 58) && sub[0] == 2 && len(sub) >= 4:
				// 38:2:colorspace:r:g:b (ITU form) or 38:2:r:g:b
				o := 1
				if len(sub) >= 5 {
					o = 2 // colorspace id present
				}
				c := RGB(uint8(sub[o]), uint8(sub[o+1]), uint8(sub[o+2]))
				switch n {
				case 38:
					e.fg = c
				case 48:
					e.bg = c
				}
			case n == 38 || n == 48 || n == 58:
				// unknown color form: ghostty skips only the owner and the
				// subparams re-enter the stream as plain params ("38:1"
				// bolds) — matched empirically via the differential fuzzer
				continue
			}
			i = end - 1
			continue
		}
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
		case n == 21: // doubly underlined (ECMA-48; modern xterm agrees —
			// found by the libghostty differential fuzzer)
			e.attr |= AttrUnderline
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
		case n == 58: // underline color — consumed, not rendered
			if _, adv, ok := extColor(ps, i); ok {
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
	// components truncate mod 256 AFTER the parser's 16-bit saturation —
	// the ghostty convention the differential fuzzer triangulated
	// (38;5;100000 → 255 via saturation, 38;5;700 → 188 via truncation)
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
