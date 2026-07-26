package transcript

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func parse(t *testing.T, line string) *Record {
	t.Helper()
	rec, err := Parse([]byte(line))
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	return rec
}

func TestAssistantToolUseKeepsID(t *testing.T) {
	// The pairing agentmon's event stream cannot express.
	rec := parse(t, `{"type":"assistant","timestamp":"2026-07-11T17:59:36.696Z","uuid":"u1","message":{"id":"msg_1","role":"assistant","model":"claude-fable-5","content":[{"type":"text","text":"Let me ask."},{"type":"tool_use","id":"toolu_abc","name":"AskUserQuestion","input":{"questions":[]}}]}}`)

	calls := rec.Message.ToolCalls()
	if len(calls) != 1 {
		t.Fatalf("ToolCalls = %d, want 1", len(calls))
	}
	if calls[0].ID != "toolu_abc" {
		t.Errorf("tool_use id = %q, want toolu_abc", calls[0].ID)
	}
	if calls[0].Name != "AskUserQuestion" {
		t.Errorf("tool_use name = %q", calls[0].Name)
	}
	if got := rec.Message.Text(); got != "Let me ask." {
		t.Errorf("Text = %q", got)
	}
	if rec.Timestamp.IsZero() {
		t.Error("timestamp not parsed")
	}
}

func TestToolResultKeepsToolUseID(t *testing.T) {
	rec := parse(t, `{"type":"user","timestamp":"2026-07-11T17:59:54.367Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_abc","content":"the answer"}]}}`)

	results := rec.Message.ToolResults()
	if len(results) != 1 {
		t.Fatalf("ToolResults = %d, want 1", len(results))
	}
	if results[0].ToolUseID != "toolu_abc" {
		t.Errorf("tool_use_id = %q, want toolu_abc", results[0].ToolUseID)
	}
	if got := results[0].ResultText(); got != "the answer" {
		t.Errorf("ResultText = %q", got)
	}
}

func TestToolResultBlockArrayContent(t *testing.T) {
	rec := parse(t, `{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":[{"type":"text","text":"one"},{"type":"text","text":"two"}]}]}}`)
	if got := rec.Message.ToolResults()[0].ResultText(); got != "one\ntwo" {
		t.Errorf("ResultText = %q, want \"one\\ntwo\"", got)
	}
}

func TestToolResultError(t *testing.T) {
	rec := parse(t, `{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"boom","is_error":true}]}}`)
	if !rec.Message.ToolResults()[0].IsError {
		t.Error("is_error not captured")
	}
}

// The whole reason this package exists: agentmon caps content at 2KB at
// parse time, which clips exactly the payload a renderer needs.
func TestToolInputIsNotTruncated(t *testing.T) {
	var opts []map[string]string
	for i := range 12 {
		opts = append(opts, map[string]string{
			"label":       fmt.Sprintf("Option %d", i),
			"description": strings.Repeat("x", 400),
		})
	}
	input, err := json.Marshal(map[string]any{
		"questions": []map[string]any{{"question": "Which?", "options": opts}},
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(input) <= 2048 {
		t.Fatalf("fixture is only %d bytes; it must exceed agentmon's 2KB cap to be a test", len(input))
	}
	line, err := json.Marshal(map[string]any{
		"type": "assistant",
		"message": map[string]any{
			"role":    "assistant",
			"content": []map[string]any{{"type": "tool_use", "id": "t1", "name": "AskUserQuestion", "input": json.RawMessage(input)}},
		},
	})
	if err != nil {
		t.Fatal(err)
	}

	got := parse(t, string(line)).Message.ToolCalls()[0].Input
	if len(got) != len(input) {
		t.Fatalf("input round-tripped %d bytes, want %d — something is capping content", len(got), len(input))
	}

	// and it must still be valid JSON, i.e. not cut mid-structure
	var back struct {
		Questions []struct {
			Options []struct{ Label string } `json:"options"`
		} `json:"questions"`
	}
	if err := json.Unmarshal(got, &back); err != nil {
		t.Fatalf("input no longer parses: %v", err)
	}
	if n := len(back.Questions[0].Options); n != 12 {
		t.Errorf("recovered %d options, want 12", n)
	}
}

func TestBareStringContentNormalisesToTextBlock(t *testing.T) {
	rec := parse(t, `{"type":"user","message":{"role":"user","content":"just typed this"}}`)
	if len(rec.Message.Content) != 1 || rec.Message.Content[0].Type != BlockText {
		t.Fatalf("content = %+v, want one text block", rec.Message.Content)
	}
	if got := rec.Message.Text(); got != "just typed this" {
		t.Errorf("Text = %q", got)
	}
}

func TestThinkingBlockKeptAndExcludedFromText(t *testing.T) {
	rec := parse(t, `{"type":"assistant","message":{"role":"assistant","content":[{"type":"thinking","thinking":"","signature":"CAIS0x"},{"type":"text","text":"said"}]}}`)
	if len(rec.Message.Content) != 2 {
		t.Fatalf("blocks = %d, want 2 (thinking must survive)", len(rec.Message.Content))
	}
	if rec.Message.Content[0].Signature != "CAIS0x" {
		t.Error("thinking signature dropped")
	}
	if got := rec.Message.Text(); got != "said" {
		t.Errorf("Text = %q, want \"said\" — thinking is reasoning, not speech", got)
	}
}

func TestUsageParsedIncludingCacheSplit(t *testing.T) {
	rec := parse(t, `{"type":"assistant","message":{"id":"m1","role":"assistant","model":"claude-fable-5","stop_reason":"end_turn","usage":{"input_tokens":10,"output_tokens":20,"cache_read_input_tokens":30,"cache_creation_input_tokens":40,"cache_creation":{"ephemeral_5m_input_tokens":25,"ephemeral_1h_input_tokens":15}},"content":[]}}`)
	want := Usage{InputTokens: 10, OutputTokens: 20, CacheReadTokens: 30, CacheCreationTokens: 40, Cache5mTokens: 25, Cache1hTokens: 15}
	if rec.Message.Usage != want {
		t.Errorf("Usage = %+v, want %+v", rec.Message.Usage, want)
	}
	if rec.Message.StopReason != "end_turn" {
		t.Errorf("StopReason = %q", rec.Message.StopReason)
	}
}

// usage.speed reaches Usage, because Cost bills on it. A line written
// before the field existed leaves it empty, which Cost reads as standard.
func TestUsageSpeedParsed(t *testing.T) {
	rec := parse(t, `{"type":"assistant","message":{"id":"m1","role":"assistant","model":"claude-opus-5","usage":{"output_tokens":20,"speed":"fast"},"content":[]}}`)
	if got := rec.Message.Usage.Speed; got != SpeedFast {
		t.Errorf("Speed = %q, want %q", got, SpeedFast)
	}

	rec = parse(t, `{"type":"assistant","message":{"id":"m1","role":"assistant","model":"claude-opus-5","usage":{"output_tokens":20},"content":[]}}`)
	if got := rec.Message.Usage.Speed; got != "" {
		t.Errorf("Speed = %q on a line with no speed field, want empty", got)
	}
}

func TestHeaderOnlyRecords(t *testing.T) {
	// Types Claude Code writes without a timestamp or a message. Not errors.
	pm := parse(t, `{"type":"permission-mode","permissionMode":"auto","sessionId":"s1"}`)
	if pm.PermissionMode != "auto" {
		t.Errorf("PermissionMode = %q", pm.PermissionMode)
	}
	if pm.SessionID != "s1" {
		t.Errorf("SessionID = %q", pm.SessionID)
	}
	if !pm.Timestamp.IsZero() {
		t.Error("timestamp should stay zero; the parser must not invent one")
	}
	if pm.Message != nil {
		t.Error("Message should be nil")
	}

	if m := parse(t, `{"type":"mode","mode":"normal"}`); m.Mode != "normal" {
		t.Errorf("Mode = %q", m.Mode)
	}
	if a := parse(t, `{"type":"ai-title","aiTitle":"Some title"}`); a.AITitle != "Some title" {
		t.Errorf("AITitle = %q", a.AITitle)
	}
}

func TestSystemTurnDuration(t *testing.T) {
	rec := parse(t, `{"type":"system","subtype":"turn_duration","durationMs":159265,"messageCount":65,"timestamp":"2026-07-15T23:08:36.813Z"}`)
	if rec.Subtype != SubtypeTurnDuration || rec.DurationMs != 159265 || rec.MessageCount != 65 {
		t.Errorf("got %+v", rec)
	}
}

func TestUnknownTypesAreNotErrors(t *testing.T) {
	// Fail open: a Claude Code release that adds a record type must degrade
	// to a hole in the render, never a dead sensor.
	rec, err := Parse([]byte(`{"type":"something-new-in-2027","weirdField":1,"uuid":"u9"}`))
	if err != nil {
		t.Fatalf("unknown record type errored: %v", err)
	}
	if rec.Type != "something-new-in-2027" || rec.UUID != "u9" {
		t.Errorf("got %+v", rec)
	}

	rec = parse(t, `{"type":"assistant","message":{"role":"assistant","content":[{"type":"future_block","q":1},{"type":"text","text":"kept"}]}}`)
	if len(rec.Message.Content) != 2 {
		t.Fatalf("blocks = %d, want 2 — unknown blocks keep their slot", len(rec.Message.Content))
	}
	if got := rec.Message.Text(); got != "kept" {
		t.Errorf("Text = %q — known blocks must survive an unknown sibling", got)
	}
}

func TestParseErrors(t *testing.T) {
	if _, err := Parse([]byte(`{"nope":1}`)); err == nil {
		t.Error("line without a type should error")
	}
	if _, err := Parse([]byte(`not json`)); err == nil {
		t.Error("malformed line should error")
	}
}

func TestBadMessageKeepsHeader(t *testing.T) {
	rec := parse(t, `{"type":"user","uuid":"u1","message":"not-an-object"}`)
	if rec.UUID != "u1" {
		t.Errorf("UUID = %q — the header is still worth having", rec.UUID)
	}
	if rec.Message != nil {
		t.Error("Message should be nil when it will not decode")
	}
}

// TestRealCorpus parses every transcript on this machine. It is the drift
// detector: agentmon's parser was written against Claude Code v2.1.200 and
// this one is written against whatever is installed now, so the histogram
// of unrecognised types is the thing worth looking at when a release lands.
// Skips anywhere the tree is absent (CI, a fresh machine).
func TestRealCorpus(t *testing.T) {
	home, err := os.UserHomeDir()
	if err != nil {
		t.Skip("no home dir")
	}
	root := filepath.Join(home, ".claude", "projects")
	if _, err := os.Stat(root); err != nil {
		t.Skip("no ~/.claude/projects on this machine")
	}
	var files []string
	filepath.WalkDir(root, func(p string, d os.DirEntry, err error) error {
		if err == nil && !d.IsDir() && strings.HasSuffix(p, ".jsonl") {
			files = append(files, p)
		}
		return nil
	})
	if len(files) == 0 {
		t.Skip("no transcripts")
	}

	types := map[string]int{}
	blocks := map[string]int{}
	var lines, malformed, toolUse, withID int
	for _, f := range files {
		data, err := os.ReadFile(f)
		if err != nil {
			continue
		}
		for ln := range strings.SplitSeq(string(data), "\n") {
			if strings.TrimSpace(ln) == "" {
				continue
			}
			lines++
			rec, err := Parse([]byte(ln))
			if err != nil {
				malformed++
				continue
			}
			types[rec.Type]++
			for _, b := range rec.Message.blocksOrNil() {
				blocks[b.Type]++
				if b.Type == BlockToolUse {
					toolUse++
					if b.ID != "" {
						withID++
					}
				}
			}
		}
	}

	t.Logf("%d files, %d lines, %d malformed", len(files), lines, malformed)
	t.Logf("record types: %v", types)
	t.Logf("block types: %v", blocks)

	if lines == 0 {
		t.Skip("no lines")
	}
	// A handful of malformed lines is plausible (a torn write on a live
	// transcript). A wave of them means the format moved.
	if rate := float64(malformed) / float64(lines); rate > 0.01 {
		t.Errorf("%.1f%% of lines failed to parse (%d/%d) — the format likely changed", rate*100, malformed, lines)
	}
	if toolUse > 0 && withID != toolUse {
		t.Errorf("%d/%d tool_use blocks carry an id — pairing depends on all of them", withID, toolUse)
	}
}

func (m *Message) blocksOrNil() []Block {
	if m == nil {
		return nil
	}
	return m.Content
}
