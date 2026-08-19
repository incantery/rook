// rook-plugin-start — the start screen.
//
// What a bare `re` shows over an empty scratch buffer: a header, the
// files you were last in, what git thinks changed, which agent sessions
// are alive, and the four or five gestures worth a letter. alpha-nvim's
// startify theme is the ancestor, and the debt is deliberate — a start
// screen is a thing people have opinions about, and the shape those
// opinions have already settled on is worth inheriting.
//
// It speaks the rook plugin protocol (man 7 rook-plugin) over stdio and
// answers exactly one outbound verb, `intro.list`. Rows say WHAT they
// are — art, heading, entry, blank — and what pressing one reaches: a
// path to open, or a command id to run. Where any of it lands on the
// grid is rook's, which is why this file has no widths in it.
//
// Everything it reads already exists. The recency comes from rook's own
// oldfiles journal (the app appends every file it opens); git is asked
// through git; the sessions are the transcripts Claude Code writes. It
// stores nothing and asks nothing of anybody.
package main

import (
	"bufio"
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/incantery/rook/plugins/internal/transcript"
)

const version = "0.1.0"

// The header. ANSI Shadow, because it is the one every dashboard in
// this genre is written in and rook is not the place to be original
// about that. Overridable with --art: a start screen you cannot put
// your own name on is somebody else's start screen.
var defaultArt = []string{
	`██████╗  ██████╗  ██████╗ ██╗  ██╗`,
	`██╔══██╗██╔═══██╗██╔═══██╗██║ ██╔╝`,
	`██████╔╝██║   ██║██║   ██║█████╔╝ `,
	`██╔══██╗██║   ██║██║   ██║██╔═██╗ `,
	`██║  ██║╚██████╔╝╚██████╔╝██║  ██╗`,
	`╚═╝  ╚═╝ ╚═════╝  ╚═════╝ ╚═╝  ╚═╝`,
}

// The letters the action rows keep. Files and changes draw from
// everything else, so a jump letter never means two things — the one
// property this screen has to hold, since the human presses a letter
// before reading what it is next to.
var actionKeys = map[byte]bool{'f': true, 'p': true, 'w': true, 'g': true, 'q': true}

// The pool, in the order it is handed out. `a` first because it is the
// most recent file and the one your hand goes to.
const filePool = "abcdehijklmnorstuvxyz"

// row is one line of the model. The wire shape, verbatim.
type row struct {
	Kind   string `json:"kind"`
	Key    string `json:"key,omitempty"`
	Label  string `json:"label,omitempty"`
	Detail string `json:"detail,omitempty"`
	Path   string `json:"path,omitempty"`
	Cmd    string `json:"cmd,omitempty"`
}

type builder struct {
	journal  string        // the oldfiles journal rook writes
	projects string        // ~/.claude/projects
	art      []string      // header lines
	recent   int           // most files listed in one section
	changed  int           // most git entries listed
	sessions int           // most agent sessions listed
	window   time.Duration // how far back a session counts as alive
	now      func() time.Time
	// git answers `git -C dir <args...>`; a field so the tests do not
	// need a repository on disk to prove the sections.
	git func(dir string, args ...string) (string, error)
}

func main() {
	journal := flag.String("journal", defaultJournal(), "rook's oldfiles journal")
	projects := flag.String("projects", "", "Claude Code projects directory (default ~/.claude/projects)")
	art := flag.String("art", "", "file of header lines, one per row (default: rook's own)")
	recent := flag.Int("recent", 8, "most recent files listed per section")
	changed := flag.Int("changed", 5, "most changed files listed")
	sessions := flag.Int("sessions", 4, "most agent sessions listed")
	window := flag.Duration("window", 12*time.Hour, "how far back a session counts as alive")
	flag.Parse()

	if *projects == "" {
		if home, err := os.UserHomeDir(); err == nil {
			*projects = filepath.Join(home, ".claude", "projects")
		}
	}
	b := &builder{
		journal:  *journal,
		projects: *projects,
		art:      readArt(*art),
		recent:   *recent,
		changed:  *changed,
		sessions: *sessions,
		window:   *window,
		now:      time.Now,
		git:      runGit,
	}
	serve(b, os.Stdin, os.Stdout)
}

func defaultJournal() string {
	if x := os.Getenv("XDG_STATE_HOME"); x != "" {
		return filepath.Join(x, "rook", "oldfiles")
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return filepath.Join(home, ".local", "state", "rook", "oldfiles")
}

func readArt(path string) []string {
	if path == "" {
		return defaultArt
	}
	data, err := os.ReadFile(path)
	if err != nil {
		// A missing art file is not a reason to have no start screen.
		fmt.Fprintf(os.Stderr, "start: %v — using the built-in header\n", err)
		return defaultArt
	}
	lines := strings.Split(strings.TrimRight(string(data), "\n"), "\n")
	if len(lines) == 0 || (len(lines) == 1 && lines[0] == "") {
		return defaultArt
	}
	return lines
}

type reply struct {
	V      int    `json:"v"`
	ID     uint64 `json:"id"`
	OK     bool   `json:"ok"`
	Result any    `json:"result,omitempty"`
	Error  string `json:"error,omitempty"`
}

func serve(b *builder, in *os.File, out *os.File) {
	sc := bufio.NewScanner(in)
	sc.Buffer(make([]byte, 64*1024), 2*1024*1024)
	enc := json.NewEncoder(out)
	for sc.Scan() {
		var req struct {
			ID     uint64 `json:"id"`
			Op     string `json:"op"`
			Params struct {
				Root string `json:"root"`
			} `json:"params"`
		}
		if json.Unmarshal(sc.Bytes(), &req) != nil {
			continue
		}
		switch req.Op {
		case "describe":
			enc.Encode(reply{1, req.ID, true, map[string]any{
				"name":         "start",
				"version":      version,
				"capabilities": []string{"intro.list"},
				"surfaces":     []string{"INTRO"},
			}, ""})
		case "intro.list":
			enc.Encode(reply{1, req.ID, true, map[string]any{
				"rows": b.build(req.Params.Root),
			}, ""})
		case "":
			// rook answering something we asked. We never ask.
		default:
			enc.Encode(reply{1, req.ID, false, nil, "start does not do " + req.Op})
		}
	}
}

// build assembles the whole screen for a pane rooted at `root`.
//
// Sections are dropped WHOLE when they are empty — a heading over
// nothing is a screen telling you it failed to find something, which is
// worse than a shorter screen. Order is by how often a hand reaches for
// it: the files you were in, then what you changed, then what is
// running, then the gestures, which never move because a fixed letter
// you can press without reading is the point of them.
func (b *builder) build(root string) []row {
	out := make([]row, 0, 48)
	for _, a := range b.art {
		out = append(out, row{Kind: "art", Label: a})
	}
	if line := b.headline(root); line != "" {
		out = append(out, row{Kind: "blank"})
		out = append(out, row{Kind: "art", Label: line})
	}

	keys := newKeyPool()
	here, elsewhere := b.recentFiles(root)

	if len(here) > 0 {
		out = append(out, row{Kind: "blank"})
		out = append(out, row{Kind: "heading", Label: "recent in " + tildeShort(base(root))})
		out = append(out, b.fileRows(here, root, keys)...)
	}
	if len(elsewhere) > 0 {
		out = append(out, row{Kind: "blank"})
		out = append(out, row{Kind: "heading", Label: "recent"})
		out = append(out, b.fileRows(elsewhere, "", keys)...)
	}
	if changed := b.changedFiles(root, keys); len(changed) > 0 {
		out = append(out, row{Kind: "blank"})
		out = append(out, row{Kind: "heading", Label: "changed"})
		out = append(out, changed...)
	}
	if live := b.agentSessions(root); len(live) > 0 {
		out = append(out, row{Kind: "blank"})
		out = append(out, row{Kind: "heading", Label: "sessions"})
		out = append(out, live...)
	}

	out = append(out, row{Kind: "blank"})
	out = append(out, row{Kind: "heading", Label: "go"})
	out = append(out,
		row{Kind: "entry", Key: "f", Label: "find a file", Cmd: "palette.files"},
		row{Kind: "entry", Key: "p", Label: "command palette", Cmd: "palette.commands"},
		row{Kind: "entry", Key: "w", Label: "switch workspace", Cmd: "workspace.switch"},
		row{Kind: "entry", Key: "g", Label: "edit config", Cmd: "config.edit"},
		row{Kind: "entry", Key: "q", Label: "close this pane", Cmd: "pane.close"},
	)
	return out
}

// headline is the one line under the art: where you are, and what git
// says about it. Empty outside a repository — "no branch" is not news.
func (b *builder) headline(root string) string {
	if root == "" {
		return ""
	}
	branch, err := b.git(root, "rev-parse", "--abbrev-ref", "HEAD")
	if err != nil {
		return ""
	}
	branch = strings.TrimSpace(branch)
	if branch == "" {
		return ""
	}
	line := base(root) + " · " + branch
	if st, err := b.git(root, "status", "--porcelain"); err == nil {
		if n := len(nonEmptyLines(st)); n > 0 {
			line += fmt.Sprintf(" · %d changed", n)
		}
	}
	return line
}

// recentFiles splits the journal into "in this repo" and "everywhere
// else", newest first, dropping what no longer exists.
//
// The two lists are separate because they answer different questions.
// "What was I doing here" is the one you ask nine times out of ten, and
// a single list sorted by time buries it under whatever you touched in
// another project ten minutes ago.
func (b *builder) recentFiles(root string) (here, elsewhere []string) {
	data, err := os.ReadFile(b.journal)
	if err != nil {
		return nil, nil
	}
	prefix := ""
	if root != "" {
		prefix = strings.TrimSuffix(root, "/") + "/"
	}
	for _, p := range nonEmptyLines(string(data)) {
		if len(here) >= b.recent && len(elsewhere) >= b.recent {
			break
		}
		// Stat rather than trust: a journal entry outlives its file,
		// and a row you press that opens an empty buffer is a row that
		// lied. (One stat per line, ~16 lines — cheaper than the
		// process rook spawned to ask.)
		if st, err := os.Stat(p); err != nil || st.IsDir() {
			continue
		}
		if prefix != "" && strings.HasPrefix(p, prefix) {
			if len(here) < b.recent {
				here = append(here, p)
			}
			continue
		}
		if len(elsewhere) < b.recent {
			elsewhere = append(elsewhere, p)
		}
	}
	return here, elsewhere
}

func (b *builder) fileRows(paths []string, root string, keys *keyPool) []row {
	out := make([]row, 0, len(paths))
	now := b.now()
	for _, p := range paths {
		label := p
		if root != "" {
			label = strings.TrimPrefix(p, strings.TrimSuffix(root, "/")+"/")
		} else {
			label = tildeShort(p)
		}
		detail := ""
		if st, err := os.Stat(p); err == nil {
			detail = transcript.RelAge(now.Sub(st.ModTime()))
		}
		out = append(out, row{
			Kind:   "entry",
			Key:    keys.take(),
			Label:  shortPath(label, 96),
			Detail: detail,
			Path:   p,
		})
	}
	return out
}

// changedFiles is git's answer, not the journal's: what you changed is
// where you are, whether or not you opened it in rook.
func (b *builder) changedFiles(root string, keys *keyPool) []row {
	if root == "" {
		return nil
	}
	st, err := b.git(root, "status", "--porcelain")
	if err != nil {
		return nil
	}
	out := make([]row, 0, b.changed)
	for _, line := range nonEmptyLines(st) {
		if len(out) >= b.changed {
			break
		}
		// `XY path`, and for a rename `XY old -> new`. The new name is
		// the one that exists to be opened.
		if len(line) < 4 {
			continue
		}
		status := strings.TrimSpace(line[:2])
		p := strings.TrimSpace(line[3:])
		if i := strings.Index(p, " -> "); i >= 0 {
			p = p[i+4:]
		}
		p = strings.Trim(p, `"`)
		abs := filepath.Join(root, p)
		if st, err := os.Stat(abs); err != nil || st.IsDir() {
			continue // deleted, or a directory of untracked files
		}
		out = append(out, row{
			Kind:   "entry",
			Key:    keys.take(),
			Label:  shortPath(p, 96),
			Detail: status,
			Path:   abs,
		})
	}
	return out
}

// agentSessions is what is alive right now, in this repo when there is
// one. No keys: a row you cannot press is honest here, because opening
// a transcript is not what anybody wants from a session — they want the
// pane it is in, and reaching that from an empty editor is not a thing
// this screen can do yet.
func (b *builder) agentSessions(root string) []row {
	if b.projects == "" {
		return nil
	}
	sc := &transcript.Scanner{
		Dir:    b.projects,
		Window: b.window,
		Idle:   10 * time.Minute,
		Quiet:  60 * time.Second,
		Max:    b.sessions * 4,
	}
	now := b.now()
	out := make([]row, 0, b.sessions)
	sessions := sc.Scan(now)
	// In-repo first, everything else after — the same reason the
	// recents are split.
	if root != "" {
		sort.SliceStable(sessions, func(i, j int) bool {
			return sameRepo(sessions[i].Cwd, root) && !sameRepo(sessions[j].Cwd, root)
		})
	}
	for _, s := range sessions {
		if len(out) >= b.sessions {
			break
		}
		label := transcript.Snip(s.Title, 72)
		if label == "" {
			label = transcript.Snip(s.Prompt, 72)
		}
		if label == "" {
			continue
		}
		out = append(out, row{
			Kind:   "entry",
			Label:  label,
			Detail: string(s.State),
		})
	}
	return out
}

// keyPool hands out jump letters, never twice and never one an action
// row has already claimed.
type keyPool struct{ i int }

func newKeyPool() *keyPool { return &keyPool{} }

func (k *keyPool) take() string {
	for k.i < len(filePool) {
		c := filePool[k.i]
		k.i++
		if actionKeys[c] {
			continue
		}
		return string(c)
	}
	return "" // out of letters: the row is still text, still readable
}

func runGit(dir string, args ...string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, "git", append([]string{"-C", dir}, args...)...)
	// A start screen must not inherit a pager or a colour opinion.
	cmd.Env = append(os.Environ(), "GIT_PAGER=cat", "GIT_OPTIONAL_LOCKS=0")
	out, err := cmd.Output()
	if err != nil {
		return "", err
	}
	return string(out), nil
}

func nonEmptyLines(s string) []string {
	out := []string{}
	for l := range strings.SplitSeq(s, "\n") {
		if strings.TrimSpace(l) != "" {
			out = append(out, l)
		}
	}
	return out
}

func base(path string) string {
	if path == "" {
		return ""
	}
	return filepath.Base(strings.TrimSuffix(path, "/"))
}

func sameRepo(cwd, root string) bool {
	if cwd == "" || root == "" {
		return false
	}
	root = strings.TrimSuffix(root, "/")
	return cwd == root || strings.HasPrefix(cwd, root+"/")
}

// shortPath trims a path from the LEFT, which is the only end it can
// be trimmed from. The tail is the filename — the thing you are looking
// for — and a row that ends in "…" has thrown away the word the eye was
// scanning for and kept the directory it already knew.
func shortPath(path string, max int) string {
	if len(path) <= max {
		return path
	}
	cut := len(path) - max + len("…")
	// Onto a separator where there is one nearby, so the result reads
	// as a path rather than as a word cut in half.
	if i := strings.Index(path[cut:], "/"); i >= 0 && i < 24 {
		cut += i + 1
	}
	return "…" + path[cut:]
}

func tildeShort(path string) string {
	home, err := os.UserHomeDir()
	if err != nil || home == "" || !strings.HasPrefix(path, home+"/") {
		return path
	}
	return "~" + strings.TrimPrefix(path, home)
}
