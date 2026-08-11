package main

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/incantery/rook-host/link"
	"github.com/incantery/rook-host/projection"

	"github.com/incantery/rook/plugins/internal/cmdjournal"
	"github.com/incantery/rook/plugins/internal/statusfold"
	"github.com/incantery/rook/plugins/internal/transcript"
)

// testLk builds a host with a memory journal and a pre-warmed world,
// so the paths that decide BEFORE touching the keyboard can be pinned
// without a substrate.
func testLk(t *testing.T, sessions []transcript.Session, panes []transcript.PaneActivity) *lk {
	t.Helper()
	j, err := cmdjournal.Open("", time.Hour, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	return &lk{
		journal: j,
		names:   []string{"claude", "node"},
		world:   world{sessions: sessions, panes: panes, at: time.Now()},
	}
}

// The at-most-once promise, seen from the RPC side: a journaled key
// comes back Duplicate — success, loudly — and never reaches a pane.
func TestAnswerDuplicateWinsBeforeTheKeyboard(t *testing.T) {
	sess := transcript.Session{ID: "s1", Cwd: "/w/a", State: transcript.StateNeedsYou, LastText: "which?"}
	h := testLk(t, []transcript.Session{sess}, nil)
	askID := statusfold.AskID(sess)
	h.journal.MarkDelivered(askID)

	out := h.Answer(context.Background(), projection.Answer{AskID: askID, Text: "the first"})
	if out.Disposition != link.Duplicate {
		t.Errorf("redelivery got %v (%s), want Duplicate", out.Disposition, out.Note)
	}
}

// The both-settle rule: an ask the sessions no longer carry was
// answered at the desk or superseded — the answer is Dropped with the
// reason on the record, never typed.
func TestAnswerStaleAskIsDroppedWithANote(t *testing.T) {
	sess := transcript.Session{ID: "s1", Cwd: "/w/a", State: transcript.StateNeedsYou, LastText: "moved on"}
	h := testLk(t, []transcript.Session{sess}, nil)

	out := h.Answer(context.Background(), projection.Answer{AskID: "s1:deadbeef", Text: "too late"})
	if out.Disposition != link.Dropped || out.Note == "" {
		t.Errorf("stale answer got %v (%q), want Dropped with a reason", out.Disposition, out.Note)
	}
}

// A journaled command key is one command no matter which rail carried
// it — and an unknown kind is refused honestly.
func TestExecuteDuplicateAndUnknownKind(t *testing.T) {
	h := testLk(t, nil, nil)
	h.journal.MarkDelivered("cmd:compact:s9")
	out := h.Execute(context.Background(), projection.Command{ID: "compact:s9", Kind: "compact", SessionID: "s9"})
	if out.Disposition != link.Duplicate {
		t.Errorf("journaled command got %v, want Duplicate", out.Disposition)
	}

	out = h.Execute(context.Background(), projection.Command{ID: "warp:x", Kind: "warp"})
	if out.Disposition != link.Dropped || !strings.Contains(out.Note, "warp") {
		t.Errorf("unknown kind got %v (%q), want Dropped naming the kind", out.Disposition, out.Note)
	}
}

// A compact for a session that is gone, and a resume with an id that
// could reach a shell: both refused before anything is typed.
func TestExecuteGuardsBeforeTheKeyboard(t *testing.T) {
	evil := transcript.Session{ID: "x;rm -rf", Cwd: "/w/a", State: transcript.StateIdle}
	h := testLk(t, []transcript.Session{evil}, nil)

	out := h.Execute(context.Background(), projection.Command{ID: "compact:gone", Kind: "compact", SessionID: "gone"})
	if out.Disposition != link.Dropped {
		t.Errorf("compact for a gone session: %v, want Dropped", out.Disposition)
	}

	out = h.Execute(context.Background(), projection.Command{ID: "resume:x;rm -rf", Kind: "resume", SessionID: "x;rm -rf"})
	if out.Disposition != link.Dropped || !strings.Contains(out.Note, "shell-safe") {
		t.Errorf("unsafe resume id: %v (%q), want a shell-safe refusal", out.Disposition, out.Note)
	}
}

func TestShellSafeID(t *testing.T) {
	for id, want := range map[string]bool{
		"5c9d3a2e-1b.ok_ID": true,
		"":                  false,
		"a b":               false,
		"a'b":               false,
		"a$(x)":             false,
	} {
		if got := shellSafeID(id); got != want {
			t.Errorf("shellSafeID(%q) = %v, want %v", id, got, want)
		}
	}
}

// The neutral fold crosses to the projection 1:1 — same story the
// cloud bridge tells its wire.
func TestToProjectionIsOneToOne(t *testing.T) {
	at := time.Date(2026, 8, 9, 10, 0, 0, 0, time.UTC)
	n := statusfold.Status{
		Hostname: "boxen", RookVersion: "1.2.3",
		Workspaces: []statusfold.Workspace{{
			Name: "alpha", Branch: "main", Attention: 1,
			Agents: []statusfold.Agent{{
				ID: "s1", State: "needs_input", Title: "t", Ask: "which?", AskID: "s1:aa",
				Model: "claude", CtxPct: 42, LastEvent: at,
				Digest: &statusfold.Digest{Headline: "h", Bullets: []string{"b"}, At: at},
			}},
		}},
	}
	p := toProjection(n)
	if p.Hostname != "boxen" || p.RookVersion != "1.2.3" || len(p.Workspaces) != 1 {
		t.Fatalf("top level: %+v", p)
	}
	w := p.Workspaces[0]
	if w.Name != "alpha" || w.Branch != "main" || w.Attention != 1 || len(w.Agents) != 1 {
		t.Fatalf("workspace: %+v", w)
	}
	a := w.Agents[0]
	if a.ID != "s1" || a.State != "needs_input" || a.Ask != "which?" || a.AskID != "s1:aa" ||
		a.Model != "claude" || a.CtxPct != 42 || !a.LastEvent.Equal(at) {
		t.Errorf("agent: %+v", a)
	}
	if a.Digest == nil || a.Digest.Headline != "h" || len(a.Digest.Bullets) != 1 || !a.Digest.At.Equal(at) {
		t.Errorf("digest: %+v", a.Digest)
	}
}

// say refuses everything except an attached target — a detached or
// bystander session is pointed at resume, before anything is typed.
func TestExecuteSayNeedsAnAttachedPane(t *testing.T) {
	old := transcript.Session{ID: "old", Cwd: "/w/a", State: transcript.StateIdle, Mtime: time.Now().Add(-2 * time.Hour)}
	live := transcript.Session{ID: "live", Cwd: "/w/a", State: transcript.StateIdle, Mtime: time.Now()}
	parked := transcript.Session{ID: "parked", Cwd: "/w/b", State: transcript.StateIdle, Mtime: time.Now()}
	panes := []transcript.PaneActivity{{ID: 3, Cwd: "/w/a", Fg: "claude"}}
	h := testLk(t, []transcript.Session{old, live, parked}, panes)

	out := h.Execute(context.Background(), projection.Command{ID: "say:parked:x", Kind: "say", SessionID: "parked", Prompt: "hi"})
	if out.Disposition != link.Dropped || !strings.Contains(out.Note, "resume") {
		t.Errorf("say to a detached session: %v (%q), want Dropped pointing at resume", out.Disposition, out.Note)
	}
	out = h.Execute(context.Background(), projection.Command{ID: "say:old:x", Kind: "say", SessionID: "old", Prompt: "hi"})
	if out.Disposition != link.Dropped || !strings.Contains(out.Note, "resume") {
		t.Errorf("say to bystander history: %v (%q), want Dropped pointing at resume", out.Disposition, out.Note)
	}
	out = h.Execute(context.Background(), projection.Command{ID: "say:gone:x", Kind: "say", SessionID: "gone", Prompt: "hi"})
	if out.Disposition != link.Dropped {
		t.Errorf("say to a gone session: %v, want Dropped", out.Disposition)
	}
}
