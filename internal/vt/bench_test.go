package vt

import (
	"strings"
	"testing"
)

// The performance baseline for the grid engine. These track our own emulator
// over time — a regression net for the numbers Phase 1 was gated on (D2/D3).
// Comparative benchmarks against x/vt and xterm.js live in spike/, which is
// where the "how do we stack up" question was answered; here the question is
// "did we get slower".
//
// Reading the numbers:
//   - MB/s is the ingest rate at the capture's real geometry.
//   - B/op and allocs/op are the whole story for D3: the parse must be
//     zero-allocation. BenchmarkFirehose reuses one emulator, so its allocs/op
//     is the true steady-state figure; BenchmarkParse allocates a fresh grid
//     each iteration, so its B/op is dominated by New (the two preallocated
//     buffers), not the parse.

// benchProfiles are captures with distinct content shapes, each stressing a
// different path: SGR churn, alt-screen redraw, the \r-firehose, plain wrapping,
// and the slow wide/combining unicode path.
var benchProfiles = []string{"git-graph", "nvim-edit", "redraw", "longlines", "unicode"}

// grow repeats one capture up to ~size bytes so a benchmark iteration does
// enough work to be stable.
func grow(one []byte, size int) []byte {
	data := make([]byte, 0, size)
	for len(data) < size {
		data = append(data, one...)
	}
	return data
}

// BenchmarkParse: a fresh terminal per capture — the realistic cost of
// materializing a grid from one command's output (New + Write).
func BenchmarkParse(b *testing.B) {
	for _, name := range benchProfiles {
		raw, m := loadCapture(b, name)
		b.Run(name, func(b *testing.B) {
			b.SetBytes(int64(len(raw)))
			b.ReportAllocs()
			for b.Loop() {
				e := New(m.Cols, m.Rows)
				e.Write(raw)
			}
		})
	}
}

// BenchmarkFirehose: one long-lived emulator fed continuously — the steady
// state of a session streaming output. This is the true zero-alloc proof:
// allocs/op should be ~0 for every ASCII/SGR capture (unicode allocates only
// for the rare combining/ZWJ cells).
func BenchmarkFirehose(b *testing.B) {
	for _, name := range benchProfiles {
		raw, m := loadCapture(b, name)
		data := grow(raw, 4<<20)
		b.Run(name, func(b *testing.B) {
			e := New(m.Cols, m.Rows)
			b.SetBytes(int64(len(data)))
			b.ReportAllocs()
			for b.Loop() {
				e.Write(data)
			}
		})
	}
}

// BenchmarkPlaintext: pure ASCII, no escapes — the bulk-scan ceiling, the
// closest thing to `cat bigfile`. The gap to BenchmarkFirehose/git-graph is the
// cost of the escape/SGR slow path.
func BenchmarkPlaintext(b *testing.B) {
	line := "the quick brown fox jumps over the lazy dog while carrying a load\n"
	data := grow([]byte(strings.Repeat(line, 1)), 4<<20)
	e := New(120, 40)
	b.SetBytes(int64(len(data)))
	b.ReportAllocs()
	for b.Loop() {
		e.Write(data)
	}
}

// BenchmarkScrollFirehose: many short lines into a small screen — scroll-
// dominated, so it exercises the ring's O(1) full-screen scroll on nearly every
// line feed. A regression here means the ring broke.
func BenchmarkScrollFirehose(b *testing.B) {
	var sb strings.Builder
	for i := range 100000 {
		sb.WriteString("scrolling line of moderate length number ")
		sb.WriteByte(byte('0' + i%10))
		sb.WriteString("\r\n")
	}
	data := []byte(sb.String())
	e := New(120, 40)
	b.SetBytes(int64(len(data)))
	b.ReportAllocs()
	for b.Loop() {
		e.Write(data)
	}
}

// BenchmarkNew: the cost of standing up an emulator — the two preallocated
// grids. This is the fixed per-session setup that N-session scale multiplies.
func BenchmarkNew(b *testing.B) {
	b.ReportAllocs()
	for b.Loop() {
		_ = New(120, 40)
	}
}
