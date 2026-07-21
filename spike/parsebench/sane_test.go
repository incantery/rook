package parsebench

import (
	"os"
	"strings"
	"testing"
)

// A fast emulator that renders garbage is worthless. Feed the real git-graph
// capture (once, not replicated) and confirm the grid holds recognizable
// content — graph glyphs and commit-subject words that are actually in it.
func TestPackedProducesSaneGrid(t *testing.T) {
	raw, err := os.ReadFile("../corpus/git-graph.raw")
	if err != nil {
		t.Fatal(err)
	}
	e := newPacked(120, 40)
	e.Write(raw)

	var sb strings.Builder
	for y := 0; y < e.h; y++ {
		for x := 0; x < e.w; x++ {
			c := e.grid[e.idx(x, y)]
			if c.r == 0 {
				sb.WriteByte(' ')
			} else {
				sb.WriteRune(c.r)
			}
		}
		sb.WriteByte('\n')
	}
	screen := sb.String()
	if nonSpace := len(strings.ReplaceAll(strings.ReplaceAll(screen, " ", ""), "\n", "")); nonSpace < 500 {
		t.Errorf("grid nearly empty (%d non-space cells) — content dropped", nonSpace)
	}
	for _, want := range []string{"*", "|", "Merge", "monitor"} {
		if !strings.Contains(screen, want) {
			t.Errorf("grid missing %q — parser/grid may be dropping content", want)
		}
	}
}
