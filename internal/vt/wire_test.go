package vt

import (
	"testing"
)

// assertClientMatches is the reattach gate's core check: every visible cell and
// the cursor on the client must equal the emulator's — reconstructed purely
// from Frames, never from the byte stream.
func assertClientMatches(t *testing.T, tag string, client *ClientGrid, e *Emulator) {
	t.Helper()
	for y := range e.Rows() {
		for x := range e.Cols() {
			got := client.Cell(x, y)
			want := e.CellAt(x, y)
			wc := e.Content(want)
			if got.Content != wc || got.Width != want.Width ||
				got.FG != want.FG || got.BG != want.BG || got.Attr != want.Attr {
				t.Fatalf("%s (%d,%d): client{%q w%d fg%s bg%s a%q} != emu{%q w%d fg%s bg%s a%q}",
					tag, x, y, got.Content, got.Width, got.FG.Token(), got.BG.Token(), got.Attr.Token(),
					wc, want.Width, want.FG.Token(), want.BG.Token(), want.Attr.Token())
			}
		}
	}
	if c := client.CursorPos(); c.X != e.cur.cx || c.Y != e.cur.cy || c.Visible != e.cursorVisible {
		t.Fatalf("%s cursor: client %+v != emu {X:%d Y:%d Visible:%v}", tag, c, e.cur.cx, e.cur.cy, e.cursorVisible)
	}
}

// roundtrip encodes a frame to bytes and decodes it back — the client never
// sees the frame struct directly, only the wire bytes.
func roundtrip(t *testing.T, f Frame) Frame {
	t.Helper()
	got, err := DecodeFrame(f.Encode())
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	return got
}

// TestReattachGate is the Phase 2 acceptance test: a client that attaches partway
// through a session, receives a snapshot Frame, then streams incremental Frames,
// reconstructs the emulator's grid identically at every step — from wire bytes
// alone. This holds across every corpus capture.
func TestReattachGate(t *testing.T) {
	for _, name := range []string{"git-graph", "nvim-edit", "redraw", "longlines", "unicode", "scrollregion", "editing", "altthrash", "wrap"} {
		t.Run(name, func(t *testing.T) {
			raw, m := loadCapture(t, name)
			e := New(m.Cols, m.Rows)

			// Feed the first 60% before the client attaches.
			split := len(raw) * 6 / 10
			e.Write(raw[:split])

			// Attach: a blank surface, first Render is the snapshot.
			surf := e.NewSurface()
			client := NewClientGrid(m.Cols, m.Rows)
			client.Apply(roundtrip(t, e.Render(surf)))
			assertClientMatches(t, "snapshot", client, e)

			// Stream the rest in chunks, rendering a diff after each.
			rest := raw[split:]
			const chunks = 8
			for i := range chunks {
				lo := len(rest) * i / chunks
				hi := len(rest) * (i + 1) / chunks
				e.Write(rest[lo:hi])
				client.Apply(roundtrip(t, e.Render(surf)))
				assertClientMatches(t, "diff", client, e)
			}

			// A final render with no new input must be an empty frame.
			if f := e.Render(surf); !f.Empty() {
				t.Fatalf("idempotent render produced %d changed rows", len(f.Rows))
			}
		})
	}
}

// TestCoalescing proves the frame-cadence diff collapses a redraw firehose. The
// progress-bar capture is 2974 raw bytes of \r-overwrites; a single Render after
// feeding it all must emit only the final screen — a fraction of that — while
// still reconstructing identically.
func TestCoalescing(t *testing.T) {
	raw, m := loadCapture(t, "redraw")
	e := New(m.Cols, m.Rows)
	e.Write(raw)

	surf := e.NewSurface()
	frame := e.Render(surf)
	enc := frame.Encode()

	client := NewClientGrid(m.Cols, m.Rows)
	client.Apply(roundtrip(t, frame))
	assertClientMatches(t, "coalesced", client, e)

	t.Logf("redraw: %d raw bytes -> %d wire bytes (%.1fx)", len(raw), len(enc), float64(len(raw))/float64(len(enc)))
	if len(enc) >= len(raw)/2 {
		t.Errorf("coalescing weak: %d raw -> %d wire, want < %d", len(raw), len(enc), len(raw)/2)
	}
}

// TestCoalescingBeatsPerWrite contrasts one coalesced frame against rendering a
// frame after every small write — the coalesced path must ship far fewer bytes.
func TestCoalescingBeatsPerWrite(t *testing.T) {
	raw, m := loadCapture(t, "redraw")

	// Per-write: a diff after every 8-byte chunk (a chatty renderer).
	ePer := New(m.Cols, m.Rows)
	surfPer := ePer.NewSurface()
	perBytes := 0
	for i := 0; i < len(raw); i += 8 {
		hi := min(i+8, len(raw))
		ePer.Write(raw[i:hi])
		perBytes += len(ePer.Render(surfPer).Encode())
	}

	// Coalesced: one diff at the end.
	eCo := New(m.Cols, m.Rows)
	surfCo := eCo.NewSurface()
	eCo.Write(raw)
	coBytes := len(eCo.Render(surfCo).Encode())

	t.Logf("per-write %d bytes vs coalesced %d bytes (%.1fx)", perBytes, coBytes, float64(perBytes)/float64(coBytes))
	if coBytes >= perBytes {
		t.Errorf("coalesced (%d) not smaller than per-write (%d)", coBytes, perBytes)
	}
}

func TestFrameEncodeRoundtrip(t *testing.T) {
	f := Frame{
		Cursor: Cursor{X: 3, Y: 7, Visible: false},
		Rows: []RowRuns{{
			Y: 2,
			Runs: []Run{
				{X: 0, Cells: []WCell{{Content: "A", FG: Palette(1), Width: 1, Attr: AttrBold}}},
				{X: 5, Cells: []WCell{{Content: "世", Width: 2}, {Content: " ", Width: 0}}},
			},
		}},
	}
	got := roundtrip(t, f)
	if got.Cursor != f.Cursor {
		t.Fatalf("cursor: %+v != %+v", got.Cursor, f.Cursor)
	}
	if len(got.Rows) != 1 || got.Rows[0].Y != 2 || len(got.Rows[0].Runs) != 2 {
		t.Fatalf("rows structure lost: %+v", got.Rows)
	}
	if got.Rows[0].Runs[1].Cells[0].Content != "世" {
		t.Fatalf("wide content lost: %q", got.Rows[0].Runs[1].Cells[0].Content)
	}
}
