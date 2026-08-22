// Package sessions is rook's own session model — the layer that used
// to be delegated to sesh. A row is either a live session on the rook
// server or a zoxide-ranked directory that could become one; rook owns
// listing, the detail card, and connect-or-create (including naming,
// which is how the full-path session names died).
package sessions

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"syscall"

	"github.com/incantery/rook/internal/attention"
	"github.com/incantery/rook/internal/tmux"
)

const (
	sessionMark = "●"
	dirMark     = "○"

	accent = "\x1b[33m"
	dim    = "\x1b[90m"
	bold   = "\x1b[1m"
	reset  = "\x1b[0m"
)

var (
	ansiRe = regexp.MustCompile(`\x1b\[[0-9;]*m`)
	// annotations appended by List — git context, then a state chip;
	// Parse must give back the bare value
	chipRe = regexp.MustCompile(`\s{2,}(● waiting|✳ working|· done)\s*$`)
	gitRe  = regexp.MustCompile(`\s{2,}⎇ \S+\s*$`)
)

// Kind says what a row points at.
type Kind int

const (
	KindSession Kind = iota
	KindDir
)

// Row is one line of `rook ls`.
type Row struct {
	Kind Kind
	// Name is the session name (KindSession); Path the directory
	// (KindDir), home-contracted for display.
	Value string
}

// Line renders the row for fzf: a colored kind mark, then the value.
func (r Row) Line() string {
	if r.Kind == KindSession {
		return accent + sessionMark + reset + " " + r.Value
	}
	return dim + dirMark + reset + " " + r.Value
}

// Parse turns a picker selection back into a row. It survives ANSI
// codes, missing marks (a query typed by hand), and tilde paths.
func Parse(line string) Row {
	s := strings.TrimSpace(ansiRe.ReplaceAllString(line, ""))
	s = chipRe.ReplaceAllString(s, "")
	s = gitRe.ReplaceAllString(s, "")
	switch {
	case strings.HasPrefix(s, sessionMark+" "):
		return Row{KindSession, strings.TrimSpace(strings.TrimPrefix(s, sessionMark+" "))}
	case strings.HasPrefix(s, dirMark+" "):
		return Row{KindDir, strings.TrimSpace(strings.TrimPrefix(s, dirMark+" "))}
	case strings.HasPrefix(s, "~") || strings.HasPrefix(s, "/"):
		return Row{KindDir, s}
	default:
		return Row{KindSession, s}
	}
}

// Merge builds the list: sessions first, then ranked dirs that would
// not just recreate a session already listed.
func Merge(sessions []string, rankedDirs []string) []Row {
	rows := make([]Row, 0, len(sessions)+len(rankedDirs))
	taken := make(map[string]bool, len(sessions))
	for _, s := range sessions {
		taken[s] = true
		rows = append(rows, Row{KindSession, s})
	}
	for _, d := range rankedDirs {
		if !taken[tmux.SessionName(expand(d))] {
			rows = append(rows, Row{KindDir, contract(d)})
		}
	}
	return rows
}

// List prints rows for the picker. filter: "" for all, "-t" sessions
// only, "-z" dirs only. A session row wears its repo when git knows
// more than the name does — "tmux" alone hides that it is a rook
// worktree.
func List(filter string) error {
	feed := attention.Load()
	dirs := sessionDirs()
	for _, r := range rows(filter) {
		line := r.Line()
		if r.Kind == KindSession {
			if repo, _ := gitInfo(dirs[r.Value]); repo != "" && repo != r.Value {
				line += "  " + dim + "⎇ " + repo + reset
			}
		}
		state := rowState(r, feed)
		if state != StateNone {
			line += "  " + state.Chip()
		}
		fmt.Println(line)
	}
	return nil
}

// sessionDirs maps each session to its active pane's directory, one
// tmux call for all of them.
func sessionDirs() map[string]string {
	out, err := rookTmux("list-panes", "-a", "-F",
		"#{session_name}\t#{window_active}#{pane_active}\t#{pane_current_path}")
	if err != nil {
		return nil
	}
	dirs := map[string]string{}
	for line := range strings.SplitSeq(strings.TrimSpace(out), "\n") {
		f := strings.Split(line, "\t")
		if len(f) == 3 && f[1] == "11" {
			dirs[f[0]] = f[2]
		}
	}
	return dirs
}

// gitInfo names the checkout a directory lives in: the repo (from the
// common git dir, so worktrees answer with their true home) and the
// branch. Empty when git has nothing to say.
func gitInfo(dir string) (repo, branch string) {
	if dir == "" {
		return "", ""
	}
	out, err := exec.Command("git", "-C", dir, "rev-parse", "--abbrev-ref", "HEAD", "--git-common-dir").Output()
	if err != nil {
		return "", ""
	}
	lines := strings.Split(strings.TrimSpace(string(out)), "\n")
	if len(lines) != 2 {
		return "", ""
	}
	branch = lines[0]
	common := lines[1]
	if !filepath.IsAbs(common) {
		common = filepath.Join(dir, common)
	}
	return filepath.Base(filepath.Dir(common)), branch
}

// ListJSON prints the same rows as machine-readable lines: rook's
// surface for publishers like vera.
func ListJSON(filter string) error {
	feed := attention.Load()
	enc := json.NewEncoder(os.Stdout)
	for _, r := range rows(filter) {
		out := struct {
			Kind      string           `json:"kind"`
			Name      string           `json:"name,omitempty"`
			Path      string           `json:"path,omitempty"`
			Agent     string           `json:"agent,omitempty"`
			Attention []attention.Item `json:"attention,omitempty"`
		}{}
		if r.Kind == KindSession {
			out.Kind, out.Name = "session", r.Value
			out.Agent = sessionAgentState(r.Value).String()
			out.Attention = attention.ForSession(feed, r.Value)
		} else {
			out.Kind, out.Path = "dir", expand(r.Value)
			out.Attention = attention.ForDir(feed, out.Path)
		}
		if err := enc.Encode(out); err != nil {
			return err
		}
	}
	return nil
}

func rows(filter string) []Row {
	var sessions, dirs []string
	if filter != "-z" {
		sessions = liveSessions()
	}
	if filter != "-t" {
		dirs = zoxideDirs()
	}
	return Merge(sessions, dirs)
}

// rowState folds the built-in pane heuristics with the attention feed:
// a feed item that needs a human makes the row wait, whoever wrote it.
func rowState(r Row, feed []attention.Item) AgentState {
	state := StateNone
	var items []attention.Item
	if r.Kind == KindSession {
		state = sessionAgentState(r.Value)
		items = attention.ForSession(feed, r.Value)
	} else {
		items = attention.ForDir(feed, expand(r.Value))
	}
	if attention.AnyWaiting(items) {
		state = state.merge(StateWaiting)
	}
	return state
}

// StateOf is a session's agent state as the picker shows it: the pane
// heuristics folded with the attention feed. StateNone when the session
// doesn't exist or hosts no agent.
func StateOf(session string) AgentState {
	return rowState(Row{KindSession, session}, attention.Load())
}

// agentPanes returns pane-id → window-index for every agent pane in a
// session.
func agentPanes(session string) map[string]string {
	out, err := rookTmux("list-panes", "-s", "-t", "="+session, "-F",
		"#{pane_id}\t#{window_index}\t#{pane_current_command}\t#{pane_title}")
	if err != nil {
		return nil
	}
	panes := map[string]string{}
	for line := range strings.SplitSeq(strings.TrimSpace(out), "\n") {
		f := strings.Split(line, "\t")
		if len(f) >= 4 && IsAgentPane(f[2], f[3]) {
			panes[f[0]] = f[1]
		}
	}
	return panes
}

func paneState(paneID string) AgentState {
	content, err := rookTmux("capture-pane", "-p", "-t", paneID)
	if err != nil {
		return StateNone
	}
	return Classify(content)
}

// sessionAgentState folds every agent pane's state into the one that
// most needs attention; StateNone means no agents at all.
func sessionAgentState(session string) AgentState {
	state := StateNone
	for paneID := range agentPanes(session) {
		state = state.merge(paneState(paneID))
	}
	return state
}

// Connect switches to the row's session, creating it first when the
// row is a directory. Inside tmux it switches the client; outside it
// replaces the process with an attach.
func Connect(raw string) error {
	if strings.TrimSpace(raw) == "" {
		return fmt.Errorf("connect: nothing selected")
	}
	row := Parse(raw)
	name := row.Value
	if row.Kind == KindDir {
		dir := expand(row.Value)
		if info, err := os.Stat(dir); err != nil || !info.IsDir() {
			return fmt.Errorf("connect: %s is not a directory", dir)
		}
		name = tmux.SessionName(dir)
		if !hasSession(name) {
			if out, err := rookTmux("new-session", "-d", "-s", name, "-c", dir); err != nil {
				return fmt.Errorf("creating session %s: %v\n%s", name, err, out)
			}
		}
	}
	if tmux.InsideRook() {
		if out, err := rookTmux("switch-client", "-t", "="+name); err != nil {
			return fmt.Errorf("switching to %s: %v\n%s", name, err, out)
		}
		return nil
	}
	argv, err := attachArgv(name)
	if err != nil {
		return err
	}
	return syscall.Exec(argv[0], argv, os.Environ())
}

// PaneLine renders one pane's bottom border strip: the pane's own git
// place, and — on the active pane only — global info items from the
// attention feed (vera's spend, for one). Subdued by design: the
// border strip whispers, the top bar talks.
func PaneLine(dir string, active bool) error {
	var parts []string
	if repo, branch := gitInfo(dir); repo != "" {
		place := "⎇ " + repo
		if branch != "" && branch != "main" && branch != "master" {
			place += " · " + branch
		}
		parts = append(parts, place)
	}
	if active {
		for _, it := range attention.Load() {
			if it.Kind == "spend" {
				parts = append(parts, it.Headline)
			}
		}
	}
	fmt.Print(strings.Join(parts, "   "))
	return nil
}

// Preview draws the detail card for a row: the right-hand pane of the
// picker. Sessions get their window list with agent panes marked;
// directories get git context and a listing. Attention items pointing
// at the row close the card.
func Preview(raw string) error {
	row := Parse(raw)
	var err error
	var items []attention.Item
	if row.Kind == KindSession {
		err = previewSession(row.Value)
		items = attention.ForSession(attention.Load(), row.Value)
	} else {
		err = previewDir(expand(row.Value))
		items = attention.ForDir(attention.Load(), expand(row.Value))
	}
	if err == nil && len(items) > 0 {
		fmt.Println()
		for _, it := range items {
			mark, style := "·", dim
			if it.Waiting() {
				mark, style = sessionMark, accent+bold
			}
			src := ""
			if it.Source != "" {
				src = dim + "  " + it.Source + reset
			}
			fmt.Printf("%s%s %s%s%s\n", style, mark, it.Headline, reset, src)
		}
	}
	return err
}

func previewSession(name string) error {
	fmt.Printf("%s%s♜ %s%s\n", bold, accent, name, reset)
	if dir := sessionDirs()[name]; dir != "" {
		fmt.Printf("%s%s%s\n", dim, contract(dir), reset)
		if repo, branch := gitInfo(dir); repo != "" {
			fmt.Printf("%s⎇ %s · %s%s\n", accent, repo, branch, reset)
		}
	}
	fmt.Println()
	out, err := rookTmux("list-windows", "-t", "="+name, "-F",
		"#{window_index}\t#{window_name}\t#{window_active}\t#{window_panes}")
	if err != nil {
		return fmt.Errorf("no such session: %s", name)
	}

	// window index → most attention-needing agent state in it
	windowState := map[string]AgentState{}
	for paneID, window := range agentPanes(name) {
		windowState[window] = windowState[window].merge(paneState(paneID))
	}

	for line := range strings.SplitSeq(strings.TrimSpace(out), "\n") {
		f := strings.Split(line, "\t")
		if len(f) < 4 {
			continue
		}
		style, mark := dim, "  "
		if f[2] == "1" {
			style, mark = accent, "▸ "
		}
		agent := ""
		if state, ok := windowState[f[0]]; ok && state != StateNone {
			agent = "  " + state.Chip()
		}
		panes := ""
		if f[3] != "1" {
			panes = dim + "  " + f[3] + " panes" + reset
		}
		fmt.Printf("%s%s%s·%s%s%s%s\n", style, mark, f[0], f[1], reset, agent, panes)
	}
	return nil
}

func previewDir(dir string) error {
	fmt.Printf("%s%s○ %s%s\n", bold, dim, contract(dir), reset)
	if branch, err := exec.Command("git", "-C", dir, "branch", "--show-current").Output(); err == nil {
		if b := strings.TrimSpace(string(branch)); b != "" {
			fmt.Printf("%s⎇ %s%s\n", accent, b, reset)
		}
	}
	fmt.Println()
	entries, err := os.ReadDir(dir)
	if err != nil {
		return err
	}
	shown := 0
	for _, e := range entries {
		if strings.HasPrefix(e.Name(), ".") {
			continue
		}
		if e.IsDir() {
			fmt.Printf("%s%s/%s\n", dim, e.Name(), reset)
		} else {
			fmt.Println(e.Name())
		}
		if shown++; shown >= 20 {
			fmt.Printf("%s…%s\n", dim, reset)
			break
		}
	}
	return nil
}

// liveSessions asks the rook server; a down server just means none.
func liveSessions() []string {
	out, err := rookTmux("list-sessions", "-F", "#{session_name}")
	if err != nil {
		return nil
	}
	return strings.Fields(strings.TrimSpace(out))
}

func zoxideDirs() []string {
	out, err := exec.Command("zoxide", "query", "-l").Output()
	if err != nil {
		return nil
	}
	var dirs []string
	for line := range strings.SplitSeq(strings.TrimSpace(string(out)), "\n") {
		if line != "" {
			dirs = append(dirs, line)
		}
	}
	return dirs
}

func hasSession(name string) bool { return tmux.HasSession(name) }

// rookTmux runs a tmux command against the rook server.
func rookTmux(cmd ...string) (string, error) { return tmux.Run(cmd...) }

func attachArgv(name string) ([]string, error) {
	return tmux.RunArgv("attach-session", "-t", "="+name)
}

func expand(path string) string {
	if path == "~" || strings.HasPrefix(path, "~/") {
		if home, err := os.UserHomeDir(); err == nil {
			return filepath.Join(home, strings.TrimPrefix(path[1:], "/"))
		}
	}
	return path
}

func contract(path string) string {
	if home, err := os.UserHomeDir(); err == nil {
		if path == home {
			return "~"
		}
		if strings.HasPrefix(path, home+"/") {
			return "~" + strings.TrimPrefix(path, home)
		}
	}
	return path
}
