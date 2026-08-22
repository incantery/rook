// Package ui is the worktree manager's face: a Bubble Tea program that
// draws the repo's worktrees with live state and runs the lifecycle
// verbs on them. One program for both homes — `rook wt` standalone in
// a terminal, and the prefix-w tmux popup — because it draws to
// whatever size it is given.
package ui

import (
	"fmt"
	"strings"
	"time"

	"github.com/charmbracelet/bubbles/textinput"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"

	"github.com/incantery/rook/internal/sessions"
	"github.com/incantery/rook/internal/tmux"
	"github.com/incantery/rook/internal/tui"
	"github.com/incantery/rook/internal/worktree"
)

var (
	accent   = tui.Accent
	dim      = tui.Dim
	bold     = tui.Bold
	selected = tui.Selected
	errStyle = tui.Err
)

const refreshEvery = 2 * time.Second

type mode int

const (
	modeList mode = iota
	modeNaming
	modeConfirm
	modeBusy
)

type row struct {
	worktree.Worktree
	State sessions.AgentState
}

type rowsMsg struct {
	rows []row
	err  error
}

type tickMsg struct{}

type doneMsg struct {
	note string
	err  error
	// attach names a session to land in when the program exits.
	attach string
}

type model struct {
	repo   worktree.Repo
	opts   worktree.Options
	rows   []row
	cursor int
	width  int
	height int
	mode   mode
	input  textinput.Model
	// confirm is the pending destructive verb: "merge" or "remove".
	confirm string
	force   bool
	note    string
	err     error
	attach  string
}

// Run shows the manager and blocks until it exits. It returns the
// session to attach to, when the user opened a worktree from outside
// rook (inside rook the client has already switched).
func Run(repo worktree.Repo, opts worktree.Options) (attach string, err error) {
	in := textinput.New()
	in.Prompt = accent.Render("new worktree ") + dim.Render(repo.Name+"--")
	in.CharLimit = 64
	m := model{repo: repo, opts: opts, input: in}
	out, err := tea.NewProgram(m, tea.WithAltScreen()).Run()
	if err != nil {
		return "", err
	}
	final := out.(model)
	return final.attach, final.err
}

func (m model) Init() tea.Cmd {
	return tea.Batch(m.load(), tick())
}

func tick() tea.Cmd {
	return tea.Tick(refreshEvery, func(time.Time) tea.Msg { return tickMsg{} })
}

// load re-reads the worktrees and each live session's agent state, off
// the UI thread.
func (m model) load() tea.Cmd {
	repo := m.repo
	return func() tea.Msg {
		wts, err := repo.List()
		if err != nil {
			return rowsMsg{err: err}
		}
		rows := make([]row, len(wts))
		for i, wt := range wts {
			rows[i] = row{Worktree: wt}
			if wt.Live {
				rows[i].State = sessions.StateOf(wt.Session)
			}
		}
		return rowsMsg{rows: rows}
	}
}

func (m model) current() (row, bool) {
	if m.cursor < 0 || m.cursor >= len(m.rows) {
		return row{}, false
	}
	return m.rows[m.cursor], true
}

func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width, m.height = msg.Width, msg.Height
		return m, nil
	case tickMsg:
		if m.mode == modeBusy {
			return m, tick()
		}
		return m, tea.Batch(m.load(), tick())
	case rowsMsg:
		if msg.err != nil {
			m.err = msg.err
			return m, nil
		}
		// keep the cursor on the same worktree across a reload
		var keep string
		if cur, ok := m.current(); ok {
			keep = cur.Path
		}
		m.rows = msg.rows
		m.cursor = 0
		for i, r := range m.rows {
			if r.Path == keep {
				m.cursor = i
			}
		}
		return m, nil
	case doneMsg:
		m.mode = modeList
		m.err, m.note = msg.err, msg.note
		if msg.attach != "" || (msg.err == nil && msg.note == "opened") {
			m.attach = msg.attach
			return m, tea.Quit
		}
		return m, m.load()
	case tea.KeyMsg:
		switch m.mode {
		case modeNaming:
			return m.updateNaming(msg)
		case modeConfirm:
			return m.updateConfirm(msg)
		case modeBusy:
			if msg.String() == "ctrl+c" {
				return m, tea.Quit
			}
			return m, nil
		}
		return m.updateList(msg)
	}
	return m, nil
}

func (m model) updateList(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	m.err, m.note = nil, ""
	switch msg.String() {
	case "q", "esc", "ctrl+c":
		return m, tea.Quit
	case "j", "down":
		if m.cursor < len(m.rows)-1 {
			m.cursor++
		}
	case "k", "up":
		if m.cursor > 0 {
			m.cursor--
		}
	case "g", "home":
		m.cursor = 0
	case "G", "end":
		m.cursor = max(0, len(m.rows)-1)
	case "r":
		return m, m.load()
	case "enter", "o":
		if cur, ok := m.current(); ok {
			m.mode = modeBusy
			return m, open(cur.Worktree)
		}
	case "n":
		m.mode = modeNaming
		m.input.SetValue("")
		return m, m.input.Focus()
	case "m":
		if cur, ok := m.current(); ok && !cur.Main {
			m.mode, m.confirm, m.force = modeConfirm, "merge", false
		}
	case "d", "x":
		if cur, ok := m.current(); ok && !cur.Main {
			m.mode, m.confirm, m.force = modeConfirm, "remove", false
		}
	case "D", "X":
		if cur, ok := m.current(); ok && !cur.Main {
			m.mode, m.confirm, m.force = modeConfirm, "remove", true
		}
	}
	return m, nil
}

func (m model) updateNaming(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	switch msg.String() {
	case "esc", "ctrl+c":
		m.mode = modeList
		m.input.Blur()
		return m, nil
	case "enter":
		name := strings.TrimSpace(m.input.Value())
		m.input.Blur()
		if name == "" {
			m.mode = modeList
			return m, nil
		}
		m.mode = modeBusy
		return m, create(m.repo, name, m.opts)
	}
	var cmd tea.Cmd
	m.input, cmd = m.input.Update(msg)
	return m, cmd
}

func (m model) updateConfirm(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	cur, ok := m.current()
	switch msg.String() {
	case "y", "enter":
		if !ok {
			m.mode = modeList
			return m, nil
		}
		m.mode = modeBusy
		if m.confirm == "merge" {
			return m, merge(m.repo, cur.Worktree)
		}
		return m, remove(m.repo, cur.Worktree, m.force)
	default:
		m.mode = modeList
		return m, nil
	}
}

func open(wt worktree.Worktree) tea.Cmd {
	return func() tea.Msg {
		if err := worktree.Open(wt); err != nil {
			return doneMsg{err: err}
		}
		if tmux.InsideRook() {
			return doneMsg{note: "opened"}
		}
		return doneMsg{note: "opened", attach: wt.Session}
	}
}

func create(repo worktree.Repo, name string, opts worktree.Options) tea.Cmd {
	return func() tea.Msg {
		wt, err := repo.New(name, "", opts)
		if err != nil {
			return doneMsg{err: err}
		}
		return open(wt)()
	}
}

func merge(repo worktree.Repo, wt worktree.Worktree) tea.Cmd {
	return func() tea.Msg {
		if err := repo.Merge(wt.Name); err != nil {
			return doneMsg{err: err}
		}
		return doneMsg{note: fmt.Sprintf("merged %s into %s", wt.Branch, repo.DefaultBranch())}
	}
}

func remove(repo worktree.Repo, wt worktree.Worktree, force bool) tea.Cmd {
	return func() tea.Msg {
		if err := repo.Remove(wt, force); err != nil {
			return doneMsg{err: err}
		}
		return doneMsg{note: "removed " + displayName(repo, wt)}
	}
}

func displayName(repo worktree.Repo, wt worktree.Worktree) string {
	switch {
	case wt.Main:
		return repo.Name
	case wt.Name != "":
		return wt.Name
	default:
		return wt.Path[strings.LastIndex(wt.Path, "/")+1:]
	}
}

func (m model) View() string {
	var b strings.Builder
	b.WriteString(bold.Render(accent.Render("♜ worktrees")) + "  " + dim.Render(m.repo.Name) + "\n\n")

	nameW := 12
	for _, r := range m.rows {
		nameW = max(nameW, len(displayName(m.repo, r.Worktree)))
	}
	nameW = min(nameW, 28)

	for i, r := range m.rows {
		name := displayName(m.repo, r.Worktree)
		if rs := []rune(name); len(rs) > nameW {
			name = string(rs[:nameW-1]) + "…"
		}
		mark := dim.Render("○")
		if r.Live {
			mark = accent.Render("●")
		}
		branch := r.Branch
		if branch == "" {
			branch = "detached " + r.Head
		}
		var notes []string
		if r.Dirty {
			notes = append(notes, "dirty")
		}
		if r.Ahead > 0 {
			notes = append(notes, fmt.Sprintf("+%d", r.Ahead))
		}
		if r.Behind > 0 {
			notes = append(notes, fmt.Sprintf("-%d", r.Behind))
		}
		agent := ""
		switch r.State {
		case sessions.StateWaiting:
			agent = accent.Render(bold.Render("● waiting"))
		case sessions.StateWorking:
			agent = "✳ working"
		case sessions.StateDone:
			agent = dim.Render("· done")
		}
		pad := strings.Repeat(" ", nameW-len([]rune(name)))
		rest := fmt.Sprintf("%s  ⎇ %-24s %-14s %s", pad, branch, dim.Render(strings.Join(notes, " ")), agent)
		if i == m.cursor {
			b.WriteString(selected.Render("▸ "+name) + rest + "\n")
		} else {
			b.WriteString(mark + " " + name + rest + "\n")
		}
	}
	if len(m.rows) == 0 {
		b.WriteString(dim.Render("  (loading…)") + "\n")
	}

	b.WriteString("\n")
	switch m.mode {
	case modeNaming:
		b.WriteString(m.input.View() + "\n" + dim.Render("enter create · esc cancel"))
	case modeConfirm:
		cur, _ := m.current()
		verb := m.confirm
		if m.force {
			verb = "force-remove"
		}
		b.WriteString(accent.Render(fmt.Sprintf("%s %s? ", verb, displayName(m.repo, cur.Worktree))) + dim.Render("y/enter confirm · any key cancel"))
	case modeBusy:
		b.WriteString(dim.Render("working…"))
	default:
		if m.err != nil {
			b.WriteString(errStyle.Render(m.err.Error()))
		} else if m.note != "" {
			b.WriteString(accent.Render(m.note))
		} else {
			b.WriteString(dim.Render("enter open · n new · m merge home · d remove (D force) · r refresh · q quit"))
		}
	}
	out := b.String()
	if m.width > 0 {
		out = lipgloss.NewStyle().MaxWidth(m.width).Render(out)
	}
	return out
}
