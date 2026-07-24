// `rookctl mcp` — a stdio MCP server exposing rook's ask surface to Claude
// Code. One tool: `ask`, the RUI question form (ask.go's blockingAsk behind
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
const askToolDescription = "Ask the user one or more questions through rook's UI. " +
	"The question opens as a form in a split beside this terminal, and this call BLOCKS until the user answers there (or dismisses it). " +
	"Use this INSTEAD of the built-in AskUserQuestion tool whenever it is available. " +
	"Before calling, write one short line telling the user you've asked in rook — e.g. \"Asked in rook →\" — and do NOT restate the question or options in text: the form shows them. " +
	"The result is JSON: {\"answers\":[{\"question\":…,\"selected\":[labels…],\"other\":text?}]} — treat `other` as the user's own words when present. " +
	"A result of {\"canceled\":true} means the user dismissed the question; continue with your best judgment instead of re-asking."

// askToolSchema mirrors AskUserQuestion's input shape, so the model can
// forward a denied call's arguments verbatim.
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
        "required": ["question", "options"],
        "properties": {
          "question": {"type": "string", "description": "The complete question to ask"},
          "header": {"type": "string", "description": "Short chip label (max ~12 chars)"},
          "multiSelect": {"type": "boolean", "description": "Allow choosing several options"},
          "options": {
            "type": "array",
            "minItems": 2,
            "items": {
              "type": "object",
              "required": ["label"],
              "properties": {
                "label": {"type": "string"},
                "description": {"type": "string"}
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
				}},
			}, nil)
		case "tools/call":
			var params struct {
				Name      string          `json:"name"`
				Arguments json.RawMessage `json:"arguments"`
			}
			if err := json.Unmarshal(req.Params, &params); err != nil || params.Name != "ask" {
				reply(req.ID, nil, &rpcError{Code: -32602, Message: "unknown tool"})
				continue
			}
			result, rerr := mcpAsk(params.Arguments)
			reply(req.ID, result, rerr)
		default:
			// notifications/initialized, notifications/cancelled, …
			reply(req.ID, nil, &rpcError{Code: -32601, Message: "method not found: " + req.Method})
		}
	}
	return in.Err()
}

// mcpAsk runs one blocking ask and shapes the outcome as a tool result.
// Failures are tool-result errors (isError), not protocol errors — the
// model should read them and adapt, not crash the session.
func mcpAsk(arguments json.RawMessage) (any, *rpcError) {
	text := func(s string, isErr bool) any {
		return map[string]any{
			"content": []map[string]any{{"type": "text", "text": s}},
			"isError": isErr,
		}
	}

	self := os.Getenv("ROOK_SESSION")
	if self == "" {
		return text("not inside a rook terminal (no $ROOK_SESSION) — fall back to asking directly", true), nil
	}
	questions, err := askQuestions(arguments)
	if err != nil {
		return text(err.Error(), true), nil
	}
	c, err := connect()
	if err != nil {
		return text(fmt.Sprintf("rook host unreachable: %v — fall back to asking directly", err), true), nil
	}
	answer, err := blockingAsk(c, self, questions)
	if err != nil {
		return text(fmt.Sprintf("ask failed: %v — fall back to asking directly", err), true), nil
	}
	return text(string(answer), false), nil
}
