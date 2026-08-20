package attention

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func writeFeed(t *testing.T, lines ...string) {
	t.Helper()
	dir := t.TempDir()
	t.Setenv("XDG_STATE_HOME", dir)
	if err := os.MkdirAll(filepath.Join(dir, "rook"), 0o755); err != nil {
		t.Fatal(err)
	}
	content := strings.Join(lines, "\n") + "\n"
	if err := os.WriteFile(filepath.Join(dir, "rook", "attention.jsonl"), []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

func item(kind, session, headline string, at time.Time) string {
	return fmt.Sprintf(`{"session":%q,"kind":%q,"headline":%q,"at":%q,"source":"test"}`,
		session, kind, headline, at.Format(time.RFC3339))
}

func TestLoadSkipsStaleAndMalformed(t *testing.T) {
	now := time.Now()
	writeFeed(t,
		item("waiting", "tmux", "fresh", now),
		item("task", "tmux", "stale", now.Add(-25*time.Hour)),
		`{"broken json`,
		`{"session":"x","kind":"task","at":"2026-08-19T00:00:00Z"}`, // no headline
	)
	items := Load()
	if len(items) != 1 || items[0].Headline != "fresh" {
		t.Fatalf("Load = %+v, want only the fresh item", items)
	}
}

func TestLoadMissingFeedIsEmpty(t *testing.T) {
	t.Setenv("XDG_STATE_HOME", t.TempDir())
	if items := Load(); items != nil {
		t.Fatalf("missing feed should be empty, got %v", items)
	}
}

func TestForSessionMatchesNameAndDir(t *testing.T) {
	items := []Item{
		{Session: "rook", Kind: "waiting", Headline: "by name"},
		{Dir: "/Users/x/dev/rook", Kind: "task", Headline: "by dir"},
		{Session: "other", Kind: "task", Headline: "elsewhere"},
	}
	got := ForSession(items, "rook")
	if len(got) != 2 {
		t.Fatalf("ForSession = %+v, want name+dir matches", got)
	}
}

func TestLoadMergesAttentionDir(t *testing.T) {
	now := time.Now()
	writeFeed(t, item("waiting", "tmux", "from vera", now))
	if err := Publish("claude-abc", []Item{{Dir: "/x", Kind: "waiting", Headline: "from a hook", At: now, Source: "claude"}}); err != nil {
		t.Fatal(err)
	}
	items := Load()
	if len(items) != 2 {
		t.Fatalf("Load must merge feed + attention.d: %+v", items)
	}
	// An empty publish removes the publisher's file entirely.
	if err := Publish("claude-abc", nil); err != nil {
		t.Fatal(err)
	}
	if items := Load(); len(items) != 1 || items[0].Headline != "from vera" {
		t.Fatalf("cleared publisher must vanish: %+v", items)
	}
	if err := Publish("claude-abc", nil); err != nil {
		t.Fatal(err)
	}
}

func TestHandleClaudeHookLifecycle(t *testing.T) {
	t.Setenv("XDG_STATE_HOME", t.TempDir())
	HandleClaudeHook(strings.NewReader(`{"hook_event_name":"Notification","session_id":"abcd1234efgh","cwd":"/Users/x/dev/rook","message":"Claude needs your permission to use Bash"}`))
	items := Load()
	if len(items) != 1 || !items[0].Waiting() || items[0].Dir != "/Users/x/dev/rook" || items[0].Source != "claude" {
		t.Fatalf("notification must publish a waiting item: %+v", items)
	}
	HandleClaudeHook(strings.NewReader(`{"hook_event_name":"Stop","session_id":"abcd1234efgh"}`))
	if items := Load(); len(items) != 0 {
		t.Fatalf("stop must clear the session's item: %+v", items)
	}
	// Garbage input must be harmless — hooks run inside every turn.
	HandleClaudeHook(strings.NewReader(`not json at all`))
	HandleClaudeHook(strings.NewReader(`{"hook_event_name":"Notification"}`))
	if items := Load(); len(items) != 0 {
		t.Fatalf("garbage must publish nothing: %+v", items)
	}
}

func TestBarShowsOnlyWaiting(t *testing.T) {
	if Bar([]Item{{Kind: "task", Headline: "x"}}) != "" {
		t.Error("info items must not reach the bar")
	}
	bar := Bar([]Item{
		{Kind: "waiting", Headline: "a"},
		{Kind: "waiting", Headline: "b"},
		{Kind: "task", Headline: "c"},
	})
	if !strings.Contains(bar, "2 waiting") {
		t.Errorf("bar = %q, want 2 waiting", bar)
	}
}
