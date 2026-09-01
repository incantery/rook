// Package agents is the attention layer's face: a sidebar. Two lists —
// spaces (live sessions, with their branch) and agents (who is working
// where, and whether they need you) — each row a dot and two lines.
// Enter goes there. `rook agents` standalone, the prefix-a popup, or
// pinned as a side panel (prefix A) — one program, any size.
package agents

import (
	"fmt"
	"strings"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"

	"github.com/incantery/rook/internal/sessions"
	"github.com/incantery/rook/internal/tui"
)

const refreshEvery = 2 * time.Second

var (
	working = lipgloss.NewStyle().Foreground(lipgloss.Color("2"))
	waiting = tui.Accent
)

// rowKind says which list a row is in; the cursor runs over both.
type rowKind int

const (
	rowSpace rowKind = iota
	rowAgent
)

type row struct {
	kind  rowKind
	space sessions.Space
	agent sessions.Agent
}

type loadedMsg struct{ rows []row }
type tickMsg struct{}
type wentMsg struct{ err error }

type model struct {
	rows   []row
	cursor int
	width  int
	height int
	err    error
	// side means the board is a pinned pane: Enter takes the panel
	// along to the target's window instead of closing.
	side bool
}

// Run shows the sidebar and blocks until it exits. side pins it: see
// Side.
func Run(side bool) error {
	_, err := tea.NewProgram(model{side: side}, tea.WithAltScreen()).Run()
	return err
}

func (m model) Init() tea.Cmd { return tea.Batch(load(), tick()) }

func tick() tea.Cmd {
	return tea.Tick(refreshEvery, func(time.Time) tea.Msg { return tickMsg{} })
}

// load lists agents and spaces off the UI thread: one list-panes plus
// one capture per agent pane.
func load() tea.Cmd {
	return func() tea.Msg {
		agents := sessions.Agents()
		var rows []row
		for _, sp := range sessions.Spaces(agents) {
			if sp.Name == sideSession {
				continue
			}
			rows = append(rows, row{kind: rowSpace, space: sp})
		}
		for _, a := range agents {
			rows = append(rows, row{kind: rowAgent, agent: a})
		}
		return loadedMsg{rows}
	}
}

func (r row) key() string {
	if r.kind == rowSpace {
		return "s:" + r.space.Name
	}
	return "a:" + r.agent.PaneID
}

func (m model) selected() (row, bool) {
	if m.cursor < 0 || m.cursor >= len(m.rows) {
		return row{}, false
	}
	return m.rows[m.cursor], true
}

func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width, m.height = msg.Width, msg.Height
	case tickMsg:
		return m, tea.Batch(load(), tick())
	case loadedMsg:
		keep := ""
		if r, ok := m.selected(); ok {
			keep = r.key()
		}
		m.rows = msg.rows
		m.cursor = 0
		for i, r := range m.rows {
			if r.key() == keep {
				m.cursor = i
			}
		}
	case wentMsg:
		m.err = msg.err
		if msg.err == nil && !m.side {
			return m, tea.Quit
		}
	case tea.KeyMsg:
		m.err = nil
		switch msg.String() {
		case "q", "esc", "ctrl+c":
			if m.side && msg.String() != "ctrl+c" {
				return m, nil // a pinned panel is parked with prefix A, not closed
			}
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
			return m, load()
		case "enter":
			if r, ok := m.selected(); ok {
				side := m.side
				return m, func() tea.Msg { return wentMsg{go_(r, side)} }
			}
		}
	}
	return m, nil
}

// go_ takes the client to a row: an agent's pane, or a space's session.
func go_(r row, side bool) error {
	if r.kind == rowAgent {
		if side {
			return follow(r.agent)
		}
		return sessions.Goto(r.agent)
	}
	if side {
		return followSession(r.space.Name)
	}
	return sessions.Connect(r.space.Name)
}

// One state per channel: each gets its own shape, so the rail reads on
// a glass that has lost its colours — and so a reader learns one
// vocabulary rather than two. These are the engine's glyphs
// (`chrome.Dot`), because this sidebar and the mux rail are the same
// two lists and disagreeing about them would be the confusing part.
//
// The colours stay ANSI, as this package's palette requires: shape is
// what carries the distinction, colour only agrees with it.
func dot(s sessions.AgentState) string {
	switch s {
	case sessions.StateWaiting:
		return waiting.Render("◇")
	case sessions.StateWorking:
		return working.Render("◐")
	case sessions.StateDone:
		return tui.Dim.Render("✓")
	}
	return tui.Dim.Render("○")
}

func stateWord(s sessions.AgentState) string {
	switch s {
	case sessions.StateWaiting:
		// "needs you", not "waiting": waiting is what the agent is
		// doing, and the row is there to say what *you* have to do.
		return waiting.Render("needs you")
	case sessions.StateWorking:
		return working.Render("working")
	case sessions.StateDone:
		return tui.Dim.Render("done")
	}
	return tui.Dim.Render("idle")
}

func (m model) View() string {
	var b strings.Builder
	section := func(title string, n int) {
		b.WriteString(tui.Dim.Render(fmt.Sprintf(" %-7s %d", title, n)) + "\n")
	}
	counts := map[rowKind]int{}
	for _, r := range m.rows {
		counts[r.kind]++
	}

	last := rowKind(-1)
	for i, r := range m.rows {
		if r.kind != last {
			if last != -1 {
				b.WriteString("\n")
			}
			if r.kind == rowSpace {
				section("spaces", counts[rowSpace])
			} else {
				section("agents", counts[rowAgent])
			}
			last = r.kind
		}
		var d, name, sub string
		if r.kind == rowSpace {
			d, name = dot(r.space.State), r.space.Name
			sub = r.space.Branch
			if r.space.Repo != "" && r.space.Repo != r.space.Name {
				sub = r.space.Repo + " · " + sub
			}
		} else {
			d, name = dot(r.agent.State), r.agent.Session
			if r.agent.WindowName != "" && r.agent.WindowName != "claude" {
				name += " · " + r.agent.WindowName
			}
			sub = stateWord(r.agent.State) + tui.Dim.Render(" · claude")
			if r.agent.Headline != "" {
				sub = stateWord(r.agent.State) + tui.Dim.Render(" · "+r.agent.Headline)
			}
		}
		if i == m.cursor {
			b.WriteString(" " + d + " " + tui.Selected.Render(name) + "\n")
		} else {
			b.WriteString(" " + d + " " + tui.Bold.Render(name) + "\n")
		}
		b.WriteString("   " + sub + "\n")
	}
	if len(m.rows) == 0 {
		b.WriteString(tui.Dim.Render(" nothing on the rook server") + "\n")
	}
	if m.err != nil {
		b.WriteString("\n" + tui.Err.Render(m.err.Error()))
	}
	out := b.String()
	if m.width > 0 {
		out = lipgloss.NewStyle().MaxWidth(m.width).Render(out)
	}
	return out
}
