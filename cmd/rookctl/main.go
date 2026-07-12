// rookctl is rook's scripting surface — tmux's list-sessions/list-panes,
// but over the rook-host API. It discovers the daemon through the state
// file, so it works from any shell; inside a rook window, $ROOK_SESSION
// marks "this window" (tmux's $TMUX_PANE).
//
//	rookctl ls            workspace → window tree with live detail
//	rookctl ls --json     the same, as the raw status payloads
//	rookctl agents        every claude session agentwatch sees (raw JSON)
//	rookctl claim         claude SessionStart hook body (stdin → host)
//	rookctl unclaim       claude SessionEnd hook body
//	rookctl install-hooks add the claim hooks to ~/.claude/settings.json
package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"

	"github.com/incantery/rook/internal/host"
)

type client struct {
	endpoint string
	token    string
}

func connect() (*client, error) {
	st, err := host.ReadState()
	if err != nil {
		return nil, fmt.Errorf("rook-host not running? (%v)", err)
	}
	return &client{endpoint: st.Endpoint(), token: st.Token}, nil
}

func (c *client) req(method, path string, body any) ([]byte, error) {
	var rd io.Reader
	if body != nil {
		b, _ := json.Marshal(body)
		rd = bytes.NewReader(b)
	}
	req, err := http.NewRequest(method, c.endpoint+path, rd)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Bearer "+c.token)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	out, _ := io.ReadAll(resp.Body)
	if resp.StatusCode >= 300 {
		return nil, fmt.Errorf("%s %s: %s %s", method, path, resp.Status, strings.TrimSpace(string(out)))
	}
	return out, nil
}

func main() {
	cmd := "ls"
	if len(os.Args) > 1 {
		cmd = os.Args[1]
	}
	var err error
	switch cmd {
	case "ls":
		err = runLs(len(os.Args) > 2 && os.Args[2] == "--json")
	case "agents":
		err = runAgents()
	case "claim":
		err = runClaim(false)
	case "unclaim":
		err = runClaim(true)
	case "install-hooks":
		err = runInstallHooks()
	default:
		fmt.Fprintf(os.Stderr, "usage: rookctl [ls [--json]|agents|claim|unclaim|install-hooks]\n")
		os.Exit(2)
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "rookctl:", err)
		// hook invocations must never break claude startup/shutdown
		if cmd == "claim" || cmd == "unclaim" {
			os.Exit(0)
		}
		os.Exit(1)
	}
}

// ---- ls ----

type wsItem struct {
	Name     string `json:"name"`
	Sessions int    `json:"sessions"`
}

type wsStatus struct {
	Name     string `json:"name"`
	Root     string `json:"root"`
	Scratch  bool   `json:"scratch"`
	Git      *struct {
		Branch string `json:"branch"`
		Dirty  int    `json:"dirty"`
		Ahead  int    `json:"ahead"`
		Behind int    `json:"behind"`
	} `json:"git"`
	Sessions []struct {
		ID           string `json:"id"`
		Fg           string `json:"fg"`
		Cwd          string `json:"cwd"`
		AgentSession string `json:"agentSession"`
		Agent        *struct {
			State   string  `json:"state"`
			Ask     string  `json:"ask"`
			Tool    string  `json:"tool"`
			CostUSD float64 `json:"costUsd"`
		} `json:"agent"`
	} `json:"sessions"`
	Attention int `json:"attention"`
}

func tilde(p string) string {
	if home, err := os.UserHomeDir(); err == nil && strings.HasPrefix(p, home) {
		return "~" + p[len(home):]
	}
	return p
}

func runLs(asJSON bool) error {
	c, err := connect()
	if err != nil {
		return err
	}
	raw, err := c.req("GET", "/workspaces", nil)
	if err != nil {
		return err
	}
	var list []wsItem
	if err := json.Unmarshal(raw, &list); err != nil {
		return err
	}
	var statuses []wsStatus
	for _, ws := range list {
		raw, err := c.req("GET", "/workspaces/"+ws.Name+"/status", nil)
		if err != nil {
			return err
		}
		var st wsStatus
		if err := json.Unmarshal(raw, &st); err != nil {
			return err
		}
		statuses = append(statuses, st)
	}
	if asJSON {
		return json.NewEncoder(os.Stdout).Encode(statuses)
	}
	self := os.Getenv("ROOK_SESSION")
	for _, st := range statuses {
		line := st.Name
		if st.Root != "" {
			line += "  " + tilde(st.Root)
		}
		if st.Git != nil {
			line += fmt.Sprintf("  ⎇ %s", st.Git.Branch)
			if st.Git.Dirty > 0 {
				line += fmt.Sprintf(" ●%d", st.Git.Dirty)
			}
			if st.Git.Ahead > 0 {
				line += fmt.Sprintf(" ↑%d", st.Git.Ahead)
			}
			if st.Git.Behind > 0 {
				line += fmt.Sprintf(" ↓%d", st.Git.Behind)
			}
		}
		if st.Scratch {
			line += "  [scratch]"
		}
		fmt.Println(line)
		for _, s := range st.Sessions {
			mark := " "
			if s.ID == self && self != "" {
				mark = "*"
			}
			line := fmt.Sprintf("%s %-4s %-8s %s", mark, s.ID, s.Fg, tilde(s.Cwd))
			if s.Agent != nil {
				switch s.Agent.State {
				case "needs_input":
					line += "  ◉ needs you"
				case "quiet":
					line += "  ◌ quiet"
					if s.Agent.Tool != "" {
						line += " — " + s.Agent.Tool
					}
				default:
					line += "  ● working"
					if s.Agent.Tool != "" {
						line += " — " + s.Agent.Tool
					}
				}
				if s.Agent.CostUSD > 0 {
					line += fmt.Sprintf(" $%.2f", s.Agent.CostUSD)
				}
			}
			if s.AgentSession != "" {
				line += "  [" + s.AgentSession[:min(8, len(s.AgentSession))] + "]"
			}
			fmt.Println(line)
			if s.Agent != nil && s.Agent.State == "needs_input" && s.Agent.Ask != "" {
				ask := s.Agent.Ask
				if len(ask) > 120 {
					ask = ask[:120] + "…"
				}
				fmt.Printf("       ↳ %s\n", strings.ReplaceAll(ask, "\n", " "))
			}
		}
	}
	return nil
}

func runAgents() error {
	c, err := connect()
	if err != nil {
		return err
	}
	raw, err := c.req("GET", "/agents", nil)
	if err != nil {
		return err
	}
	os.Stdout.Write(raw)
	return nil
}

// ---- claim / unclaim (Claude Code hook bodies) ----

// runClaim reads the hook payload from stdin. Outside a rook window (no
// ROOK_SESSION) it does nothing, successfully — the hook is installed
// globally but only means something inside rook.
func runClaim(release bool) error {
	rookID := os.Getenv("ROOK_SESSION")
	if rookID == "" {
		return nil
	}
	var in struct {
		SessionID string `json:"session_id"`
	}
	if err := json.NewDecoder(os.Stdin).Decode(&in); err != nil || in.SessionID == "" {
		return nil
	}
	c, err := connect()
	if err != nil {
		return err
	}
	_, err = c.req("POST", "/sessions/"+rookID+"/claim",
		map[string]any{"agentSession": in.SessionID, "release": release})
	return err
}

// ---- install-hooks ----

// runInstallHooks merges SessionStart/SessionEnd hooks into
// ~/.claude/settings.json, referencing this binary by absolute path
// (hooks run under claude's environment; PATH is not to be trusted).
// Idempotent: an existing rookctl hook is left alone.
func runInstallHooks() error {
	self, err := os.Executable()
	if err != nil {
		return err
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return err
	}
	path := filepath.Join(home, ".claude", "settings.json")
	settings := map[string]any{}
	if raw, err := os.ReadFile(path); err == nil {
		if err := json.Unmarshal(raw, &settings); err != nil {
			return fmt.Errorf("%s is not valid JSON, not touching it: %v", path, err)
		}
	}
	hooks, _ := settings["hooks"].(map[string]any)
	if hooks == nil {
		hooks = map[string]any{}
		settings["hooks"] = hooks
	}
	changed := false
	for evt, sub := range map[string]string{"SessionStart": "claim", "SessionEnd": "unclaim"} {
		entries, _ := hooks[evt].([]any)
		if hasRookctl(entries) {
			fmt.Printf("%s: rookctl hook already present\n", evt)
			continue
		}
		entries = append(entries, map[string]any{
			"hooks": []any{map[string]any{"type": "command", "command": self + " " + sub}},
		})
		hooks[evt] = entries
		changed = true
		fmt.Printf("%s: added `%s %s`\n", evt, self, sub)
	}
	if !changed {
		return nil
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	out, err := json.MarshalIndent(settings, "", "  ")
	if err != nil {
		return err
	}
	if err := os.WriteFile(path, append(out, '\n'), 0o644); err != nil {
		return err
	}
	fmt.Printf("wrote %s — applies to newly started claude sessions\n", path)
	return nil
}

func hasRookctl(entries []any) bool {
	for _, e := range entries {
		m, _ := e.(map[string]any)
		inner, _ := m["hooks"].([]any)
		for _, hk := range inner {
			hm, _ := hk.(map[string]any)
			if cmd, _ := hm["command"].(string); strings.Contains(cmd, "rookctl") {
				return true
			}
		}
	}
	return false
}
