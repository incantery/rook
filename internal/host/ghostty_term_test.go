//go:build ghostty

package host

// The libghostty-vt experiment: benchmarks and the differential oracle.
// Run with:
//
//	make ghostty-lib                      # once: build the static library
//	go test -tags ghostty ./internal/host/ -run Ghostty -v
//	go test -tags ghostty ./internal/host/ -bench 'Pipe|WriteOnly' -run xxx
//
// The oracle feeds identical byte streams to both backends through the
// Terminal seam and compares full rendered frames (content, width, colors as
// wire tokens, attrs, cursor). Divergences fail with a cell-level report —
// each one is either our bug, their bug, or a spec ambiguity worth knowing.

import (
	"fmt"
	"regexp"
	"strings"
	"testing"
	"unicode"
	"unicode/utf8"

	"github.com/incantery/rook/internal/vt"
)

// gridOf renders a backend's full frame into comparable row strings:
// "content|fg,bg,attr" tokens per cell, trailing default-blank cells trimmed.
func gridOf(t Terminal, cols, rows int) []string {
	f := t.Render(t.NewSurface())
	grid := make([]vt.WCell, cols*rows)
	for i := range grid {
		grid[i] = vt.WCell{Content: " ", Width: 1}
	}
	for _, rr := range f.Rows {
		for _, run := range rr.Runs {
			for i, c := range run.Cells {
				if run.X+i < cols && rr.Y < rows {
					grid[rr.Y*cols+run.X+i] = c
				}
			}
		}
	}
	out := make([]string, rows)
	for y := 0; y < rows; y++ {
		var sb strings.Builder
		for x := 0; x < cols; x++ {
			c := grid[y*cols+x]
			sb.WriteString(fmt.Sprintf("[%q w%d %s %s %s]",
				c.Content, c.Width, c.FG.Token(), c.BG.Token(), c.Attr.Token()))
		}
		out[y] = sb.String()
	}
	return out
}

// oracle drives both backends with the same bytes and compares frames.
func oracle(t *testing.T, name, stream string) {
	t.Helper()
	const cols, rows = 40, 10
	ours := newTerminal(cols, rows)
	theirs := newGhosttyTerminal(cols, rows)
	defer theirs.(*ghosttyTerminal).free()
	_, _ = ours.Write([]byte(stream))
	_, _ = theirs.Write([]byte(stream))

	a := gridOf(ours, cols, rows)
	b := gridOf(theirs, cols, rows)
	for y := range a {
		if a[y] != b[y] {
			t.Errorf("%s: row %d diverges\n  vt:      %s\n  ghostty: %s", name, y, a[y], b[y])
		}
	}

	fa := ours.Render(ours.NewSurface())
	fb := theirs.Render(theirs.NewSurface())
	if fa.Cursor != fb.Cursor {
		t.Errorf("%s: cursor diverges vt=%+v ghostty=%+v", name, fa.Cursor, fb.Cursor)
	}
	if ours.AltScreen() != theirs.AltScreen() {
		t.Errorf("%s: altscreen diverges vt=%v ghostty=%v", name, ours.AltScreen(), theirs.AltScreen())
	}
}

func TestGhosttySmoke(t *testing.T) {
	term := newGhosttyTerminal(20, 4)
	defer term.(*ghosttyTerminal).free()
	_, _ = term.Write([]byte("hi \x1b[31mred\x1b[0m\r\nworld 漢"))
	f := term.Render(term.NewSurface())
	if len(f.Rows) < 2 {
		t.Fatalf("expected 2 changed rows, got %d", len(f.Rows))
	}
	r0 := f.Rows[0].Runs[0].Cells
	if r0[0].Content != "h" || r0[3].Content != "r" || r0[3].FG != vt.Palette(1) {
		t.Errorf("row0 = %+v", r0[:6])
	}
	r1 := f.Rows[1].Runs[0].Cells
	if r1[6].Content != "漢" || r1[6].Width != 2 || r1[7].Width != 0 {
		t.Errorf("row1 wide = %+v", r1[5:8])
	}
	if f.Cursor.X != 8 || f.Cursor.Y != 1 {
		t.Errorf("cursor = %+v", f.Cursor)
	}
}

func TestGhosttyOracle(t *testing.T) {
	cases := map[string]string{
		"plain text":       "hello world",
		"crlf":             "line one\r\nline two\r\n",
		"wrap":             strings.Repeat("x", 45),
		"wide wrap":        strings.Repeat("漢", 21),
		"ansi colors":      "\x1b[31mred \x1b[42mongreen \x1b[94mbrightblue\x1b[0m done",
		"256 color":        "\x1b[38;5;196mred256 \x1b[48;5;21mbg21\x1b[0m",
		"truecolor":        "\x1b[38;2;10;20;30mrgb \x1b[48;2;200;100;50mbgrgb\x1b[0m",
		"attrs":            "\x1b[1mbold \x1b[3mitalic \x1b[4munder \x1b[7mrev \x1b[9mstrike\x1b[0m",
		"attr reset":       "\x1b[1;31mboldred\x1b[22m notbold\x1b[39m defaultfg",
		"cursor moves":     "abcdef\x1b[3;5Hjump\x1b[2Aup\x1b[4Ddd",
		"erase line":       "aaaaaaaaaa\x1b[5D\x1b[K",
		"erase line left":  "aaaaaaaaaa\x1b[5D\x1b[1K",
		"erase screen":     "top\r\nmiddle\r\nbottom\x1b[2;1H\x1b[J",
		"bce":              "\x1b[41m\x1b[2Jpainted",
		"scroll":           strings.Repeat("line\r\n", 15),
		"scroll region":    "\x1b[2;5rA\r\nB\r\nC\r\nD\r\nE\r\nF\r\nG\x1b[r",
		"tabs":             "a\tb\tc\td",
		"carriage return":  "overwritten\rnew",
		"backspace":        "abc\b\bX",
		"insert chars":     "abcdef\x1b[1;1H\x1b[3@",
		"delete chars":     "abcdef\x1b[1;1H\x1b[2P",
		"insert lines":     "a\r\nb\r\nc\x1b[1;1H\x1b[2L",
		"delete lines":     "a\r\nb\r\nc\x1b[1;1H\x1b[1M",
		"reverse index":    "one\r\ntwo\x1bM\x1bM up",
		"pending wrap":     strings.Repeat("y", 40) + "z",
		"combining":        "é ä",
		"altscreen":        "primary\x1b[?1049h\x1b[31malt\x1b[0m",
		"altscreen return": "primary\x1b[?1049haltstuff\x1b[?1049l",
		"cursor hide":      "text\x1b[?25l",
		"decawm off":       "\x1b[?7l" + strings.Repeat("q", 45),
		"osc title":        "\x1b]0;a title\x07after",
		"charset box":      "\x1b(0lqk\x1b(B done",
		"charset shift":    "\x1b)0plain\x0eqqq\x0fplain",
		"invalid utf8":     "\xe6\xbc0",
		"esc restart":      "\x1b\x1b0",
		"esc intermediate": "\x1b 000",
		"decaln":           "\x1b#8",
	}
	for name, stream := range cases {
		t.Run(strings.ReplaceAll(name, " ", "_"), func(t *testing.T) {
			oracle(t, name, stream)
		})
	}
}

// explicit zero params on count commands: ghostty takes the 0 literally
// (no-op), xterm and we coerce to 1. Verified agreeing: 0C/0B. Diverging:
// 0a/0e/0I; assume the rest of the count family diverges too.
var zeroAlias = regexp.MustCompile(`\x1b\[[0;]*[aeIZjkSTXPLM@b]`)
var multiParam = regexp.MustCompile(`\x1b\[[0-9;]*;[0-9;]*[^0-9;mHfr\x1b]`)

// empty SGR params: xterm reads them as 0 (reset) — we match; ghostty drops
// them. "\x1b[1;m" keeps bold there, resets here.
var sgrEmpty = regexp.MustCompile(`\x1b\[[;:]|\x1b\[[0-9;:]*(;;|;m|::|:m|;:|:;)`)

// a charset designation other than ASCII (ESC ( B)
var altCharset = regexp.MustCompile(`\x1b[()*+][^B]`)

// ED/EL with out-of-range params: we ignore (xterm), ghostty wraps the
// value mod 10 through its enum — quirk, not semantics
var badErase = regexp.MustCompile(`\x1b\[[0-9]{2,}[JK]|\x1b\[[4-9][JK]`)

// three or more params on two-param commands (CUP/DECSTBM): xterm uses the
// first two (we match), ghostty rejects the sequence.
var overArity = regexp.MustCompile(`\x1b\[[0-9]*;[0-9]*;[0-9;]*[Hfr]`)

// FuzzGhosttyOracle explores the sequence space beyond the table. Run
// manually: go test -tags ghostty ./internal/host/ -fuzz FuzzGhosttyOracle
func FuzzGhosttyOracle(f *testing.F) {
	f.Add("hello\x1b[3;5H\x1b[41mworld")
	f.Add("\x1b[2J\x1b[1;1H" + strings.Repeat("漢x", 30))
	f.Add("\x1b[38;5;100m\x1b[4mtext\x1b[0m\r\n\x1b[K")
	f.Fuzz(func(t *testing.T, stream string) {
		// Two known-divergent-by-design input classes are skipped so the
		// fuzzer spends its budget where divergence means an emulation bug:
		// unhandled C0 controls (ghostty stores the raw codepoint in the
		// grid; we and xterm drop them) and invalid UTF-8 (ghostty executes
		// raw 8-bit C1 controls; we and UTF-8-mode xterm substitute U+FFFD —
		// the maximal-subpart case both agree on is pinned in the table).
		if !utf8.ValidString(stream) {
			t.Skip()
		}
		// C1 controls as UTF-8 codepoints (U+0080-U+009F): ghostty stores
		// the raw codepoint in the grid, we drop it, xterm would EXECUTE it
		// — three-way divergence, parser-rework backlog. And codepoints our
		// Go version's Unicode tables don't know yet (ghostty ships newer
		// data): classification skew, not emulation.
		for _, r := range stream {
			if r >= 0x80 && r <= 0x9f {
				t.Skip()
			}
			if r > 0xFF && !unicode.IsGraphic(r) && !unicode.IsControl(r) {
				t.Skip()
			}
			// astral combining marks: Unicode versions disagree on which
			// medial signs are spacing (U+1171E is Mn to Go, width 1 to
			// ghostty) — width-data skew, not emulation
			if r >= 0x10000 && unicode.In(r, unicode.Mn, unicode.Me) {
				t.Skip()
			}
		}
		for i := 0; i < len(stream); i++ {
			c := stream[i]
			if (c < 0x20 || c == 0x7f) && !strings.ContainsRune("\n\r\t\b\x0e\x0f\x1b", rune(c)) {
				t.Skip()
			}
		}
		// (the pending-wrap interaction matrix is skipped after the run,
		// via WrapOps — see below)
		// Candidate GHOSTTY bug (2026-07-22, worth an upstream report once
		// we engage): CSI 0C/0B coerce the 0 to 1 (xterm-style) but the
		// aliases CSI 0a (HPR) / 0e (VPR) move zero. We match xterm on all
		// four; skip the shape.
		if zeroAlias.MatchString(stream) {
			t.Skip()
		}
		// Param-edge adjudications: extra/empty params on single-param CSI
		// commands ("CSI ;1B") — xterm takes the first param (we match),
		// ghostty discards the sequence. Skip multi-param CSIs except the
		// legitimately multi-param finals (SGR, CUP, DECSTBM).
		if multiParam.MatchString(stream) {
			t.Skip()
		}
		if sgrEmpty.MatchString(stream) {
			t.Skip()
		}
		if overArity.MatchString(stream) {
			t.Skip()
		}
		if badErase.MatchString(stream) {
			t.Skip()
		}
		// A non-ASCII-charset designation (anything but ESC ( B) mixed with
		// UTF-8 text: ghostty drops the UTF-8, xterm passes it through (we
		// match xterm). No real program mixes these.
		if altCharset.MatchString(stream) {
			for _, r := range stream {
				if r > 0x7f {
					t.Skip()
				}
			}
		}
		// Unterminated OSC/DCS/SOS/PM/APC at end of stream: we carry it for
		// the next Write (correct against a live pty), ghostty processes
		// byte-wise — an artifact of the oracle's single-Write model.
		for i := 0; i+1 < len(stream); i++ {
			if stream[i] == 0x1b && strings.IndexByte("]PX^_", stream[i+1]) >= 0 {
				rest := stream[i+2:]
				if !strings.Contains(rest, "\x07") && !strings.Contains(rest, "\x1b\\") {
					t.Skip()
				}
			}
		}
		// Third known-divergent class: a C0 control or non-ASCII byte INSIDE
		// an escape sequence. The VT state machine executes C0s and stays in
		// the sequence, and its byte-oriented escape states predate UTF-8
		// (ghostty ignores high bytes and keeps waiting for an ASCII final;
		// we drop ESC plus one rune and resume). Fixing the C0 half means
		// the parser-rework arc (NOTES.md); the UTF-8 half is genuinely
		// implementation-defined. Skip streams with either between an ESC
		// and its final.
		for i := 0; i < len(stream); i++ {
			if stream[i] != 0x1b {
				continue
			}
			j := i + 1
			// the intro byte ('[' CSI, ']' OSC, 'P'/'X'/'^'/'_' strings) is
			// part of the sequence, not its final
			if j < len(stream) && strings.IndexByte("[]PX^_", stream[j]) >= 0 {
				j++
			}
			for ; j < len(stream); j++ {
				c := stream[j]
				if c == 0x1b || (c >= 0x40 && c <= 0x7e) {
					break // restart or a plausible final — window closed
				}
				if c < 0x20 || c >= 0x80 {
					t.Skip()
				}
			}
		}
		const cols, rows = 40, 10
		ours := newTerminal(cols, rows)
		theirs := newGhosttyTerminal(cols, rows)
		defer theirs.(*ghosttyTerminal).free()
		_, _ = ours.Write([]byte(stream))
		_, _ = theirs.Write([]byte(stream))
		// The pending-wrap interaction matrix: how each op behaves while the
		// cursor holds a deferred wrap genuinely differs per terminal
		// (ghostty resolves it as a newline for tabs, clears it for LF,
		// erases through it for ECH…) — micro-semantics no real program
		// depends on. Detected by SIMULATION, not stream shape: our emulator
		// counts ops that arrived in that state.
		if ours.(vtTerminal).Emulator.WrapOps() > 0 {
			t.Skip()
		}
		a := gridOf(ours, cols, rows)
		b := gridOf(theirs, cols, rows)
		for y := range a {
			if a[y] != b[y] {
				t.Errorf("row %d diverges\n  vt:      %s\n  ghostty: %s", y, a[y], b[y])
			}
		}
	})
}

// --- benchmarks ---

func BenchmarkGhosttyPipeAscii(b *testing.B) {
	benchPipeWith(b, "the quick brown fox jumps over the lazy dog while carrying a load\n", newGhosttyTerminal)
}

func BenchmarkGhosttyPipeUnicode(b *testing.B) {
	benchPipeWith(b, "こんにちは世界 Привет мир مرحبا بالعالم 你好世界 Γειά σου Κόσμε हैलो वर्ल्ड héllo wörld\n", newGhosttyTerminal)
}

// benchWriteOnly isolates the parse path: same bytes, no pty, no render loop.
// The purest form of the cgo-per-Write question.
func benchWriteOnly(b *testing.B, mk func(cols, rows int) Terminal, line string) {
	term := mk(405, 113)
	data := []byte(strings.Repeat(line, (1<<20)/len(line)))
	b.SetBytes(int64(len(data)))
	b.ResetTimer()
	for b.Loop() {
		_, _ = term.Write(data)
	}
}

func BenchmarkWriteOnlyVtAscii(b *testing.B) {
	benchWriteOnly(b, newTerminal, "the quick brown fox jumps over the lazy dog while carrying a load\n")
}

func BenchmarkWriteOnlyGhosttyAscii(b *testing.B) {
	benchWriteOnly(b, newGhosttyTerminal, "the quick brown fox jumps over the lazy dog while carrying a load\n")
}

func BenchmarkWriteOnlyVtUnicode(b *testing.B) {
	benchWriteOnly(b, newTerminal, "こんにちは世界 Привет мир مرحبا بالعالم 你好世界 héllo wörld\n")
}

func BenchmarkWriteOnlyGhosttyUnicode(b *testing.B) {
	benchWriteOnly(b, newGhosttyTerminal, "こんにちは世界 Привет мир مرحبا بالعالم 你好世界 héllo wörld\n")
}

// benchRenderSnapshot isolates the read path: a full-screen render into a
// fresh surface — the per-cell FFI cost question for ghostty, the diff cost
// for ours.
func benchRenderSnapshot(b *testing.B, mk func(cols, rows int) Terminal) {
	term := mk(405, 113)
	var fill strings.Builder
	for i := 0; i < 113; i++ {
		fmt.Fprintf(&fill, "\x1b[%d;1H\x1b[3%dmrow %d filled with text %s", i+1, i%8, i, strings.Repeat("x", 360))
	}
	_, _ = term.Write([]byte(fill.String()))
	b.ResetTimer()
	for b.Loop() {
		f := term.Render(term.NewSurface())
		if f.Empty() {
			b.Fatal("empty frame")
		}
	}
}

func BenchmarkRenderSnapshotVt(b *testing.B) {
	benchRenderSnapshot(b, newTerminal)
}

func BenchmarkRenderSnapshotGhostty(b *testing.B) {
	benchRenderSnapshot(b, newGhosttyTerminal)
}
