package statusfold

import (
	"strings"
	"testing"
	"time"

	"github.com/incantery/rook/plugins/internal/digestlog"
	"github.com/incantery/rook/plugins/internal/nowfile"
	"github.com/incantery/rook/plugins/internal/transcript"
)

// The fold's one job: scanner truth in, remote vocabulary out, with
// nothing invented and nothing dropped.
func TestFoldMapsStatesAndGroupsWorkspaces(t *testing.T) {
	mt := time.Date(2026, 8, 9, 10, 0, 0, 0, time.UTC)
	sessions := []transcript.Session{
		{ID: "s1", Cwd: "/w/alpha", Branch: "main", Title: "fix the parser",
			State: transcript.StateNeedsYou, LastText: "which file?", Mtime: mt},
		{ID: "s2", Cwd: "/w/alpha", Title: "long build",
			State: transcript.StateWorking, Mtime: mt},
		{ID: "s3", Cwd: "/w/beta", Title: "quiet one",
			State: transcript.StateIdle, Mtime: mt},
		{ID: "s4", Cwd: "/w/beta", Title: "approval pending",
			State: transcript.StateBlocked, Prompt: "rm -rf ok?", Mtime: mt},
	}
	digests := map[string]digestlog.Digest{
		"s2": {Headline: "built the thing", Bullets: []string{"a", "b"}, At: mt},
	}

	st := Fold(sessions, digests, nil, "boxen", "1.2.3")
	if st.Hostname != "boxen" || st.RookVersion != "1.2.3" {
		t.Errorf("identity fields: %q %q", st.Hostname, st.RookVersion)
	}
	if len(st.Workspaces) != 2 {
		t.Fatalf("workspaces: %d, want 2", len(st.Workspaces))
	}
	// Sorted by name: alpha then beta.
	alpha, beta := st.Workspaces[0], st.Workspaces[1]
	if alpha.Name != "alpha" || beta.Name != "beta" {
		t.Fatalf("workspace order: %q, %q", alpha.Name, beta.Name)
	}
	if alpha.Branch != "main" {
		t.Errorf("branch: %q", alpha.Branch)
	}
	if alpha.Attention != 1 || beta.Attention != 1 {
		t.Errorf("attention: alpha %d beta %d, want 1 and 1", alpha.Attention, beta.Attention)
	}

	a1 := alpha.Agents[0]
	if a1.State != "needs_input" || a1.Ask != "which file?" || a1.AskID != AskID(sessions[0]) {
		t.Errorf("needs-you agent: %+v", a1)
	}
	a2 := alpha.Agents[1]
	if a2.State != "working" || a2.Ask != "" || a2.AskID != "" {
		t.Errorf("working agent leaked an ask: %+v", a2)
	}
	if a2.Digest == nil || a2.Digest.Headline != "built the thing" || len(a2.Digest.Bullets) != 2 {
		t.Errorf("digest did not ride along: %+v", a2.Digest)
	}
	if beta.Agents[0].State != "quiet" {
		t.Errorf("idle should read quiet: %q", beta.Agents[0].State)
	}
	a4 := beta.Agents[1]
	if a4.State != "needs_input" || a4.Ask != "approval? rm -rf ok?" {
		t.Errorf("blocked should read needs_input with the approval ask: %+v", a4)
	}
	if a1.Model != "claude" || a1.LastEvent != mt {
		t.Errorf("agent basics: %+v", a1)
	}
}

// A directory the scanner could not name still gets a row, under "?".
func TestFoldNamelessCwd(t *testing.T) {
	st := Fold([]transcript.Session{{ID: "x", Cwd: "/", State: transcript.StateIdle}}, nil, nil, "h", "")
	if len(st.Workspaces) != 1 || st.Workspaces[0].Name != "?" {
		t.Fatalf("got %+v", st.Workspaces)
	}
}

// The ask travels near-whole: 2000 bytes with line structure kept, cut
// on a rune boundary — a reply written against a tenth of a question
// is a reply to a different question.
func TestAskTextKeepsStructureAndBounds(t *testing.T) {
	multi := "pick one:\n 1. this\n 2. that"
	if got := AskText("  " + multi + "  "); got != multi {
		t.Errorf("structure lost: %q", got)
	}
	long := strings.Repeat("é", 1500) // 3000 bytes
	got := AskText(long)
	if len(got) > maxAsk {
		t.Errorf("ask overflows the wire: %d bytes", len(got))
	}
	if !strings.HasSuffix(got, "…") {
		t.Error("a cut ask should say it was cut")
	}
	if !strings.HasPrefix(long, strings.TrimSuffix(got, "…")) {
		t.Error("cut landed inside a rune")
	}
}

// The handle is stable for the same ask and different for a moved-on
// one — that is what makes a stale answer stale by construction.
func TestAskIDTracksTheAsk(t *testing.T) {
	s := transcript.Session{ID: "s1", State: transcript.StateNeedsYou, LastText: "which?"}
	if AskID(s) != AskID(s) {
		t.Error("same ask, different handles")
	}
	moved := s
	moved.LastText = "next question"
	if AskID(s) == AskID(moved) {
		t.Error("the ask moved on but the handle did not")
	}
	blocked := transcript.Session{ID: "s1", State: transcript.StateBlocked, Prompt: "which?"}
	if AskID(s) == AskID(blocked) {
		t.Error("an approval ask must not collide with a text ask")
	}
	if !strings.HasPrefix(AskID(s), "s1:") {
		t.Errorf("handle should name the session: %q", AskID(s))
	}
}

// The live line rides only on working sessions: a needs-input session
// keeps its ask, and a leftover now-line must not survive the turn's
// end as a stale claim about the present.
func TestNowLinesRideWorkingSessionsOnly(t *testing.T) {
	at := time.Now()
	nows := map[string]nowfile.Now{
		"w": {SessionID: "w", Line: "running the migration tests", At: at},
		"n": {SessionID: "n", Line: "stale line from before the ask", At: at},
	}
	st := Fold([]transcript.Session{
		{ID: "w", Cwd: "/repo", State: transcript.StateWorking},
		{ID: "n", Cwd: "/repo", State: transcript.StateNeedsYou, LastText: "which db?"},
	}, nil, nows, "h", "")
	var w, n *Agent
	for i := range st.Workspaces[0].Agents {
		a := &st.Workspaces[0].Agents[i]
		switch a.ID {
		case "w":
			w = a
		case "n":
			n = a
		}
	}
	if w == nil || w.Now != "running the migration tests" || !w.NowAt.Equal(at) {
		t.Fatalf("working session lost its now-line: %+v", w)
	}
	if n == nil || n.Now != "" {
		t.Fatalf("needs-input session kept a stale now-line: %+v", n)
	}
}
