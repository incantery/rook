// An example environment — the SDK's showcase config, in the node-list
// shape: a config is a LIST OF DECLARATIONS, values not statements.
// Commands are typed constants generated from the app's own registry,
// so a bind to a command that does not exist fails to compile — the
// old fluent form of this very file bound "workspace.manager" and
// "explorer.toggle", neither of which exists, and nothing noticed.
//
// (main.ts and main.py beside this are July's cross-language parity
// probes, kept as history; the byte contract lives in the SDK goldens.)
//
//	go run ./sdk/rook/example --out /tmp/environment.json
package main

import "github.com/incantery/rook/sdk/rook"

func main() {
	rook.Main(
		// Fonts and window chrome. Zero fields are unset, not zero.
		rook.Font{Family: "Hack Nerd Font Mono", Size: 18},
		rook.Window{Opacity: 1, Padding: 4},
		rook.Theme("nocturne"),

		// Leaders: app (tmux's prefix) and the editor's own.
		rook.Leaders{App: "`", Editor: ","},

		// The app leader's chords. A duplicate chord here is a COMPILE
		// error; a later Binds{} group rebinds per chord.
		rook.Binds{
			`<leader>"`: rook.CmdPaneSplitDown,
			"<leader>v": rook.CmdPaneSplitRight,
			"<leader>c": rook.CmdTabNew,
			"<leader>m": rook.CmdWorkspaceSwitch,
		},

		// The editor leader's chords (normal mode — the mode the
		// editor leader arms in).
		rook.EditorBinds{
			"<leader>TAB": rook.CmdTreeToggle,
			"<leader>o":   rook.CmdTreeReveal,
		},

		// Workspaces: named roots, listed alphabetically in the palette.
		// rook derives each root's git worktrees live — no second list.
		rook.Workspaces{
			"rook": "~/go/src/github.com/incantery/rook",
		},

		// A plugin by source: rook fetches and caches it, and grants
		// exactly what is written here. Once it runs, press `y` in the
		// plugin panel — rook hands you the SHA256-pinned form of this
		// declaration to paste back.
		rook.Plugin{
			Source: "https://raw.githubusercontent.com/incantery/rook/main/examples/hello-plugin",
			Grants: []string{rook.OpItemsList},
		},
	)
}
