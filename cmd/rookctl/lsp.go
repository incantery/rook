package main

// The plugin lifecycle + language-server verbs. Lifecycle is generic
// (`rookctl plugin …` will serve every plugin kind); the capability verbs
// are domain-named: `rookctl lsp status`, and def/refs/hover — grep-shaped
// output (path:line:col: text) because a claude session is a first-class
// reader of this surface.

import (
	"encoding/json"
	"fmt"
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

func runPlugin(args []string) error {
	verb := "list"
	if len(args) > 0 {
		verb, args = args[0], args[1:]
	}
	c, err := connect()
	if err != nil {
		return err
	}
	switch verb {
	case "list":
		raw, err := c.req("GET", "/plugins", nil)
		if err != nil {
			return err
		}
		var plugins []struct {
			Name, Kind, Version, Server, State, Detail string
			Selected                                   bool
		}
		if err := jsonInto(raw, &plugins); err != nil {
			return err
		}
		for _, p := range plugins {
			sel := " "
			if p.Selected {
				sel = "*"
			}
			line := fmt.Sprintf("%s %-12s %-9s %-10s %s", sel, p.Name, p.Kind, p.Version, p.State)
			if p.Detail != "" {
				line += " (" + p.Detail + ")"
			}
			fmt.Println(line)
		}
		if len(plugins) > 0 {
			fmt.Println("\n* = selected by `lsp =` in ~/.config/rook/config")
		}
		return nil
	case "install", "upgrade":
		body := map[string]string{}
		if len(args) > 0 && args[0] != "--all" {
			body["name"] = args[0]
		}
		fmt.Println("materializing (a first install can take a minute)…")
		raw, err := c.req("POST", "/plugins/"+verb, body)
		if err != nil {
			return err
		}
		var results []struct{ Name, State, Error string }
		if err := jsonInto(raw, &results); err != nil {
			return err
		}
		for _, r := range results {
			if r.Error != "" {
				fmt.Printf("✗ %s: %s\n", r.Name, r.Error)
			} else {
				fmt.Printf("✓ %s %s\n", r.Name, r.State)
			}
		}
		return nil
	default:
		return fmt.Errorf("usage: rookctl plugin [list|install <name>|--all|upgrade [<name>]]")
	}
}

func runLSP(args []string) error {
	if len(args) == 0 {
		return fmt.Errorf("usage: rookctl lsp status|restart <server> [-w workspace]")
	}
	verb, args := args[0], args[1:]
	ws, args, err := wsFlag(args)
	if err != nil {
		return err
	}
	c, err := connect()
	if err != nil {
		return err
	}
	switch verb {
	case "status":
		raw, err := c.req("GET", "/workspaces/"+ws+"/lsp/status", nil)
		if err != nil {
			return err
		}
		var res struct {
			Servers []struct {
				Server, Plugin, Tier, State, Detail, Version string
				Filetypes                                    []string
				Instances                                    []struct {
					Root      string
					Pid       int
					UptimeSec int
				}
			}
			Issues  []struct{ Subject, Detail string }
			Refused []string
		}
		if err := jsonInto(raw, &res); err != nil {
			return err
		}
		if len(res.Servers) == 0 {
			fmt.Println("no language servers configured — set `lsp = go, …` in ~/.config/rook/config")
		}
		for _, s := range res.Servers {
			line := fmt.Sprintf("%-14s %-8s %-10s .%s", s.Server, s.Tier, s.State, strings.Join(s.Filetypes, " ."))
			if s.Version != "" {
				line += "  " + s.Version
			}
			if s.Detail != "" {
				line += "  (" + s.Detail + ")"
			}
			fmt.Println(line)
			for _, i := range s.Instances {
				root := i.Root
				if root == "" {
					root = "(workspace root)"
				}
				fmt.Printf("  ● %s  pid %d  up %ds\n", root, i.Pid, i.UptimeSec)
			}
		}
		for _, i := range res.Issues {
			fmt.Printf("⚠ %s — %s\n", i.Subject, i.Detail)
		}
		for _, r := range res.Refused {
			fmt.Printf("✗ refused (repo layer may not supply commands): %s\n", r)
		}
		return nil
	case "restart":
		body := map[string]string{}
		if len(args) > 0 {
			body["server"] = args[0]
		}
		raw, err := c.req("POST", "/workspaces/"+ws+"/lsp/restart", body)
		if err != nil {
			return err
		}
		var res struct{ Stopped int }
		jsonInto(raw, &res)
		fmt.Printf("stopped %d instance(s) — the next query starts fresh\n", res.Stopped)
		return nil
	default:
		return fmt.Errorf("usage: rookctl lsp status|restart <server> [-w workspace]")
	}
}

// runLSPQuery serves def, refs and hover: rookctl def <path>:<line>[:<col>].
func runLSPQuery(verb string, args []string) error {
	ws, args, err := wsFlag(args)
	if err != nil {
		return err
	}
	if len(args) != 1 {
		return fmt.Errorf("usage: rookctl %s <path>:<line>[:<col>] [-w workspace]", verb)
	}
	path, line, col, err := parseLoc(args[0])
	if err != nil {
		return err
	}
	endpoint := map[string]string{"def": "definition", "refs": "references", "hover": "hover"}[verb]
	c, err := connect()
	if err != nil {
		return err
	}
	raw, err := c.req("POST", "/workspaces/"+ws+"/lsp/"+endpoint,
		map[string]any{"path": path, "line": line, "col": col})
	if err != nil {
		return err
	}
	if verb == "hover" {
		var res struct{ Contents, Note string }
		if err := jsonInto(raw, &res); err != nil {
			return err
		}
		if res.Note != "" {
			fmt.Println("· " + res.Note)
		}
		if res.Contents != "" {
			fmt.Println(res.Contents)
		}
		return nil
	}
	var res struct {
		Locations []struct {
			Path                string
			StartLine, StartCol int
			LineText            string
			External            bool
		}
		Note string
	}
	if err := jsonInto(raw, &res); err != nil {
		return err
	}
	if res.Note != "" {
		fmt.Println("· " + res.Note)
	}
	for _, l := range res.Locations {
		fmt.Printf("%s:%d:%d: %s\n", l.Path, l.StartLine, l.StartCol, l.LineText)
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
