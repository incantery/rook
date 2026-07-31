// rookctl is rook's scripting surface — tmux's list-sessions/list-panes,
// but over the rook-host API. It discovers the daemon through the state
// file, so it works from any shell; inside a rook window, $ROOK_SESSION
// marks "this window" (tmux's $TMUX_PANE).
//
//	rookctl ls            workspace → window tree with live detail
//	rookctl ls --json     the same, as the raw status payloads
//	rookctl send          type into a window: rookctl send s3 yes
//	rookctl spawn         start a claude session: rookctl spawn [-w ws] [--worktree] <task…>
//	rookctl issues        the workspace's work queue (providers, mine + unassigned)
//	rookctl ask           ask the human a question, delivered to their phone via
//	                        the relay, blocking until answered: rookctl ask '<json>'
//	                        (or stdin); answer JSON on stdout, exit 0 / 1 dismissed.
//	                        503 with no relay: nothing can answer it (the local
//	                        form left in the strip)
//	rookctl mcp           stdio MCP server for Claude Code — the `ask` tool is
//	                        `rookctl ask` behind tools/call (the rook plugin wires it)
//	rookctl set-linear-token store the Linear API key (queue credential) in the keychain
//	rookctl set-relay-token store the rook-server bearer token in the keychain
//	rookctl set-cloud-token store the rook-cloud machine token in the keychain
//	rookctl version       release version of this install
//	rookctl update        fetch + install the latest release (--check to look)
package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"strings"
	"time"

	"github.com/incantery/rook/internal/host"
	"github.com/incantery/rook/internal/keychain"
	"github.com/incantery/rook/internal/selfupdate"
	"github.com/incantery/rook/internal/version"
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
	// Fail open on build skew, but never silently: a stale daemon 404s
	// endpoints this rookctl expects (a claim once vanished that way),
	// and this warning is the only trace. Hooks capture stderr.
	if st.Build != version.Build {
		fmt.Fprintf(os.Stderr, "rookctl: warning: rookctl build %s ≠ rook-host build %s — relaunch rook to replace the daemon\n",
			version.Build, st.Build)
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
	case "send":
		err = runSend(os.Args[2:])
	case "spawn":
		err = runSpawn(os.Args[2:])
	case "issues":
		err = runIssues(os.Args[2:])
	case "set-linear-token":
		err = runSetLinearToken()
	case "set-relay-token":
		err = runSetRelayToken()
	case "set-cloud-token":
		err = runSetCloudToken()
	case "ask":
		err = runAsk(os.Args[2:])
	case "mcp":
		err = runMcp()
	case "version":
		fmt.Printf("%s (build %s)\n", version.Version, version.Build)
		if st, err := host.ReadState(); err == nil {
			fmt.Printf("rook-host: %s (build %s)\n", st.Release, st.Build)
		}
	case "update":
		err = runUpdate(os.Args[2:])
	default:
		fmt.Fprintf(os.Stderr, "usage: rookctl [ls [--json]|send <session> <text…>|spawn [-w ws] [--worktree] <task…>|issues|ask [json]|mcp|version|update [--check]]\n")
		os.Exit(2)
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "rookctl:", err)
		os.Exit(1)
	}
}

// ---- ls ----

type wsItem struct {
	Name     string `json:"name"`
	Sessions int    `json:"sessions"`
}

type wsStatus struct {
	Name    string `json:"name"`
	Root    string `json:"root"`
	Scratch bool   `json:"scratch"`
	Git     *struct {
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

// ---- send ----

func runSend(args []string) error {
	if len(args) < 2 {
		return fmt.Errorf("usage: rookctl send <session> <text…>")
	}
	c, err := connect()
	if err != nil {
		return err
	}
	// \r submits — same as pressing enter in the window
	_, err = c.req("POST", "/sessions/"+args[0]+"/input",
		map[string]string{"data": strings.Join(args[1:], " ") + "\r"})
	return err
}

// ---- update ----

func runUpdate(args []string) error {
	checkOnly, force := false, false
	for _, a := range args {
		switch a {
		case "--check":
			checkOnly = true
		case "--force":
			force = true
		default:
			return fmt.Errorf("usage: rookctl update [--check] [--force]")
		}
	}
	rel, err := selfupdate.Latest()
	if err != nil {
		return err
	}
	cur := version.Version
	if !rel.NewerThan(cur) {
		fmt.Printf("up to date (%s)\n", cur)
		return nil
	}
	if checkOnly {
		fmt.Printf("update available: %s → %s (rookctl update to install)\n", cur, rel.Tag)
		return nil
	}
	// A dev install is `make install` output from a tree that is ahead of
	// the last tag (or dirty) — NEWER than any release, so there is
	// nothing to update to and "updating" would be a downgrade. Say that,
	// rather than reporting it as a blocked upgrade: the old wording read
	// as "you are behind and I won't fix it", which is the opposite of
	// what is true.
	if cur == "dev" && !force {
		return fmt.Errorf(
			"nothing to update: this is a source build (%s), ahead of the latest release %s\n"+
				"  `rook update --force` would DOWNGRADE it to %s",
			version.Build, rel.Tag, rel.Tag)
	}
	fmt.Printf("updating %s → %s…\n", cur, rel.Tag)
	if err := selfupdate.Apply(rel); err != nil {
		return err
	}
	fmt.Println("done — quit + relaunch rook to pick it up")
	return nil
}

// ---- spawn ----

// runSpawn is the user-invoked half of the spawner (docs/agent.md step 4):
// a fresh window in the workspace, with claude started on the task. Inside
// a rook window it inherits your workspace and cwd; -w overrides.
// --worktree carves a fresh git worktree (branch rook/<name>, prefix
// configurable via branch-prefix-<workspace>) off the
// workspace's repo first and lands the session there — parallel sessions
// stop sharing one checkout.
func runSpawn(args []string) error {
	ws := os.Getenv("ROOK_WORKSPACE")
	worktree := false
	for len(args) > 0 {
		if args[0] == "-w" && len(args) >= 2 {
			ws, args = args[1], args[2:]
		} else if args[0] == "--worktree" {
			worktree, args = true, args[1:]
		} else {
			break
		}
	}
	if len(args) == 0 {
		return fmt.Errorf("usage: rookctl spawn [-w workspace] [--worktree] <task…>")
	}
	task := strings.Join(args, " ")
	c, err := connect()
	if err != nil {
		return err
	}
	cwdFrom := os.Getenv("ROOK_SESSION")
	if worktree {
		raw, err := c.req("POST", "/workspaces", map[string]any{"worktreeFrom": ws})
		if err != nil {
			return err
		}
		var created struct {
			Name string `json:"name"`
		}
		if err := json.Unmarshal(raw, &created); err != nil {
			return err
		}
		// the fresh workspace's root must seed the shell, not our cwd
		ws, cwdFrom = created.Name, ""
	}
	raw, err := c.req("POST", "/sessions", map[string]any{
		"cols": 100, "rows": 30, "workspace": ws,
		"cwdFrom": cwdFrom,
	})
	if err != nil {
		return err
	}
	var s struct {
		ID        string `json:"id"`
		Workspace string `json:"workspace"`
	}
	if err := json.Unmarshal(raw, &s); err != nil {
		return err
	}
	time.Sleep(500 * time.Millisecond) // let the shell come up
	_, err = c.req("POST", "/sessions/"+s.ID+"/input",
		map[string]string{"data": "claude " + shellQuote(task) + "\r"})
	if err != nil {
		return err
	}
	fmt.Printf("spawned %s in %s: claude %s\n", s.ID, s.Workspace, shellQuote(task))
	return nil
}

// shellQuote single-quotes s for a POSIX shell.
func shellQuote(s string) string {
	return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'"
}

// ---- issues (the work queue: providers, behind the host) ----

type issueRow struct {
	Provider string `json:"provider"`
	Key      string `json:"key"`
	Title    string `json:"title"`
	State    string `json:"state"`
	Mine     bool   `json:"mine"`
	URL      string `json:"url"`
	Task     string `json:"task"`
}

type issuesResp struct {
	Issues []issueRow `json:"issues"`
	Errors []string   `json:"errors"`
}

func fetchIssues(c *client, ws string) (issuesResp, error) {
	var res issuesResp
	raw, err := c.req("GET", "/workspaces/"+ws+"/issues", nil)
	if err != nil {
		return res, err
	}
	return res, json.Unmarshal(raw, &res)
}

// runIssues prints the workspace's queue: mine first, then unassigned.
func runIssues(args []string) error {
	ws := os.Getenv("ROOK_WORKSPACE")
	if len(args) >= 2 && args[0] == "-w" {
		ws = args[1]
	}
	if ws == "" {
		return fmt.Errorf("usage: rookctl issues [-w workspace] (or run inside a rook window)")
	}
	c, err := connect()
	if err != nil {
		return err
	}
	res, err := fetchIssues(c, ws)
	if err != nil {
		return err
	}
	for _, e := range res.Errors {
		fmt.Fprintln(os.Stderr, "rookctl: issues:", e)
	}
	if len(res.Issues) == 0 {
		fmt.Println("queue empty")
		return nil
	}
	for _, i := range res.Issues {
		who := "unassigned"
		if i.Mine {
			who = "mine"
		}
		title := i.Title
		if len(title) > 70 {
			title = title[:70] + "…"
		}
		fmt.Printf("%-10s %-10s %-11s %s\n", i.Key, who, i.State, title)
	}
	return nil
}

func runSetLinearToken() error {
	cmd := exec.Command("security", "add-generic-password", "-U",
		"-s", keychain.Service, "-a", keychain.LinearAccount, "-w")
	cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("security add-generic-password: %w", err)
	}
	if k, err := keychain.Get(keychain.Service, keychain.LinearAccount); err != nil || k == "" {
		return fmt.Errorf("stored, but read-back failed — is the login keychain locked?")
	}
	fmt.Println("linear key stored — add [providers.linear] to ~/.config/rook/config.toml to turn the queue on")
	return nil
}

// runSetRelayToken stores the bearer token for the configured rook-server
// (relay-url in config.toml). Same posture as the other two: the security
// tool reads it, so the secret never enters argv or shell history.
func runSetRelayToken() error {
	cmd := exec.Command("security", "add-generic-password", "-U",
		"-s", keychain.Service, "-a", keychain.RelayAccount, "-w")
	cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("security add-generic-password: %w", err)
	}
	if k, err := keychain.Get(keychain.Service, keychain.RelayAccount); err != nil || k == "" {
		return fmt.Errorf("stored, but read-back failed — is the login keychain locked?")
	}
	fmt.Println("relay token stored — set [relay] url in ~/.config/rook/config.toml, then restart rook-host")
	return nil
}

// runSetCloudToken stores the machine token rook-cloud showed exactly once
// when the machine was added on the dashboard. Same posture as the others:
// the security tool reads it, so the secret never enters argv or history.
func runSetCloudToken() error {
	cmd := exec.Command("security", "add-generic-password", "-U",
		"-s", keychain.Service, "-a", keychain.CloudAccount, "-w")
	cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("security add-generic-password: %w", err)
	}
	if k, err := keychain.Get(keychain.Service, keychain.CloudAccount); err != nil || k == "" {
		return fmt.Errorf("stored, but read-back failed — is the login keychain locked?")
	}
	fmt.Println("cloud token stored — set [cloud] url in ~/.config/rook/config.toml, then restart rook-host")
	return nil
}

// ---- claim / unclaim (Claude Code hook bodies) ----

// ---- install-hooks ----

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
