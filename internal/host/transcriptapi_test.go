package host

import (
	"encoding/json"
	"net/http/httptest"
	"strings"
	"testing"
)

func getTranscript(t *testing.T, h *Host, path string) (*httptest.ResponseRecorder, wireTranscript) {
	t.Helper()
	req := httptest.NewRequest("GET", path, nil)
	w := httptest.NewRecorder()
	h.handleAgent(w, req)
	var out wireTranscript
	if w.Code == 200 {
		if err := json.Unmarshal(w.Body.Bytes(), &out); err != nil {
			t.Fatalf("decode: %v (body %s)", err, w.Body.String())
		}
	}
	return w, out
}

// The endpoint reads whatever transcript tree exists on this machine, so a
// missing session is the only thing it can be asked for deterministically.
// The rendering contract is tested through toWire/conversational directly.
func TestTranscriptEndpointUnknownSessionIs404(t *testing.T) {
	h, _ := draftHost(t)
	w, _ := getTranscript(t, h, "/agents/00000000-dead-beef-0000-000000000000/transcript")
	if w.Code != 404 {
		t.Errorf("unknown session: code %d, want 404", w.Code)
	}
}

// A session id is a uuid. Anything with a separator is a caller trying to
// read a file outside the tree, and FindSession must refuse before any
// filesystem work happens.
func TestTranscriptEndpointRefusesTraversal(t *testing.T) {
	h, _ := draftHost(t)
	for _, bad := range []string{"..%2f..%2fetc%2fpasswd", "..", "%2e%2e"} {
		w, _ := getTranscript(t, h, "/agents/"+bad+"/transcript")
		if w.Code == 200 {
			t.Errorf("traversal %q returned 200", bad)
		}
	}
}

func TestConversationalFiltersBookkeeping(t *testing.T) {
	yes := []string{
		assistantText("hi"),
		userTyped,
		turnDone,
	}
	for _, line := range yes {
		rec := mustParse(t, line)
		if !conversational(rec) {
			t.Errorf("%s: conversational = false, want true", rec.Type)
		}
	}

	// Real records, none of them something the agent said.
	no := []string{
		`{"type":"attachment","uuid":"a"}`,
		`{"type":"file-history-snapshot","uuid":"f"}`,
		`{"type":"queue-operation","uuid":"q"}`,
		`{"type":"mode","mode":"normal"}`,
		`{"type":"permission-mode","permissionMode":"auto"}`,
		`{"type":"ai-title","aiTitle":"x"}`,
		`{"type":"last-prompt"}`,
		`{"type":"system","subtype":"away_summary","uuid":"s"}`,
		`{"type":"user","uuid":"u"}`, // no message
	}
	for _, line := range no {
		rec := mustParse(t, line)
		if conversational(rec) {
			t.Errorf("%q: conversational = true, want false", line)
		}
	}
}

// The picker payload is why the 2KB cap had to go; it must survive the wire
// too, still parseable.
func TestToWireKeepsToolIdentityAndWholeInput(t *testing.T) {
	line := toolUse("AskUserQuestion", map[string]any{
		"questions": []map[string]any{{
			"question": "Which?",
			"options":  []map[string]string{{"label": "A", "description": strings.Repeat("z", 3000)}},
		}},
	})
	got := toWire(lineOf(t, mustParse(t, line), 42))

	if got.Offset != 42 {
		t.Errorf("Offset = %d, want 42 — it is the scrollback cursor", got.Offset)
	}
	if len(got.Blocks) != 1 {
		t.Fatalf("blocks = %d, want 1", len(got.Blocks))
	}
	b := got.Blocks[0]
	if b.ID != "toolu_1" || b.Name != "AskUserQuestion" {
		t.Errorf("tool identity lost: id=%q name=%q", b.ID, b.Name)
	}
	if len(b.Input) < 3000 {
		t.Errorf("input is %d bytes — something capped it again", len(b.Input))
	}
	var back struct {
		Questions []struct {
			Options []struct{ Label string } `json:"options"`
		} `json:"questions"`
	}
	if err := json.Unmarshal(b.Input, &back); err != nil {
		t.Fatalf("input no longer parses: %v", err)
	}
	if len(back.Questions[0].Options) != 1 {
		t.Error("options lost")
	}
}

func TestToWireFlattensToolResultAndKeepsPairing(t *testing.T) {
	got := toWire(lineOf(t, mustParse(t, toolResult), 0))
	if len(got.Blocks) != 1 {
		t.Fatalf("blocks = %d, want 1", len(got.Blocks))
	}
	b := got.Blocks[0]
	if b.ToolUseID != "toolu_1" {
		t.Errorf("ToolUseID = %q — the pairing is the point", b.ToolUseID)
	}
	if b.Content != "done" {
		t.Errorf("Content = %q, want flattened text", b.Content)
	}
}

// 25MB of signature across the corpus for zero renderable characters.
func TestToWireDropsThinkingSignature(t *testing.T) {
	line := `{"type":"assistant","message":{"role":"assistant","content":[{"type":"thinking","thinking":"","signature":"CAISjAQKiAEIDxgC"},{"type":"text","text":"said"}]}}`
	got := toWire(lineOf(t, mustParse(t, line), 0))

	raw, err := json.Marshal(got)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(raw), "CAISjAQKiAEIDxgC") || strings.Contains(string(raw), "signature") {
		t.Errorf("signature reached the wire: %s", raw)
	}
	// the block still exists, so a turn's shape survives
	if len(got.Blocks) != 2 || got.Blocks[0].Type != "thinking" {
		t.Errorf("blocks = %+v, want the thinking block kept", got.Blocks)
	}
}
