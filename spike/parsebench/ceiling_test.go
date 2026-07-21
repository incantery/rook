package parsebench

import (
	"bytes"
	"testing"

	"github.com/charmbracelet/x/ansi"
)

// ~16 MiB of plain ASCII prose, 80-col lines, no escape sequences — the best
// case for a bulk-run parser and the closest thing to `cat bigtextfile`. Shows
// the ceiling when the fast path is all that runs.
var plaintext = makePlaintext()

func makePlaintext() []byte {
	line := []byte("the quick brown fox jumps over the lazy dog while carrying a heavy load ok\n")
	out := make([]byte, 0, 16<<20)
	for len(out) < 16<<20 {
		out = append(out, line...)
	}
	return out
}

// BenchmarkMemFloor: the speed of light — just SCAN the bytes (Go's IndexByte
// is SIMD). You cannot parse faster than you can read, so this is the ceiling
// every parser is measured against.
func BenchmarkMemFloor(b *testing.B) {
	b.SetBytes(int64(len(corpus)))
	for range b.N {
		i, sink := 0, 0
		for i < len(corpus) {
			j := bytes.IndexByte(corpus[i:], 0x1b)
			if j < 0 {
				sink += len(corpus) - i
				break
			}
			sink += j
			i += j + 1
		}
		_ = sink
	}
}

// --- SGR-heavy content (git-graph) ---

func BenchmarkBulk(b *testing.B) {
	b.SetBytes(int64(len(corpus)))
	b.ReportAllocs()
	for range b.N {
		newBulk(120, 40).Write(corpus)
	}
}

// --- plain text (best case for bulk scanning) ---

func BenchmarkAnsiText(b *testing.B) {
	p := ansi.NewParser()
	p.SetHandler(ansi.Handler{Print: func(rune) {}, Execute: func(byte) {}})
	b.SetBytes(int64(len(plaintext)))
	for range b.N {
		p.Reset()
		p.Parse(plaintext)
	}
}

func BenchmarkPackedText(b *testing.B) {
	b.SetBytes(int64(len(plaintext)))
	for range b.N {
		newPacked(120, 40).Write(plaintext)
	}
}

func BenchmarkBulkText(b *testing.B) {
	b.SetBytes(int64(len(plaintext)))
	for range b.N {
		newBulk(120, 40).Write(plaintext)
	}
}

// BenchmarkBulkParseOnly: bulk scan + escape parse, but no cell writes. The
// gap to BenchmarkBulk is the cost of writing 16-byte cells (write-bound?).
func BenchmarkBulkParseOnly(b *testing.B) {
	b.SetBytes(int64(len(corpus)))
	for range b.N {
		e := newBulk(120, 40)
		e.noWrite = true
		e.Write(corpus)
	}
}
