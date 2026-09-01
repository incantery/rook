package agents

import (
	"strings"
	"testing"

	"github.com/incantery/rook/internal/sessions"
)

// One state per channel. The sidebar and the mux rail are the same two
// lists, so they owe a reader one vocabulary: a shape per state, no
// shape doing double duty, and the word that goes with it.
func TestEveryStateHasItsOwnShapeAndWord(t *testing.T) {
	states := []sessions.AgentState{
		sessions.StateNone,
		sessions.StateDone,
		sessions.StateWorking,
		sessions.StateWaiting,
	}

	// Colour is stripped: what is left has to still tell them apart,
	// because a glass that lost its colours is the case this is for.
	shapes := map[string]sessions.AgentState{}
	for _, s := range states {
		g := bare(dot(s))
		if g == "" {
			t.Fatalf("state %v draws no glyph", s)
		}
		if prev, dup := shapes[g]; dup {
			t.Errorf("states %v and %v share the glyph %q", prev, s, g)
		}
		shapes[g] = s
	}

	want := map[sessions.AgentState]struct{ glyph, word string }{
		sessions.StateWorking: {"◐", "working"},
		sessions.StateWaiting: {"◇", "needs you"},
		sessions.StateDone:    {"✓", "done"},
		sessions.StateNone:    {"○", "idle"},
	}
	for s, w := range want {
		if got := bare(dot(s)); got != w.glyph {
			t.Errorf("dot(%v) = %q, want %q", s, got, w.glyph)
		}
		if got := bare(stateWord(s)); got != w.word {
			t.Errorf("stateWord(%v) = %q, want %q", s, got, w.word)
		}
	}
}

// bare drops the SGR runs lipgloss wraps a value in, leaving the cells.
func bare(s string) string {
	var b strings.Builder
	for i := 0; i < len(s); {
		if s[i] == 0x1b {
			for i < len(s) && s[i] != 'm' {
				i++
			}
			i++ // the 'm'
			continue
		}
		b.WriteByte(s[i])
		i++
	}
	return b.String()
}
