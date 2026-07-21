// Throughput of the Go emulator: how fast x/vt parses a realistic firehose.
// Grounds the "coalesce on the host, off the browser thread" claim — if Go
// parses at tens+ of MB/s, parse is never the bottleneck (a busy build log is
// single-digit MB/s of output).
//
//	go run ./spike/bench-vt spike/corpus/nvim-edit.raw
package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/charmbracelet/x/vt"
)

func main() {
	raw, err := os.ReadFile(os.Args[1])
	if err != nil {
		panic(err)
	}
	metaRaw, _ := os.ReadFile(strings.TrimSuffix(os.Args[1], filepath.Ext(os.Args[1])) + ".meta.json")
	var m struct{ Cols, Rows int }
	_ = json.Unmarshal(metaRaw, &m)
	if m.Cols == 0 {
		m.Cols, m.Rows = 120, 40
	}

	const target = 40 << 20 // ~40 MiB of realistic heavy output
	reps := target/len(raw) + 1
	big := bytes.Repeat(raw, reps)

	e := vt.NewEmulator(m.Cols, m.Rows)
	drained := make(chan struct{})
	go func() { _, _ = io.Copy(io.Discard, e); close(drained) }() // queries would deadlock otherwise

	t0 := time.Now()
	_, err = e.Write(big)
	if err != nil {
		panic(err)
	}
	dt := time.Since(t0)
	_ = e.Close()
	<-drained

	mb := float64(len(big)) / (1 << 20)
	fmt.Printf("x/vt   : %.0f MiB in %6.1f ms = %5.0f MiB/s  (%dx%d, %d reps of %s)\n",
		mb, float64(dt.Microseconds())/1000, mb/dt.Seconds(), m.Cols, m.Rows, reps, filepath.Base(os.Args[1]))
}
