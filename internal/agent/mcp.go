package agent

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
)

// The judgment channel (docs/agent.md): the ClaudeCode engine can't ask for
// strict json_schema the way the OpenAI one does, so the output contract
// becomes a TOOL — and the pass's ONLY tool. Claude calls it; we read the
// call off the stream-json transcript. This server is therefore deliberately
// a stub: MCP declares the SHAPE, --output-format stream-json carries the
// payload. Nothing here talks to rook-host.
//
// The failure mode is the safe one. No tool call means no judgment, and no
// judgment means the ask stays surfaced draft-less — which is what
// "escalate" already does. A schema violation and the safe default are the
// same path, so this needs no enforcement to be correct.
//
// One server per pass, one tool per server: `rook-agent mcp judgment` and
// `rook-agent mcp extraction`. Keeping it to a single tool makes the
// --allowed-tools allowlist exact, which is the thing standing between a
// classifier and an agent holding a shell.

const mcpProtocolVersion = "2025-06-18"

// MCPServerName is the key the engine writes into --mcp-config. Claude Code
// namespaces MCP tools as mcp__{server}__{tool}; ToolName renders that exact
// string, which --allowed-tools must match byte for byte.
const MCPServerName = "rook"

// mcpTool is one pass's output contract.
type mcpTool struct {
	name        string
	description string
	schema      map[string]any
}

var mcpTools = map[string]mcpTool{
	"judgment": {
		name: "submit_judgment",
		description: `Submit your judgment for the pending question. You MUST call this
tool exactly once, and it MUST be your first action. It is the only way to
answer. Do not read files, run commands, search, or explore — you have the
whole question already.`,
		schema: judgmentSchema,
	},
	"extraction": {
		name: "submit_preferences",
		description: `Submit the preferences you extracted. You MUST call this tool
exactly once, and it MUST be your first action. An empty list is the normal
outcome. Do not read files, run commands, or explore.`,
		schema: extractionSchema,
	},
}

// ToolName renders the fully-qualified name Claude sees for a pass.
func ToolName(pass string) string {
	t, ok := mcpTools[pass]
	if !ok {
		return ""
	}
	return "mcp__" + MCPServerName + "__" + t.name
}

type rpcRequest struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id"`
	Method  string          `json:"method"`
}

type rpcError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

type rpcResponse struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id"`
	Result  any             `json:"result,omitempty"`
	Error   *rpcError       `json:"error,omitempty"`
}

// ServeMCP runs the stdio JSON-RPC loop for one pass until stdin closes.
// Requests carry an id and want a response; notifications have none and must
// stay silent — replying to one is a protocol error.
func ServeMCP(pass string, in io.Reader, out io.Writer) error {
	tool, ok := mcpTools[pass]
	if !ok {
		return fmt.Errorf("unknown pass %q (want judgment or extraction)", pass)
	}
	dec := json.NewDecoder(bufio.NewReader(in))
	enc := json.NewEncoder(out)
	for {
		var req rpcRequest
		if err := dec.Decode(&req); err != nil {
			if err == io.EOF {
				return nil
			}
			return err
		}
		result, err := dispatchMCP(tool, req.Method)
		if req.ID == nil {
			continue // notification: no reply, ever
		}
		resp := rpcResponse{JSONRPC: "2.0", ID: req.ID}
		if err != nil {
			resp.Error = &rpcError{Code: -32601, Message: err.Error()}
		} else {
			resp.Result = result
		}
		if err := enc.Encode(resp); err != nil {
			return err
		}
	}
}

func dispatchMCP(tool mcpTool, method string) (any, error) {
	switch method {
	case "initialize":
		return map[string]any{
			"protocolVersion": mcpProtocolVersion,
			"capabilities":    map[string]any{"tools": map[string]any{}},
			"serverInfo":      map[string]any{"name": MCPServerName, "version": "1"},
		}, nil
	case "tools/list":
		return map[string]any{
			"tools": []any{map[string]any{
				"name":        tool.name,
				"description": tool.description,
				"inputSchema": tool.schema,
			}},
		}, nil
	case "tools/call":
		// The stub half: the arguments are never read here. The engine has
		// already seen them in the stream-json tool_use block by the time
		// this returns, so all Claude needs is an acknowledgement to end
		// its turn.
		return map[string]any{
			"content": []any{map[string]any{"type": "text", "text": "recorded"}},
		}, nil
	case "ping":
		return map[string]any{}, nil
	default:
		return nil, fmt.Errorf("method not found: %s", method)
	}
}
