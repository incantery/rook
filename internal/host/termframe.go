package host

// The framed terminal transport (HI-A of the host-integration plan). Where the
// legacy path streams raw pty bytes and lets xterm.js parse them, this path runs
// the emulator on the host (internal/vt) and streams coalesced grid diffs: the
// client is a renderer, not the owner of terminal state.
//
// It is additive and unwired for now — readPump feeds the emulator alongside the
// legacy ring, and this endpoint serves whoever connects (the HI-A test client),
// but the app's mount still uses the raw path until HI-B swaps it. Query
// answering therefore still belongs to termquery.go on the raw path; the
// emulator's own answers are drained and discarded here (HI-C routes them to the
// pty and deletes termquery.go). Frames never carry query replies — those are
// pty input, never grid state — so no query ever reaches a framed client.
//
// WebSocket messages preserve boundaries, so each message is a 1-byte tag plus
// payload; no length framing is needed.

import (
	"context"
	"encoding/binary"
	"net/http"
	"time"

	"github.com/coder/websocket"
	cpty "github.com/creack/pty"

	"github.com/incantery/rook/internal/vt"
)

const (
	// server -> client
	msgFrame   byte = 0x01 // payload: vt.Frame.Encode()
	msgState   byte = 0x02 // payload: 1 flags byte (bit0 = alt screen)
	msgSbChunk byte = 0x03 // payload: vt.EncodeScrollback — a page of history
	msgEdit    byte = 0x04 // payload: editPayload JSON (edit.go) — pane takeover ask
	msgAsk     byte = 0x05 // payload: askPayload JSON (ask.go) — a question for the human
	msgAskDone byte = 0x06 // payload: {"id"} — that ask is settled, stand down

	// client -> server
	msgInput   byte = 0x10 // payload: raw bytes for the pty
	msgResize  byte = 0x11 // payload: cols, rows as two big-endian uint16
	msgPalette byte = 0x12 // payload: fg,bg,cursor (3 bytes RGB each) + 16 ansi RGB
	msgSbFetch byte = 0x13 // payload: start (BE uint32), count (BE uint16)
	msgVis     byte = 0x14 // payload: 1 byte — 0 hidden, 1 visible
)

// paletteBytes is the msgPalette payload length: fg+bg+cursor (9) + 16 ANSI (48).
const paletteBytes = 9 + 16*3

// msgState payload is one flags byte: bit0 = alt screen; bits1-3 = mouse
// tracking level (0=off..4=any-event); bit4 = SGR mouse encoding; bit5 = the
// pane is a live claimed agent window (host.agentPane).
const (
	stateAlt      byte = 1 << 0
	stateMouseSGR byte = 1 << 4
	// stateAgentPane is only ever set alongside stateAlt — it exists to
	// qualify the yield the alt bit triggers, and means nothing without it.
	stateAgentPane byte = 1 << 5
)

// mouseFlags packs the mouse level (0-4) into bits 1-3.
func mouseFlags(level int) byte { return byte(level&0x7) << 1 }

// rgb24 reads a 0xRRGGBB color from the first three bytes of b.
func rgb24(b []byte) uint32 { return uint32(b[0])<<16 | uint32(b[1])<<8 | uint32(b[2]) }

// frameInterval bounds how often the render loop diffs the grid: a burst of pty
// output between ticks folds into one net frame (the coalescing D6 wants). It is
// a latency floor, not a latency source — the spec measured the browser paint,
// not transport, as the keystroke→glyph cost.
const frameInterval = 16 * time.Millisecond

// handleAttachFramed serves the framed transport for one session. It runs a
// render loop (grid diffs out) and, on this goroutine, an input loop (keystrokes
// and resizes in). One framed client per session, like the raw path: a new
// attach replaces the old.
func (h *Host) handleAttachFramed(w http.ResponseWriter, r *http.Request, s *session) {
	c, err := websocket.Accept(w, r, &websocket.AcceptOptions{InsecureSkipVerify: true})
	if err != nil {
		return
	}

	// Out-of-band pushes (edit requests) ride to the render loop — the sole
	// writer to c — like scrollback fetches do. Registered on the session so
	// HTTP handlers can reach the live attach; cleared on detach.
	oob := make(chan []byte, 4)

	s.mu.Lock()
	if old := s.frameConn; old != nil {
		go old.Close(websocket.StatusPolicyViolation, "replaced")
	}
	s.frameConn = c
	s.oob = oob
	s.mu.Unlock()

	// A pending ask survives the app (the blocked rookctl is still parked
	// in this pty) — re-push it so the fresh attach re-renders the form.
	for _, frame := range h.pendingAskFrames(s.info.ID) {
		select {
		case oob <- frame:
		default:
		}
	}

	// A fresh (blank) Surface: the first Render against it is the whole non-blank
	// screen — the snapshot, gap-free by construction, no ring replay.
	s.emuMu.Lock()
	surface := s.emu.NewSurface()
	s.emuMu.Unlock()

	ctx := r.Context()
	// Scrollback fetches ride to the render loop — the sole writer to c — over
	// a small buffered channel. A full channel drops the request: the client
	// re-asks after a beat (its in-flight marker expires), and history reads
	// must never backpressure the input loop.
	fetch := make(chan sbFetch, 4)
	// Visibility rides its own cap-1 channel; the input loop (sole producer)
	// drains a stale value before pushing, so the render loop always sees the
	// latest state and the input loop never blocks.
	vis := make(chan bool, 1)
	go h.framedRenderLoop(ctx, s, c, surface, fetch, vis, oob)

	// Client -> host: input and resize. Detach on any read error; the session and
	// its emulator live on.
	for {
		_, data, rerr := c.Read(ctx)
		if rerr != nil {
			break
		}
		if len(data) == 0 {
			continue
		}
		switch data[0] {
		case msgInput:
			// Marked BEFORE the write, not after: the echo comes back through
			// the line discipline immediately, so readPump can signal dirty
			// while this goroutine is still between the two statements. Marking
			// after loses that race and the echo waits out the tick — the exact
			// stall this exists to remove.
			s.lastInput.Store(time.Now().UnixNano())
			s.pty.Write(data[1:])
		case msgResize:
			if len(data) < 5 {
				continue
			}
			cols := int(binary.BigEndian.Uint16(data[1:3]))
			rows := int(binary.BigEndian.Uint16(data[3:5]))
			if cols <= 0 || rows <= 0 {
				continue
			}
			cpty.Setsize(s.pty, &cpty.Winsize{Cols: uint16(cols), Rows: uint16(rows)})
			s.emuMu.Lock()
			s.emu.Resize(cols, rows)
			s.emuMu.Unlock()
			s.mu.Lock()
			s.info.Cols, s.info.Rows = cols, rows
			s.mu.Unlock()
			s.signalDirty() // force the resend that the geometry change needs
		case msgPalette:
			p := data[1:]
			if len(p) < paletteBytes {
				continue
			}
			var ansi [16]uint32
			for i := range ansi {
				ansi[i] = rgb24(p[9+i*3:])
			}
			s.emuMu.Lock()
			s.emu.SetPalette(rgb24(p[0:]), rgb24(p[3:]), rgb24(p[6:]), ansi)
			s.emuMu.Unlock()
		case msgSbFetch:
			if len(data) < 7 {
				continue
			}
			req := sbFetch{
				start: uint64(binary.BigEndian.Uint32(data[1:5])),
				count: int(binary.BigEndian.Uint16(data[5:7])),
			}
			select {
			case fetch <- req:
			default: // full — drop; the client retries
			}
		case msgVis:
			if len(data) < 2 {
				continue
			}
			select {
			case <-vis:
			default:
			}
			vis <- data[1] != 0
		}
	}

	s.mu.Lock()
	if s.frameConn == c {
		s.frameConn = nil
		s.oob = nil
	}
	s.mu.Unlock()
	c.CloseNow()
}

// sbFetch is a client's request for a page of scrollback history.
type sbFetch struct {
	start uint64
	count int
}

// framedRenderLoop diffs the emulator's grid against what this client knows and
// ships the delta, coalesced at frameInterval. It is the sole writer to c —
// scrollback chunk replies are written here too, for that reason.
//
// A hidden pane (vis false) pauses here, not upstream: the emulator keeps
// parsing (correctness — the grid must be right whenever the user looks), but
// no diff is taken, no frame encoded, no bytes sent, no client DOM touched.
// The Surface just goes stale; the reveal render diffs the live grid against
// it and ships the net of everything missed as one frame. N background
// sessions cost their ring storage and parsing — nothing per-frame.
func (h *Host) framedRenderLoop(ctx context.Context, s *session, c *websocket.Conn, surface Surface, fetch <-chan sbFetch, vis <-chan bool, oob <-chan []byte) {
	lastState, stateKnown := byte(0), false
	lastCursor, cursorKnown := vt.Cursor{}, false
	render := func() bool {
		s.emuMu.Lock()
		f := s.emu.Render(surface)
		alt := s.emu.AltScreen()
		mlevel, msgr := s.emu.MouseTracking()
		s.emuMu.Unlock()
		// Announce session state (alt screen + mouse mode) before the frame that
		// changed it, so keybind routing (HI-6) and mouse forwarding are never a
		// frame behind.
		state := mouseFlags(mlevel)
		if alt {
			state |= stateAlt
			// Gated on alt deliberately: the client only consults this when
			// deciding whether a full-screen app takes the nav chords, so a
			// shell prompt never pays the ioctl.
			if h.agentPane(s) {
				state |= stateAgentPane
			}
		}
		if msgr {
			state |= stateMouseSGR
		}
		if !stateKnown || state != lastState {
			stateKnown, lastState = true, state
			if c.Write(ctx, websocket.MessageBinary, []byte{msgState, state}) != nil {
				return false
			}
		}
		// Send when cells changed OR the cursor moved. A cursor-only frame
		// matters: typing a space into an already-blank cell changes no cell,
		// only the cursor — dropping it left the space invisible until the next
		// glyph forced a frame.
		if f.Empty() && cursorKnown && f.Cursor == lastCursor {
			return true // nothing changed — not an error
		}
		lastCursor, cursorKnown = f.Cursor, true
		msg := append([]byte{msgFrame}, f.Encode()...)
		return c.Write(ctx, websocket.MessageBinary, msg) == nil
	}

	// serve answers one scrollback fetch. Chunks bypass the frame rate limit:
	// they are history reads, not grid churn, and the user is mid-scroll.
	serve := func(req sbFetch) bool {
		s.emuMu.Lock()
		chunk := s.emu.EncodeScrollback(req.start, req.count)
		s.emuMu.Unlock()
		msg := append([]byte{msgSbChunk}, chunk...)
		return c.Write(ctx, websocket.MessageBinary, msg) == nil
	}

	// The snapshot: whatever is already on screen when the client attaches.
	if !render() {
		return
	}
	last := time.Now()
	visible := true
	for {
		select {
		case <-ctx.Done():
			return
		case req := <-fetch:
			if !serve(req) {
				return
			}
			continue
		case msg := <-oob:
			// pre-framed control messages (edit requests) — visibility
			// doesn't gate them, the app must hear the ask regardless
			if c.Write(ctx, websocket.MessageBinary, msg) != nil {
				return
			}
			continue
		case v := <-vis:
			if v == visible {
				continue
			}
			visible = v
			if !visible {
				continue
			}
			// reveal: whatever accumulated while hidden, as one net frame now
			if !render() {
				return
			}
			last = time.Now()
			continue
		case <-s.dirty:
			if !visible {
				continue // parsing continues; rendering waits for the reveal
			}
		}
		// Coalesce a burst to one frame per interval, but render a change that
		// lands after an idle gap immediately — that is the keystroke echo the
		// user feels. A fixed wait here made every echo a frame late, which read
		// as sluggish typing under an interactive TUI.
		//
		// The idle gap alone is not enough, because it only covers a session
		// that is QUIET. Type into a pane that is itself producing output — a
		// build, a test run, an agent streaming — and `last` is never stale, so
		// every keystroke waited out the remainder of the tick: measured p50
		// 9.9-13.0ms against 0.8ms at a quiet prompt (echolat_test.go). That is
		// the largest single latency term in the pipeline, and it is pure wait,
		// not work. So an echo skips the wait outright: if a keystroke arrived
		// since the last frame, this frame is carrying it.
		//
		// Bounded by construction — one extra frame per keystroke, and only for
		// the pane the human is typing into. The firehose in the next pane
		// still coalesces at frameInterval.
		//
		// The wait itself has to be interruptible, which is the part that is
		// easy to get wrong: under a stream the loop is nearly always ALREADY
		// inside this timer when the keystroke lands, so a check made only on
		// the way in fixes almost nothing (measured: p50 13.0ms → 13.0ms, with
		// only the lucky minority dropping to 0.4ms). Waking on the keystroke
		// itself is also wrong — the echo has not been parsed yet, so the frame
		// would go out empty and the glyph would wait for the NEXT tick. Wake
		// on the first dirty that follows the keystroke: that is the echo
		// arriving.
		if wait := frameInterval - time.Since(last); wait > 0 && !s.echoPending(last) {
			t := time.NewTimer(wait)
		coalesce:
			for {
				select {
				case <-ctx.Done():
					t.Stop()
					return
				case <-t.C:
					break coalesce
				case <-s.dirty:
					if s.echoPending(last) {
						t.Stop()
						break coalesce
					}
					// Not an echo — stream output. It folds into the frame this
					// wait is already going to send, which is the whole point of
					// coalescing; keep waiting.
				}
			}
		}
		// Stamped BEFORE the frame is built, not after: render() snapshots the
		// emulator on entry, so a keystroke echo parsed while it is encoding is
		// NOT in the frame going out. Stamping after would date the frame later
		// than its own contents and that echo would read as already-sent, then
		// wait out a full tick — the p99 ~18ms that survived the first cut.
		snapshot := time.Now()
		if !render() {
			return
		}
		last = snapshot
	}
}

// echoPending reports whether a keystroke arrived since the frame sent at
// `last` — i.e. whether the next frame is carrying an echo the user is waiting
// on, and must not be held back for coalescing.
func (s *session) echoPending(last time.Time) bool {
	return s.lastInput.Load() > last.UnixNano()
}

// signalDirty wakes the render loop without blocking the caller; the buffered
// channel coalesces many signals between renders into one.
func (s *session) signalDirty() {
	select {
	case s.dirty <- struct{}{}:
	default:
	}
}
