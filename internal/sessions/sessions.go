// Package sessions is rook's own session model — the layer that used
// to be delegated to sesh. A row is either a live session on the rook
// server or a zoxide-ranked directory that could become one; rook owns
// listing, the detail card, and connect-or-create (including naming,
// which is how the full-path session names died).
package sessions

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"syscall"

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

var ansiRe = regexp.MustCompile(`\x1b\[[0-9;]*m`)

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
// only, "-z" dirs only.
func List(filter string) error {
	var sessions, dirs []string
	if filter != "-z" {
		sessions = liveSessions()
	}
	if filter != "-t" {
		dirs = zoxideDirs()
	}
	for _, r := range Merge(sessions, dirs) {
		fmt.Println(r.Line())
	}
	return nil
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
	if os.Getenv("TMUX") != "" {
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

// Preview draws the detail card for a row: the right-hand pane of the
// picker. Sessions get their window list with agent panes marked;
// directories get git context and a listing.
func Preview(raw string) error {
	row := Parse(raw)
	if row.Kind == KindSession {
		return previewSession(row.Value)
	}
	return previewDir(expand(row.Value))
}

func previewSession(name string) error {
	fmt.Printf("%s%s♜ %s%s\n\n", bold, accent, name, reset)
	out, err := rookTmux("list-windows", "-t", "="+name, "-F",
		"#{window_index}\t#{window_name}\t#{window_active}\t#{window_panes}")
	if err != nil {
		return fmt.Errorf("no such session: %s", name)
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
		if f[1] == "claude" {
			agent = "  " + accent + sessionMark + " agent" + reset
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

func hasSession(name string) bool {
	_, err := rookTmux("has-session", "-t", "="+name)
	return err == nil
}

// rookTmux runs a tmux command against the rook server, conf included
// so a down server boots as rook, never as stock tmux.
func rookTmux(cmd ...string) (string, error) {
	argv, err := rookArgv(cmd...)
	if err != nil {
		return "", err
	}
	out, err := exec.Command(argv[0], argv[1:]...).CombinedOutput()
	return string(out), err
}

func attachArgv(name string) ([]string, error) {
	return rookArgv("attach-session", "-t", "="+name)
}

func rookArgv(cmd ...string) ([]string, error) {
	confPath, err := tmux.ConfPath()
	if err != nil {
		return nil, err
	}
	if _, err := os.Stat(confPath); err != nil {
		if _, err := tmux.WriteConf(tmux.Defaults()); err != nil {
			return nil, err
		}
	}
	return tmux.Argv(confPath, cmd...)
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
