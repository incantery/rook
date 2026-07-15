package agent

import (
	"encoding/json"
	"strings"
	"testing"
)

// serve runs one stdio session over the given request lines and returns the
// decoded responses.
func serve(t *testing.T, pass string, requests ...string) []rpcResponse {
	t.Helper()
	var out strings.Builder
	if err := ServeMCP(pass, strings.NewReader(strings.Join(requests, "\n")+"\n"), &out); err != nil {
		t.Fatalf("ServeMCP: %v", err)
	}
	var got []rpcResponse
	for _, line := range strings.Split(strings.TrimSpace(out.String()), "\n") {
		if line == "" {
			continue
		}
		var r rpcResponse
		if err := json.Unmarshal([]byte(line), &r); err != nil {
			t.Fatalf("response %q: %v", line, err)
		}
		got = append(got, r)
	}
	return got
}

func TestMCPHandshake(t *testing.T) {
	got := serve(t, "judgment",
		`{"jsonrpc":"2.0","id":1,"method":"initialize"}`,
		`{"jsonrpc":"2.0","id":2,"method":"tools/list"}`)
	if len(got) != 2 {
		t.Fatalf("want 2 responses, got %d", len(got))
	}
	init, _ := json.Marshal(got[0].Result)
	if !strings.Contains(string(init), mcpProtocolVersion) {
		t.Fatalf("initialize = %s", init)
	}
	list, _ := json.Marshal(got[1].Result)
	if !strings.Contains(string(list), "submit_judgment") {
		t.Fatalf("tools/list = %s", list)
	}
}

// The judgment pass and the extraction pass each see exactly one tool — the
// thing that makes --allowed-tools an exact allowlist rather than a hope.
func TestMCPServesOneToolPerPass(t *testing.T) {
	for pass, want := range map[string]string{
		"judgment":   "submit_judgment",
		"extraction": "submit_preferences",
	} {
		got := serve(t, pass, `{"jsonrpc":"2.0","id":1,"method":"tools/list"}`)
		var res struct {
			Tools []struct {
				Name        string         `json:"name"`
				InputSchema map[string]any `json:"inputSchema"`
			} `json:"tools"`
		}
		raw, _ := json.Marshal(got[0].Result)
		if err := json.Unmarshal(raw, &res); err != nil {
			t.Fatal(err)
		}
		if len(res.Tools) != 1 {
			t.Fatalf("%s pass exposes %d tools, want exactly 1", pass, len(res.Tools))
		}
		if res.Tools[0].Name != want {
			t.Fatalf("%s pass exposes %q, want %q", pass, res.Tools[0].Name, want)
		}
		if res.Tools[0].InputSchema == nil {
			t.Fatalf("%s pass advertises no schema — the output contract IS the schema", pass)
		}
	}
}

// The judgment tool's schema is the drafter's output contract, and it must be
// the same shape the OpenAI engine asks for via json_schema. One Judgment
// struct, two engines.
func TestMCPToolSchemaMatchesJudgment(t *testing.T) {
	got := serve(t, "judgment", `{"jsonrpc":"2.0","id":1,"method":"tools/list"}`)
	raw, _ := json.Marshal(got[0].Result)
	if !strings.Contains(string(raw), `"escalate"`) || !strings.Contains(string(raw), `"draft"`) {
		t.Fatalf("action enum missing from the advertised schema: %s", raw)
	}
	for _, f := range []string{"action", "reply", "confidence", "reason"} {
		if !strings.Contains(string(raw), `"`+f+`"`) {
			t.Errorf("schema is missing %q", f)
		}
	}
}

// Notifications carry no id and must never be answered — replying to one is a
// JSON-RPC protocol error and Claude Code drops the server.
func TestMCPNotificationsGetNoReply(t *testing.T) {
	got := serve(t, "judgment",
		`{"jsonrpc":"2.0","method":"notifications/initialized"}`,
		`{"jsonrpc":"2.0","id":1,"method":"ping"}`)
	if len(got) != 1 {
		t.Fatalf("want only the ping's reply, got %d responses", len(got))
	}
	if string(got[0].ID) != "1" {
		t.Fatalf("replied to the wrong message: id=%s", got[0].ID)
	}
}

func TestMCPUnknownMethodErrors(t *testing.T) {
	got := serve(t, "judgment", `{"jsonrpc":"2.0","id":1,"method":"resources/list"}`)
	if got[0].Error == nil {
		t.Fatal("want a JSON-RPC error for an unimplemented method")
	}
}

func TestMCPUnknownPassRefuses(t *testing.T) {
	if err := ServeMCP("wat", strings.NewReader(""), &strings.Builder{}); err == nil {
		t.Fatal("want an error for an unknown pass")
	}
}

func TestToolName(t *testing.T) {
	if got := ToolName("judgment"); got != "mcp__rook__submit_judgment" {
		t.Fatalf("ToolName = %q — must match Claude Code's mcp__{server}__{tool} exactly, "+
			"since --allowed-tools compares byte for byte", got)
	}
	if got := ToolName("nope"); got != "" {
		t.Fatalf("ToolName(unknown) = %q, want empty", got)
	}
}
