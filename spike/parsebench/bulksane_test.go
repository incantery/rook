package parsebench

import (
	"os"
	"strings"
	"testing"
)

// bulk must render the SAME grid as packed on real content — a fast parser
// that disagrees is a different (wrong) parser, not a faster one.
func TestBulkMatchesPacked(t *testing.T) {
	raw, err := os.ReadFile("../corpus/git-graph.raw")
	if err != nil {
		t.Fatal(err)
	}
	p := newPacked(120, 40)
	p.Write(raw)
	bk := newBulk(120, 40)
	bk.Write(raw)

	diffs := 0
	for y := 0; y < 40; y++ {
		for x := 0; x < 120; x++ {
			pc, bc := p.grid[p.idx(x, y)], bk.grid[bk.idx(x, y)]
			if pc.r != bc.r || pc.fg != bc.fg || pc.bg != bc.bg || pc.attr != bc.attr {
				diffs++
			}
		}
	}
	if diffs > 0 {
		t.Errorf("bulk and packed disagree on %d/%d cells", diffs, 40*120)
	}
	// and it's not empty
	var sb strings.Builder
	for i := range bk.grid {
		if bk.grid[i].r != 0 {
			sb.WriteRune(bk.grid[i].r)
		}
	}
	if !strings.Contains(sb.String(), "Merge") {
		t.Error("bulk grid missing expected content")
	}
}
