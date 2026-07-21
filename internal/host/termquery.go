package host

import "sync"

// The terminal answering its own questions.
//
// A program asks its terminal things on startup — "what are you" (DA), "are
// you there" (DSR), "do you support synchronized output" (DECRQM). Until now
// the ANSWERS came from xterm.js in the browser, which has two consequences
// rook keeps paying for:
//
//  1. Nobody answers a detached session. readPump runs whether or not a
//     client is attached, but the replies do not — so a program started in a
//     background workspace blocks on a DA1 that never comes. Harmless today
//     only because rook attaches everything; the detach work removes that.
//
//  2. A reattaching client re-parses the whole replayed ring and answers
//     every query in it a second time, to a program that asked once and long
//     since moved on. That is a whole subsystem in term/manager.ts — a gate,
//     a timer, a marker frame, and a regex — and the $y hole in that regex is
//     what put five stale mode reports into a live nvim.
//
// Both dissolve if the host answers. It sees every byte the program writes,
// it is always there, and its reply goes in as INPUT so it never lands in the
// ring to be replayed at all.
//
// What the host CANNOT answer is the honest boundary of this idea, and worth
// stating because it is the same boundary a server-side emulator would move:
//
//   CPR (CSI 6 n)      needs the cursor position
//   DECRQSS (DCS $ q)  needs the current SGR/cursor state
//   OSC 4/10-12        needs the palette, which lives in the theme
//
// Each needs a model of the screen rather than a model of the conversation.
// Those stay with xterm.js, and term/manager.ts still filters them during
// replay. Everything below is answerable from the byte stream alone.
//
// The answers mirror xterm.js's exactly (InputHandler.requestMode), including
// its quirks — this is a change of WHO answers, and it would be a poor time
// to also change WHAT is answered.

// DECRPM report values.
const (
	modeNotRecognized = 0
	modeSet           = 1
	modeReset         = 2
	modePermSet       = 3
	modePermReset     = 4
)

// termQ tracks the little state a report needs and reassembles sequences
// split across reads. One per session; readPump is its only caller, so the
// mutex guards nothing today and is there for the next caller.
type termQ struct {
	mu   sync.Mutex
	dec  map[int]bool // DEC private modes, by the CSI ? Ps h/l we have seen
	ansi map[int]bool
	// carry holds a trailing partial escape sequence: a 32KiB read can end
	// mid-CSI, and a query split across two reads is still a query.
	carry []byte
}

func newTermQ() *termQ {
	return &termQ{
		// Defaults that are not false. xterm.js starts with wraparound on and
		// the cursor visible, and a report before any h/l must say so.
		dec:  map[int]bool{7: true, 25: true},
		ansi: map[int]bool{},
	}
}

const carryMax = 64 // a query is far shorter; anything longer is not one

// scan consumes a chunk of pty OUTPUT, updates mode state, and returns the
// bytes to write back as INPUT. Never modifies the output.
func (q *termQ) scan(out []byte) []byte {
	// A session built without one (older test fixtures) answers nothing
	// rather than panicking: readPump is a goroutine per session, so a nil
	// deref here would take the daemon down and every shell with it. Silence
	// degrades to the pre-host-answering behaviour; a panic does not.
	if q == nil {
		return nil
	}
	q.mu.Lock()
	defer q.mu.Unlock()

	buf := out
	if len(q.carry) > 0 {
		buf = append(append([]byte{}, q.carry...), out...)
		q.carry = nil
	}

	var reply []byte
	for i := 0; i < len(buf); {
		if buf[i] != 0x1b {
			i++
			continue
		}
		seq, n, complete := parseCSI(buf[i:])
		if !complete {
			// Keep the tail for the next read — but only if it could still
			// become a sequence. A lone ESC in program output is common.
			if len(buf)-i <= carryMax {
				q.carry = append([]byte{}, buf[i:]...)
			}
			break
		}
		if n == 0 { // an ESC that begins nothing we parse
			i++
			continue
		}
		reply = append(reply, q.handle(seq)...)
		i += n
	}
	return reply
}

// csi is one parsed control sequence: CSI <prefix> <params> <intermediate> <final>
type csi struct {
	prefix byte // '?', '>', '<', '=' or 0
	inter  byte // '$', ' ', '"' … or 0
	final  byte
	params []int
}

// parseCSI reads one CSI at the start of b. Returns how many bytes it spans,
// and whether it is complete — an incomplete tail is a split read, not a
// malformed sequence.
func parseCSI(b []byte) (csi, int, bool) {
	var c csi
	if len(b) < 2 {
		return c, 0, false
	}
	if b[1] != '[' {
		return c, 0, true // ESC something-else: not ours, skip the ESC only
	}
	i := 2
	if i < len(b) && (b[i] == '?' || b[i] == '>' || b[i] == '<' || b[i] == '=') {
		c.prefix = b[i]
		i++
	}
	cur, has := 0, false
	for ; i < len(b); i++ {
		ch := b[i]
		switch {
		case ch >= '0' && ch <= '9':
			cur, has = cur*10+int(ch-'0'), true
		case ch == ';' || ch == ':':
			c.params = append(c.params, cur)
			cur, has = 0, false
		case ch >= 0x20 && ch <= 0x2f: // intermediates
			c.inter = ch
		case ch >= 0x40 && ch <= 0x7e: // final
			if has || len(c.params) > 0 {
				c.params = append(c.params, cur)
			}
			c.final = ch
			return c, i + 1, true
		default:
			return c, i + 1, true // junk: consume and move on
		}
	}
	return c, 0, false // ran out mid-sequence
}

func (q *termQ) param(c csi, i int) int {
	if i < len(c.params) {
		return c.params[i]
	}
	return 0
}

func (q *termQ) handle(c csi) []byte {
	switch {
	// mode set/reset — tracked, never answered
	case c.final == 'h' || c.final == 'l':
		on := c.final == 'h'
		m := q.dec
		if c.prefix != '?' {
			m = q.ansi
		}
		for _, p := range c.params {
			m[p] = on
		}
		return nil

	// DA1 — "what are you". xterm.js: VT100 with Advanced Video Option.
	case c.final == 'c' && c.prefix == 0:
		if q.param(c, 0) != 0 {
			return nil // CSI <n> c with n≠0 is not a query
		}
		return []byte("\x1b[?1;2c")

	// DA2 — "what version". xterm.js reports VT100 / 276 / 0.
	case c.final == 'c' && c.prefix == '>':
		return []byte("\x1b[>0;276;0c")

	// DSR 5 — "are you ok". 6 is CPR and needs the cursor: not ours.
	case c.final == 'n' && c.prefix == 0 && q.param(c, 0) == 5:
		return []byte("\x1b[0n")

	// DECRQM — "is mode Ps set". The one that started this.
	case c.final == 'p' && c.inter == '$':
		p := q.param(c, 0)
		v := q.modeReport(p, c.prefix == '?')
		mark := "?"
		if c.prefix != '?' {
			mark = ""
		}
		return append([]byte("\x1b["+mark), append([]byte(itoa(p)+";"+itoa(v)), '$', 'y')...)
	}
	return nil
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	var b []byte
	for n > 0 {
		b = append([]byte{byte('0' + n%10)}, b...)
		n /= 10
	}
	return string(b)
}

func b2v(on bool) int {
	if on {
		return modeSet
	}
	return modeReset
}

// modeReport mirrors xterm.js InputHandler.requestMode, quirks included.
func (q *termQ) modeReport(p int, private bool) int {
	if !private {
		switch p {
		case 2:
			return modePermReset
		case 4:
			return b2v(q.ansi[4])
		case 12:
			return modePermSet
		case 20:
			return b2v(q.ansi[20])
		}
		return modeNotRecognized
	}
	switch p {
	case 1, 6, 45, 66, 1004, 2004, 2026:
		return b2v(q.dec[p])
	case 7, 25:
		return b2v(q.dec[p]) // defaults set in newTermQ
	case 8, 1048:
		return modePermSet
	case 67, 1005, 1015:
		return modePermReset
	case 9:
		return b2v(q.mouseProtocol() == 9)
	case 1000:
		return b2v(q.mouseProtocol() == 1000)
	case 1002:
		return b2v(q.mouseProtocol() == 1002)
	case 1003:
		return b2v(q.mouseProtocol() == 1003)
	case 1006:
		return b2v(q.mouseEncoding() == 1006)
	case 1016:
		return b2v(q.mouseEncoding() == 1016)
	case 47, 1047, 1049:
		return b2v(q.dec[47] || q.dec[1047] || q.dec[1049])
	case 12:
		return modeReset // xterm option cursorBlink, off by default
	case 3:
		return modeNotRecognized // windowOptions.setWinLines is off
	}
	return modeNotRecognized
}

// The mouse modes are exclusive in xterm.js — the last one set wins — so a
// report has to name the ACTIVE one rather than test each flag.
func (q *termQ) mouseProtocol() int {
	for _, m := range []int{1003, 1002, 1000, 9} {
		if q.dec[m] {
			return m
		}
	}
	return 0
}

func (q *termQ) mouseEncoding() int {
	for _, m := range []int{1016, 1006} {
		if q.dec[m] {
			return m
		}
	}
	return 0
}
