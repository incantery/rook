// `rookctl mcp` — a stdio MCP server exposing rook's ask surface to Claude
// Code. One tool: `ask`, the relay-delivered question (ask.go's flow behind
// a tools/call). The rook plugin points Claude at this server and denies
// the built-in AskUserQuestion, so questions land in a rook split instead
// of the TUI — asked once, in one place.
//
// The protocol is small enough to speak directly: newline-delimited
// JSON-RPC 2.0 on stdio (the MCP stdio transport). We implement exactly
// what a tools-only server needs — initialize, tools/list, tools/call,
// ping — and answer anything else with method-not-found. Notifications
// (no id) get no reply, per JSON-RPC.
package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"

	"github.com/incantery/rook/internal/version"
)

// mcpProtocolVersion is the newest MCP revision this server knows. Clients
// negotiate down to it; Claude Code accepts anything current.
const mcpProtocolVersion = "2024-11-05"

// askToolDescription is the model-facing contract. It carries the whole
// redirection etiquette so the plugin's hook can stay a one-liner: what to
// say inline (one short pointer, not a restatement of the options), and to
// never double-ask.
const askToolDescription = "Ask the user one or more questions through rook, delivered to their PHONE via the configured relay. " +
	"This call returns IMMEDIATELY with {\"askId\":…,\"pending\":true} — it does not wait. " +
	"Use this when the user is away from the desk, or the question can wait for them; " +
	"the built-in AskUserQuestion tool is the right one when they are sitting here, since rook no longer renders a local form. " +
	"It fails with 503 when no relay is configured — fall back to AskUserQuestion then. " +
	"Before calling, write one short line telling the user you've asked in rook — e.g. \"Asked in rook →\" — and do NOT restate the question or options in text: the ask carries them. " +
	"Use the whole form: set multiSelect:true whenever several options can apply together (\"pick as many as apply\"), " +
	"give an option a `preview` when the choice is between concrete artifacts worth reading side by side (mockups, code snippets, config variants — carried verbatim), " +
	"mark at most one option `recommended:true` when you have a real recommendation, and omit `options` entirely for a free-text question (naming, a value, a sentence). " +
	"NOTHING will tell you when it is answered — the local notification went with the form. Poll the rook answers tool. " +
	"If you have other useful work, continue it and check between steps; if everything depends on the answer, end your turn and say you're waiting on them."

// answersToolDescription — the read half of the ask/answer split.
const answersToolDescription = "Collect the user's answers to rook asks posed in this session. " +
	"Returns {\"answered\":[{\"askId\":…,\"answer\":…}],\"pending\":[askId…]} — each answer is " +
	"{\"answers\":[{\"question\":…,\"selected\":[labels…],\"other\":text?}]} (treat `other` as the user's own words; " +
	"`selected` carries every label they ticked on a multiSelect question, and an EMPTY `selected` means they chose none of the options — take that as a real answer, not a dismissal) " +
	"or {\"canceled\":true}, meaning they dismissed that ask: proceed on your best judgment instead of re-asking. " +
	"Answered asks are consumed by the read. Nothing announces an answer, so call this periodically while an ask is pending, and always before deciding anything that waited on one."

// askToolSchema is AskUserQuestion's input shape — so the model can forward
// a denied call's arguments verbatim — plus what a rook ask can carry that
// the TUI cannot: previews, a marked recommendation, and a question with no
// options at all. Every addition is optional, so the verbatim forward keeps
// working.
var askToolSchema = json.RawMessage(`{
  "type": "object",
  "required": ["questions"],
  "properties": {
    "questions": {
      "type": "array",
      "minItems": 1,
      "maxItems": 4,
      "items": {
        "type": "object",
        "required": ["question"],
        "properties": {
          "question": {"type": "string", "description": "The complete question to ask"},
          "header": {"type": "string", "description": "Short chip label (max ~12 chars)"},
          "multiSelect": {"type": "boolean", "description": "True when several options can apply together — the user ticks any number of them and may tick none. Use it for 'pick as many as apply'; leave it off when the options are mutually exclusive."},
          "options": {
            "type": "array",
            "description": "2-4 options. Omit entirely for a free-text question — the ask becomes a single input.",
            "items": {
              "type": "object",
              "required": ["label"],
              "properties": {
                "label": {"type": "string", "description": "1-5 words, the choice itself"},
                "description": {"type": "string", "description": "What this option means or what happens if chosen"},
                "preview": {"type": "string", "description": "A concrete artifact to compare — ASCII mockup, code snippet, config, diagram. Carried verbatim to whatever renders the ask. Use when the choice is really between these artifacts."},
                "recommended": {"type": "boolean", "description": "Your recommendation: the cursor starts here, and in a multiSelect it starts ticked. At most one per question."}
              }
            }
          }
        }
      }
    }
  }
}`)

type rpcRequest struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id"`
	Method  string          `json:"method"`
	Params  json.RawMessage `json:"params"`
}

type rpcError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

func runMcp() error {
	in := bufio.NewScanner(os.Stdin)
	// tool arguments can be large; the default 64K line cap is not enough
	in.Buffer(make([]byte, 0, 64*1024), 4*1024*1024)
	out := json.NewEncoder(os.Stdout)

	reply := func(id json.RawMessage, result any, rerr *rpcError) {
		if id == nil {
			return // notification — no reply
		}
		msg := map[string]any{"jsonrpc": "2.0", "id": id}
		if rerr != nil {
			msg["error"] = rerr
		} else {
			msg["result"] = result
		}
		out.Encode(msg)
	}

	for in.Scan() {
		line := in.Bytes()
		if len(line) == 0 {
			continue
		}
		var req rpcRequest
		if err := json.Unmarshal(line, &req); err != nil {
			continue // not ours to fix; skip the frame
		}
		switch req.Method {
		case "initialize":
			reply(req.ID, map[string]any{
				"protocolVersion": mcpProtocolVersion,
				"capabilities":    map[string]any{"tools": map[string]any{}},
				"serverInfo":      map[string]any{"name": "rook", "version": version.Version},
			}, nil)
		case "ping":
			reply(req.ID, map[string]any{}, nil)
		case "tools/list":
			reply(req.ID, map[string]any{
				"tools": []map[string]any{{
					"name":        "ask",
					"description": askToolDescription,
					"inputSchema": askToolSchema,
				}, {
					"name":        "answers",
					"description": answersToolDescription,
					"inputSchema": json.RawMessage(`{"type":"object","properties":{}}`),
				}},
			}, nil)
		case "tools/call":
			var params struct {
				Name      string          `json:"name"`
				Arguments json.RawMessage `json:"arguments"`
			}
			if err := json.Unmarshal(req.Params, &params); err != nil {
				reply(req.ID, nil, &rpcError{Code: -32602, Message: "bad params"})
				continue
			}
			switch params.Name {
			case "ask":
				result, rerr := mcpAsk(params.Arguments)
				reply(req.ID, result, rerr)
			case "answers":
				result, rerr := mcpAnswers()
				reply(req.ID, result, rerr)
			default:
				reply(req.ID, nil, &rpcError{Code: -32602, Message: "unknown tool"})
			}
		default:
			// notifications/initialized, notifications/cancelled, …
			reply(req.ID, nil, &rpcError{Code: -32601, Message: "method not found: " + req.Method})
		}
	}
	return in.Err()
}

// mcpText shapes a tool result. Failures are tool-result errors (isError),
// not protocol errors — the model should read them and adapt, not crash
// the session.
func mcpText(s string, isErr bool) any {
	return map[string]any{
		"content": []map[string]any{{"type": "text", "text": s}},
		"isError": isErr,
	}
}

// mcpSession is the rook window this server serves — the pty claude runs
// in, inherited through the environment.
func mcpSession() (string, *client, any) {
	self := os.Getenv("ROOK_SESSION")
	if self == "" {
		return "", nil, mcpText("not inside a rook terminal (no $ROOK_SESSION) — fall back to asking directly", true)
	}
	c, err := connect()
	if err != nil {
		return "", nil, mcpText(fmt.Sprintf("rook host unreachable: %v — fall back to asking directly", err), true)
	}
	return self, c, nil
}

// mcpAsk posts the questions and returns immediately — the ask/answer
// relay. The answer comes back through the answers tool, which the caller polls.
func mcpAsk(arguments json.RawMessage) (any, *rpcError) {
	self, c, errRes := mcpSession()
	if errRes != nil {
		return errRes, nil
	}
	questions, err := askQuestions(arguments)
	if err != nil {
		return mcpText(err.Error(), true), nil
	}
	out, err := c.req("POST", "/sessions/"+self+"/ask", map[string]any{
		"questions": questions,
		"notify":    true,
	})
	if err != nil {
		return mcpText(fmt.Sprintf("ask failed: %v — fall back to asking directly", err), true), nil
	}
	var created struct {
		AskID string `json:"askId"`
	}
	if json.Unmarshal(out, &created) != nil || created.AskID == "" {
		return mcpText(fmt.Sprintf("unexpected response: %s", out), true), nil
	}
	return mcpText(fmt.Sprintf(`{"askId":%q,"pending":true}`, created.AskID), false), nil
}

// mcpAnswers drains this session's decided asks — the read half.
func mcpAnswers() (any, *rpcError) {
	self, c, errRes := mcpSession()
	if errRes != nil {
		return errRes, nil
	}
	out, err := c.req("GET", "/sessions/"+self+"/asks", nil)
	if err != nil {
		return mcpText(fmt.Sprintf("answers unavailable: %v", err), true), nil
	}
	return mcpText(string(out), false), nil
}
