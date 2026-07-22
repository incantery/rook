package host

// The Terminal seam (perf-strategy direction, 2026-07-22): everything the host
// demands of a terminal-emulator backend, and nothing more. internal/vt is the
// native backend; a libghostty-vt adapter behind a build tag is the planned
// second. The seam is what keeps our emulator honest about its surface, and
// what turns "why not just use libghostty?" into an empirical question —
// benchmarks and differential fuzzing against the same interface — instead of
// a debate.

import "github.com/incantery/rook/internal/vt"

// Surface is a backend's opaque record of what one framed client has been
// sent. Created per attach, advanced by every Render, never inspected by the
// host — each backend diffs against its own representation.
type Surface any

// Terminal is the host's demand on an emulator backend. vt.Frame stays the
// wire currency across backends: whatever parses the bytes, the client speaks
// frames — the protocol, not the emulator, is the contract.
type Terminal interface {
	// Write parses pty output into the grid (io.Writer-shaped).
	Write(p []byte) (int, error)
	// TakeOutput drains the emulator's replies to terminal queries
	// (DA/DSR/CPR/OSC palette...) — they are pty INPUT, never frame data.
	TakeOutput() []byte
	Resize(cols, rows int)
	// SetPalette supplies the theme for OSC 4/10-12 answers; 0xRRGGBB.
	SetPalette(fg, bg, cursor uint32, ansi [16]uint32)
	// AltScreen and MouseTracking are the session-state byte (msgState).
	AltScreen() bool
	MouseTracking() (level int, sgr bool)
	// EncodeScrollback encodes a page of history by absolute line index — the
	// msgSbChunk payload (reverse-paginated virtualized scrolling).
	EncodeScrollback(start uint64, count int) []byte
	// NewSurface is a blank client; its first Render is the whole non-blank
	// screen — snapshot and incremental update as one code path.
	NewSurface() Surface
	Render(s Surface) vt.Frame
}

// vtTerminal is the native backend — internal/vt, bridged only where the
// concrete Surface type needs erasing.
type vtTerminal struct{ *vt.Emulator }

// newTerminal returns the configured emulator backend. Only the native one
// exists today; the config knob arrives with the second backend.
func newTerminal(cols, rows int) Terminal { return vtTerminal{vt.New(cols, rows)} }

func (t vtTerminal) NewSurface() Surface { return t.Emulator.NewSurface() }

func (t vtTerminal) Render(s Surface) vt.Frame { return t.Emulator.Render(s.(*vt.Surface)) }
