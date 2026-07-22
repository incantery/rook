package vt

import (
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

// The wire protocol crosses a language boundary: Go encodes Frames, the browser
// (frontend/src/term/vt) decodes them. This writes a conformance fixture — for
// each corpus capture, the encoded snapshot Frame plus the grid it must
// reconstruct to (the same {c,w,fg,bg,a} token schema the fidelity oracle uses).
// The TypeScript decoder replays these and must land the identical grid, so a
// divergence in either the codec or the color/attr interpretation is caught.
//
// It writes only when asked, so a normal `go test` never mutates the tree:
//
//	VT_GEN_FIXTURES=1 go test ./internal/vt -run TestWriteWireFixtures
//
// then commit frontend/src/term/vt/testdata/frames.json.
func TestWriteWireFixtures(t *testing.T) {
	if os.Getenv("VT_GEN_FIXTURES") == "" {
		t.Skip("set VT_GEN_FIXTURES=1 to regenerate the frontend wire fixture")
	}

	type fixture struct {
		Name   string   `json:"name"`
		Cols   int      `json:"cols"`
		Rows   int      `json:"rows"`
		Frame  string   `json:"frame"`  // hex of the encoded snapshot Frame
		Cursor Cursor   `json:"cursor"` // expected cursor after applying the frame
		Grid   []string `json:"grid"`   // one packed string per row (see below)
	}

	// Each row is packed compactly: cells joined by US (\x1f), fields within a
	// cell joined by RS (\x1e) in the order content,width,fg,bg,attr. These
	// control bytes never occur in cell content, and the TS side splits on them
	// to recover the same {c,w,fg,bg,a} tokens the fidelity oracle uses.
	const us, rs = "\x1f", "\x1e"
	packRow := func(e *Emulator, y int) string {
		var b []byte
		for x := range e.Cols() {
			if x > 0 {
				b = append(b, us...)
			}
			c := e.CellAt(x, y)
			b = append(b, e.Content(c)...)
			b = append(b, rs...)
			b = append(b, byte('0'+c.Width))
			b = append(b, rs...)
			b = append(b, c.FG.Token()...)
			b = append(b, rs...)
			b = append(b, c.BG.Token()...)
			b = append(b, rs...)
			b = append(b, c.Attr.Token()...)
		}
		return string(b)
	}

	names := []string{"git-graph", "nvim-edit", "redraw", "longlines", "unicode", "scrollregion", "editing", "altthrash", "wrap"}
	fixtures := make([]fixture, 0, len(names))
	for _, name := range names {
		raw, m := loadCapture(t, name)
		e := New(m.Cols, m.Rows)
		e.Write(raw)

		frame := e.Render(e.NewSurface()) // snapshot: diff from blank
		fx := fixture{
			Name:   name,
			Cols:   m.Cols,
			Rows:   m.Rows,
			Frame:  hex.EncodeToString(frame.Encode()),
			Cursor: frame.Cursor,
			Grid:   make([]string, m.Rows),
		}
		for y := range m.Rows {
			fx.Grid[y] = packRow(e, y)
		}
		fixtures = append(fixtures, fx)
	}

	out, err := json.MarshalIndent(fixtures, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	dst := filepath.Join("..", "..", "frontend", "src", "term", "vt", "testdata", "frames.json")
	if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(dst, out, 0o644); err != nil {
		t.Fatal(err)
	}
	t.Logf("wrote %d fixtures to %s (%d bytes)", len(fixtures), dst, len(out))
}
