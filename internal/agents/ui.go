// Package agents is the attention layer's face: the whole fleet on one
// board — every agent on the rook server as a card with its state, its
// place, what it asked for, and the tail of its screen — the ones that
// need you first. Enter jumps to the agent in tmux. `rook agents`
// standalone, the prefix-a popup, or pinned as a side panel (prefix A)
// — one program, any size.
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

const (
	refreshEvery = 2 * time.Second
	minTail      = 2 // screen lines per card at the tightest
	maxTail      = 6
)

type card struct {
	sessions.Agent
	tail []string
}

type loadedMsg struct{ cards []card }
type tickMsg struct{}
type actMsg struct {
	note string
	err  error
	quit bool
}

type model struct {
	cards  []card
	cursor int
	width  int
	height int
	note   string
	err    error
	// side means the board is a pinned pane: Enter takes the panel
	// along to the agent's window instead of closing.
	side bool
}

// Run shows the board and blocks until it exits. side pins it: see
// Side.
func Run(side bool) error {
	_, err := tea.NewProgram(model{side: side}, tea.WithAltScreen()).Run()
	return err
}

func (m model) Init() tea.Cmd { return tea.Batch(load(), tick()) }

func tick() tea.Cmd {
	return tea.Tick(refreshEvery, func(time.Time) tea.Msg { return tickMsg{} })
}

// load lists the fleet and captures every agent's screen, off the UI
// thread: one list-panes, then one capture per agent.
func load() tea.Cmd {
	return func() tea.Msg {
		agents := sessions.Agents()
		cards := make([]card, len(agents))
		for i, a := range agents {
			lines := strings.Split(sessions.Screen(a.PaneID), "\n")
			for len(lines) > 0 && strings.TrimSpace(lines[len(lines)-1]) == "" {
				lines = lines[:len(lines)-1]
			}
			if len(lines) > maxTail {
				lines = lines[len(lines)-maxTail:]
			}
			cards[i] = card{Agent: a, tail: lines}
		}
		return loadedMsg{cards}
	}
}

func (m model) selected() (card, bool) {
	if m.cursor < 0 || m.cursor >= len(m.cards) {
		return card{}, false
	}
	return m.cards[m.cursor], true
}

func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width, m.height = msg.Width, msg.Height
	case tickMsg:
		return m, tea.Batch(load(), tick())
	case loadedMsg:
		// selection follows the pane id across the re-sort
		keep := ""
		if c, ok := m.selected(); ok {
			keep = c.PaneID
		}
		m.cards = msg.cards
		m.cursor = 0
		for i, c := range m.cards {
			if c.PaneID == keep {
				m.cursor = i
			}
		}
	case actMsg:
		m.err, m.note = msg.err, msg.note
		if msg.quit && msg.err == nil {
			return m, tea.Quit
		}
		return m, load()
	case tea.KeyMsg:
		return m.key(msg)
	}
	return m, nil
}

func (m model) key(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	m.err, m.note = nil, ""
	switch msg.String() {
	case "q", "esc", "ctrl+c":
		if m.side && msg.String() != "ctrl+c" {
			return m, nil // a pinned panel doesn't close on esc; prefix A does
		}
		return m, tea.Quit
	case "j", "down":
		if m.cursor < len(m.cards)-1 {
			m.cursor++
		}
	case "k", "up":
		if m.cursor > 0 {
			m.cursor--
		}
	case "g", "home":
		m.cursor = 0
	case "G", "end":
		m.cursor = max(0, len(m.cards)-1)
	case "r":
		return m, load()
	case "enter":
		if c, ok := m.selected(); ok {
			if m.side {
				return m, act("", false, func() error { return follow(c.Agent) })
			}
			return m, act("", true, func() error { return sessions.Goto(c.Agent) })
		}
	}
	return m, nil
}

func act(note string, quit bool, f func() error) tea.Cmd {
	return func() tea.Msg { return actMsg{note: note, err: f(), quit: quit} }
}

func chip(s sessions.AgentState) string {
	switch s {
	case sessions.StateWaiting:
		return tui.Accent.Render(tui.Bold.Render("● waiting"))
	case sessions.StateWorking:
		return "✳ working"
	default:
		return tui.Dim.Render("· done")
	}
}

func (m model) View() string {
	var b strings.Builder
	waiting := 0
	for _, c := range m.cards {
		if c.State == sessions.StateWaiting {
			waiting++
		}
	}
	title := tui.Bold.Render(tui.Accent.Render("♜ agents"))
	if waiting > 0 {
		title += "  " + tui.Accent.Render(fmt.Sprintf("%d waiting", waiting)) + tui.Dim.Render(fmt.Sprintf(" · %d total", len(m.cards)))
	} else {
		title += "  " + tui.Dim.Render(fmt.Sprintf("%d agents, none waiting", len(m.cards)))
	}
	b.WriteString(title + "\n\n")
	if len(m.cards) == 0 {
		b.WriteString(tui.Dim.Render("  no agents on the rook server") + "\n")
	}

	// Share the height between cards: header + tail + blank each.
	tail := maxTail
	if m.height > 0 && len(m.cards) > 0 {
		room := m.height - 4 // title, blank, blank, footer
		tail = max(minTail, min(maxTail, room/len(m.cards)-2))
	}

	for i, c := range m.cards {
		where := ""
		if c.Repo != "" {
			where = "⎇ " + c.Repo
			if c.Branch != "" && c.Branch != "main" && c.Branch != "master" {
				where += " · " + c.Branch
			}
		}
		head := fmt.Sprintf("  %-11s %s", chip(c.State), tui.Dim.Render(where))
		if c.Headline != "" {
			head += "  " + c.Headline
		}
		if i == m.cursor {
			b.WriteString(tui.Selected.Render("▸ "+place(c.Agent)) + head + "\n")
		} else {
			b.WriteString("  " + place(c.Agent) + head + "\n")
		}
		lines := c.tail
		if len(lines) > tail {
			lines = lines[len(lines)-tail:]
		}
		for _, l := range lines {
			b.WriteString(tui.Dim.Render("    │ ") + l + "\n")
		}
		b.WriteString("\n")
	}

	switch {
	case m.err != nil:
		b.WriteString(tui.Err.Render(m.err.Error()))
	case m.note != "":
		b.WriteString(tui.Accent.Render(m.note))
	case m.side:
		b.WriteString(tui.Dim.Render("enter go · j/k move"))
	default:
		b.WriteString(tui.Dim.Render("enter go · j/k move · esc close"))
	}
	out := b.String()
	if m.width > 0 {
		out = lipgloss.NewStyle().MaxWidth(m.width).Render(out)
	}
	return out
}

// place names where an agent lives: session·window, the window name
// when it says more than "claude".
func place(a sessions.Agent) string {
	s := a.Session + "·" + a.Window
	if a.WindowName != "" && a.WindowName != "claude" {
		s += " " + a.WindowName
	}
	return s
}
