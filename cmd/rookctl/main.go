// rookctl is rook's scripting surface — tmux's list-sessions/list-panes,
// but over the rook-host API. It discovers the daemon through the state
// file, so it works from any shell; inside a rook window, $ROOK_SESSION
// marks "this window" (tmux's $TMUX_PANE).
//
//	rookctl ls            workspace → window tree with live detail
//	rookctl ls --json     the same, as the raw status payloads
//	rookctl agents        every claude session agentwatch sees (raw JSON)
//	rookctl attention     who's waiting on you, cross-workspace (text inbox)
//	rookctl usage         subscription usage windows (host-cached)
//	rookctl send          type into a window: rookctl send s3 yes
//	rookctl approve       send a draft (optionally edited) into its window
//	rookctl reject        decline a draft
//	rookctl spawn         start a claude session: rookctl spawn [-w ws] [--worktree] <task…>
//	rookctl issues        the workspace's work queue (GitHub + Jira, mine + unassigned)
//	rookctl work          start claude on an issue in a fresh worktree: rookctl work INF-7
//	rookctl decisions     the drafter's ledger, last 7 days, with the verdict mix
//	rookctl set-openai-key store the drafter's API key in the keychain
//	rookctl set-jira-token store the Jira API token (queue credential) in the keychain
//	rookctl claim         claude SessionStart hook body (stdin → host)
//	rookctl unclaim       claude SessionEnd hook body
//	rookctl notify-hook   claude Notification hook body (permission prompts)
//	rookctl install-hooks add the claim hooks to ~/.claude/settings.json
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
	"path/filepath"
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
	case "agents":
		err = runAgents()
	case "attention":
		err = runAttention()
	case "usage":
		err = runUsage()
	case "send":
		err = runSend(os.Args[2:])
	case "approve":
		err = runApprove(os.Args[2:])
	case "reject":
		err = runReject(os.Args[2:])
	case "spawn":
		err = runSpawn(os.Args[2:])
	case "issues":
		err = runIssues(os.Args[2:])
	case "work":
		err = runWork(os.Args[2:])
	case "decisions":
		err = runDecisions()
	case "set-openai-key":
		err = runSetOpenAIKey()
	case "set-jira-token":
		err = runSetJiraToken()
	case "claim":
		err = runClaim(false)
	case "unclaim":
		err = runClaim(true)
	case "notify-hook":
		err = runNotifyHook()
	case "install-hooks":
		err = runInstallHooks()
	case "version":
		fmt.Printf("%s (build %s)\n", version.Version, version.Build)
		if st, err := host.ReadState(); err == nil {
			fmt.Printf("rook-host: %s (build %s)\n", st.Release, st.Build)
		}
	case "update":
		err = runUpdate(os.Args[2:])
	default:
		fmt.Fprintf(os.Stderr, "usage: rookctl [ls [--json]|agents|attention|usage|send <session> <text…>|approve <draft-id> [text…]|reject <draft-id>|spawn [-w ws] [--worktree] <task…>|set-openai-key|claim|unclaim|install-hooks|version|update [--check]]\n")
		os.Exit(2)
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "rookctl:", err)
		// hook invocations must never break claude startup/shutdown
		if cmd == "claim" || cmd == "unclaim" || cmd == "notify-hook" {
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

// ---- attention / send / approve / reject (the parity proof: everything
// the inbox can do, scriptable) ----

type attentionItem struct {
	Workspace    string    `json:"workspace"`
	RookSession  string    `json:"rookSession"`
	Window       int       `json:"window"`
	AgentSession string    `json:"agentSession"`
	AskSeq       int       `json:"askSeq"`
	Title        string    `json:"title"`
	Ask          string    `json:"ask"`
	Interactive  bool      `json:"interactive"`
	Since        time.Time `json:"since"`
	Draft        *struct {
		ID         int64   `json:"id"`
		Action     string  `json:"action"`
		Reply      string  `json:"reply"`
		Reason     string  `json:"reason"`
		Confidence float64 `json:"confidence"`
	} `json:"draft"`
}

func runAttention() error {
	c, err := connect()
	if err != nil {
		return err
	}
	raw, err := c.req("GET", "/attention", nil)
	if err != nil {
		return err
	}
	var items []attentionItem
	if err := json.Unmarshal(raw, &items); err != nil {
		return err
	}
	if len(items) == 0 {
		fmt.Println("nobody needs you")
		return nil
	}
	for _, it := range items {
		age := time.Since(it.Since).Round(time.Second)
		fmt.Printf("%s · window %d (%s)  ◉ waiting %s\n", it.Workspace, it.Window, it.RookSession, age)
		if it.Ask != "" {
			fmt.Printf("   ↳ %s\n", strings.ReplaceAll(it.Ask, "\n", " "))
		}
		if it.Interactive {
			fmt.Println("   ⌨ interactive prompt — answer in the window")
		}
		if it.Draft != nil {
			switch it.Draft.Action {
			case "draft":
				fmt.Printf("   ✎ draft #%d (%.0f%%): %s\n", it.Draft.ID, it.Draft.Confidence*100,
					strings.ReplaceAll(it.Draft.Reply, "\n", " "))
				fmt.Printf("     rookctl approve %d | rookctl reject %d\n", it.Draft.ID, it.Draft.ID)
			case "spawn":
				fmt.Printf("   ▶ new session #%d (%.0f%%): %s\n", it.Draft.ID, it.Draft.Confidence*100,
					strings.ReplaceAll(it.Draft.Reply, "\n", " "))
				fmt.Printf("     rookctl approve %d | rookctl reject %d\n", it.Draft.ID, it.Draft.ID)
			case "escalate":
				if it.Draft.Reason != "" {
					fmt.Printf("   ⚑ yours to answer — %s\n", strings.ReplaceAll(it.Draft.Reason, "\n", " "))
				} else {
					fmt.Printf("   ⚑ yours to answer (draft #%d escalated)\n", it.Draft.ID)
				}
			}
		}
	}
	return nil
}

func runUsage() error {
	c, err := connect()
	if err != nil {
		return err
	}
	raw, err := c.req("GET", "/usage", nil)
	if err != nil {
		return err
	}
	var snap struct {
		Windows []struct {
			Label  string `json:"label"`
			Pct    int    `json:"pct"`
			Resets string `json:"resets"`
		} `json:"windows"`
		CapturedAt time.Time `json:"capturedAt"`
	}
	if err := json.Unmarshal(raw, &snap); err != nil {
		return err
	}
	if len(snap.Windows) == 0 {
		fmt.Println("no usage data yet (first probe pending, or API billing)")
		return nil
	}
	for _, w := range snap.Windows {
		fmt.Printf("%-22s %3d%%  resets %s\n", w.Label, w.Pct, w.Resets)
	}
	fmt.Printf("as of %s\n", snap.CapturedAt.Local().Format("3:04pm"))
	// the other half of the picture: what this usage would cost on API
	// billing (host-observed raw-inference pricing)
	if raw, err := c.req("GET", "/costs", nil); err == nil {
		var costs struct {
			TodayUSD        float64 `json:"todayUsd"`
			WeekUSD         float64 `json:"weekUsd"`
			DrafterTodayUSD float64 `json:"drafterTodayUsd"`
		}
		if json.Unmarshal(raw, &costs) == nil && (costs.TodayUSD > 0 || costs.WeekUSD > 0) {
			fmt.Printf("raw-inference value: $%.2f today · $%.2f 7d", costs.TodayUSD, costs.WeekUSD)
			if costs.DrafterTodayUSD > 0 {
				fmt.Printf(" · drafter $%.2f today", costs.DrafterTodayUSD)
			}
			fmt.Println()
		}
	}
	return nil
}

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

func runApprove(args []string) error {
	if len(args) < 1 {
		return fmt.Errorf("usage: rookctl approve <draft-id> [text…]")
	}
	c, err := connect()
	if err != nil {
		return err
	}
	body := map[string]string{}
	if len(args) > 1 {
		body["text"] = strings.Join(args[1:], " ")
	}
	raw, err := c.req("POST", "/drafts/"+args[0]+"/approve", body)
	if err != nil {
		return err
	}
	var res struct {
		RookSession string `json:"rookSession"`
		Verdict     string `json:"verdict"`
	}
	json.Unmarshal(raw, &res)
	fmt.Printf("%s → %s\n", res.Verdict, res.RookSession)
	return nil
}

func runReject(args []string) error {
	if len(args) < 1 {
		return fmt.Errorf("usage: rookctl reject <draft-id>")
	}
	c, err := connect()
	if err != nil {
		return err
	}
	_, err = c.req("POST", "/drafts/"+args[0]+"/reject", map[string]string{})
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
	// A dev install is `make install` output — newer than any release, and
	// blindly "updating" it would roll the daily driver back.
	if cur == "dev" && !force {
		return fmt.Errorf("this is a dev build; latest release is %s — rookctl update --force to overwrite it", rel.Tag)
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
// --worktree carves a fresh git worktree (branch rook/<name>) off the
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

// ---- set-openai-key ----

// ---- issues (the work queue: GitHub + Jira behind the host) ----

type issueRow struct {
	Tracker string `json:"tracker"`
	Key     string `json:"key"`
	Title   string `json:"title"`
	State   string `json:"state"`
	Mine    bool   `json:"mine"`
	URL     string `json:"url"`
	Task    string `json:"task"`
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

// runWork starts a claude session on an issue — the issue→worktree→session
// loop in one command. Worktree isolation is the default when the
// workspace has a repo; --no-worktree lands in the workspace itself.
func runWork(args []string) error {
	ws := os.Getenv("ROOK_WORKSPACE")
	worktree := true
	for len(args) > 0 {
		if args[0] == "-w" && len(args) >= 2 {
			ws, args = args[1], args[2:]
		} else if args[0] == "--no-worktree" {
			worktree, args = false, args[1:]
		} else {
			break
		}
	}
	if len(args) != 1 || ws == "" {
		return fmt.Errorf("usage: rookctl work [-w workspace] [--no-worktree] <issue-key>")
	}
	key := args[0]
	c, err := connect()
	if err != nil {
		return err
	}
	res, err := fetchIssues(c, ws)
	if err != nil {
		return err
	}
	var issue *issueRow
	for idx, i := range res.Issues {
		if i.Key == key || strings.TrimPrefix(i.Key, "#") == key {
			issue = &res.Issues[idx]
			break
		}
	}
	if issue == nil {
		return fmt.Errorf("%s is not in %s's queue (rookctl issues to see it)", key, ws)
	}
	task := issue.Task
	target, cwdFrom := ws, os.Getenv("ROOK_SESSION")
	if worktree {
		// stamp provenance: the workspace records which issue spawned it
		raw, err := c.req("POST", "/workspaces", map[string]any{
			"worktreeFrom": ws,
			"issue":        map[string]string{"tracker": issue.Tracker, "key": issue.Key},
		})
		if err != nil {
			return err
		}
		var created struct {
			Name string `json:"name"`
		}
		if err := json.Unmarshal(raw, &created); err != nil {
			return err
		}
		target, cwdFrom = created.Name, ""
	}
	raw, err := c.req("POST", "/sessions", map[string]any{
		"cols": 100, "rows": 30, "workspace": target, "cwdFrom": cwdFrom,
	})
	if err != nil {
		return err
	}
	var s struct {
		ID string `json:"id"`
	}
	if err := json.Unmarshal(raw, &s); err != nil {
		return err
	}
	time.Sleep(500 * time.Millisecond) // let the shell come up
	if _, err := c.req("POST", "/sessions/"+s.ID+"/input",
		map[string]string{"data": "claude " + shellQuote(task) + "\r"}); err != nil {
		return err
	}
	fmt.Printf("working %s in %s (session %s)\n", key, target, s.ID)
	return nil
}

// ---- decisions (the drafter's ledger, human-readable) ----

func runDecisions() error {
	c, err := connect()
	if err != nil {
		return err
	}
	since := time.Now().Add(-7 * 24 * time.Hour)
	raw, err := c.req("GET", "/decisions?since="+since.UTC().Format("2006-01-02T15:04:05Z"), nil)
	if err != nil {
		return err
	}
	var rows []struct {
		Action     string  `json:"action"`
		Verdict    string  `json:"verdict"`
		Confidence float64 `json:"confidence"`
		Model      string  `json:"model"`
		CostUSD    float64 `json:"costUsd"`
		Ask        string  `json:"ask"`
	}
	if err := json.Unmarshal(raw, &rows); err != nil {
		return err
	}
	if len(rows) == 0 {
		fmt.Println("no decisions in the last 7 days")
		return nil
	}
	mix := map[string]int{}
	var usd float64
	for _, r := range rows {
		mix[r.Verdict]++
		usd += r.CostUSD
		ask := strings.ReplaceAll(r.Ask, "\n", " ")
		if len(ask) > 60 {
			ask = ask[:60] + "…"
		}
		fmt.Printf("%-9s %-9s %4.2f  $%.4f  %s\n", r.Action, r.Verdict, r.Confidence, r.CostUSD, ask)
	}
	fmt.Printf("\n%d decisions, $%.4f — verdicts:", len(rows), usd)
	for _, v := range []string{"approved", "edited", "rejected", "manual", "stale", "open", "auto"} {
		if mix[v] > 0 {
			fmt.Printf(" %s %d", v, mix[v])
		}
	}
	fmt.Println()
	return nil
}

// runSetJiraToken mirrors runSetOpenAIKey for the issue queue's Jira
// credential (api token from id.atlassian.com; email + url live in config).
func runSetJiraToken() error {
	cmd := exec.Command("security", "add-generic-password", "-U",
		"-s", keychain.Service, "-a", keychain.JiraAccount, "-w")
	cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("security add-generic-password: %w", err)
	}
	if k, err := keychain.Get(keychain.Service, keychain.JiraAccount); err != nil || k == "" {
		return fmt.Errorf("stored, but read-back failed — is the login keychain locked?")
	}
	fmt.Println("jira token stored — set jira-url, jira-email, and jira-project-<workspace> in ~/.config/rook/config")
	return nil
}

// runSetOpenAIKey hands the whole prompt to the security tool: it reads
// the key with hidden input on the tty, so the secret never appears in
// argv, shell history, or this process at all. Creating the item via
// /usr/bin/security also puts the ACL on that stable Apple-signed binary —
// rook-agent's reads (same tool) never trigger keychain prompts, no matter
// how often `make agent` rebuilds it.
func runSetOpenAIKey() error {
	cmd := exec.Command("security", "add-generic-password", "-U",
		"-s", keychain.Service, "-a", keychain.OpenAIAccount, "-w")
	cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("security add-generic-password: %w", err)
	}
	if k, err := keychain.Get(keychain.Service, keychain.OpenAIAccount); err != nil || k == "" {
		return fmt.Errorf("stored, but read-back failed — is the login keychain locked?")
	}
	fmt.Println("key stored in the login keychain — rook-agent picks it up within a minute")
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

// runNotifyHook relays Claude Code's Notification hook (permission
// prompts, idle reminders) to the host — the only mechanical source for
// "claude is blocked on a permission menu", which the transcript cannot
// see. Outside a rook window it does nothing, successfully.
func runNotifyHook() error {
	if os.Getenv("ROOK_SESSION") == "" {
		return nil
	}
	var in struct {
		SessionID string `json:"session_id"`
		Message   string `json:"message"`
	}
	if err := json.NewDecoder(os.Stdin).Decode(&in); err != nil || in.SessionID == "" {
		return nil
	}
	c, err := connect()
	if err != nil {
		return err
	}
	_, err = c.req("POST", "/agents/"+in.SessionID+"/notify",
		map[string]string{"message": in.Message})
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
	for evt, sub := range map[string]string{"SessionStart": "claim", "SessionEnd": "unclaim", "Notification": "notify-hook"} {
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
