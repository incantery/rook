// Package config loads rook's user configuration from
// ~/.config/rook/rook.toml (XDG_CONFIG_HOME respected). A missing file
// means defaults; a malformed file or an unrecognized key refuses to
// boot — a typo that silently falls back to defaults is how settings
// get lost.
//
// The file is rook.toml, not config.toml: that name is owned by the
// previous rook app and this rebuild never reads or writes it.
package config

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/BurntSushi/toml"
)

// Config is the whole user-facing configuration surface. Keys appear
// here when they earn a knob, not before.
type Config struct {
	Tmux      Tmux      `toml:"tmux"`
	Companion Companion `toml:"companion"`
	Worktree  Worktree  `toml:"worktree"`
	// Mux is the [mux] table: the engine's knobs, handed to it compiled
	// (engine.go, `rook config json`).
	Mux   Mux   `toml:"mux"`
	Namer Namer `toml:"namer"`
	// Keys is the [keys] table: what each key after the prefix does,
	// "key" = "verb [arg]". The engine reads it (mux/src/keys.zig);
	// Load only refuses what the engine would skip (keys.go).
	Keys map[string]string `toml:"keys"`
	Home Home              `toml:"home"`
}

// Namer is the [namer] table: what gives tabs their names once the
// first program's name stops being the best rook can do. rookd runs
// it; the engine only accepts its suggestions, and never over a name
// a person gave.
type Namer struct {
	// Command reads what a tab holds on stdin and prints a name. Unset
	// means "wisp name"; a command that is not on PATH names nothing.
	Command *string `toml:"command"`
	// Off turns the namer off whatever the command.
	Off bool `toml:"off"`
}

// NamerCommand is the command to run, or "" for none.
func (c Config) NamerCommand(def string) string {
	if c.Namer.Off {
		return ""
	}
	if c.Namer.Command != nil {
		return *c.Namer.Command
	}
	return def
}

// Worktree is the [worktree] table: what a fresh worktree needs that git
// doesn't carry. Paths are repo-relative and apply to every repo; a
// path a repo doesn't have is skipped.
type Worktree struct {
	// Copy lists files copied from the main checkout (".env").
	Copy []string `toml:"copy"`
	// Link lists paths symlinked to the main checkout's ("node_modules").
	Link []string `toml:"link"`
}

// Companion is the resident rook knows by name, so it can say when
// and where it is open (`rook companion`, the state feed's
// `companion`). Rook ships the slot; only the config names an
// occupant, and without this table there is none.
type Companion struct {
	// Command is what summons it; its first word names the program.
	Command string `toml:"command"`
	// Name labels it; the program when nothing better does.
	Name string `toml:"name"`
	// Key is accepted and ignored: nothing has read it since the tmux
	// front door went. Bind keys in [keys].
	Key string `toml:"key"`
	// Program is the foreground program that means "the companion is
	// open in this pane" — what the engine watches for. Empty means
	// the first word of Command (its basename); set it when that word
	// is a wrapper, or to "" to turn the slot off. Read by the engine,
	// declared here because this loader refuses keys it has not heard
	// of and one file cannot have two ideas of what is valid.
	Program string `toml:"program"`
	// Ask and Chat are accepted and ignored: the ask door and the
	// hosted chat went with the root (docs/home.md).
	Ask  string `toml:"ask"`
	Chat string `toml:"chat"`

	// programSet is whether `program` was said at all: `program = ""`
	// turns the slot off, which the zero value cannot say.
	programSet bool
}

// Home is the [home] table: what the one workspace outside the list
// of spaces is seeded with, and what closing its last pane does. The
// engine reads it (mux/src/config.zig, Home); it is declared here so a
// file that uses it loads, and checked here so a typo refuses to boot.
type Home struct {
	// OnEmpty is what its last pane closing does: "return" (the
	// default) goes back to the space you came from and seeds home
	// fresh next time; "stay" seeds it again in place.
	OnEmpty string `toml:"on_empty"`
	// Color is home's accent, and what its chrome is tinted toward:
	// a hex colour or an ANSI name. The config's accent when unset.
	Color string `toml:"color"`
	// Dir is where its panes start unless they say; "~" when unset.
	Dir string `toml:"dir"`
	// Window is its windows in order; none is one shell.
	Window []HomeWindow `toml:"window"`
}

// HomeWindow is one [[home.window]].
type HomeWindow struct {
	Name string `toml:"name"`
	Dir  string `toml:"dir"`
	// Panes is the short form: a command per pane, side by side.
	Panes []string `toml:"panes"`
	// Pane is the long form, after any Panes: each its own command,
	// dir and split.
	Pane []HomePane `toml:"pane"`
}

// HomePane is one [[home.window.pane]]. An empty command is a shell.
type HomePane struct {
	Command string `toml:"command" json:"command,omitempty"`
	Dir     string `toml:"dir" json:"dir,omitempty"`
	// Split is how it sits against the pane before it: "right" (the
	// default) or "down".
	Split string `toml:"split" json:"split,omitempty"`
}

// checkHome refuses what the engine would quietly misread.
func checkHome(h Home) error {
	if h.OnEmpty != "" && h.OnEmpty != "return" && h.OnEmpty != "stay" {
		return fmt.Errorf("[home] on_empty = %q: \"return\" or \"stay\"", h.OnEmpty)
	}
	if len(h.Window) > 8 {
		return fmt.Errorf("[home]: %d windows, at most 8", len(h.Window))
	}
	for i, w := range h.Window {
		if n := len(w.Panes) + len(w.Pane); n > 8 {
			return fmt.Errorf("[[home.window]] %d: %d panes, at most 8", i+1, n)
		}
		for _, p := range w.Pane {
			if p.Split != "" && p.Split != "right" && p.Split != "down" {
				return fmt.Errorf("[[home.window.pane]] split = %q: \"right\" or \"down\"", p.Split)
			}
		}
	}
	return nil
}

// Tmux is the [tmux] table: the slice of rook settings that proxy into
// tmux options.
type Tmux struct {
	// Prefix is the tmux prefix key in tmux key syntax: "C-b", "C-a",
	// "`". Empty means rook's default.
	Prefix string `toml:"prefix"`

	// Plugins are tmux plugins as "owner/repo" GitHub specs, e.g.
	// "christoomey/vim-tmux-navigator". Rook clones and wires them
	// itself; there is no TPM.
	Plugins []string `toml:"plugins"`
}

// Path returns where the config file lives, whether or not it exists.
func Path() (string, error) {
	dir := os.Getenv("XDG_CONFIG_HOME")
	if dir == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			return "", err
		}
		dir = filepath.Join(home, ".config")
	}
	return filepath.Join(dir, "rook", "rook.toml"), nil
}

// Load reads the config file at path. A missing file is not an error:
// it returns the zero Config, which means all defaults.
func Load(path string) (Config, error) {
	var c Config
	md, err := toml.DecodeFile(path, &c)
	if os.IsNotExist(err) {
		return Config{}, nil
	}
	if err != nil {
		return Config{}, fmt.Errorf("%s: %w", path, err)
	}
	if undecoded := md.Undecoded(); len(undecoded) > 0 {
		keys := make([]string, len(undecoded))
		for i, k := range undecoded {
			keys[i] = k.String()
		}
		return Config{}, fmt.Errorf("%s: unrecognized keys: %s (typo, or a newer rook?)",
			path, strings.Join(keys, ", "))
	}
	c.Companion.programSet = md.IsDefined("companion", "program")
	if err := checkMux(c.Mux); err != nil {
		return Config{}, fmt.Errorf("%s: %w", path, err)
	}
	if err := checkKeys(c.Keys); err != nil {
		return Config{}, fmt.Errorf("%s: %w", path, err)
	}
	if err := checkHome(c.Home); err != nil {
		return Config{}, fmt.Errorf("%s: %w", path, err)
	}
	return c, nil
}
