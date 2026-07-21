package parsebench

import (
	"os"
	"testing"

	"github.com/charmbracelet/x/ansi"
	"github.com/charmbracelet/x/vt"
)

// The corpus, replicated to a stable size. git-graph: pure SGR + text, no
// terminal queries — so x/vt needs no response-drain and the three benches see
// identical bytes. A "colored output firehose", which is the realistic heavy
// case for throughput (a build log, ls --color, a git graph).
var corpus = load("../corpus/git-graph.raw")

func load(path string) []byte {
	b, err := os.ReadFile(path)
	if err != nil {
		panic(err)
	}
	out := make([]byte, 0, 16<<20)
	for len(out) < 16<<20 {
		out = append(out, b...)
	}
	return out
}

// BenchmarkAnsiParse: the x/ansi tokenizer alone, doing NOTHING with the
// events. The parser ceiling — everything above this is grid-model cost.
func BenchmarkAnsiParse(b *testing.B) {
	p := ansi.NewParser()
	p.SetHandler(ansi.Handler{
		Print:     func(rune) {},
		Execute:   func(byte) {},
		HandleCsi: func(ansi.Cmd, ansi.Params) {},
		HandleEsc: func(ansi.Cmd) {},
		HandleOsc: func(int, []byte) {},
		HandleDcs: func(ansi.Cmd, ansi.Params, []byte) {},
	})
	b.SetBytes(int64(len(corpus)))
	b.ReportAllocs()
	b.ResetTimer()
	for range b.N {
		p.Reset()
		p.Parse(corpus)
	}
}

// BenchmarkPacked: x/ansi parser + our fixed-cell preallocated grid. The
// "build our own" ceiling.
func BenchmarkPacked(b *testing.B) {
	b.SetBytes(int64(len(corpus)))
	b.ReportAllocs()
	b.ResetTimer()
	for range b.N {
		e := newPacked(120, 40)
		e.Write(corpus)
	}
}

// BenchmarkXVT: the full x/vt emulator, for the comparison. git-graph has no
// queries, so no response-drain is needed.
func BenchmarkXVT(b *testing.B) {
	b.SetBytes(int64(len(corpus)))
	b.ReportAllocs()
	b.ResetTimer()
	for range b.N {
		e := vt.NewEmulator(120, 40)
		_, _ = e.Write(corpus)
		_ = e.Close()
	}
}
