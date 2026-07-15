package agent

import (
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"slices"
	"strings"
	"testing"
	"time"
)

// fakeClaude writes a stand-in `claude` that echoes fixed stream-json lines
// and records the argv + stdin it was handed.
func fakeClaude(t *testing.T, stdoutLines ...string) (bin, argvFile, stdinFile string) {
	t.Helper()
	if runtime.GOOS == "windows" {
		t.Skip("shell stub is POSIX")
	}
	dir := t.TempDir()
	bin = filepath.Join(dir, "claude")
	argvFile = filepath.Join(dir, "argv")
	stdinFile = filepath.Join(dir, "stdin")
	var b strings.Builder
	b.WriteString("#!/bin/sh\n")
	b.WriteString("for a in \"$@\"; do printf '%s\\n' \"$a\" >> " + argvFile + "; done\n")
	b.WriteString("cat > " + stdinFile + "\n")
	for _, l := range stdoutLines {
		b.WriteString("printf '%s\\n' " + shQuote(l) + "\n")
	}
	if err := os.WriteFile(bin, []byte(b.String()), 0o755); err != nil {
		t.Fatal(err)
	}
	return bin, argvFile, stdinFile
}

func shQuote(s string) string { return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'" }

func toolUseLine(t *testing.T, name string, input any) string {
	t.Helper()
	raw, err := json.Marshal(map[string]any{
		"type": "assistant",
		"message": map[string]any{
			"content": []any{map[string]any{"type": "tool_use", "name": name, "input": input}},
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	return string(raw)
}

const resultLine = `{"type":"result","subtype":"success","is_error":false,"num_turns":1,` +
	`"total_cost_usd":0.0021,"usage":{"input_tokens":10,"cache_creation_input_tokens":0,` +
	`"cache_read_input_tokens":18879,"output_tokens":41}}`

func testClaude(bin string) *ClaudeCode {
	return &ClaudeCode{Bin: bin, Model: "haiku", SelfBin: "/nonexistent/rook-agent"}
}

func TestClaudeCodeJudgeReadsToolCall(t *testing.T) {
	bin, _, stdinFile := fakeClaude(t,
		toolUseLine(t, ToolName("judgment"), map[string]any{
			"action": "draft", "reply": "yes", "confidence": 0.9, "reason": "mechanical",
		}),
		resultLine)

	j, u, err := testClaude(bin).Judge(context.Background(), "SYS", "USER PROMPT")
	if err != nil {
		t.Fatalf("Judge: %v", err)
	}
	if j.Action != "draft" || j.Reply != "yes" || j.Confidence != 0.9 {
		t.Fatalf("judgment = %+v", j)
	}
	// Usage parity with the OpenAI engine: InputTokens is the whole prompt
	// (cached included), CachedTokens the cached subset, cost from the
	// envelope (no pricing-map entry needed).
	if u.InputTokens != 18889 || u.CachedTokens != 18879 || u.OutputTokens != 41 {
		t.Fatalf("usage = %+v", u)
	}
	if u.CostUSD != 0.0021 {
		t.Fatalf("cost = %v, want the envelope's 0.0021", u.CostUSD)
	}
	// The prompt rides on stdin, never argv — see TestClaudeCodePromptNeverPositional.
	if got, _ := os.ReadFile(stdinFile); string(got) != "USER PROMPT" {
		t.Fatalf("stdin = %q, want the user prompt", got)
	}
}

// A pass that produces no tool call must fail, not fabricate. The caller then
// leaves the ask surfaced draft-less — which is exactly what escalate looks
// like to the user, so the omission path is already the safe path. A
// synthesized judgment would instead put a made-up row in the ledger that
// eventually earns autonomy.
func TestClaudeCodeNoToolCallIsError(t *testing.T) {
	bin, _, _ := fakeClaude(t,
		`{"type":"assistant","message":{"content":[{"type":"text","text":"action: draft, sure"}]}}`,
		resultLine)

	_, u, err := testClaude(bin).Judge(context.Background(), "SYS", "USER")
	if err == nil {
		t.Fatal("want an error when the model answers in prose instead of calling the tool")
	}
	if !strings.Contains(err.Error(), "no ") {
		t.Fatalf("error should name the missing tool call, got %v", err)
	}
	// Spend still happened — the ledger stays honest about a wasted call.
	if u.CostUSD != 0.0021 {
		t.Fatalf("usage should survive a missing tool call, got %+v", u)
	}
}

func TestClaudeCodeRejectsBadAction(t *testing.T) {
	bin, _, _ := fakeClaude(t,
		toolUseLine(t, ToolName("judgment"), map[string]any{
			"action": "send_it", "reply": "yes", "confidence": 1, "reason": "",
		}),
		resultLine)
	if _, _, err := testClaude(bin).Judge(context.Background(), "SYS", "USER"); err == nil {
		t.Fatal("want an error for an action outside the enum")
	}
}

func TestClaudeCodeExtract(t *testing.T) {
	bin, _, _ := fakeClaude(t,
		toolUseLine(t, ToolName("extraction"), map[string]any{
			"preferences": []string{"never approve force-pushes"},
		}),
		resultLine)
	e, _, err := testClaude(bin).Extract(context.Background(), "SYS", "USER")
	if err != nil {
		t.Fatalf("Extract: %v", err)
	}
	if len(e.Preferences) != 1 || e.Preferences[0] != "never approve force-pushes" {
		t.Fatalf("preferences = %v", e.Preferences)
	}
}

// The recursion guard. claude -p writes a transcript into ~/.claude/projects
// by default — the tree agentmon watches — so without this flag the drafter
// manufactures the very events rook-host reduces to session state, and the
// agent starts watching itself. Verified by hand: the flag is what makes the
// difference. If this test ever fails, do not "fix" it by deleting it.
func TestClaudeCodeNeverPersistsSessions(t *testing.T) {
	args, err := testClaude("claude").args("judgment", "SYS")
	if err != nil {
		t.Fatal(err)
	}
	if !slices.Contains(args, "--no-session-persistence") {
		t.Fatalf("--no-session-persistence missing: the drafter would land in agentmon's watch tree\nargs: %v", args)
	}
}

// The classifier guard: our tool must be the only one it may call, from the
// only MCP server it may see. Unrestricted, a judgment call turns into an
// agentic run — with a shell — against an already-blocked session.
func TestClaudeCodeIsAClassifierNotAnAgent(t *testing.T) {
	args, err := testClaude("claude").args("judgment", "SYS")
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{"--strict-mcp-config", "--allowed-tools"} {
		if !slices.Contains(args, want) {
			t.Errorf("%s missing — the drafter could act, not just judge\nargs: %v", want, args)
		}
	}
	i := slices.Index(args, "--allowed-tools")
	if got := args[i+1]; got != "mcp__rook__submit_judgment" {
		t.Errorf("allowed tool = %q, want only the judgment tool", got)
	}
}

// Regression guard for a footgun that cost real debugging: --mcp-config and
// --allowed-tools are VARIADIC, so a positional prompt gets swallowed as
// another config file (the error is a baffling "MCP config file not found:
// <your prompt>"). The prompt must go over stdin — which also dodges argv
// limits on long transcripts.
func TestClaudeCodePromptNeverPositional(t *testing.T) {
	args, err := testClaude("claude").args("judgment", "SYS")
	if err != nil {
		t.Fatal(err)
	}
	// Every arg is either a flag or the value of the flag before it; nothing
	// trails the flag list.
	last := args[len(args)-1]
	if !strings.HasPrefix(args[len(args)-2], "--") {
		t.Fatalf("last arg %q does not belong to a flag — a positional would be eaten by a variadic flag", last)
	}
}

func TestClaudeCodeMCPConfigPointsAtOurselves(t *testing.T) {
	c := testClaude("claude")
	c.SelfBin = "/opt/rook/rook-agent"
	raw, err := c.mcpConfig("extraction")
	if err != nil {
		t.Fatal(err)
	}
	var cfg struct {
		MCPServers map[string]struct {
			Command string   `json:"command"`
			Args    []string `json:"args"`
		} `json:"mcpServers"`
	}
	if err := json.Unmarshal([]byte(raw), &cfg); err != nil {
		t.Fatalf("mcp config is not valid JSON: %v", err)
	}
	srv, ok := cfg.MCPServers[MCPServerName]
	if !ok {
		t.Fatalf("no %q server in %s", MCPServerName, raw)
	}
	if srv.Command != "/opt/rook/rook-agent" || !slices.Equal(srv.Args, []string{"mcp", "extraction"}) {
		t.Fatalf("server = %+v, want this binary re-executed for the extraction pass", srv)
	}
}

// The real thing: our argv against the real claude, end to end. Opt-in — it
// spends money (or subscription quota) and needs claude logged in:
//
//	ROOK_E2E_CLAUDE=1 go test ./internal/agent -run TestClaudeCodeLive -v
//
// Everything above this line stubs the CLI; this is the only test that can
// catch the CLI's own surface moving under us — a renamed flag, a changed
// stream-json shape, a variadic flag eating an argument.
func TestClaudeCodeLive(t *testing.T) {
	if os.Getenv("ROOK_E2E_CLAUDE") == "" {
		t.Skip("set ROOK_E2E_CLAUDE=1 to run against the real claude CLI")
	}
	bin, err := exec.LookPath("claude")
	if err != nil {
		t.Skipf("no claude on PATH: %v", err)
	}
	self, err := exec.LookPath("rook-agent")
	if err != nil {
		t.Skipf("no rook-agent on PATH (make agent): %v", err)
	}
	c := &ClaudeCode{Bin: bin, Model: "haiku", SelfBin: self}

	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()
	j, u, err := c.Judge(ctx,
		SystemPrompt("- yes to running tests, linters, typechecks, and builds"),
		UserPrompt(&AskContext{
			Title: "rook", CWD: "/tmp", AskSeq: 1, State: "needs_input",
			Ask: "Tests are passing. Want me to run the linter too?",
		}))
	if err != nil {
		t.Fatalf("Judge against real claude: %v", err)
	}
	t.Logf("action=%s confidence=%.2f reply=%q", j.Action, j.Confidence, j.Reply)
	t.Logf("usage: in=%d cached=%d out=%d cost=$%.5f", u.InputTokens, u.CachedTokens, u.OutputTokens, u.CostUSD)
	if j.Action != "draft" && j.Action != "escalate" {
		t.Fatalf("action = %q", j.Action)
	}
	if u.InputTokens == 0 {
		t.Error("usage did not survive the stream — the result envelope shape may have moved")
	}
}
