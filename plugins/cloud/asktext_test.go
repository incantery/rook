package main

import (
	"strings"
	"testing"
)

// The ask is the one field the phone reads in full before answering, so
// the two ways it used to get damaged are pinned here: it was cut to a
// tenth of what the wire allows, and it was flattened to a single line.
// Both regressions are invisible on the desktop panel — its rows are one
// line and short — which is exactly why they need a test.
func TestAskTextKeepsWhatThePhoneNeeds(t *testing.T) {
	// Line structure survives. A numbered list is the ask hardest to
	// answer away from the keyboard and the one flattening destroys.
	choices := "Which should I do?\n\n1. Keep the old test\n2. Delete it\n3. Rewrite it"
	if got := askText(choices); got != choices {
		t.Errorf("line structure lost:\n got %q\nwant %q", got, choices)
	}

	// Well past the old 200-byte cut, well under the wire's limit: must
	// arrive whole and without an ellipsis.
	long := strings.Repeat("a question that keeps going ", 30) // ~840 bytes
	long = strings.TrimSpace(long)
	got := askText(long)
	if got != long {
		t.Errorf("text of %d bytes was altered; got %d bytes", len(long), len(got))
	}
	if strings.Contains(got, "…") {
		t.Error("an ask inside the limit came back with an ellipsis")
	}
}

// Past the limit it still has to stop somewhere, and say that it did.
func TestAskTextClipsAtTheWireLimit(t *testing.T) {
	got := askText(strings.Repeat("x", maxCloudAsk+500))
	if len(got) > maxCloudAsk {
		t.Errorf("clipped to %d bytes, over the %d the server stores", len(got), maxCloudAsk)
	}
	if !strings.HasSuffix(got, "…") {
		t.Error("a truncated ask must say so")
	}
}

// Cutting mid-rune would put invalid UTF-8 on the wire, which presents on
// the phone as a replacement character rather than as a bug here.
func TestAskTextCutsOnRuneBoundary(t *testing.T) {
	got := askText(strings.Repeat("é", maxCloudAsk)) // 2 bytes each
	if !utf8Valid(got) {
		t.Errorf("clipped mid-rune: %q", got[len(got)-8:])
	}
}

func utf8Valid(s string) bool {
	for _, r := range s {
		if r == '�' {
			return false
		}
	}
	return true
}
