package main

import (
	"strings"
	"testing"
	"time"

	"github.com/incantery/rook/internal/mux"
)

func win(n int) *int { return &n }

// The line is the answer read out loud: who, where, whether she is in
// front of you, and how long she has been there.
func TestCompanionLines(t *testing.T) {
	now := time.UnixMilli(1756500000000)
	ago := func(d time.Duration) int64 { return now.Add(-d).UnixMilli() }

	cases := []struct {
		name string
		in   *mux.Companion
		want []string
	}{
		{
			"no companion at all: no server, or none configured",
			nil,
			[]string{"rook knows of no companion — is one configured, and is rook running?"},
		},
		{
			"configured, not running anywhere",
			&mux.Companion{Name: "vera"},
			[]string{"vera is not open in rook"},
		},
		{
			"open in a window, and you are looking at it",
			&mux.Companion{Name: "vera", Open: true, Panes: []mux.CompanionPane{
				{Pane: 7, Workspace: "rook", Window: win(2), Place: "window", Visible: true, Focused: true, Since: ago(20 * time.Minute)},
			}},
			[]string{"vera · rook, window 2 · pane 7 · in front of you · open 20m"},
		},
		{
			"open behind another workspace",
			&mux.Companion{Name: "vera", Open: true, Panes: []mux.CompanionPane{
				{Pane: 3, Workspace: "dora", Window: win(1), Place: "window", Since: ago(30 * time.Hour)},
			}},
			[]string{"vera · dora, window 1 · pane 3 · out of sight · open 1d"},
		},
		{
			"on the rail of every workspace",
			&mux.Companion{Name: "vera", Open: true, Panes: []mux.CompanionPane{
				{Pane: 4, Place: "pin", Visible: true, Since: ago(2 * time.Hour)},
			}},
			[]string{"vera · the rail, every workspace · pane 4 · on the glass · open 2h"},
		},
		{
			"floating over the window she was summoned from",
			&mux.Companion{Name: "vera", Open: true, Panes: []mux.CompanionPane{
				{Pane: 9, Workspace: "rook", Place: "popup", Visible: true, Focused: true, Since: ago(3 * time.Second)},
			}},
			[]string{"vera · rook, the popup · pane 9 · in front of you · open just now"},
		},
		{
			"two of her: rook reports what it sees, not what it wishes",
			&mux.Companion{Name: "vera", Open: true, Panes: []mux.CompanionPane{
				{Pane: 1, Workspace: "rook", Window: win(1), Place: "window", Visible: true, Focused: true, Since: ago(time.Minute)},
				{Pane: 2, Workspace: "dora", Window: win(1), Place: "window", Since: ago(time.Minute)},
			}},
			[]string{
				"vera · rook, window 1 · pane 1 · in front of you · open 1m",
				"vera · dora, window 1 · pane 2 · out of sight · open 1m",
			},
		},
		{
			"open says so even with no panes to point at",
			&mux.Companion{Name: "vera", Open: true},
			[]string{"vera is not open in rook"},
		},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := companionLines(c.in, now)
			if strings.Join(got, "\n") != strings.Join(c.want, "\n") {
				t.Errorf("got:\n%s\nwant:\n%s", strings.Join(got, "\n"), strings.Join(c.want, "\n"))
			}
		})
	}
}

// A clock that disagrees with the server's must not print nonsense.
func TestSince(t *testing.T) {
	now := time.UnixMilli(1756500000000)
	if got := since(0, now); got != "" {
		t.Errorf("never seen: %q", got)
	}
	if got := since(now.Add(time.Hour).UnixMilli(), now); got != "" {
		t.Errorf("stamped in the future: %q", got)
	}
}
