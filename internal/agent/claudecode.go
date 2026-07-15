package agent

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"time"
)

// ClaudeCode drives the `claude` CLI in print mode (docs/agent.md). The bet
// is dependency arithmetic, not model quality: rook-agent already REQUIRES
// claude — agentmon reads its transcripts, and with no claude sessions there
// is nothing to draft against. So this engine adds no dependency and removes
// one (an OpenAI key, a keychain entry, a config edit). If claude is on PATH
// the drafter works; that is the whole point.
//
// Three flags are load-bearing, each for a measured reason:
//
//	--no-session-persistence  claude -p writes a transcript into
//	    ~/.claude/projects by default — the exact tree agentmon watches. The
//	    drafter would then produce events rook-host reduces to session
//	    state: the agent watching itself. Verified: without this flag a
//	    transcript appears, with it none does. Never drop it.
//	--strict-mcp-config + --allowed-tools  our tool must be the ONLY tool it
//	    may call. Unrestricted, a $0.002 classify becomes a multi-turn
//	    agentic run against a session that is already blocked. The drafter
//	    judges; approveDraft acts.
//	--output-format stream-json  carries the tool_use payload. MCP declares
//	    the shape (mcp.go), the stream carries the data.
//
// The honest cost, measured (TestClaudeCodeLive, 2026-07-14, haiku): one
// judgment ran ~80k tokens, ~15s, $0.0146 — against the OpenAI engine's ~2.5k
// tokens, ~1s, $0.0005. Roughly 30x. Almost none of that is ours: an empty
// `claude -p` on this machine already carries ~19k tokens and 31 tools before
// our prompt, then spends a ToolSearch round-trip loading our own schema.
// It is a tax on inheriting the user's global claude config — their plugins,
// their tool set, their hooks (which DO fire) — and it scales with how much
// they have installed, so it is not a number rook controls.
//
// --bare skips all of that (hooks, plugin sync, auto-memory, CLAUDE.md
// discovery) but reads auth ONLY from ANTHROPIC_API_KEY — never OAuth, never
// the keychain — so it cannot run on a subscription, which was the entire
// point. Hence Bare is a knob, not a default: on when a key exists, off when
// the subscription is the credential. Cheap and clean, or free and inherited;
// you can't have both, and the user's credential decides which.
//
// At the drafter's cadence (~35 calls/day) that's cents either way, and the
// daily cap still guards the tail. If it ever stops being cents, the lever is
// --bare, not a smaller model.
type ClaudeCode struct {
	Bin     string // `claude`, or config's coder
	Model   string // haiku unless overridden
	SelfBin string // this binary, re-executed as `rook-agent mcp <pass>`
	Bare    bool   // clean room; requires ANTHROPIC_API_KEY
}

func NewClaudeCode(bin, model string) *ClaudeCode {
	self, err := os.Executable()
	if err != nil {
		self = "rook-agent"
	}
	return &ClaudeCode{
		Bin:     bin,
		Model:   model,
		SelfBin: self,
		// --bare cannot use OAuth or the keychain, so it is only viable
		// when the user brought their own key. Auto-detect rather than ask.
		Bare: os.Getenv("ANTHROPIC_API_KEY") != "",
	}
}

func (c *ClaudeCode) Name() string { return "claude-code/" + c.Model }

// Timeout is deliberately generous, and the asymmetry is why. Overshooting
// costs a held sem slot on a call that is spending anyway, against an ask
// that is already blocked on a human — nobody is waiting on us. Undershooting
// costs the call's tokens AND records no ledger row (judge drops Usage on
// error) AND pauses the whole drafter 60s AND retries into the same wall. One
// side is free, the other compounds.
//
// So this is not "measured 15s plus a margin". 15s was one machine's config
// on one day, and the whole point of the cost note above is that the number
// scales with what the USER has installed — their plugins, their tools, their
// hooks — which makes it not rook's to predict. The budget has to cover a
// config we have never seen. Two minutes is the smallest number that stops
// pretending we know.
func (c *ClaudeCode) Timeout() time.Duration { return 2 * time.Minute }

func (c *ClaudeCode) Judge(ctx context.Context, system, user string) (*Judgment, Usage, error) {
	var j Judgment
	u, err := c.run(ctx, "judgment", system, user, &j)
	if err != nil {
		return nil, u, err
	}
	if j.Action != "draft" && j.Action != "escalate" {
		return nil, u, fmt.Errorf("claude: bad action %q", j.Action)
	}
	return &j, u, nil
}

func (c *ClaudeCode) Extract(ctx context.Context, system, user string) (*Extraction, Usage, error) {
	var e Extraction
	u, err := c.run(ctx, "extraction", system, user, &e)
	if err != nil {
		return nil, u, err
	}
	return &e, u, nil
}

// mcpConfig renders the one-server, one-tool config for a pass. We re-exec
// ourselves rather than ship a second binary: the schema the tool advertises
// and the struct we unmarshal into are then the same code.
func (c *ClaudeCode) mcpConfig(pass string) (string, error) {
	b, err := json.Marshal(map[string]any{
		"mcpServers": map[string]any{
			MCPServerName: map[string]any{
				"command": c.SelfBin,
				"args":    []string{"mcp", pass},
			},
		},
	})
	return string(b), err
}

// outputContract is the half of the prompt that is this engine's alone. The
// shared rubric (prompt.go) says what to decide, not how to answer — the
// OpenAI engine needs no "how", because json_schema makes the shape a
// property of the request. Here the shape is a tool, and a tool is only ever
// an OFFER: nothing forces the model to take it. Saying so is the difference
// between a judgment and a paragraph of prose (measured: without this the
// model reasons beautifully in text and calls nothing).
//
// Appended, never prepended: the rubric+preferences prefix stays byte-stable,
// which is what the prompt cache keys on.
func outputContract(pass string) string {
	return "\n\nHOW TO ANSWER: call the " + ToolName(pass) + " tool exactly once," +
		" as your first and only action. That tool call IS your answer — text" +
		" replies are discarded unread. You have no other tools; do not read" +
		" files, run commands, or search. Everything you need is above."
}

func (c *ClaudeCode) args(pass, system string) ([]string, error) {
	cfg, err := c.mcpConfig(pass)
	if err != nil {
		return nil, err
	}
	a := []string{
		"-p",
		"--no-session-persistence",
		"--model", c.Model,
		"--output-format", "stream-json",
		"--verbose", // stream-json in print mode requires it
		"--effort", "low",
		"--strict-mcp-config",
		"--mcp-config", cfg,
		"--allowed-tools", ToolName(pass),
		"--system-prompt", system + outputContract(pass),
	}
	if c.Bare {
		a = append(a, "--bare")
	}
	// NOTE: --mcp-config and --allowed-tools are VARIADIC — they swallow
	// following non-flag args. The prompt therefore goes over stdin, never
	// as a positional. (It also removes any argv length ceiling, which a
	// long transcript would otherwise hit.)
	return a, nil
}

// streamEvent is the subset of --output-format stream-json we read.
type streamEvent struct {
	Type    string `json:"type"`
	Message struct {
		Content []struct {
			Type  string          `json:"type"`
			Name  string          `json:"name"`
			Input json.RawMessage `json:"input"`
		} `json:"content"`
	} `json:"message"`
	// result envelope
	IsError    bool    `json:"is_error"`
	Subtype    string  `json:"subtype"`
	TotalCost  float64 `json:"total_cost_usd"`
	NumTurns   int     `json:"num_turns"`
	ResultText string  `json:"result"`
	Usage      struct {
		InputTokens     int64 `json:"input_tokens"`
		OutputTokens    int64 `json:"output_tokens"`
		CacheCreation   int64 `json:"cache_creation_input_tokens"`
		CacheReadTokens int64 `json:"cache_read_input_tokens"`
	} `json:"usage"`
}

// run executes one pass and unmarshals the tool call's arguments into out.
//
// Absence of a tool call is an error, and that is the safe direction: the
// caller leaves the ask surfaced draft-less, which is what escalate looks
// like to the user anyway. We never synthesize a judgment — a fabricated
// row would be worse than none, because the ledger is the thing that
// eventually earns autonomy.
func (c *ClaudeCode) run(ctx context.Context, pass, system, user string, out any) (Usage, error) {
	args, err := c.args(pass, system)
	if err != nil {
		return Usage{}, err
	}
	cmd := exec.CommandContext(ctx, c.Bin, args...)
	cmd.Stdin = strings.NewReader(user)
	var stdout, stderr bytes.Buffer
	cmd.Stdout, cmd.Stderr = &stdout, &stderr
	runErr := cmd.Run()

	var u Usage
	var input json.RawMessage
	want := ToolName(pass)
	// Split rather than bufio.Scanner: a stream-json line carries a whole
	// assistant message and can exceed the scanner's default token cap.
	for line := range bytes.SplitSeq(stdout.Bytes(), []byte("\n")) {
		if len(bytes.TrimSpace(line)) == 0 {
			continue
		}
		var ev streamEvent
		if json.Unmarshal(line, &ev) != nil {
			continue // non-JSON chatter on stdout is not fatal
		}
		switch ev.Type {
		case "assistant":
			for _, b := range ev.Message.Content {
				if b.Type == "tool_use" && b.Name == want {
					input = b.Input // last call wins; there should be one
				}
			}
		case "result":
			u = Usage{
				// Parity with the OpenAI engine: InputTokens is the whole
				// prompt (cached included), CachedTokens the cached subset.
				InputTokens:  ev.Usage.InputTokens + ev.Usage.CacheCreation + ev.Usage.CacheReadTokens,
				OutputTokens: ev.Usage.OutputTokens,
				CachedTokens: ev.Usage.CacheReadTokens,
				// The envelope prices itself, so no pricing map entry is
				// needed. Caveat for the ledger: on a subscription this is
				// what the call WOULD have cost on the API, not money spent.
				CostUSD: ev.TotalCost,
			}
		}
	}
	if runErr != nil {
		return u, fmt.Errorf("claude: %v: %s", runErr, truncate(strings.TrimSpace(stderr.String()), 200))
	}
	if input == nil {
		return u, fmt.Errorf("claude: no %s tool call (escalating by omission)", want)
	}
	if err := json.Unmarshal(input, out); err != nil {
		return u, fmt.Errorf("claude: bad %s payload: %w", pass, err)
	}
	return u, nil
}
