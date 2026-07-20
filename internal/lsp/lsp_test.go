package lsp

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// The fake server: this test binary re-exec'd with ROOK_FAKE_LSP=1 speaks
// LSP on stdio — real framing, real pipes, no toolchain, no network.
func TestMain(m *testing.M) {
	if os.Getenv("ROOK_FAKE_LSP") != "" {
		runFakeServer()
		return
	}
	os.Exit(m.Run())
}

func runFakeServer() {
	r := bufio.NewReader(os.Stdin)
	w := os.Stdout
	send := func(v any) {
		b, _ := json.Marshal(v)
		fmt.Fprintf(w, "Content-Length: %d\r\n\r\n%s", len(b), b)
	}
	reply := func(id json.RawMessage, result any) {
		send(map[string]any{"jsonrpc": "2.0", "id": id, "result": result})
	}
	pulled := "" // what workspace/configuration handed us
	docVersion := 0
	for {
		m, err := readMsg(r)
		if err != nil {
			os.Exit(0)
		}
		switch m.Method {
		case "initialize":
			reply(m.ID, map[string]any{"capabilities": map[string]any{
				"semanticTokensProvider": map[string]any{
					"legend": map[string]any{
						"tokenTypes":     []string{"namespace", "type", "function"},
						"tokenModifiers": []string{"declaration", "readonly"},
					},
					"full": true,
				},
			}})
		case "initialized":
			// pull configuration like gopls does; stash the client's answer
			send(map[string]any{"jsonrpc": "2.0", "id": 100, "method": "workspace/configuration",
				"params": map[string]any{"items": []map[string]any{{"section": "fake"}}}})
		case "textDocument/didOpen":
			docVersion = 1
		case "textDocument/didChange":
			var p struct {
				TextDocument struct {
					Version int `json:"version"`
				} `json:"textDocument"`
			}
			json.Unmarshal(m.Params, &p)
			docVersion = p.TextDocument.Version
		case "textDocument/definition":
			// LocationLink shape — the normalizer's hard case
			reply(m.ID, []map[string]any{{
				"targetUri":            "file:///tmp/fake/other.go",
				"targetSelectionRange": map[string]any{"start": map[string]int{"line": 4, "character": 2}, "end": map[string]int{"line": 4, "character": 9}},
			}})
		case "textDocument/references":
			reply(m.ID, []map[string]any{
				{"uri": "file:///tmp/fake/a.go", "range": map[string]any{"start": map[string]int{"line": 1, "character": 0}, "end": map[string]int{"line": 1, "character": 3}}},
				{"uri": "file:///tmp/fake/b.go", "range": map[string]any{"start": map[string]int{"line": 9, "character": 5}, "end": map[string]int{"line": 9, "character": 8}}},
			})
		case "textDocument/hover":
			// prove the round trips: the pulled config and the doc version
			reply(m.ID, map[string]any{"contents": map[string]any{
				"kind":  "markdown",
				"value": fmt.Sprintf("cfg=%s v=%d", pulled, docVersion),
			}})
		case "textDocument/semanticTokens/full":
			// two tokens in LSP's relative 5-tuple encoding: a `function`
			// at 0:0 len 3, then a `type` two lines down at char 4 len 5
			reply(m.ID, map[string]any{"data": []int{
				0, 0, 3, 2, 0,
				2, 4, 5, 1, 1,
			}})
		case "shutdown":
			reply(m.ID, nil)
		case "exit":
			os.Exit(0)
		default:
			if m.ID != nil && m.Method == "" && m.Result != nil {
				// the configuration response coming back
				var vals []json.RawMessage
				json.Unmarshal(m.Result, &vals)
				if len(vals) > 0 {
					pulled = string(vals[0])
				}
			}
		}
	}
}

// startFake spawns the fake through a wrapper script (Start has no env
// hook — by design, servers get the host's environment).
func startFake(t *testing.T, settings string) *Client {
	t.Helper()
	exe, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	dir := t.TempDir()
	script := filepath.Join(dir, "fake-lsp")
	body := "#!/bin/sh\nROOK_FAKE_LSP=1 exec " + exe + "\n"
	if err := os.WriteFile(script, []byte(body), 0o755); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	c, err := Start(ctx, []string{script}, dir, settings)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(c.Close)
	return c
}

func testCtx(t *testing.T) context.Context {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	t.Cleanup(cancel)
	return ctx
}

func TestDefinitionNormalizesLocationLink(t *testing.T) {
	c := startFake(t, "")
	writeDoc := filepath.Join(t.TempDir(), "main.go")
	os.WriteFile(writeDoc, []byte("package main\n"), 0o644)
	if err := c.EnsureOpen(writeDoc, ""); err != nil {
		t.Fatal(err)
	}
	locs, err := c.Definition(testCtx(t), writeDoc, Position{Line: 0, Col: 8})
	if err != nil {
		t.Fatal(err)
	}
	if len(locs) != 1 || locs[0].Path != "/tmp/fake/other.go" || locs[0].Range.Start.Line != 4 {
		t.Fatalf("locs: %+v", locs)
	}
}

func TestReferences(t *testing.T) {
	c := startFake(t, "")
	locs, err := c.References(testCtx(t), "/tmp/x.go", Position{})
	if err != nil {
		t.Fatal(err)
	}
	if len(locs) != 2 || locs[1].Path != "/tmp/fake/b.go" || locs[1].Range.Start.Line != 9 {
		t.Fatalf("locs: %+v", locs)
	}
}

// Settings round-trip (the gopls path: server pulls workspace/configuration,
// client answers from the opaque JSON) and full-sync versioning.
func TestHoverConfigPullAndSync(t *testing.T) {
	c := startFake(t, `{"fake":{"knob":true}}`)
	p := filepath.Join(t.TempDir(), "f.go")
	os.WriteFile(p, []byte("one\n"), 0o644)
	if err := c.EnsureOpen(p, ""); err != nil {
		t.Fatal(err)
	}
	if err := c.EnsureOpen(p, "one\n"); err != nil { // same text: no-op
		t.Fatal(err)
	}
	if err := c.EnsureOpen(p, "two\n"); err != nil { // didChange → v2
		t.Fatal(err)
	}
	// the configuration pull races the handshake; poll briefly
	deadline := time.Now().Add(3 * time.Second)
	for {
		text, _, err := c.Hover(testCtx(t), p, Position{})
		if err != nil {
			t.Fatal(err)
		}
		if strings.Contains(text, `cfg={"knob":true}`) && strings.Contains(text, "v=2") {
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("hover never carried the round-trips: %q", text)
		}
		time.Sleep(20 * time.Millisecond)
	}
}

// A dead server fails pending calls once and stays failed — never a hang.
func TestServerExitFailsCalls(t *testing.T) {
	c := startFake(t, "")
	c.cmd.Process.Kill()
	<-c.Done()
	_, err := c.References(testCtx(t), "/tmp/x.go", Position{})
	if err == nil {
		t.Fatal("call on a dead server must error")
	}
}

func TestSemanticTokens(t *testing.T) {
	c := startFake(t, "")

	// the legend is read off initialize, not requested separately
	lg := c.Legend()
	if strings.Join(lg.Types, ",") != "namespace,type,function" {
		t.Fatalf("legend types: %+v", lg.Types)
	}
	if strings.Join(lg.Modifiers, ",") != "declaration,readonly" {
		t.Fatalf("legend modifiers: %+v", lg.Modifiers)
	}

	f := filepath.Join(t.TempDir(), "a.go")
	os.WriteFile(f, []byte("package x\n"), 0o644)
	if err := c.EnsureOpen(f, ""); err != nil {
		t.Fatal(err)
	}
	data, err := c.SemanticTokens(testCtx(t), f)
	if err != nil {
		t.Fatal(err)
	}
	// passed through verbatim — the encoding Monaco wants is the one LSP
	// sends, so any reshaping here would be a bug
	want := []uint32{0, 0, 3, 2, 0, 2, 4, 5, 1, 1}
	if len(data) != len(want) {
		t.Fatalf("data: %+v", data)
	}
	for i := range want {
		if data[i] != want[i] {
			t.Fatalf("data[%d] = %d, want %d (%+v)", i, data[i], want[i], data)
		}
	}
}
