package main

// What survived the host's language surface: workspace-wide grep, and the
// CLI helpers the rest of rookctl shares.
//
// `rookctl def/refs/hover`, `lsp` and `plugin` went with internal/lsp and
// internal/plugin — the editor speaks LSP itself now, so the host had no
// language server left to ask. Grep stayed because it is a filesystem
// question rather than a language one, and its shape (path:line:col:
// text) is what makes a claude session a first-class reader of it.

import (
	"encoding/json"
	"fmt"
	"net/url"
	"os"
	"strconv"
	"strings"
)

func jsonInto(raw []byte, v any) error {
	if err := json.Unmarshal(raw, v); err != nil {
		return fmt.Errorf("bad response: %v", err)
	}
	return nil
}

func envWorkspace() string { return os.Getenv("ROOK_WORKSPACE") }

// runGrep is workspace-wide content search: rookctl grep <pattern> [-w ws].
// Output is path:line:col: text — greppable by eye and by agent.
func runGrep(args []string) error {
	ws, args, err := wsFlag(args)
	if err != nil {
		return err
	}
	if len(args) != 1 {
		return fmt.Errorf("usage: rookctl grep <pattern> [-w workspace]")
	}
	c, err := connect()
	if err != nil {
		return err
	}
	raw, err := c.req("GET", "/workspaces/"+ws+"/grep?q="+url.QueryEscape(args[0]), nil)
	if err != nil {
		return err
	}
	var res struct {
		Hits []struct {
			Path      string
			Line, Col int
			Text      string
		}
		Truncated bool
		Note      string
	}
	if err := jsonInto(raw, &res); err != nil {
		return err
	}
	if res.Note != "" {
		fmt.Println("· " + res.Note)
	}
	for _, h := range res.Hits {
		fmt.Printf("%s:%d:%d: %s\n", h.Path, h.Line, h.Col, h.Text)
	}
	if res.Truncated {
		fmt.Println("· truncated — narrow the pattern")
	}
	return nil
}

// wsFlag pulls -w (or $ROOK_WORKSPACE) out of args, leaving the rest.
func wsFlag(args []string) (string, []string, error) {
	ws := envWorkspace()
	var rest []string
	for i := 0; i < len(args); i++ {
		if args[i] == "-w" && i+1 < len(args) {
			ws = args[i+1]
			i++
			continue
		}
		rest = append(rest, args[i])
	}
	if ws == "" {
		return "", nil, fmt.Errorf("no workspace: pass -w or run inside a rook window")
	}
	return ws, rest, nil
}

// parseLoc splits path:line[:col]; col defaults to 1.
func parseLoc(s string) (path string, line, col int, err error) {
	col = 1
	parts := strings.Split(s, ":")
	if len(parts) < 2 {
		return "", 0, 0, fmt.Errorf("want <path>:<line>[:<col>], got %q", s)
	}
	if len(parts) > 2 {
		if col, err = strconv.Atoi(parts[len(parts)-1]); err == nil {
			parts = parts[:len(parts)-1]
		} else {
			col = 1
		}
	}
	line, err = strconv.Atoi(parts[len(parts)-1])
	if err != nil {
		return "", 0, 0, fmt.Errorf("bad line in %q", s)
	}
	return strings.Join(parts[:len(parts)-1], ":"), line, col, nil
}
