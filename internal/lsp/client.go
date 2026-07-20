package lsp

import (
	"context"
	"encoding/json"
	"fmt"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// Positions on this API are LSP-native: 0-based line and UTF-16 column.
// Rook requests the protocol default encoding (utf-16), which is also
// Monaco's — the host converts to 1-based editor lines at its boundary.

type Position struct {
	Line int `json:"line"`
	Col  int `json:"character"`
}

type Range struct {
	Start Position `json:"start"`
	End   Position `json:"end"`
}

// Location is a normalized definition/reference hit: an absolute file
// path (translated from the server's URI) and its range.
type Location struct {
	Path  string
	Range Range
}

// Client is one live server instance: a spawned process, an initialized
// session, and the set of documents synced into it. Instances are keyed
// by (server, root) at the host layer.
type Client struct {
	cmd  *exec.Cmd
	conn *conn
	root string

	mu   sync.Mutex
	docs map[string]doc // abs path → synced state

	// the server's semantic-token legend, read once off its initialize
	// reply. Immutable after Start, so no lock — and empty when the server
	// doesn't do semantic tokens, which is how callers detect that.
	legend SemanticLegend

	done chan struct{} // closed when the process exits
	err  error         // Wait's result, valid after done
}

// SemanticLegend is the server's token vocabulary: semantic token data is
// integer indices INTO these arrays, so the legend is the only way to read
// it. Every server publishes its own — gopls names 22 types, vtsls fewer —
// which is why it rides to the client rather than being hardcoded anywhere.
type SemanticLegend struct {
	Types     []string `json:"types"`
	Modifiers []string `json:"modifiers"`
}

type doc struct {
	version int
	text    string
}

const callTimeout = 15 * time.Second

// Start spawns argv rooted at root and runs the initialize handshake.
// settings is the server's opaque configuration JSON ("" = none): sent as
// didChangeConfiguration and served back on workspace/configuration pulls
// (gopls asks; vtsls reads the push).
func Start(ctx context.Context, argv []string, root, settings string) (*Client, error) {
	if len(argv) == 0 || argv[0] == "" {
		return nil, fmt.Errorf("lsp: empty command")
	}
	cmd := exec.CommandContext(ctx, argv[0], argv[1:]...)
	cmd.Dir = root
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return nil, err
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, err
	}
	cmd.Stderr = nil // servers chat on stderr; silence beats interleaving
	if err := cmd.Start(); err != nil {
		return nil, err
	}
	c := &Client{cmd: cmd, root: root, docs: map[string]doc{}, done: make(chan struct{})}
	c.conn = newConn(stdin, stdout, c.serverRequest(settings))
	go func() {
		c.err = cmd.Wait()
		close(c.done)
	}()

	initCtx, cancel := context.WithTimeout(ctx, callTimeout)
	defer cancel()
	initParams := map[string]any{
		"processId": os.Getpid(),
		"rootUri":   pathToURI(root),
		"workspaceFolders": []map[string]any{
			{"uri": pathToURI(root), "name": filepath.Base(root)},
		},
		"capabilities": map[string]any{
			"textDocument": map[string]any{
				"definition": map[string]any{},
				"references": map[string]any{},
				"hover":      map[string]any{"contentFormat": []string{"markdown", "plaintext"}},
				"synchronization": map[string]any{
					"didSave": false,
				},
				// Semantic tokens: the whole-file request only. Deltas and
				// ranges are protocol-level optimizations we don't need
				// while a query is one HTTP round trip anyway, and gopls
				// refuses the capability outright if `requests` is absent.
				"semanticTokens": map[string]any{
					"requests":       map[string]any{"full": true},
					"tokenTypes":     []string{},
					"tokenModifiers": []string{},
					"formats":        []string{"relative"},
				},
			},
			"workspace": map[string]any{
				"configuration":    true,
				"workspaceFolders": true,
			},
		},
	}
	// The initialize reply carries the server's capabilities; the only one
	// we read is the semantic-token legend, because token data is
	// meaningless without it. Everything else stays "just try the request".
	var initRes struct {
		Capabilities struct {
			SemanticTokensProvider *struct {
				Legend struct {
					TokenTypes     []string `json:"tokenTypes"`
					TokenModifiers []string `json:"tokenModifiers"`
				} `json:"legend"`
			} `json:"semanticTokensProvider"`
		} `json:"capabilities"`
	}
	if err := c.callResult(initCtx, "initialize", initParams, &initRes); err != nil {
		c.Close()
		return nil, fmt.Errorf("lsp: initialize: %w", err)
	}
	if p := initRes.Capabilities.SemanticTokensProvider; p != nil {
		c.legend = SemanticLegend{Types: p.Legend.TokenTypes, Modifiers: p.Legend.TokenModifiers}
	}
	c.conn.notify("initialized", map[string]any{})
	if settings != "" {
		var s json.RawMessage = []byte(settings)
		c.conn.notify("workspace/didChangeConfiguration", map[string]any{"settings": s})
	}
	return c, nil
}

// serverRequest answers the server→client requests a session needs to
// stay healthy; everything unknown gets MethodNotFound (fail open — a
// server survives that).
func (c *Client) serverRequest(settings string) func(string, json.RawMessage) (any, error) {
	return func(method string, params json.RawMessage) (any, error) {
		switch method {
		case "workspace/configuration":
			// answer each item with the settings' matching top-level
			// section, null otherwise — gopls pulls its config this way
			var req struct {
				Items []struct {
					Section string `json:"section"`
				} `json:"items"`
			}
			json.Unmarshal(params, &req)
			var sections map[string]json.RawMessage
			if settings != "" {
				json.Unmarshal([]byte(settings), &sections)
			}
			out := make([]json.RawMessage, len(req.Items))
			for i, item := range req.Items {
				if v, ok := sections[item.Section]; ok {
					out[i] = v
				} else {
					out[i] = []byte("null")
				}
			}
			return out, nil
		case "workspace/workspaceFolders":
			return []map[string]any{{"uri": pathToURI(c.root), "name": filepath.Base(c.root)}}, nil
		case "client/registerCapability", "client/unregisterCapability",
			"window/workDoneProgress/create", "workspace/applyEdit":
			return nil, nil
		case "window/showMessageRequest":
			return nil, nil
		default:
			return nil, fmt.Errorf("unhandled method %s", method)
		}
	}
}

func (c *Client) callResult(ctx context.Context, method string, params, result any) error {
	ch, err := c.conn.call(method, params)
	if err != nil {
		return err
	}
	select {
	case <-ctx.Done():
		return ctx.Err()
	case m := <-ch:
		if m.Error != nil {
			return m.Error
		}
		if result != nil && len(m.Result) > 0 && string(m.Result) != "null" {
			return json.Unmarshal(m.Result, result)
		}
		return nil
	}
}

// EnsureOpen syncs a document before a query: first sight is didOpen,
// changed text is a full-sync didChange, same text is a no-op. Empty text
// reads from disk — correct after :w, the habit the editor encourages.
func (c *Client) EnsureOpen(path, text string) error {
	if text == "" {
		b, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		text = string(b)
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	d, open := c.docs[path]
	if open && d.text == text {
		return nil
	}
	if !open {
		c.docs[path] = doc{version: 1, text: text}
		return c.conn.notify("textDocument/didOpen", map[string]any{
			"textDocument": map[string]any{
				"uri":        pathToURI(path),
				"languageId": languageID(path),
				"version":    1,
				"text":       text,
			},
		})
	}
	d.version++
	d.text = text
	c.docs[path] = d
	return c.conn.notify("textDocument/didChange", map[string]any{
		"textDocument":   map[string]any{"uri": pathToURI(path), "version": d.version},
		"contentChanges": []map[string]any{{"text": text}},
	})
}

func (c *Client) posParams(path string, pos Position) map[string]any {
	return map[string]any{
		"textDocument": map[string]any{"uri": pathToURI(path)},
		"position":     pos,
	}
}

// Definition resolves gd. The wire result is Location | []Location |
// []LocationLink depending on the server — all three normalize here.
func (c *Client) Definition(ctx context.Context, path string, pos Position) ([]Location, error) {
	var raw json.RawMessage
	if err := c.callResult(ctx, "textDocument/definition", c.posParams(path, pos), &raw); err != nil {
		return nil, err
	}
	return parseLocations(raw)
}

func (c *Client) References(ctx context.Context, path string, pos Position) ([]Location, error) {
	params := c.posParams(path, pos)
	params["context"] = map[string]any{"includeDeclaration": true}
	var raw json.RawMessage
	if err := c.callResult(ctx, "textDocument/references", params, &raw); err != nil {
		return nil, err
	}
	return parseLocations(raw)
}

// Hover returns the hover contents flattened to markdown text.
func (c *Client) Hover(ctx context.Context, path string, pos Position) (string, *Range, error) {
	var res struct {
		Contents json.RawMessage `json:"contents"`
		Range    *Range          `json:"range"`
	}
	if err := c.callResult(ctx, "textDocument/hover", c.posParams(path, pos), &res); err != nil {
		return "", nil, err
	}
	return hoverText(res.Contents), res.Range, nil
}

// Legend is the server's semantic-token vocabulary; empty Types means the
// server doesn't do semantic tokens (the caller then skips the request).
func (c *Client) Legend() SemanticLegend { return c.legend }

// SemanticTokens is textDocument/semanticTokens/full: the whole file's
// tokens as LSP's relative 5-tuple encoding
// (deltaLine, deltaStartChar, length, typeIndex, modifierBits), flattened.
//
// The encoding is passed through UNTOUCHED all the way to Monaco, which
// happens to want the identical layout — same tuple, same relative deltas,
// same 0-based utf-16 coordinates. That is why this is the one LSP surface
// rook does not convert: every other one crosses the 1-based editor
// boundary, and a "helpful" conversion here would corrupt the stream.
func (c *Client) SemanticTokens(ctx context.Context, path string) ([]uint32, error) {
	if len(c.legend.Types) == 0 {
		return nil, nil // server declined the capability — not an error
	}
	var res struct {
		Data []uint32 `json:"data"`
	}
	params := map[string]any{
		"textDocument": map[string]any{"uri": pathToURI(path)},
	}
	if err := c.callResult(ctx, "textDocument/semanticTokens/full", params, &res); err != nil {
		return nil, err
	}
	return res.Data, nil
}

// Done closes when the server process exits — the supervision hook.
func (c *Client) Done() <-chan struct{} { return c.done }

// Pid is the server process id — status surface only.
func (c *Client) Pid() int {
	if c.cmd.Process == nil {
		return 0
	}
	return c.cmd.Process.Pid
}

// Close ends the session: polite shutdown/exit with a short grace, then
// the kill. Safe on an already-dead server.
func (c *Client) Close() {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	c.callResult(ctx, "shutdown", nil, nil)
	c.conn.notify("exit", nil)
	select {
	case <-c.done:
	case <-ctx.Done():
		c.cmd.Process.Kill()
		<-c.done
	}
}

// ---- wire helpers ----

type wireLocation struct {
	URI   string `json:"uri"`
	Range Range  `json:"range"`
	// LocationLink shape
	TargetURI   string `json:"targetUri"`
	TargetRange *Range `json:"targetSelectionRange"`
}

func (w wireLocation) toLocation() (Location, bool) {
	uri, rng := w.URI, w.Range
	if uri == "" && w.TargetURI != "" {
		uri = w.TargetURI
		if w.TargetRange != nil {
			rng = *w.TargetRange
		}
	}
	p := uriToPath(uri)
	if p == "" {
		return Location{}, false
	}
	return Location{Path: p, Range: rng}, true
}

func parseLocations(raw json.RawMessage) ([]Location, error) {
	if len(raw) == 0 || string(raw) == "null" {
		return nil, nil
	}
	var many []wireLocation
	if err := json.Unmarshal(raw, &many); err != nil {
		var one wireLocation
		if err := json.Unmarshal(raw, &one); err != nil {
			return nil, fmt.Errorf("lsp: unrecognized location shape: %s", tailStr(raw))
		}
		many = []wireLocation{one}
	}
	out := make([]Location, 0, len(many))
	for _, w := range many {
		if loc, ok := w.toLocation(); ok {
			out = append(out, loc)
		}
	}
	return out, nil
}

// hoverText flattens the three historical hover shapes — MarkupContent,
// MarkedString, and arrays of MarkedString — to plain markdown text.
func hoverText(raw json.RawMessage) string {
	if len(raw) == 0 || string(raw) == "null" {
		return ""
	}
	var markup struct {
		Value string `json:"value"`
	}
	if err := json.Unmarshal(raw, &markup); err == nil && markup.Value != "" {
		return markup.Value
	}
	var s string
	if err := json.Unmarshal(raw, &s); err == nil {
		return s
	}
	var parts []json.RawMessage
	if err := json.Unmarshal(raw, &parts); err == nil {
		var out []string
		for _, p := range parts {
			if t := hoverText(p); t != "" {
				out = append(out, t)
			}
		}
		return strings.Join(out, "\n\n")
	}
	return ""
}

func pathToURI(path string) string {
	u := url.URL{Scheme: "file", Path: filepath.ToSlash(path)}
	return u.String()
}

func uriToPath(uri string) string {
	u, err := url.Parse(uri)
	if err != nil || u.Scheme != "file" {
		return ""
	}
	return filepath.FromSlash(u.Path)
}

func languageID(path string) string {
	switch ext := strings.TrimPrefix(filepath.Ext(path), "."); ext {
	case "go":
		return "go"
	case "ts":
		return "typescript"
	case "tsx":
		return "typescriptreact"
	case "js", "mjs", "cjs":
		return "javascript"
	case "jsx":
		return "javascriptreact"
	case "svelte":
		return "svelte"
	case "mod":
		return "go.mod"
	case "work":
		return "go.work"
	default:
		return ext
	}
}

func tailStr(b []byte) string {
	s := string(b)
	if len(s) > 200 {
		s = s[:200] + "…"
	}
	return s
}
