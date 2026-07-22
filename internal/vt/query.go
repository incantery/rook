package vt

import (
	"fmt"
	"strconv"
	"strings"
)

// The terminal answering its own questions.
//
// A program asks its terminal things — "what are you" (DA), "where is the
// cursor" (CPR), "is mode Ps set" (DECRQM), "what is the current SGR" (DECRQSS).
// With xterm-in-the-browser those answers came from the client, which is why a
// detached session blocked on a DA1 that never came, and why a reattaching
// client re-answered every query in the replayed ring (the AUTO_REPLY
// subsystem, and its $y hole). Here the emulator answers: it sees every byte,
// it is always present, and its reply goes to e.out (written back to the pty as
// input), never into the grid — so no query can reach a rendering client.
//
// This subsumes internal/host/termquery.go, and goes past it: termquery could
// not answer CPR or DECRQSS because those need a model of the screen rather than
// the byte stream, and left them to xterm.js. The emulator HAS the screen, so it
// answers them too. The DA/DSR/DECRQM answers mirror xterm.js's exactly, quirks
// included — a change of who answers, not what.
//
// The one residual is OSC 4/10-12 (palette queries): the answer is the theme's
// colors, which live in the renderer, not here. Those are left for the host to
// answer from the theme once the client emulator is gone (Phase 3/4).

// DECRPM report values.
const (
	modeNotRecognized = 0
	modeSet           = 1
	modeReset         = 2
	modePermSet       = 3
	modePermReset     = 4
)

func (e *Emulator) reply(s string) { e.out = append(e.out, s...) }

// answerQuery handles the CSI forms that are questions, writing the reply to
// e.out. It returns true if the sequence was a query (and therefore must not
// fall through to the grid dispatch).
func (e *Emulator) answerQuery(ps []int, prefix, inter, final byte) bool {
	p0 := 0
	if len(ps) > 0 {
		p0 = ps[0]
	}
	switch {
	// DA1 — "what are you". xterm.js: VT100 with Advanced Video Option.
	case final == 'c' && prefix == 0:
		if p0 != 0 {
			return false // CSI <n> c with n≠0 is not a query
		}
		e.reply("\x1b[?1;2c")
		return true

	// DA2 — "what version". xterm.js reports VT100 / 276 / 0.
	case final == 'c' && prefix == '>':
		e.reply("\x1b[>0;276;0c")
		return true

	// DSR — device status. 5 is "are you ok"; 6 is CPR, the cursor position,
	// which the emulator can now answer because it holds the cursor.
	case final == 'n' && prefix == 0 && p0 == 5:
		e.reply("\x1b[0n")
		return true
	case final == 'n' && prefix == 0 && p0 == 6:
		e.reply(e.cpr(false))
		return true
	// DECXCPR — CSI ? 6 n, the private CPR variant (reports a page too).
	case final == 'n' && prefix == '?' && p0 == 6:
		e.reply(e.cpr(true))
		return true

	// DECRQM — "is mode Ps set", CSI [?] Ps $ p.
	case final == 'p' && inter == '$':
		private := prefix == '?'
		v := e.modeReport(p0, private)
		mark := ""
		if private {
			mark = "?"
		}
		e.reply("\x1b[" + mark + strconv.Itoa(p0) + ";" + strconv.Itoa(v) + "$y")
		return true
	}
	return false
}

// cpr builds a Cursor Position Report. Row is region-relative under origin mode,
// as xterm reports it. The private form adds a trailing page parameter (always 1).
func (e *Emulator) cpr(private bool) string {
	row, col := e.cur.cy+1, e.cur.cx+1
	if e.originMode {
		row = e.cur.cy - e.cur.stop + 1
	}
	if private {
		return "\x1b[?" + strconv.Itoa(row) + ";" + strconv.Itoa(col) + ";1R"
	}
	return "\x1b[" + strconv.Itoa(row) + ";" + strconv.Itoa(col) + "R"
}

// dcs handles a DCS payload. The one it answers is DECRQSS ("$q<name>"): a
// request for the current value of a setting the emulator holds.
func (e *Emulator) dcs(payload []byte) {
	s := string(payload)
	req, ok := strings.CutPrefix(s, "$q")
	if !ok {
		return
	}
	switch req {
	case "m": // SGR — the current pen
		e.reply("\x1bP1$r" + e.sgrString() + "m\x1b\\")
	case "r": // DECSTBM — the scroll region
		e.reply("\x1bP1$r" + strconv.Itoa(e.cur.stop+1) + ";" + strconv.Itoa(e.cur.sbot+1) + "r\x1b\\")
	default:
		e.reply("\x1bP0$r\x1b\\") // not a setting we report: invalid
	}
}

// sgrString serializes the current pen as SGR parameters (without the leading
// CSI or trailing 'm'), for a DECRQSS "m" reply. Always starts from a reset so
// the string is self-contained.
func (e *Emulator) sgrString() string {
	parts := []string{"0"}
	for _, a := range []struct {
		bit  Attr
		code string
	}{
		{AttrBold, "1"}, {AttrDim, "2"}, {AttrItalic, "3"}, {AttrUnderline, "4"},
		{AttrBlink, "5"}, {AttrReverse, "7"}, {AttrHidden, "8"}, {AttrStrike, "9"},
	} {
		if e.attr&a.bit != 0 {
			parts = append(parts, a.code)
		}
	}
	if s := colorSGR(e.fg, false); s != "" {
		parts = append(parts, s)
	}
	if s := colorSGR(e.bg, true); s != "" {
		parts = append(parts, s)
	}
	return strings.Join(parts, ";")
}

// colorSGR renders a Color as its SGR parameter(s), or "" for the default.
func colorSGR(c Color, bg bool) string {
	if c.IsDefault() {
		return ""
	}
	base := 30
	if bg {
		base = 40
	}
	if c&colorRGB != 0 {
		v := uint32(c)
		r, g, b := (v>>16)&0xff, (v>>8)&0xff, v&0xff
		return strconv.Itoa(base+8) + ";2;" + strconv.Itoa(int(r)) + ";" + strconv.Itoa(int(g)) + ";" + strconv.Itoa(int(b))
	}
	n := uint32(c) & 0xff
	switch {
	case n < 8:
		return strconv.Itoa(base + int(n))
	case n < 16:
		return strconv.Itoa(base + 60 + int(n-8)) // bright: 90-97 / 100-107
	default:
		return strconv.Itoa(base+8) + ";5;" + strconv.Itoa(int(n))
	}
}

func b2v(on bool) int {
	if on {
		return modeSet
	}
	return modeReset
}

// modeReport mirrors xterm.js InputHandler.requestMode, quirks included, reading
// the modes the emulator has tracked from the program's own h/l sequences.
func (e *Emulator) modeReport(p int, private bool) int {
	if !private {
		switch p {
		case 2:
			return modePermReset
		case 4:
			return b2v(e.ansiModes[4])
		case 12:
			return modePermSet
		case 20:
			return b2v(e.ansiModes[20])
		}
		return modeNotRecognized
	}
	switch p {
	case 1, 6, 45, 66, 1004, 2004, 2026:
		return b2v(e.decModes[p])
	case 7, 25:
		return b2v(e.decModes[p]) // defaults seeded in New
	case 8, 1048:
		return modePermSet
	case 67, 1005, 1015:
		return modePermReset
	case 9:
		return b2v(e.mouseProtocol() == 9)
	case 1000:
		return b2v(e.mouseProtocol() == 1000)
	case 1002:
		return b2v(e.mouseProtocol() == 1002)
	case 1003:
		return b2v(e.mouseProtocol() == 1003)
	case 1006:
		return b2v(e.mouseEncoding() == 1006)
	case 1016:
		return b2v(e.mouseEncoding() == 1016)
	case 47, 1047, 1049:
		return b2v(e.decModes[47] || e.decModes[1047] || e.decModes[1049])
	case 12:
		return modeReset // xterm option cursorBlink, off by default
	case 3:
		return modeNotRecognized // windowOptions.setWinLines is off
	}
	return modeNotRecognized
}

// The mouse modes are exclusive in xterm.js — the last one set wins — so a
// report names the ACTIVE one rather than testing each flag.
func (e *Emulator) mouseProtocol() int {
	for _, m := range []int{1003, 1002, 1000, 9} {
		if e.decModes[m] {
			return m
		}
	}
	return 0
}

func (e *Emulator) mouseEncoding() int {
	for _, m := range []int{1016, 1006} {
		if e.decModes[m] {
			return m
		}
	}
	return 0
}

// osc handles an OSC payload (the bytes between ESC ] and the terminator). It
// answers the color queries programs use to read the theme — OSC 10/11/12 for
// the default fg/bg/cursor, OSC 4 for a palette index — the residual query.go
// left to the client (the "vim reads OSC 11 for the background" case). A set
// (spec is a color, not "?") is recorded so a later query stays consistent;
// rendering stays client-driven, so a set does not repaint. Other OSC codes
// (title, hyperlinks) are ignored — they never reached the grid before either.
func (e *Emulator) osc(payload []byte) {
	code, rest, ok := strings.Cut(string(payload), ";")
	if !ok {
		return
	}
	switch code {
	case "10":
		e.oscDynColor(10, rest, &e.fgColor)
	case "11":
		e.oscDynColor(11, rest, &e.bgColor)
	case "12":
		e.oscDynColor(12, rest, &e.cursorColor)
	case "4":
		e.oscIndexColor(rest)
	}
}

// oscDynColor answers or sets one of the dynamic colors (OSC 10/11/12).
func (e *Emulator) oscDynColor(code int, spec string, slot *uint32) {
	if spec == "?" {
		e.reply("\x1b]" + strconv.Itoa(code) + ";" + oscColorString(*slot) + "\x1b\\")
		return
	}
	if c, ok := parseOSCColor(spec); ok {
		*slot = c
	}
}

// oscIndexColor answers or sets a palette index (OSC 4 ; index ; spec).
func (e *Emulator) oscIndexColor(rest string) {
	idxStr, spec, ok := strings.Cut(rest, ";")
	if !ok {
		return
	}
	idx, err := strconv.Atoi(idxStr)
	if err != nil || idx < 0 || idx > 15 {
		return
	}
	if spec == "?" {
		e.reply("\x1b]4;" + idxStr + ";" + oscColorString(e.palette[idx]) + "\x1b\\")
		return
	}
	if c, ok := parseOSCColor(spec); ok {
		e.palette[idx] = c
	}
}

// oscColorString formats a 0xRRGGBB color as xterm's 16-bit reply, each 8-bit
// channel doubled into 16 bits (0xff -> ffff).
func oscColorString(c uint32) string {
	r, g, b := (c>>16)&0xff, (c>>8)&0xff, c&0xff
	return fmt.Sprintf("rgb:%04x/%04x/%04x", r*0x101, g*0x101, b*0x101)
}

// parseOSCColor parses the color specs a program uses to set a color: xterm's
// rgb:R/G/B (1-4 hex digits per channel) and #RRGGBB.
func parseOSCColor(spec string) (uint32, bool) {
	if rest, ok := strings.CutPrefix(spec, "rgb:"); ok {
		parts := strings.Split(rest, "/")
		if len(parts) != 3 {
			return 0, false
		}
		var out uint32
		for _, p := range parts {
			v, err := strconv.ParseUint(p, 16, 32)
			if err != nil || len(p) < 1 || len(p) > 4 {
				return 0, false
			}
			switch len(p) { // scale to 8 bits
			case 1:
				v *= 0x11
			case 3:
				v >>= 4
			case 4:
				v >>= 8
			}
			out = out<<8 | (uint32(v) & 0xff)
		}
		return out, true
	}
	if rest, ok := strings.CutPrefix(spec, "#"); ok && len(rest) == 6 {
		v, err := strconv.ParseUint(rest, 16, 32)
		if err != nil {
			return 0, false
		}
		return uint32(v), true
	}
	return 0, false
}
