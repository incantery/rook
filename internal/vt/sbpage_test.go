package vt

import (
	"fmt"
	"strings"
	"testing"
)

// Scrollback paging: history is addressed by absolute line index — stable
// within an epoch even as the ring evicts — so a client can page it on demand
// (reverse-paginated virtualized scrolling) instead of holding a copy.

// chunkLine flattens one decoded chunk line to a string.
func chunkLine(cells []WCell) string {
	var b strings.Builder
	for _, c := range cells {
		b.WriteString(c.Content)
	}
	return b.String()
}

// feedLines writes n numbered lines (L1..Ln) to the emulator.
func feedLines(e *Emulator, n int) {
	for i := 1; i <= n; i++ {
		e.Write(fmt.Appendf(nil, "L%d", i))
		if i < n {
			e.Write([]byte("\r\n"))
		}
	}
}

func TestHistoryWindowSurvivesEviction(t *testing.T) {
	e := NewWithScrollback(10, 2, 3) // cap 3 lines
	feedLines(e, 8)                  // L1..L6 scroll off; ring keeps L4,L5,L6

	base, total := e.History()
	if base != 3 || total != 6 {
		t.Fatalf("History() = [%d,%d), want [3,6): eviction moves base, never renumbers", base, total)
	}
}

func TestEncodeScrollbackPages(t *testing.T) {
	e := NewWithScrollback(20, 3, 100)
	feedLines(e, 10) // L1..L7 in history at absolute 0..6

	// a middle page
	ch, err := DecodeSbChunk(e.EncodeScrollback(2, 3))
	if err != nil {
		t.Fatal(err)
	}
	if ch.Base != 0 || ch.Total != 7 || ch.Start != 2 || len(ch.Lines) != 3 {
		t.Fatalf("chunk window = base %d total %d start %d n %d, want 0/7/2/3",
			ch.Base, ch.Total, ch.Start, len(ch.Lines))
	}
	for j, want := range []string{"L3", "L4", "L5"} {
		if got := chunkLine(ch.Lines[j]); got != want {
			t.Fatalf("line %d = %q, want %q", j, got, want)
		}
	}

	// count 0 is a stat: bounds only, no lines
	ch, err = DecodeSbChunk(e.EncodeScrollback(0, 0))
	if err != nil {
		t.Fatal(err)
	}
	if ch.Base != 0 || ch.Total != 7 || len(ch.Lines) != 0 {
		t.Fatalf("stat = base %d total %d n %d, want 0/7/0", ch.Base, ch.Total, len(ch.Lines))
	}

	// a request past the end comes back empty, not an error
	ch, err = DecodeSbChunk(e.EncodeScrollback(50, 10))
	if err != nil || len(ch.Lines) != 0 {
		t.Fatalf("past-end fetch: n=%d err=%v, want 0/nil", len(ch.Lines), err)
	}
}

func TestEncodeScrollbackClampsToBase(t *testing.T) {
	e := NewWithScrollback(10, 2, 3)
	feedLines(e, 8) // window is [3,6): L4,L5,L6

	// asking below base answers from base — the reply says where it started
	ch, err := DecodeSbChunk(e.EncodeScrollback(0, 10))
	if err != nil {
		t.Fatal(err)
	}
	if ch.Start != 3 || len(ch.Lines) != 3 {
		t.Fatalf("clamped fetch: start %d n %d, want 3/3", ch.Start, len(ch.Lines))
	}
	if got := chunkLine(ch.Lines[0]); got != "L4" {
		t.Fatalf("line at absolute 3 = %q, want L4", got)
	}
}

func TestEncodeScrollbackKeepsStyle(t *testing.T) {
	e := New(20, 2)
	e.Write([]byte("\x1b[1;31mred\x1b[0m\r\nplain\r\nnext\r\nmore")) // "red" scrolls off
	ch, err := DecodeSbChunk(e.EncodeScrollback(0, 1))
	if err != nil {
		t.Fatal(err)
	}
	c := ch.Lines[0][0]
	if c.Content != "r" || c.Attr&AttrBold == 0 {
		t.Fatalf("styled cell = %q attr %v, want bold r", c.Content, c.Attr)
	}
}

// The frame places itself in history's address space: Hist advances by the real
// scroll amount even when Scroll is capped at the screen height — that gap is
// what the client fetches instead of mislabeling rows it never saw.
func TestFrameHistOutrunsCappedScroll(t *testing.T) {
	e := New(10, 3)
	s := e.NewSurface()
	e.Render(s) // baseline

	feedLines(e, 20) // 17 lines scroll off between renders; cap is 3
	f := e.Render(s)
	if f.Scroll != 3 {
		t.Fatalf("Scroll = %d, want 3 (capped at height)", f.Scroll)
	}
	if f.Hist != 17 {
		t.Fatalf("Hist = %d, want 17 (the real depth)", f.Hist)
	}
}

func TestSbEpochBumpsOnResizeAndReset(t *testing.T) {
	e := New(10, 3)
	ep := e.SbEpoch()
	e.Resize(12, 3)
	if e.SbEpoch() == ep {
		t.Fatal("resize did not bump the scrollback epoch")
	}
	ep = e.SbEpoch()
	e.Resize(12, 3) // no-op resize: indices unchanged, epoch must hold
	if e.SbEpoch() != ep {
		t.Fatal("no-op resize bumped the epoch")
	}
	e.Write([]byte("\x1bc")) // RIS
	if e.SbEpoch() == ep {
		t.Fatal("reset did not bump the scrollback epoch")
	}
}

// Encode/Decode round-trips the new Frame fields.
func TestFrameWireCarriesHistAndEpoch(t *testing.T) {
	f := Frame{Cursor: Cursor{X: 1, Y: 2, Visible: true}, Scroll: 3, Hist: 900, Epoch: 7}
	got, err := DecodeFrame(f.Encode())
	if err != nil {
		t.Fatal(err)
	}
	if got.Hist != 900 || got.Epoch != 7 || got.Scroll != 3 {
		t.Fatalf("round trip = hist %d epoch %d scroll %d, want 900/7/3", got.Hist, got.Epoch, got.Scroll)
	}
}
