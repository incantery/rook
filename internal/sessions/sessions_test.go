package sessions

import (
	"os"
	"testing"
)

func TestParseSurvivesLineForms(t *testing.T) {
	home, _ := os.UserHomeDir()
	cases := []struct {
		line string
		kind Kind
		val  string
	}{
		{"\x1b[33m●\x1b[0m rook", KindSession, "rook"},
		{"● tmux", KindSession, "tmux"},
		{"\x1b[90m○\x1b[0m ~/dev/rook", KindDir, "~/dev/rook"},
		{"~/dev/rook", KindDir, "~/dev/rook"},
		{"/tmp/x", KindDir, "/tmp/x"},
		{"bare-name", KindSession, "bare-name"},
	}
	for _, c := range cases {
		got := Parse(c.line)
		if got.Kind != c.kind || got.Value != c.val {
			t.Errorf("Parse(%q) = %v %q, want %v %q", c.line, got.Kind, got.Value, c.kind, c.val)
		}
	}
	if expand("~/x") != home+"/x" {
		t.Errorf("expand(~/x) = %q", expand("~/x"))
	}
}

func TestRowLineRoundTrips(t *testing.T) {
	for _, r := range []Row{{KindSession, "rook"}, {KindDir, "~/dev/rook"}} {
		if got := Parse(r.Line()); got != r {
			t.Errorf("Parse(Line(%v)) = %v", r, got)
		}
	}
}

func TestMergeDedupesDirsBehindSessions(t *testing.T) {
	home, _ := os.UserHomeDir()
	rows := Merge(
		[]string{"rook", "tmux"},
		[]string{home + "/dev/rook", home + "/other/project"},
	)
	// dev/rook would recreate session "rook": only the session row and
	// the novel dir must survive.
	if len(rows) != 3 {
		t.Fatalf("got %d rows: %v", len(rows), rows)
	}
	if rows[2].Kind != KindDir || rows[2].Value != "~/other/project" {
		t.Errorf("dir row = %v, want contracted ~/other/project", rows[2])
	}
}
