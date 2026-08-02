// Package rook is the Go SDK for describing a rook development
// environment.
//
// The program importing this is not configuration in the init.lua
// sense: it does not run inside rook and cannot mutate anything. It
// runs once, at apply time, and emits a graph — the IR documented in
// docs/environments/IR.md — which rook materializes at launch. That
// split is the whole point: launch cost never depends on the language
// this file is written in, and the program's blast radius is exactly
// the graph it can describe.
//
// Emission is canonical (docs/environments/IR.md, "Canonical bytes"):
// every SDK produces byte-identical output for the same environment,
// so cross-language parity is `diff` and future provenance diffs stay
// noise-free. Keep the writer boring and by hand; encoding/json's
// HTML escaping and map ordering are both wrong for this.
package rook

import (
	"flag"
	"fmt"
	"os"
	"sort"
	"strconv"
	"strings"
)

// Env accumulates nodes. Methods return *Env for chaining, but
// statement-per-line reads better in a config; both work.
type Env struct {
	nodes []node
}

type node struct {
	source  string
	id      string
	kind    string
	scope   string
	key     string // option, leader
	value   any    // option
	chord   string // keybind
	command string // keybind
	name    string // table, plugin
	entries map[string]any
	// plugin
	argv   []string
	load   string
	grants []string
}

func New() *Env { return &Env{} }

// put appends, or replaces in place when the id already exists — the
// later call wins, at the earlier call's position. Same rule as
// TOML's "config lines replace defaults", and what makes composing
// environments (base then overrides) mean something.
func (e *Env) put(n node) *Env {
	for i := range e.nodes {
		if e.nodes[i].id == n.id {
			e.nodes[i] = n
			return e
		}
	}
	e.nodes = append(e.nodes, n)
	return e
}

// Option is the building block: one knob, by scope. Scope "app" keys
// are config.toml's top-level app keys, same names. Prefer the named
// helpers below; this is for keys the SDK hasn't grown a name for.
func (e *Env) Option(scope, key string, value any) *Env {
	return e.put(node{id: "option:" + scope + ":" + key, kind: "option", scope: scope, key: key, value: value})
}

// Set sets an app option.
func (e *Env) Set(key string, value any) *Env { return e.Option("app", key, value) }

// Host sets a host option (coder, workspace-allow, …).
// Carried in the graph; the host consumes it via the TOML renderer
// slice (IR.md).
func (e *Env) Host(key string, value any) *Env { return e.Option("host", key, value) }

// Plugin declares a plugin: what to run, when to run it, and what it is
// allowed to do.
//
// This is where the plugin system meets configuration, and it is the
// USER-facing half of it. Writing a plugin is the protocol
// (github.com/incantery/rook-demos/sdk/go/plugin); declaring one is this,
// and a plugin rook was never told about does not exist.
//
// DECLARED vs GRANTED is the load-bearing distinction. A plugin's own
// `describe` says what it WANTS — items.list, session.spawn. This says what
// it MAY HAVE. The gap between the two is what preview shows you before
// anything runs (VISION.md): adopting a stranger's environment tells you
// which plugins it adds and what they asked for, and a capability is never
// inherited silently from a composed package.
//
// load is WHEN, and lazy is the default for the reason every poller in
// rook's history learned the hard way: a surface nobody opened must cost
// nothing. "eager" is for a plugin that has to be watching before you look.
//
//	eager  spawn at launch
//	lazy   spawn on first use (default)
//
// Grants are op names from the plugin protocol — "items.list", "items.act".
// Empty grants nothing, which makes a plugin declared-but-inert: useful for
// staging one before you trust it.
func (e *Env) Plugin(name string, command []string, load string, grants ...string) *Env {
	if load == "" {
		load = "lazy"
	}
	return e.put(node{
		id: "plugin:" + name, kind: "plugin", scope: "app",
		name: name, argv: command, load: load, grants: grants,
	})
}

// PluginFrom declares a plugin by WHERE IT COMES FROM, and lets rook do
// the rest: it downloads the binary into its own cache on first use, and
// nothing in your config names a path.
//
// The alternative — fetch it yourself, chmod it, then point Plugin at the
// result — is installing a plugin by hand and then telling config about
// it, which is a symlink with extra steps.
//
// The name is the source's last path segment. rook records what the
// plugin's own `describe` calls itself too, and shows both.
//
// https only. Executing something downloaded over plain http is not a
// thing to make easy.
func (e *Env) PluginFrom(source string, grants ...string) *Env {
	name := source
	if i := strings.LastIndex(name, "/"); i >= 0 {
		name = name[i+1:]
	}
	return e.put(node{
		id: "plugin:" + name, kind: "plugin", scope: "app",
		name: name, source: source, load: "lazy", grants: grants,
	})
}

// Table declares an opaque host table ([agent], [jira], [lsp], …).
func (e *Env) Table(name string, entries map[string]any) *Env {
	return e.put(node{id: "table:host:" + name, kind: "table", scope: "host", name: name, entries: entries})
}

// Leader sets the app leader (vim's mapleader, tmux's prefix).
// One key; TAB, SPACE and ESC are accepted as names.
func (e *Env) Leader(key string) *Env {
	return e.put(node{id: "leader:app", kind: "leader", scope: "app", key: key})
}

// EditorLeader sets the editor's own leader (vim's maplocalleader —
// a separate namespace from the app leader, on purpose).
func (e *Env) EditorLeader(key string) *Env {
	return e.put(node{id: "leader:editor", kind: "leader", scope: "editor", key: key})
}

// Bind binds an app-scope chord ("<leader>v") to a registry command id.
func (e *Env) Bind(chord, command string) *Env {
	return e.put(node{id: "keybind:app:" + chord, kind: "keybind", scope: "app", chord: chord, command: command})
}

// EditorBind binds a chord in an editor mode ("normal", "visual",
// "insert") to a registry command id.
func (e *Env) EditorBind(mode, chord, command string) *Env {
	scope := "editor." + mode
	return e.put(node{id: "keybind:" + scope + ":" + chord, kind: "keybind", scope: scope, chord: chord, command: command})
}

// ---- named app options, the discoverable surface ----

// TopBar sets the top strip's contents (presence, not order: tabs
// left, title center). No arguments hides the strip and
// the pane area reclaims its row.
func (e *Env) TopBar(segments ...string) *Env {
	return e.Set("top-bar", segList(segments))
}

// StatusLeft / StatusRight set the status bar's two clusters, in
// display order — tmux's own keys, on purpose. When the window is
// narrow, segments shed from the END of the right list backward, then
// the end of the left list; `cwd` is flexible and never blocks.
func (e *Env) StatusLeft(segments ...string) *Env {
	return e.Set("status-left", segList(segments))
}
func (e *Env) StatusRight(segments ...string) *Env {
	return e.Set("status-right", segList(segments))
}

// TabStyle picks how a `tabs` segment renders: "chips" (the top
// strip's pill), "index-name" (tmux's `1:name 2:name` list) or
// "current" (one compact active-tab chip; click cycles).
func (e *Env) TabStyle(style string) *Env { return e.Set("tab-style", style) }

// EditorMode: "insert" opens writable file buffers ready to type (the
// VS Code hand's contract; Esc still reaches vim's normal mode), or
// the default "normal".
func (e *Env) EditorMode(mode string) *Env { return e.Set("editor-mode", mode) }

// ActivityBar toggles the left icon rail (VS Code's activity bar):
// explorer, find-in-files, source control, agents, review.
func (e *Env) ActivityBar(on bool) *Env { return e.Set("activity-bar", on) }

// ExplorerAuto opens the file-tree sidebar at launch when the launch
// directory is inside a repository (a Dock launch lands in $HOME, and
// a sidebar listing a home directory is noise). Focus stays on the
// shell either way.
func (e *Env) ExplorerAuto(on bool) *Env { return e.Set("explorer-auto", on) }

func segList(segments []string) []string {
	if segments == nil {
		return []string{}
	}
	return segments
}

// ---- presets: identities as bundles ----
//
// A preset EXPANDS at emit time — the graph shows every knob it set,
// which is what future provenance attaches to. These bundles must
// match config.zig's applyPreset (the TOML front end's expansion):
// the golden test here pins this side, the e2e `presetparity`
// scenario diffs both sides on the live app.

// PresetTmuxNeovim arranges rook for a tmux+neovim hand: no top
// strip, one bottom bar with the tab list as text (tmux's window
// list), no buffer line (:ls people). Leaders are yours to set.
func (e *Env) PresetTmuxNeovim() *Env {
	e.TopBar()
	e.StatusLeft("tabs")
	e.StatusRight("workspace", "branch", "cwd")
	e.TabStyle("index-name")
	e.BufferLine(false)
	return e
}

// PresetVSCode arranges rook for a VS Code hand — look and feel both:
// editor surfaces carry identity (per-pane buffer line on), sessions
// demoted to a compact current-tab chip in the bottom bar, branch
// beside it — VS Code's own bottom-left — the teaching hints kept in
// reach, Dark+ colors with the blue status bar, the activity-bar icon
// rail, and files that open ready to type (Esc still reaches vim).
func (e *Env) PresetVSCode() *Env {
	e.TopBar()
	e.StatusLeft("tabs", "branch")
	e.StatusRight("cwd", "hints")
	e.TabStyle("current")
	e.BufferLineMode("always")
	e.Theme("vscode-dark")
	e.EditorMode("insert")
	e.ActivityBar(true)
	e.ExplorerAuto(true)
	return e
}

func (e *Env) FontFamily(name string) *Env      { return e.Set("font-family", name) }
func (e *Env) FontSize(pts float64) *Env        { return e.Set("font-size", pts) }
func (e *Env) Theme(name string) *Env           { return e.Set("theme", name) }
func (e *Env) BackgroundOpacity(v float64) *Env { return e.Set("background-opacity", v) }
func (e *Env) BackgroundBlur(mode string) *Env  { return e.Set("background-blur", mode) }
func (e *Env) WindowPadding(pts float64) *Env   { return e.Set("window-padding", pts) }
func (e *Env) Bell(mode string) *Env            { return e.Set("bell", mode) }
func (e *Env) ClipboardWrite(mode string) *Env  { return e.Set("clipboard-write", mode) }
func (e *Env) BufferLine(on bool) *Env          { return e.Set("buffer-line", on) }

// BufferLineMode is BufferLine's three-way form: "off", "multiple"
// (the default — the strip appears with the second document) or
// "always" (VS Code's: the tab is there from the first file).
func (e *Env) BufferLineMode(mode string) *Env { return e.Set("buffer-line", mode) }
func (e *Env) CursorBlink(on bool) *Env        { return e.Set("cursor-blink", on) }
func (e *Env) Scrollback(size string) *Env     { return e.Set("scrollback", size) }

// ---- emission ----

// JSON renders the canonical bytes of the graph.
func (e *Env) JSON() []byte {
	var b strings.Builder
	b.WriteString(`{"rookEnvironment":1,"nodes":[`)
	for i, n := range e.nodes {
		if i > 0 {
			b.WriteByte(',')
		}
		b.WriteString(`{"id":`)
		writeString(&b, n.id)
		b.WriteString(`,"kind":`)
		writeString(&b, n.kind)
		b.WriteString(`,"scope":`)
		writeString(&b, n.scope)
		switch n.kind {
		case "option":
			b.WriteString(`,"key":`)
			writeString(&b, n.key)
			b.WriteString(`,"value":`)
			writeValue(&b, n.value)
		case "leader":
			b.WriteString(`,"key":`)
			writeString(&b, n.key)
		case "keybind":
			b.WriteString(`,"chord":`)
			writeString(&b, n.chord)
			b.WriteString(`,"command":`)
			writeString(&b, n.command)
		case "table":
			b.WriteString(`,"name":`)
			writeString(&b, n.name)
			b.WriteString(`,"entries":`)
			writeEntries(&b, n.entries)
		case "plugin":
			b.WriteString(`,"name":`)
			writeString(&b, n.name)
			// One of the two, never both: a source says where the binary
			// comes FROM and rook caches it; a command says where it
			// already IS. Emitting both would leave two answers to the
			// same question.
			if n.source != "" {
				b.WriteString(`,"source":`)
				writeString(&b, n.source)
			} else {
				b.WriteString(`,"command":`)
				writeStrings(&b, n.argv)
			}
			b.WriteString(`,"load":`)
			writeString(&b, n.load)
			b.WriteString(`,"grants":`)
			writeStrings(&b, n.grants)
		}
		b.WriteByte('}')
	}
	b.WriteString("]}\n")
	return []byte(b.String())
}

// Run is the program's main: `env-program` prints the graph to stdout,
// `env-program --out PATH` writes it (the app reads
// ~/.config/rook/environment.json). Kept trivial on purpose — apply
// orchestration belongs to `rook env`, not to every user's program.
func (e *Env) Run() {
	out := flag.String("out", "", "write the graph here instead of stdout")
	flag.Parse()
	data := e.JSON()
	if *out == "" {
		os.Stdout.Write(data)
		return
	}
	if err := os.WriteFile(*out, data, 0o644); err != nil {
		fmt.Fprintf(os.Stderr, "rook env: %v\n", err)
		os.Exit(1)
	}
}

// writeString escapes exactly like every other SDK: the JSON minimum
// (quote, backslash, control chars), no HTML escaping, raw UTF-8.
func writeString(b *strings.Builder, s string) {
	b.WriteByte('"')
	for _, r := range s {
		switch r {
		case '"':
			b.WriteString(`\"`)
		case '\\':
			b.WriteString(`\\`)
		case '\n':
			b.WriteString(`\n`)
		case '\t':
			b.WriteString(`\t`)
		case '\r':
			b.WriteString(`\r`)
		default:
			if r < 0x20 {
				fmt.Fprintf(b, `\u%04x`, r)
			} else {
				b.WriteRune(r)
			}
		}
	}
	b.WriteByte('"')
}

// writeStrings emits a JSON array, ALWAYS — never null. An absent grants
// list and an empty one mean the same thing (nothing granted) and a reader
// that has to handle both shapes is a reader that will get one wrong.
func writeStrings(b *strings.Builder, ss []string) {
	b.WriteByte('[')
	for i, s := range ss {
		if i > 0 {
			b.WriteByte(',')
		}
		writeString(b, s)
	}
	b.WriteByte(']')
}

func writeValue(b *strings.Builder, v any) {
	switch x := v.(type) {
	case nil:
		b.WriteString("null")
	case bool:
		if x {
			b.WriteString("true")
		} else {
			b.WriteString("false")
		}
	case string:
		writeString(b, x)
	case int:
		b.WriteString(strconv.Itoa(x))
	case int64:
		b.WriteString(strconv.FormatInt(x, 10))
	case float64:
		// Integral floats emit as integers — the canonical-bytes rule
		// that keeps Go's 1, Python's 1.0 and TS's 1 the same byte.
		if x == float64(int64(x)) {
			b.WriteString(strconv.FormatInt(int64(x), 10))
		} else {
			b.WriteString(strconv.FormatFloat(x, 'g', -1, 64))
		}
	case []string:
		b.WriteByte('[')
		for i, s := range x {
			if i > 0 {
				b.WriteByte(',')
			}
			writeString(b, s)
		}
		b.WriteByte(']')
	case []any:
		b.WriteByte('[')
		for i, e := range x {
			if i > 0 {
				b.WriteByte(',')
			}
			writeValue(b, e)
		}
		b.WriteByte(']')
	default:
		// A type the canon doesn't cover would silently skew parity —
		// fail loudly at emit time instead, which is a compile-adjacent
		// moment where the user can fix it.
		fmt.Fprintf(os.Stderr, "rook env: unsupported value type %T\n", v)
		os.Exit(1)
	}
}

func writeEntries(b *strings.Builder, m map[string]any) {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	b.WriteByte('{')
	for i, k := range keys {
		if i > 0 {
			b.WriteByte(',')
		}
		writeString(b, k)
		b.WriteByte(':')
		writeValue(b, m[k])
	}
	b.WriteByte('}')
}
