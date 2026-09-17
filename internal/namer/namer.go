// Package namer gives tabs better names than the first program that
// ran in them. It watches the engine's state feed, and for every tab a
// person has not named by hand it gathers what the tab holds — the
// project, the branch, the program, the title, the recent screen —
// hands that to a command on stdin, and offers the command's one line
// of stdout back to the engine as a suggestion (`rook rename
// --suggest`). The engine, not the namer, decides whether it lands: a
// name given by hand is final.
//
// The command is a seam, not a dependency. The default is `wisp name`
// (the model Apple ships on the Mac); anything that reads context and
// prints a name will do. No command on PATH means no namer, and the
// tabs keep the names rook mints for itself.
package namer

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"
)

// DefaultCommand is what names tabs when the config says nothing.
const DefaultCommand = "wisp name"

const (
	// maxName is the engine's own cap on a tab name, in bytes.
	maxName = 32
	// settle is how long a tab's facts must hold still before they
	// are worth a question: a `cd` on the way somewhere is not a place.
	settle = 8 * time.Second
	// refresh is how often a tab whose facts have not changed is asked
	// about again, if it has printed anything since: work drifts
	// inside one long-lived agent pane.
	refresh = 10 * time.Minute
	// screenLines and screenBytes bound what the command is shown.
	screenLines = 40
	screenBytes = 2500
)

// Options configures a Namer. Engine and Ask are seams for tests.
type Options struct {
	// Command is the namer command line, split on spaces.
	Command string
	// Engine runs the engine CLI and returns its stdout.
	Engine func(args ...string) (string, error)
	// Ask runs the namer command over a context and returns its name.
	// Nil means exec Command.
	Ask func(ctx context.Context, tabContext string) (string, error)
	// Git answers the two questions asked of a directory. Nil means
	// the real git.
	Git func(dir string) (project, branch string)
	// Now is the clock. Nil means time.Now.
	Now func() time.Time
	// Logf reports what the namer did. Nil means silence.
	Logf func(format string, args ...any)
}

// Namer is the loop's memory: what each tab looked like when it was
// last asked about.
type Namer struct {
	opt  Options
	tabs map[string]*tab
}

type tab struct {
	sig      string    // the facts, as last seen
	since    time.Time // when the facts last changed
	askedSig string    // the facts the last question was about
	askedAt  time.Time
	outputMs int64  // the pane's lastOutputMs at the last question
	pending  string // a refresh's new name, waiting to be said twice
}

// New returns a Namer. It does nothing until Tick is called.
func New(opt Options) *Namer {
	if opt.Command == "" {
		opt.Command = DefaultCommand
	}
	if opt.Now == nil {
		opt.Now = time.Now
	}
	if opt.Git == nil {
		opt.Git = gitFacts
	}
	if opt.Logf == nil {
		opt.Logf = func(string, ...any) {}
	}
	n := &Namer{opt: opt, tabs: map[string]*tab{}}
	if n.opt.Ask == nil {
		n.opt.Ask = n.execAsk
	}
	return n
}

// Available reports whether the namer command can be found at all.
func (n *Namer) Available() bool {
	f := strings.Fields(n.opt.Command)
	if len(f) == 0 {
		return false
	}
	_, err := exec.LookPath(f[0])
	return err == nil
}

// Run ticks until ctx is done. A missing command is looked for again
// each minute, so installing one later needs no restart.
func (n *Namer) Run(ctx context.Context, every time.Duration) {
	t := time.NewTicker(every)
	defer t.Stop()
	var lastLook time.Time
	ok := false
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
		if !ok && time.Since(lastLook) >= time.Minute {
			lastLook = time.Now()
			if ok = n.Available(); ok {
				n.opt.Logf("namer: naming tabs with %q", n.opt.Command)
			}
		}
		if ok {
			n.Tick(ctx)
		}
	}
}

type feed struct {
	Workspaces []struct {
		Name    string `json:"name"`
		Windows []struct {
			Name   string          `json:"name"`
			NameBy string          `json:"nameBy"`
			Layout json.RawMessage `json:"layout"`
		} `json:"windows"`
	} `json:"workspaces"`
	Panes []pane `json:"panes"`
}

type pane struct {
	ID           int    `json:"id"`
	Program      string `json:"program"`
	Cwd          string `json:"cwd"`
	Title        string `json:"title"`
	Exited       bool   `json:"exited"`
	LastOutputMs int64  `json:"lastOutputMs"`
}

// Tick looks at every tab once and asks about the ones that are due.
func (n *Namer) Tick(ctx context.Context) {
	raw, err := n.opt.Engine("state")
	if err != nil {
		return
	}
	var f feed
	if json.Unmarshal([]byte(raw), &f) != nil {
		return
	}
	panes := map[int]pane{}
	for _, p := range f.Panes {
		panes[p.ID] = p
	}
	now := n.opt.Now()
	live := map[string]bool{}
	for _, ws := range f.Workspaces {
		for _, w := range ws.Windows {
			ids := paneIDs(w.Layout)
			if len(ids) == 0 {
				continue
			}
			// the pane the window was born with speaks for it: focus
			// moving between splits must not rename the tab
			p, ok := panes[ids[0]]
			if !ok || p.Exited {
				continue
			}
			key := fmt.Sprintf("%s/%d", ws.Name, p.ID)
			live[key] = true
			// an engine too old to say whose word a name is would
			// also ignore a suggestion: asking would be pure waste
			if w.NameBy == "" {
				continue
			}
			if w.NameBy == "hand" {
				delete(n.tabs, key)
				continue
			}
			n.consider(ctx, key, w.Name, p, now)
		}
	}
	for k := range n.tabs {
		if !live[k] {
			delete(n.tabs, k)
		}
	}
}

func (n *Namer) consider(ctx context.Context, key, current string, p pane, now time.Time) {
	// a shell that has never printed has nothing to be named after
	if p.LastOutputMs == 0 {
		return
	}
	project, branch := n.opt.Git(p.Cwd)
	title := cleanTitle(p.Title)
	sig := strings.Join([]string{p.Cwd, branch, p.Program, title}, "\x1f")
	t := n.tabs[key]
	if t == nil {
		t = &tab{sig: sig, since: now}
		n.tabs[key] = t
	}
	if t.sig != sig {
		t.sig, t.since, t.pending = sig, now, ""
	}
	changed := t.askedSig != sig
	switch {
	case changed && now.Sub(t.since) >= settle:
	case !changed && now.Sub(t.askedAt) >= refresh && p.LastOutputMs > t.outputMs:
	default:
		return
	}
	t.askedSig, t.askedAt, t.outputMs = sig, now, p.LastOutputMs

	screen, _ := n.opt.Engine("read", fmt.Sprint(p.ID), "-n", fmt.Sprint(screenLines))
	actx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	name, err := n.opt.Ask(actx, Context(project, p, branch, title, screen))
	if err != nil {
		n.opt.Logf("namer: pane %d: %v", p.ID, err)
		return
	}
	name = Clamp(name)
	if name == "" || name == current || strings.EqualFold(name, p.Program) {
		t.pending = ""
		return
	}
	// New facts earn a new name at once. The same facts, asked about
	// again, must give the same new answer twice: a name that flickers
	// is worse than a name that is a little stale.
	if !changed && t.pending != name {
		t.pending = name
		t.askedAt = now.Add(-refresh + time.Minute)
		return
	}
	t.pending = ""
	if _, err := n.opt.Engine("rename", "--suggest", fmt.Sprint(p.ID), name); err != nil {
		n.opt.Logf("namer: pane %d: %v", p.ID, err)
		return
	}
	n.opt.Logf("namer: pane %d: %q → %q", p.ID, current, name)
}

// Context is what a namer command reads on stdin: facts first, one
// per line, then the recent screen. It is the whole contract.
func Context(project string, p pane, branch, title, screen string) string {
	var b strings.Builder
	home, _ := os.UserHomeDir()
	cwd := p.Cwd
	if home != "" && strings.HasPrefix(cwd, home) {
		cwd = "~" + cwd[len(home):]
	}
	if project != "" {
		fmt.Fprintf(&b, "project: %s\n", project)
	}
	fmt.Fprintf(&b, "cwd: %s\nbranch: %s\nprogram: %s\ntitle: %s\nscreen:\n", cwd, branch, p.Program, title)
	var lines []string
	for _, l := range strings.Split(screen, "\n") {
		if l = strings.TrimRight(l, " \t\r"); l != "" {
			lines = append(lines, l)
		}
	}
	s := strings.Join(lines, "\n")
	if len(s) > screenBytes {
		s = s[len(s)-screenBytes:]
		if i := strings.IndexByte(s, '\n'); i >= 0 {
			s = s[i+1:]
		}
	}
	b.WriteString(s)
	b.WriteByte('\n')
	return b.String()
}

// Clamp makes a command's answer fit a tab: its first line, no control
// characters, at most the engine's 32 bytes, cut on a rune and then
// back to a whole word.
func Clamp(s string) string {
	if i := strings.IndexAny(s, "\r\n"); i >= 0 {
		s = s[:i]
	}
	s = strings.Map(func(r rune) rune {
		if unicode.IsControl(r) {
			return -1
		}
		return r
	}, strings.TrimSpace(s))
	if len(s) <= maxName {
		return s
	}
	cut := s[:maxName]
	for !utf8.ValidString(cut) {
		cut = cut[:len(cut)-1]
	}
	// a cut that fell inside a word takes the whole word with it
	if s[len(cut)] != ' ' {
		if i := strings.LastIndexByte(cut, ' '); i > 0 {
			cut = cut[:i]
		}
	}
	return strings.TrimSpace(cut)
}

// cleanTitle drops what a program animates in its title — Claude
// Code's spinner glyph — so a title that only spins is not news.
func cleanTitle(t string) string {
	return strings.TrimLeftFunc(t, func(r rune) bool {
		return !unicode.IsLetter(r) && !unicode.IsDigit(r)
	})
}

// paneIDs walks a window's layout tree and returns its pane ids,
// lowest first: the lowest is the pane the window was born with.
func paneIDs(layout json.RawMessage) []int {
	var ids []int
	var walk func(v any)
	walk = func(v any) {
		switch x := v.(type) {
		case map[string]any:
			if id, ok := x["pane"].(float64); ok {
				ids = append(ids, int(id))
			}
			for k, c := range x {
				if k != "pane" {
					walk(c)
				}
			}
		case []any:
			for _, c := range x {
				walk(c)
			}
		}
	}
	var v any
	if json.Unmarshal(layout, &v) == nil {
		walk(v)
	}
	sort.Ints(ids)
	return ids
}

// gitFacts names the project and branch of a directory. The project is
// the repository's own name even from inside a linked worktree, whose
// directory is usually named for the branch instead. Outside a
// repository the project is the directory, and home is no project.
func gitFacts(dir string) (project, branch string) {
	if dir == "" {
		return "", ""
	}
	git := func(args ...string) string {
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		defer cancel()
		out, err := exec.CommandContext(ctx, "git", append([]string{"-C", dir}, args...)...).Output()
		if err != nil {
			return ""
		}
		return strings.TrimSpace(string(out))
	}
	if common := git("rev-parse", "--path-format=absolute", "--git-common-dir"); common != "" {
		project = filepath.Base(filepath.Dir(common))
		if filepath.Base(common) != ".git" { // a bare repository
			project = strings.TrimSuffix(filepath.Base(common), ".git")
		}
		branch = git("branch", "--show-current")
		return strings.ToLower(project), branch
	}
	if home, _ := os.UserHomeDir(); dir == home || dir == "/" {
		return "", ""
	}
	return strings.ToLower(filepath.Base(dir)), ""
}

func (n *Namer) execAsk(ctx context.Context, tabContext string) (string, error) {
	f := strings.Fields(n.opt.Command)
	cmd := exec.CommandContext(ctx, f[0], f[1:]...)
	cmd.Stdin = strings.NewReader(tabContext)
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	out, err := cmd.Output()
	if err != nil {
		return "", fmt.Errorf("%s: %v: %s", f[0], err, strings.TrimSpace(stderr.String()))
	}
	return string(out), nil
}
