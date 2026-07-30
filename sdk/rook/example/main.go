// Seth's live config.toml (2026-07-30), as a Go environment — the
// first real program against the SDK, and the parity fixture: the
// TypeScript and Python probes beside it (main.ts, main.py) must emit
// byte-identical graphs, and the e2e `envgraph` scenario proves the
// app actually consumes what this describes.
//
//	go run ./sdk/rook/example --out ~/.config/rook/environment.json
package main

import "github.com/incantery/rook/sdk/rook"

func main() {
	e := rook.New()

	// Fonts and window chrome.
	e.FontFamily("Hack Nerd Font Mono")
	e.FontSize(18)
	e.BackgroundOpacity(1)
	e.WindowPadding(4)
	e.Theme("Nocturne")

	// Leaders: app (tmux's prefix) and the editor's own.
	e.Leader("`")
	e.EditorLeader(",")

	// App-scope chords, by registry command id.
	e.Bind(`<leader>"`, "app.split.horizontal")
	e.Bind("<leader>v", "app.split.vertical")
	e.Bind("<leader>c", "tab.new")
	e.Bind("<leader>m", "workspace.manager")

	// Editor-scope chords (explorer.*, the registry's names).
	e.EditorBind("normal", "<leader>TAB", "explorer.toggle")
	e.EditorBind("normal", "<leader>o", "explorer.reveal")

	// The host's half of the file, carried in the graph.
	e.Host("coder", "claude")
	e.Host("workspace-allow", []string{"rook", "rook-cloud", "rook-site", "presentation"})
	e.Table("agent", map[string]any{
		"enabled":       true,
		"engine":        "auto",
		"model":         "",
		"daily-cap-usd": 1.0,
	})
	e.Table("lsp", map[string]any{
		"enable": []string{"go", "typescript", "svelte"},
	})
	e.Table("cloud", map[string]any{
		"url": "https://api.rookide.com",
	})

	e.Run()
}
