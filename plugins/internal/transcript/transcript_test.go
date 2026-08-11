package transcript

import (
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// The clock every fixture is written against. Tests pass `now` explicitly;
// only mtime (via os.Chtimes) and these timestamps matter.
var t0 = time.Date(2026, 8, 3, 12, 0, 0, 0, time.UTC)

func ts(d time.Duration) string { return t0.Add(d).Format("2006-01-02T15:04:05.000Z") }

// Transcript line builders — the shapes observed in real Claude Code
// transcripts, reduced to what the parser reads.

func prompt(at time.Duration, text string) string {
	return fmt.Sprintf(`{"type":"user","timestamp":"%s","cwd":"/home/u/proj","gitBranch":"main","message":{"role":"user","content":%q}}`, ts(at), text)
}

func toolUse(at time.Duration) string {
	return fmt.Sprintf(`{"type":"assistant","timestamp":"%s","cwd":"/home/u/proj","gitBranch":"main","message":{"role":"assistant","stop_reason":"tool_use","content":[{"type":"tool_use","id":"tu1"}]}}`, ts(at))
}

func toolResult(at time.Duration) string {
	return fmt.Sprintf(`{"type":"user","timestamp":"%s","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tu1"}]}}`, ts(at))
}

func endTurn(at time.Duration, text string) string {
	return fmt.Sprintf(`{"type":"assistant","timestamp":"%s","message":{"role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":%q}]}}`, ts(at), text)
}

func meta(title, lastPrompt, permMode string) []string {
	return []string{
		fmt.Sprintf(`{"type":"ai-title","aiTitle":%q}`, title),
		fmt.Sprintf(`{"type":"last-prompt","lastPrompt":%q}`, lastPrompt),
		fmt.Sprintf(`{"type":"permission-mode","permissionMode":%q}`, permMode),
	}
}

// writeSession writes one transcript and stamps its mtime.
func writeSession(t *testing.T, dir, proj, id string, mtimeAt time.Duration, lines ...string) string {
	t.Helper()
	d := filepath.Join(dir, proj)
	if err := os.MkdirAll(d, 0o755); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(d, id+".jsonl")
	body := ""
	for _, l := range lines {
		body += l + "\n"
	}
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	mt := t0.Add(mtimeAt)
	if err := os.Chtimes(path, mt, mt); err != nil {
		t.Fatal(err)
	}
	return path
}

func testScanner(dir string) *Scanner {
	return &Scanner{Dir: dir, Window: 48 * time.Hour, Idle: 10 * time.Minute, Quiet: 60 * time.Second, Max: 20}
}

// one scans a directory holding a single session and returns it.
func one(t *testing.T, sc *Scanner, now time.Time) Session {
	t.Helper()
	got := sc.Scan(now)
	if len(got) != 1 {
		t.Fatalf("want 1 session, got %d", len(got))
	}
	return got[0]
}

func TestEndTurnNeedsYou(t *testing.T) {
	dir := t.TempDir()
	lines := append([]string{prompt(0, "do the thing"), toolUse(10 * time.Second), toolResult(15 * time.Second)},
		endTurn(90*time.Second, "done: the thing is did"))
	lines = append(lines, meta("Doing the thing", "do the thing", "default")...)
	writeSession(t, dir, "-home-u-proj", "aaaa1111", 90*time.Second, lines...)

	s := one(t, testScanner(dir), t0.Add(2*time.Minute))
	if s.State != StateNeedsYou {
		t.Fatalf("state = %q, want %q", s.State, StateNeedsYou)
	}
	if s.TurnDur != 90*time.Second {
		t.Errorf("TurnDur = %v, want 90s", s.TurnDur)
	}
	if s.Title != "Doing the thing" || s.Prompt != "do the thing" {
		t.Errorf("title/prompt = %q/%q", s.Title, s.Prompt)
	}
	if s.LastText != "done: the thing is did" {
		t.Errorf("LastText = %q", s.LastText)
	}
	if s.Cwd != "/home/u/proj" || s.Branch != "main" {
		t.Errorf("cwd/branch = %q/%q", s.Cwd, s.Branch)
	}
}

func TestPendingToolFreshIsWorking(t *testing.T) {
	dir := t.TempDir()
	writeSession(t, dir, "p", "bbbb2222", 0,
		prompt(-10*time.Second, "go"), toolUse(0))
	s := one(t, testScanner(dir), t0.Add(5*time.Second))
	if s.State != StateWorking {
		t.Fatalf("state = %q, want %q", s.State, StateWorking)
	}
}

func TestPendingToolQuietIsBlocked(t *testing.T) {
	dir := t.TempDir()
	lines := append([]string{prompt(-10*time.Second, "go"), toolUse(0)}, meta("T", "go", "default")...)
	writeSession(t, dir, "p", "cccc3333", 0, lines...)
	s := one(t, testScanner(dir), t0.Add(2*time.Minute))
	if s.State != StateBlocked {
		t.Fatalf("state = %q, want %q", s.State, StateBlocked)
	}
}

func TestPendingToolQuietAutoStaysWorking(t *testing.T) {
	dir := t.TempDir()
	lines := append([]string{prompt(-10*time.Second, "go"), toolUse(0)}, meta("T", "go", "auto")...)
	writeSession(t, dir, "p", "dddd4444", 0, lines...)
	s := one(t, testScanner(dir), t0.Add(2*time.Minute))
	if s.State != StateWorking {
		t.Fatalf("state = %q, want %q", s.State, StateWorking)
	}
}

func TestQuietLongIsIdle(t *testing.T) {
	dir := t.TempDir()
	writeSession(t, dir, "p", "eeee5555", 0, endTurn(0, "bye"))
	s := one(t, testScanner(dir), t0.Add(30*time.Minute))
	if s.State != StateIdle {
		t.Fatalf("state = %q, want %q", s.State, StateIdle)
	}
}

func TestInterruptNeedsYouWithoutBanner(t *testing.T) {
	dir := t.TempDir()
	writeSession(t, dir, "p", "ffff6666", time.Minute,
		prompt(0, "go"), toolUse(30*time.Second),
		prompt(time.Minute, "[Request interrupted by user]"))
	s := one(t, testScanner(dir), t0.Add(90*time.Second))
	if s.State != StateNeedsYou {
		t.Fatalf("state = %q, want %q", s.State, StateNeedsYou)
	}
	if s.TurnDur != 0 {
		t.Errorf("TurnDur = %v, want 0 (an interrupt is the human's own hand)", s.TurnDur)
	}
}

func TestSidechainDoesNotEndTheTurn(t *testing.T) {
	dir := t.TempDir()
	side := fmt.Sprintf(`{"type":"assistant","timestamp":"%s","isSidechain":true,"message":{"role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"subagent done"}]}}`, ts(20*time.Second))
	writeSession(t, dir, "p", "abab7777", 20*time.Second,
		prompt(0, "go"), toolUse(10*time.Second), side)
	s := one(t, testScanner(dir), t0.Add(25*time.Second))
	if s.State != StateWorking {
		t.Fatalf("state = %q, want %q (a sidechain's end_turn is not the session's)", s.State, StateWorking)
	}
	if s.LastText == "subagent done" {
		t.Errorf("LastText leaked from a sidechain")
	}
}

func TestScanOrderWindowAndFallbackTitle(t *testing.T) {
	dir := t.TempDir()
	// idle but recent
	writeSession(t, dir, "-home-u-old", "11111111-aaaa", -time.Hour, endTurn(-time.Hour, "old news"))
	// working, fresh — no meta lines, so the title falls back
	writeSession(t, dir, "p", "22222222-bbbb", 0, prompt(-5*time.Second, "go"), toolUse(0))
	// needs you
	lines := append([]string{prompt(-2*time.Minute, "x"), endTurn(-time.Minute, "ready")}, meta("Ready one", "x", "default")...)
	writeSession(t, dir, "p", "33333333-cccc", -time.Minute, lines...)
	// outside the window entirely
	writeSession(t, dir, "p", "44444444-dddd", -72*time.Hour, endTurn(-72*time.Hour, "ancient"))
	// a subagent transcript in a subdirectory must not be listed
	sub := filepath.Join(dir, "p", "33333333-cccc", "subagents")
	if err := os.MkdirAll(sub, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(sub, "agent-1.jsonl"), []byte(endTurn(0, "x")+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	got := testScanner(dir).Scan(t0.Add(2 * time.Second))
	if len(got) != 3 {
		t.Fatalf("want 3 sessions, got %d: %+v", len(got), got)
	}
	if got[0].ID != "33333333-cccc" || got[0].State != StateNeedsYou {
		t.Errorf("first should be the needs-you session, got %s (%s)", got[0].ID, got[0].State)
	}
	if got[1].ID != "22222222-bbbb" || got[1].State != StateWorking {
		t.Errorf("second should be the working session, got %s (%s)", got[1].ID, got[1].State)
	}
	if got[2].State != StateIdle {
		t.Errorf("third should be idle, got %s", got[2].State)
	}
	if got[1].Title != "proj · 22222222" {
		t.Errorf("fallback title = %q", got[1].Title)
	}
}

func TestPlainStringContentAndSnip(t *testing.T) {
	if got := contentText([]byte(`"hello there"`)); got != "hello there" {
		t.Errorf("string content = %q", got)
	}
	if got := contentText([]byte(`[{"type":"thinking"},{"type":"text","text":"the answer"}]`)); got != "the answer" {
		t.Errorf("block content = %q", got)
	}
	if got := Snip("héllo wörld this is long", 12); len(got) > 12 {
		t.Errorf("snip overflowed: %q (%d bytes)", got, len(got))
	}
	if got := Snip("short", 12); got != "short" {
		t.Errorf("snip mangled a short string: %q", got)
	}
	if got := Snip("a\n b\t\tc", 100); got != "a b c" {
		t.Errorf("snip should flatten whitespace: %q", got)
	}
}

func TestFuseSpinnerRateMeansWorking(t *testing.T) {
	// A pane writing at spinner rate is an agent working, whatever the
	// transcript says — blocked? and idle both promote.
	ss := []Session{
		{ID: "a", Cwd: "/w", State: StateBlocked},
		{ID: "b", Cwd: "/x", State: StateIdle},
	}
	panes := []PaneActivity{
		{Cwd: "/w", Fg: "claude", RateBps: 900, InMs: -1},
		{Cwd: "/x", Fg: "claude", RateBps: 900, InMs: -1},
	}
	Fuse(ss, panes, []string{"claude", "node"}, 200, 45*time.Second)
	for _, s := range ss {
		if s.State != StateWorking {
			t.Fatalf("%s = %q, want working (spinner rate is proof of work)", s.ID, s.State)
		}
	}
}

func TestFuseOnlyTheFreshestSessionInACwdPromotes(t *testing.T) {
	// Every past session in a repo shares its cwd. One busy pane runs
	// ONE of them — the freshest transcript — not ten hours of history.
	ss := []Session{
		{ID: "old", Cwd: "/w", State: StateIdle, Mtime: t0.Add(-10 * time.Hour)},
		{ID: "live", Cwd: "/w", State: StateIdle, Mtime: t0},
		{ID: "mid", Cwd: "/w", State: StateIdle, Mtime: t0.Add(-3 * time.Hour)},
	}
	panes := []PaneActivity{{Cwd: "/w", Fg: "claude", RateBps: 900, InMs: -1}}
	Fuse(ss, panes, []string{"claude"}, 200, 45*time.Second)
	byID := map[string]State{}
	for _, s := range ss {
		byID[s.ID] = s.State
	}
	if byID["live"] != StateWorking {
		t.Errorf("live = %q, want working", byID["live"])
	}
	if byID["old"] != StateIdle || byID["mid"] != StateIdle {
		t.Errorf("bystanders promoted: old=%q mid=%q, want idle", byID["old"], byID["mid"])
	}
}

func TestFuseCursorBlinkIsNotWork(t *testing.T) {
	// An idle TUI's cursor blink also wrote "just now" — but at a
	// hundredth the rate. Rate below the bar changes nothing.
	ss := []Session{{ID: "a", Cwd: "/w", State: StateBlocked}}
	panes := []PaneActivity{{Cwd: "/w", Fg: "claude", RateBps: 40, InMs: -1}}
	Fuse(ss, panes, []string{"claude"}, 200, 45*time.Second)
	if ss[0].State != StateBlocked {
		t.Fatalf("state = %q, want blocked? (a blink is not a spinner)", ss[0].State)
	}
}

func TestFuseEchoDoesNotCountAsWork(t *testing.T) {
	// High output right after a keystroke is the TUI echoing the human.
	ss := []Session{{ID: "a", Cwd: "/w", State: StateIdle}}
	panes := []PaneActivity{{Cwd: "/w", Fg: "claude", RateBps: 900, InMs: 500}}
	Fuse(ss, panes, []string{"claude"}, 200, 45*time.Second)
	if ss[0].State != StateIdle {
		t.Fatalf("state = %q, want idle (echo is the human's doing)", ss[0].State)
	}
	if !ss[0].Present {
		t.Errorf("typed 500ms ago — should be present")
	}
}

func TestFuseVersionedBinaryMatchesByPath(t *testing.T) {
	// Claude Code's versioned install runs as a binary literally named
	// "2.1.220" — the name says nothing, the path still says whose it is.
	ss := []Session{{ID: "a", Cwd: "/w", State: StateBlocked}}
	panes := []PaneActivity{{Cwd: "/w", Fg: "2.1.220",
		Path: "/Users/u/.local/share/claude/versions/2.1.220", RateBps: 900, InMs: -1}}
	Fuse(ss, panes, []string{"claude", "node"}, 200, 45*time.Second)
	if ss[0].State != StateWorking {
		t.Fatalf("state = %q, want working (matched by path)", ss[0].State)
	}
}

func TestFuseWrongProgramOrDirIsNoMatch(t *testing.T) {
	ss := []Session{{ID: "a", Cwd: "/w", State: StateBlocked}}
	panes := []PaneActivity{
		{Cwd: "/w", Fg: "vim", RateBps: 900, InMs: 100},            // right dir, wrong program
		{Cwd: "/elsewhere", Fg: "claude", RateBps: 900, InMs: 100}, // right program, wrong dir
	}
	Fuse(ss, panes, []string{"claude"}, 200, 45*time.Second)
	if ss[0].State != StateBlocked || ss[0].Present {
		t.Fatalf("state/present = %q/%v — an unmatched session keeps the transcript's word", ss[0].State, ss[0].Present)
	}
}

func TestFusePresenceFromRecentKeyboard(t *testing.T) {
	ss := []Session{
		{ID: "a", Cwd: "/w", State: StateNeedsYou},
		{ID: "b", Cwd: "/x", State: StateNeedsYou},
	}
	panes := []PaneActivity{
		{Cwd: "/w", Fg: "claude", InMs: 2_000},
		{Cwd: "/x", Fg: "claude", InMs: 300_000},
	}
	Fuse(ss, panes, []string{"claude"}, 200, 45*time.Second)
	byID := map[string]Session{}
	for _, s := range ss {
		byID[s.ID] = s
	}
	if !byID["a"].Present {
		t.Errorf("a: typed 2s ago, should be present")
	}
	if byID["b"].Present {
		t.Errorf("b: typed 5m ago, should not be present")
	}
}

func TestFuseResorts(t *testing.T) {
	// Fusion can promote blocked? to working, which changes panel order.
	ss := []Session{
		{ID: "was-blocked", Cwd: "/w", State: StateBlocked, Mtime: t0},
		{ID: "stays-needs", Cwd: "/n", State: StateNeedsYou, Mtime: t0},
	}
	panes := []PaneActivity{{Cwd: "/w", Fg: "claude", RateBps: 900, InMs: -1}}
	Fuse(ss, panes, []string{"claude"}, 200, 45*time.Second)
	if ss[0].ID != "stays-needs" {
		t.Fatalf("needs-you should lead after the promotion, got %s first", ss[0].ID)
	}
}

func TestComputeRates(t *testing.T) {
	prev := map[int]PaneSample{}
	p1 := []PaneActivity{{ID: 1, OutBytes: 10_000}}
	ComputeRates(prev, p1, t0)
	if p1[0].RateBps != 0 {
		t.Fatalf("first sighting must have rate 0, got %v", p1[0].RateBps)
	}
	p2 := []PaneActivity{{ID: 1, OutBytes: 12_000}}
	ComputeRates(prev, p2, t0.Add(2*time.Second))
	if p2[0].RateBps != 1000 {
		t.Fatalf("2000 bytes over 2s = 1000 B/s, got %v", p2[0].RateBps)
	}
}

func TestTailAlignment(t *testing.T) {
	// A file bigger than the tail window whose oldest visible line is
	// partial: the partial line must be dropped, the rest parsed.
	dir := t.TempDir()
	filler := make([]string, 0, 4000)
	for i := range 4000 {
		filler = append(filler, toolUse(time.Duration(i)*time.Millisecond))
	}
	lines := append(filler, endTurn(10*time.Second, "made it"))
	lines = append(lines, meta("Big one", "go", "default")...)
	writeSession(t, dir, "p", "55555555-eeee", 10*time.Second, lines...)

	s := one(t, testScanner(dir), t0.Add(15*time.Second))
	if s.State != StateNeedsYou || s.LastText != "made it" {
		t.Fatalf("state/text = %q/%q", s.State, s.LastText)
	}
}

// Context occupancy comes from the LAST main-chain assistant usage —
// input + cache writes + cache reads + output is what the next request
// starts from — and a zero-usage synthetic line must not erase a real
// reading. A sidechain's usage is the subagent's business, not the
// session's.
func TestCtxTokensFromLastRealUsage(t *testing.T) {
	early := fmt.Sprintf(`{"type":"assistant","timestamp":"%s","message":{"role":"assistant","model":"claude-fable-5","stop_reason":"tool_use","content":[{"type":"tool_use","id":"t1"}],"usage":{"input_tokens":2,"cache_creation_input_tokens":3000,"cache_read_input_tokens":90000,"output_tokens":500}}}`, ts(10*time.Second))
	side := fmt.Sprintf(`{"type":"assistant","timestamp":"%s","isSidechain":true,"message":{"role":"assistant","model":"claude-haiku-4-5","stop_reason":"end_turn","content":[{"type":"text","text":"sub"}],"usage":{"input_tokens":1,"cache_read_input_tokens":180000,"output_tokens":9}}}`, ts(11*time.Second))
	late := fmt.Sprintf(`{"type":"assistant","timestamp":"%s","message":{"role":"assistant","model":"claude-fable-5","stop_reason":"end_turn","content":[{"type":"text","text":"done"}],"usage":{"input_tokens":2,"cache_creation_input_tokens":2890,"cache_read_input_tokens":102969,"output_tokens":212}}}`, ts(20*time.Second))
	synthetic := fmt.Sprintf(`{"type":"assistant","timestamp":"%s","message":{"role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"note"}],"usage":{"input_tokens":0,"output_tokens":0}}}`, ts(21*time.Second))
	dir := t.TempDir()
	writeSession(t, dir, "-home-u-proj", "ctx1", 21*time.Second, early, side, late, synthetic)
	s := one(t, testScanner(dir), t0.Add(30*time.Second))
	if want := 2 + 2890 + 102969 + 212; s.CtxTokens != want {
		t.Fatalf("ctx %d want %d", s.CtxTokens, want)
	}
	if s.Model != "claude-fable-5" {
		t.Fatalf("model %q", s.Model)
	}
}

// Percent is honest arithmetic: -1 when nothing was seen, uncapped
// past 100 (a wrong window table should LOOK wrong), and the [1m]
// window when the model id says so.
func TestCtxPctAndWindow(t *testing.T) {
	if p := CtxPct(0, "claude-fable-5"); p != -1 {
		t.Fatalf("unknown must be -1, got %d", p)
	}
	// Current-generation models carry 1M windows — the old 200k default
	// here was exactly the bug that read busy sessions as 150-260%.
	if p := CtxPct(106073, "claude-fable-5"); p != 10 {
		t.Fatalf("fable pct %d want 10", p)
	}
	if p := CtxPct(500_000, "claude-fable-5"); p != 50 {
		t.Fatalf("fable pct %d want 50", p)
	}
	if p := CtxPct(300_000, "claude-sonnet-4-5[1m]"); p != 30 {
		t.Fatalf("1m window pct %d want 30", p)
	}
	if p := CtxPct(100_000, "claude-haiku-4-5"); p != 50 {
		t.Fatalf("haiku pct %d want 50", p)
	}
	if p := CtxPct(100_000, "claude-3-5-sonnet-20241022"); p != 50 {
		t.Fatalf("legacy-model pct %d want 50 (200k floor)", p)
	}
}

func TestFuseAttachmentIsTheFreshestTranscriptWithAnOpenPane(t *testing.T) {
	// An IDLE claude pane still attaches its directory's freshest
	// session — quiet-but-attached is "idle at a keyboard", and the
	// resume button must know not to appear. Bystander history in the
	// same cwd stays detached, and a cwd with no claude pane detaches
	// entirely.
	ss := []Session{
		{ID: "old", Cwd: "/w", State: StateIdle, Mtime: t0.Add(-10 * time.Hour)},
		{ID: "live", Cwd: "/w", State: StateIdle, Mtime: t0},
		{ID: "parked", Cwd: "/gone", State: StateIdle, Mtime: t0},
	}
	panes := []PaneActivity{{Cwd: "/w", Fg: "claude", RateBps: 0, InMs: -1}}
	Fuse(ss, panes, []string{"claude"}, 200, 45*time.Second)
	byID := map[string]bool{}
	for _, s := range ss {
		byID[s.ID] = s.Attached
	}
	if !byID["live"] {
		t.Error("freshest session with an open pane must be attached")
	}
	if byID["old"] {
		t.Error("bystander history must not be attached")
	}
	if byID["parked"] {
		t.Error("a session with no claude pane must not be attached")
	}
}
