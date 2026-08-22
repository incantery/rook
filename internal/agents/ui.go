// Package agents is the attention layer's face: every agent on the rook
// server in one list, the ones that need you first, with where each one
// is, what it asked for, and its screen. Enter goes there. `rook agents`
// standalone or the prefix-a popup — one program, any size.
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

type loadedMsg struct {
	agents []sessions.Agent
	screen string // the selected agent's pane, captured in the same pass
}

type tickMsg struct{}

type wentMsg struct{ err error }

type model struct {
	agents  []sessions.Agent
	screen  string
	cursor  int
	width   int
	height  int
	err     error
	preview bool
}

// Run shows the agents view and blocks until it exits.
func Run() error {
	_, err := tea.NewProgram(model{preview: true}, tea.WithAltScreen()).Run()
	return err
}

func (m model) Init() tea.Cmd { return tea.Batch(m.load(), tick()) }

func tick() tea.Cmd {
	return tea.Tick(refreshEvery, func(time.Time) tea.Msg { return tickMsg{} })
}

func (m model) selected() (sessions.Agent, bool) {
	if m.cursor < 0 || m.cursor >= len(m.agents) {
		return sessions.Agent{}, false
	}
	return m.agents[m.cursor], true
}

// load lists agents and captures the selected pane, off the UI thread.
// The selection is carried by pane id so it survives the re-sort.
func (m model) load() tea.Cmd {
	keep := ""
	if a, ok := m.selected(); ok {
		keep = a.PaneID
	}
	want := m.preview
	return func() tea.Msg {
		agents := sessions.Agents()
		msg := loadedMsg{agents: agents}
		idx := 0
		for i, a := range agents {
			if a.PaneID == keep {
				idx = i
			}
		}
		if want && len(agents) > 0 {
			msg.screen = sessions.Screen(agents[idx].PaneID)
		}
		return msg
	}
}

func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width, m.height = msg.Width, msg.Height
	case tickMsg:
		return m, tea.Batch(m.load(), tick())
	case loadedMsg:
		keep := ""
		if a, ok := m.selected(); ok {
			keep = a.PaneID
		}
		m.agents, m.screen = msg.agents, msg.screen
		m.cursor = 0
		for i, a := range m.agents {
			if a.PaneID == keep {
				m.cursor = i
			}
		}
	case wentMsg:
		if msg.err != nil {
			m.err = msg.err
			return m, nil
		}
		return m, tea.Quit
	case tea.KeyMsg:
		m.err = nil
		switch msg.String() {
		case "q", "esc", "ctrl+c":
			return m, tea.Quit
		case "j", "down":
			if m.cursor < len(m.agents)-1 {
				m.cursor++
			}
			return m, m.load()
		case "k", "up":
			if m.cursor > 0 {
				m.cursor--
			}
			return m, m.load()
		case "g", "home":
			m.cursor = 0
			return m, m.load()
		case "G", "end":
			m.cursor = max(0, len(m.agents)-1)
			return m, m.load()
		case "p":
			m.preview = !m.preview
			return m, m.load()
		case "r":
			return m, m.load()
		case "enter":
			if a, ok := m.selected(); ok {
				return m, func() tea.Msg { return wentMsg{sessions.Goto(a)} }
			}
		}
	}
	return m, nil
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
	for _, a := range m.agents {
		if a.State == sessions.StateWaiting {
			waiting++
		}
	}
	title := tui.Bold.Render(tui.Accent.Render("♜ agents"))
	if waiting > 0 {
		title += "  " + tui.Accent.Render(fmt.Sprintf("%d waiting", waiting))
	} else {
		title += "  " + tui.Dim.Render(fmt.Sprintf("%d running", len(m.agents)))
	}
	b.WriteString(title + "\n\n")

	if len(m.agents) == 0 {
		b.WriteString(tui.Dim.Render("  no agents on the rook server") + "\n")
	}
	placeW := 14
	for _, a := range m.agents {
		placeW = max(placeW, len([]rune(place(a))))
	}
	placeW = min(placeW, 30)
	for i, a := range m.agents {
		pl := place(a)
		if rs := []rune(pl); len(rs) > placeW {
			pl = string(rs[:placeW-1]) + "…"
		}
		pad := strings.Repeat(" ", placeW-len([]rune(pl)))
		where := ""
		if a.Repo != "" {
			where = "⎇ " + a.Repo
			if a.Branch != "" && a.Branch != "main" && a.Branch != "master" {
				where += " · " + a.Branch
			}
		}
		rest := fmt.Sprintf("%s  %-11s %s", pad, chip(a.State), tui.Dim.Render(where))
		if a.Headline != "" {
			rest += "  " + a.Headline
		}
		if i == m.cursor {
			b.WriteString(tui.Selected.Render("▸ "+pl) + rest + "\n")
		} else {
			b.WriteString("  " + pl + rest + "\n")
		}
	}

	// The selected agent's screen fills what's left, bottom-aligned
	// like the pane itself: the last lines are where the question is.
	if m.preview && m.screen != "" && m.height > 0 {
		used := strings.Count(b.String(), "\n") + 3
		room := m.height - used
		if room > 3 {
			lines := strings.Split(m.screen, "\n")
			for len(lines) > 0 && strings.TrimSpace(lines[len(lines)-1]) == "" {
				lines = lines[:len(lines)-1]
			}
			if len(lines) > room {
				lines = lines[len(lines)-room:]
			}
			b.WriteString("\n" + tui.Dim.Render(strings.Repeat("─", max(0, m.width))) + "\n")
			b.WriteString(strings.Join(lines, "\n") + "\n")
		}
	}

	b.WriteString("\n")
	if m.err != nil {
		b.WriteString(tui.Err.Render(m.err.Error()))
	} else {
		b.WriteString(tui.Dim.Render("enter go · j/k move · p preview · r refresh · q quit"))
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
