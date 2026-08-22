// Package tui is what rook's Bubble Tea faces share: the palette. ANSI
// names on purpose, the same rule as the tmux theme — the glass owns
// the colours, rook owns emphasis.
package tui

import "github.com/charmbracelet/lipgloss"

var (
	Accent   = lipgloss.NewStyle().Foreground(lipgloss.Color("3"))
	Dim      = lipgloss.NewStyle().Foreground(lipgloss.Color("8"))
	Bold     = lipgloss.NewStyle().Bold(true)
	Selected = lipgloss.NewStyle().Foreground(lipgloss.Color("3")).Background(lipgloss.Color("8")).Bold(true)
	Err      = lipgloss.NewStyle().Foreground(lipgloss.Color("1"))
)
