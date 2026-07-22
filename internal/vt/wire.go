package vt

import (
	"encoding/binary"
	"errors"
)

// The wire protocol (D6). The host owns the authoritative grid; a client is a
// renderer of diffs. A Frame is the unit sent at frame cadence: the cursor plus
// the cell runs that changed since the client's last known state. Because the
// diff is taken against what the client already knows (see surface.go), a fresh
// client — starting from a blank surface — receives its whole non-blank screen
// as its first Frame. Snapshot and incremental update are one code path.
//
// This is not raw bytes and not an ANSI snapshot: it is structured, so the
// renderer applies it directly with no re-parse. The big coalescing win (a
// 2974-byte progress-bar redraw collapsing to its final line) comes from taking
// the diff at frame cadence — every intermediate write has already folded into
// the current grid by the time Render runs.

// Cursor is the visible cursor state carried in every Frame.
type Cursor struct {
	X, Y    int
	Visible bool
}

// WCell is a cell on the wire: content resolved to a string (so the combined-
// cluster side table never has to cross the wire), plus its style.
type WCell struct {
	Content string
	FG, BG  Color
	Attr    Attr
	Width   uint8
}

// Run is a horizontal span of changed cells starting at column X.
type Run struct {
	X     int
	Cells []WCell
}

// RowRuns is the set of changed runs on one row.
type RowRuns struct {
	Y    int
	Runs []Run
}

// Frame is one coalesced update: the cursor, how far the screen scrolled since
// the client's last frame, and the rows that changed. Scroll lets a full-screen
// scroll ship as "scrolled N + the newly-exposed rows" rather than a whole-
// screen diff, and is how the client feeds its own scrollback: it captures the N
// rows about to leave the top before shifting.
//
// Hist and Epoch place the frame in history's absolute address space
// (Emulator.History): Scroll is capped at the screen height, so a burst that
// scrolled 500 lines between frames advances Hist by 500 while Scroll says the
// screen's worth — the client captures its departing rows at [prevHist,
// prevHist+Scroll) and knows the rest is fetchable from the host ring, never
// mislabeling what it saw as lines it didn't.
type Frame struct {
	Cursor Cursor
	Scroll int
	Hist   uint64 // absolute index of the live screen's top row (lines ever pushed)
	Epoch  byte   // history numbering epoch; a change voids cached history
	Rows   []RowRuns
}

// Empty reports whether the frame carries no changes at all.
func (f Frame) Empty() bool { return len(f.Rows) == 0 && f.Scroll == 0 }

const wireVersion = 3

// Encode serializes a Frame to bytes. The layout is length-prefixed and
// varint-packed; colors are the packed 32-bit Color, content is a UTF-8 string.
func (f Frame) Encode() []byte {
	buf := make([]byte, 0, 64)
	buf = append(buf, wireVersion)
	buf = binary.AppendUvarint(buf, uint64(f.Cursor.X))
	buf = binary.AppendUvarint(buf, uint64(f.Cursor.Y))
	buf = append(buf, boolByte(f.Cursor.Visible))
	buf = binary.AppendUvarint(buf, uint64(f.Scroll))
	buf = binary.AppendUvarint(buf, f.Hist)
	buf = append(buf, f.Epoch)
	buf = binary.AppendUvarint(buf, uint64(len(f.Rows)))
	for _, row := range f.Rows {
		buf = binary.AppendUvarint(buf, uint64(row.Y))
		buf = binary.AppendUvarint(buf, uint64(len(row.Runs)))
		for _, run := range row.Runs {
			buf = binary.AppendUvarint(buf, uint64(run.X))
			buf = binary.AppendUvarint(buf, uint64(len(run.Cells)))
			for _, c := range run.Cells {
				buf = appendCell(buf, c)
			}
		}
	}
	return buf
}

func appendCell(buf []byte, c WCell) []byte {
	buf = append(buf, byte(c.Attr), c.Width)
	buf = binary.AppendUvarint(buf, uint64(c.FG))
	buf = binary.AppendUvarint(buf, uint64(c.BG))
	buf = binary.AppendUvarint(buf, uint64(len(c.Content)))
	buf = append(buf, c.Content...)
	return buf
}

var errShortFrame = errors.New("vt: truncated frame")

// DecodeFrame parses a Frame from bytes produced by Encode.
func DecodeFrame(b []byte) (Frame, error) {
	d := decoder{b: b}
	var f Frame
	if d.byte() != wireVersion {
		return f, errors.New("vt: unknown wire version")
	}
	f.Cursor.X = int(d.uvarint())
	f.Cursor.Y = int(d.uvarint())
	f.Cursor.Visible = d.byte() != 0
	f.Scroll = int(d.uvarint())
	f.Hist = d.uvarint()
	f.Epoch = d.byte()
	nRows := int(d.uvarint())
	f.Rows = make([]RowRuns, nRows)
	for i := range f.Rows {
		f.Rows[i].Y = int(d.uvarint())
		nRuns := int(d.uvarint())
		f.Rows[i].Runs = make([]Run, nRuns)
		for j := range f.Rows[i].Runs {
			f.Rows[i].Runs[j].X = int(d.uvarint())
			nCells := int(d.uvarint())
			cells := make([]WCell, nCells)
			for k := range cells {
				cells[k] = d.cell()
			}
			f.Rows[i].Runs[j].Cells = cells
		}
	}
	if d.err != nil {
		return Frame{}, d.err
	}
	return f, nil
}

type decoder struct {
	b   []byte
	i   int
	err error
}

func (d *decoder) byte() byte {
	if d.i >= len(d.b) {
		d.err = errShortFrame
		return 0
	}
	v := d.b[d.i]
	d.i++
	return v
}

func (d *decoder) uvarint() uint64 {
	v, n := binary.Uvarint(d.b[d.i:])
	if n <= 0 {
		d.err = errShortFrame
		return 0
	}
	d.i += n
	return v
}

func (d *decoder) cell() WCell {
	attr := Attr(d.byte())
	width := d.byte()
	fg := Color(d.uvarint())
	bg := Color(d.uvarint())
	n := int(d.uvarint())
	if d.i+n > len(d.b) {
		d.err = errShortFrame
		return WCell{}
	}
	content := string(d.b[d.i : d.i+n])
	d.i += n
	return WCell{Content: content, FG: fg, BG: bg, Attr: attr, Width: width}
}

func boolByte(b bool) byte {
	if b {
		return 1
	}
	return 0
}

// --- scrollback paging ---
//
// History never ships whole: the ring is the store and a client is a viewport
// over it, requesting pages of absolute-indexed lines as the user scrolls
// (reverse-paginated virtualized scrolling). A chunk reply always carries the
// current [base, total) window and epoch, so every fetch also refreshes the
// client's knowledge of what exists — including "nothing below base", which is
// how it learns to clamp.

// MaxSbChunk bounds one chunk reply; a client pages, it doesn't bulk-fetch.
const MaxSbChunk = 512

// SbChunk is a decoded page of scrollback lines starting at absolute index
// Start. Lines are trimmed of trailing blanks; the client pads to width.
type SbChunk struct {
	Epoch       byte
	Base, Total uint64
	Start       uint64
	Lines       [][]WCell
}

// EncodeScrollback encodes up to count history lines starting at absolute index
// start, clamped to the retained window and MaxSbChunk. count 0 is a stat: the
// reply carries just the current epoch and [base, total).
func (e *Emulator) EncodeScrollback(start uint64, count int) []byte {
	base, total := e.History()
	count = min(count, MaxSbChunk)
	start = max(start, base)
	end := min(start+uint64(count), total)
	start = min(start, end)
	buf := make([]byte, 0, 256)
	buf = append(buf, wireVersion, e.sbEpoch)
	buf = binary.AppendUvarint(buf, base)
	buf = binary.AppendUvarint(buf, total)
	buf = binary.AppendUvarint(buf, start)
	buf = binary.AppendUvarint(buf, end-start)
	sb := e.primary.sb
	for i := start; i < end; i++ {
		row := sb.row(int(i - base))
		n := len(row)
		for n > 0 && row[n-1] == blank {
			n--
		}
		buf = binary.AppendUvarint(buf, uint64(n))
		for _, c := range row[:n] {
			buf = appendCell(buf, e.wcell(c))
		}
	}
	return buf
}

// DecodeSbChunk parses a chunk produced by EncodeScrollback.
func DecodeSbChunk(b []byte) (SbChunk, error) {
	d := decoder{b: b}
	var ch SbChunk
	if d.byte() != wireVersion {
		return ch, errors.New("vt: unknown wire version")
	}
	ch.Epoch = d.byte()
	ch.Base = d.uvarint()
	ch.Total = d.uvarint()
	ch.Start = d.uvarint()
	n := int(d.uvarint())
	if d.err != nil || n > MaxSbChunk {
		return SbChunk{}, errShortFrame
	}
	ch.Lines = make([][]WCell, n)
	for i := range ch.Lines {
		m := int(d.uvarint())
		if d.err != nil || m < 0 || m > len(b) {
			return SbChunk{}, errShortFrame
		}
		line := make([]WCell, m)
		for j := range line {
			line[j] = d.cell()
		}
		ch.Lines[i] = line
	}
	if d.err != nil {
		return SbChunk{}, d.err
	}
	return ch, nil
}

// ClientGrid is the renderer side: a grid a client maintains by applying Frames.
// It is exactly the state a Phase 3 renderer paints from, and here it is what
// the reattach gate reconstructs and checks against the emulator.
type ClientGrid struct {
	cols, rows int
	cells      []WCell
	cursor     Cursor
}

// NewClientGrid returns a blank grid of the given geometry — a fresh client that
// has seen no frames yet.
func NewClientGrid(cols, rows int) *ClientGrid {
	g := &ClientGrid{cols: cols, rows: rows, cells: make([]WCell, cols*rows)}
	for i := range g.cells {
		g.cells[i] = WCell{Content: " ", Width: 1}
	}
	g.cursor.Visible = true
	return g
}

// Apply updates the grid with a Frame: first the scroll (shift up, blanking the
// exposed rows), then the changed runs.
func (g *ClientGrid) Apply(f Frame) {
	g.cursor = f.Cursor
	if f.Scroll > 0 {
		g.scrollUp(f.Scroll)
	}
	for _, row := range f.Rows {
		if row.Y < 0 || row.Y >= g.rows {
			continue
		}
		base := row.Y * g.cols
		for _, run := range row.Runs {
			for k, c := range run.Cells {
				x := run.X + k
				if x >= 0 && x < g.cols {
					g.cells[base+x] = c
				}
			}
		}
	}
}

// scrollUp shifts the visible grid up by n rows, blanking the exposed bottom.
func (g *ClientGrid) scrollUp(n int) {
	blank := WCell{Content: " ", Width: 1}
	if n >= g.rows {
		for i := range g.cells {
			g.cells[i] = blank
		}
		return
	}
	copy(g.cells, g.cells[n*g.cols:])
	for i := (g.rows - n) * g.cols; i < len(g.cells); i++ {
		g.cells[i] = blank
	}
}

// Cols and Rows are the client grid's geometry.
func (g *ClientGrid) Cols() int { return g.cols }
func (g *ClientGrid) Rows() int { return g.rows }

// Cell returns the client's cell at (x,y).
func (g *ClientGrid) Cell(x, y int) WCell { return g.cells[y*g.cols+x] }

// CursorPos returns the client's cursor.
func (g *ClientGrid) CursorPos() Cursor { return g.cursor }
