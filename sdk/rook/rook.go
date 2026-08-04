// Package rook is the Go SDK for describing a rook development
// environment.
//
// A config is a LIST OF DECLARATIONS — values, not statements:
//
//	func main() {
//		rook.Main(
//			rook.Font{Family: "Hack Nerd Font Mono", Size: 16},
//			rook.Theme("nocturne"),
//			rook.Leaders{App: "`", Editor: ","},
//			rook.Binds{
//				"<leader>v": rook.CmdPaneSplitRight,
//				"<leader>c": rook.CmdTabNew,
//			},
//			rook.Workspaces{
//				"rook": "~/go/src/github.com/incantery/rook",
//			},
//		)
//	}
//
// The program importing this is not configuration in the init.lua
// sense: it does not run inside rook and cannot mutate anything. It
// runs once, at apply time, and emits a graph — the IR documented in
// docs/environments/IR.md — which rook materializes at launch.
//
// Commands are TYPED (cmds.go, generated from the app's own registry),
// so a chord bound to a command that does not exist fails to compile
// instead of being silently skipped at load — which is most of the
// reason to write config in Go at all.
//
// Groups (Binds, Workspaces, EditorBinds) are sugar, not structure:
// each flattens into per-entry nodes, sorted for canonical bytes, and
// merges per entry — two Binds{} in one config union, the later chord
// winning in the earlier one's position. A duplicate key WITHIN one
// group is Go's own compile error, which is stricter than the graph's
// later-wins and deliberately so.
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

// Node is one declaration: anything that can contribute nodes to the
// graph. Every exported value type in this package implements it.
type Node interface {
	appendTo(e *env)
}

// Main is the config program's entire main: emit the graph for these
// declarations to stdout, or to --out PATH (how rook invokes it).
func Main(decls ...Node) {
	out := flag.String("out", "", "write the graph here instead of stdout")
	flag.Parse()
	data := JSON(decls...)
	if *out == "" {
		os.Stdout.Write(data)
		return
	}
	if err := os.WriteFile(*out, data, 0o644); err != nil {
		fmt.Fprintf(os.Stderr, "rook env: %v\n", err)
		os.Exit(1)
	}
}

// JSON renders the canonical bytes for these declarations — Main
// without the I/O, for tests and for callers doing their own writing.
func JSON(decls ...Node) []byte {
	var e env
	for _, d := range decls {
		if d != nil {
			d.appendTo(&e)
		}
	}
	return e.json()
}

// Group combines declarations into one Node. A preset is exactly this;
// so is any bundle you want to reuse between machines or personas.
func Group(decls ...Node) Node { return group(decls) }

type group []Node

func (g group) appendTo(e *env) {
	for _, d := range g {
		if d != nil {
			d.appendTo(e)
		}
	}
}

// Cmd is a registry command id. The constants in cmds.go are generated
// from app/src/registry.zig — the app's one command vocabulary — so a
// binding cannot name a command that does not exist.
type Cmd string

// TabSelect is the parameterized `tab.select-N` (1–9): jump to tab N.
func TabSelect(n int) Cmd { return Cmd("tab.select-" + strconv.Itoa(n)) }

// ---- options ----

// Set is the escape hatch: one app option by key, for keys the SDK has
// not grown a type for yet. Prefer the typed declarations.
func Set(key string, value any) Node { return opt{key, value} }

type opt struct {
	key   string
	value any
}

func (o opt) appendTo(e *env) {
	e.put(node{id: "option:app:" + o.key, kind: "option", scope: "app", key: o.key, value: o.value})
}

// Theme names a theme ("nocturne", "vscode-dark", …; case-insensitive).
type Theme string

func (t Theme) appendTo(e *env) { opt{"theme", string(t)}.appendTo(e) }

// Font declares the face and size. Zero fields are unset, not zero:
// Font{Size: 16} leaves the family alone.
type Font struct {
	Family string
	Size   float64 // points, app clamps to 6–72
}

func (f Font) appendTo(e *env) {
	if f.Family != "" {
		opt{"font-family", f.Family}.appendTo(e)
	}
	if f.Size != 0 {
		opt{"font-size", f.Size}.appendTo(e)
	}
}

// Window declares window chrome. Zero fields are unset (0 is outside
// every valid range here — opacity floors at 0.3).
type Window struct {
	Opacity  float64 // 0.3–1.0
	Padding  float64 // points, 0–32; the one knob
	PaddingX float64
	PaddingY float64
	Blur     Blur
}

func (w Window) appendTo(e *env) {
	if w.Opacity != 0 {
		opt{"background-opacity", w.Opacity}.appendTo(e)
	}
	if w.Padding != 0 {
		opt{"window-padding", w.Padding}.appendTo(e)
	}
	if w.PaddingX != 0 {
		opt{"window-padding-x", w.PaddingX}.appendTo(e)
	}
	if w.PaddingY != 0 {
		opt{"window-padding-y", w.PaddingY}.appendTo(e)
	}
	if w.Blur != "" {
		opt{"background-blur", string(w.Blur)}.appendTo(e)
	}
}

// Blur is the window backdrop treatment.
type Blur string

const (
	BlurNone       Blur = "none"
	BlurBlur       Blur = "blur"
	BlurGlass      Blur = "glass"
	BlurGlassClear Blur = "glass-clear"
)

// Bell is the bell style — and a declaration: `rook.BellVisual,` is a
// complete line of config.
type Bell string

func (b Bell) appendTo(e *env) { opt{"bell", string(b)}.appendTo(e) }

const (
	BellNone    Bell = "none"
	BellVisual  Bell = "visual"
	BellAudible Bell = "audible"
	BellAll     Bell = "all"
)

// TabStyle picks how a `tabs` segment renders — a declaration, like
// Bell.
type TabStyle string

func (t TabStyle) appendTo(e *env) { opt{"tab-style", string(t)}.appendTo(e) }

const (
	TabChips     TabStyle = "chips"      // the top strip's pill
	TabIndexName TabStyle = "index-name" // tmux's `1:name 2:name`
	TabCurrent   TabStyle = "current"    // one compact active chip
)

// EditorMode is what a fresh file buffer opens in — a declaration.
type EditorMode string

func (m EditorMode) appendTo(e *env) { opt{"editor-mode", string(m)}.appendTo(e) }

const (
	EditorNormal EditorMode = "normal"
	EditorInsert EditorMode = "insert" // VS Code's hand; Esc still reaches vim
)

// BufferLine is the per-pane buffer strip's mode — a declaration.
type BufferLine string

func (b BufferLine) appendTo(e *env) { opt{"buffer-line", string(b)}.appendTo(e) }

const (
	BufferLineOff      BufferLine = "off"
	BufferLineMultiple BufferLine = "multiple" // appears with the second document
	BufferLineAlways   BufferLine = "always"   // VS Code's: there from the first
)

// Seg is one status-bar segment.
type Seg string

const (
	SegTabs      Seg = "tabs"
	SegWorkspace Seg = "workspace"
	SegBranch    Seg = "branch"
	SegCwd       Seg = "cwd"
	SegHints     Seg = "hints"
	SegHud       Seg = "hud"
	SegTitle     Seg = "title"
)

// TopBar sets the top strip's contents. No arguments hides the strip
// and the pane area reclaims its row.
func TopBar(segments ...Seg) Node { return opt{"top-bar", segStrings(segments)} }

// StatusLeft / StatusRight set the bottom bar's two clusters, in
// display order — tmux's own keys. When the window is narrow, segments
// shed from the END of the right list backward, then the left.
func StatusLeft(segments ...Seg) Node  { return opt{"status-left", segStrings(segments)} }
func StatusRight(segments ...Seg) Node { return opt{"status-right", segStrings(segments)} }

func segStrings(segments []Seg) []string {
	out := make([]string, len(segments))
	for i, s := range segments {
		out[i] = string(s)
	}
	return out
}

// The boolean and small-scalar options, each one declaration.
func ActivityBar(on bool) Node    { return opt{"activity-bar", on} }    // VS Code's icon rail
func ExplorerAuto(on bool) Node   { return opt{"explorer-auto", on} }   // file tree opens with a repo
func CursorBlink(on bool) Node    { return opt{"cursor-blink", on} }    //
func PaneDim(amount float64) Node { return opt{"pane-dim", amount} }    // fade unfocused panes, 0–0.9
func ClipboardWrite(on bool) Node { return opt{"clipboard-write", on} } // OSC 52 writes
func Scrollback(size string) Node { return opt{"scrollback", size} }    // "10mb", or lines

// ---- leaders and keybinds ----

// Leaders declares the two leader keys: the app's (tmux's prefix) and
// the editor's own (vim's maplocalleader — a separate namespace on
// purpose). Empty fields are unset. TAB, SPACE and ESC are accepted.
type Leaders struct {
	App    string
	Editor string
}

func (l Leaders) appendTo(e *env) {
	if l.App != "" {
		e.put(node{id: "leader:app", kind: "leader", scope: "app", key: l.App})
	}
	if l.Editor != "" {
		e.put(node{id: "leader:editor", kind: "leader", scope: "editor", key: l.Editor})
	}
}

// Binds is the app leader's chord table: "<leader>X" to a command. A
// duplicate chord in one literal is a compile error; across groups the
// later declaration wins per chord. Emitted sorted by chord — Go map
// order is random and the graph's bytes must not be.
type Binds map[string]Cmd

func (b Binds) appendTo(e *env) {
	for _, chord := range sortedKeys(b) {
		e.put(node{id: "keybind:app:" + chord, kind: "keybind", scope: "app", chord: chord, command: string(b[chord])})
	}
}

// EditorBinds is the EDITOR leader's chord table (normal mode — the
// only mode the editor leader arms in). Same rules as Binds.
type EditorBinds map[string]Cmd

func (b EditorBinds) appendTo(e *env) {
	for _, chord := range sortedKeys(b) {
		e.put(node{id: "keybind:editor.normal:" + chord, kind: "keybind", scope: "editor.normal", chord: chord, command: string(b[chord])})
	}
}

// Bind is the single-chord form, for the computed case.
func Bind(chord string, do Cmd) Node { return Binds{chord: do} }

// EditorBind is Bind for the editor leader.
func EditorBind(chord string, do Cmd) Node { return EditorBinds{chord: do} }

// ---- workspaces ----

// Workspaces declares named directories rook treats as workspaces:
// the palette lists them, a space launched inside one wears its name,
// worktree tooling anchors on the root. A leading "~/" is expanded by
// rook against $HOME. Emitted sorted by name, so the palette is
// alphabetical — stable beats clever for muscle memory.
//
// Worktrees are deliberately absent: rook derives them live from each
// root's .git/worktrees, so there is no second list to keep in step.
type Workspaces map[string]string

func (w Workspaces) appendTo(e *env) {
	for _, name := range sortedKeys(w) {
		Workspace{Name: name, Root: w[name]}.appendTo(e)
	}
}

// Workspace is the single form, for the computed case — or when
// declaration order should be the palette order.
type Workspace struct {
	Name string
	Root string
}

func (w Workspace) appendTo(e *env) {
	e.put(node{id: "workspace:" + w.Name, kind: "workspace", scope: "app", name: w.Name, root: w.Root})
}

// ---- plugins ----

// Plugin declares a plugin: what to run (or where to fetch it), when,
// and what it MAY do. One struct, three strengths:
//
//	Plugin{Name: "hello", Command: []string{"/path/hello"}}   a binary on disk
//	Plugin{Source: "https://…/hello-plugin"}                  rook fetches and caches it
//	Plugin{Source: "https://…", SHA256: "459e7f1e…"}          …and pins the bytes
//
// Source and Command are mutually exclusive — two answers to "where is
// the binary" — and emission fails loudly on both or neither. With a
// Source, Name defaults to its last path segment.
//
// DECLARED vs GRANTED is the load-bearing distinction: the plugin's
// own describe says what it WANTS, Grants say what it MAY HAVE, and
// `ctl plugins` shows both so the gap is visible. Empty Grants is a
// declared-but-inert plugin — useful for staging one before trust.
//
// Load defaults to lazy for the reason every poller in rook's history
// learned the hard way: a surface nobody opened must cost nothing.
type Plugin struct {
	Name    string
	Command []string
	Source  string
	SHA256  string
	Load    Load
	Grants  []string
}

func (p Plugin) appendTo(e *env) {
	if (p.Source == "") == (len(p.Command) == 0) {
		fmt.Fprintf(os.Stderr, "rook env: plugin %q needs exactly one of Source or Command\n", p.Name)
		os.Exit(1)
	}
	name := p.Name
	if name == "" && p.Source != "" {
		name = p.Source
		if i := strings.LastIndex(name, "/"); i >= 0 {
			name = name[i+1:]
		}
	}
	if name == "" {
		fmt.Fprintln(os.Stderr, "rook env: a Command plugin needs a Name")
		os.Exit(1)
	}
	load := p.Load
	if load == "" {
		load = Lazy
	}
	grants := p.Grants
	if grants == nil {
		grants = []string{}
	}
	e.put(node{
		id: "plugin:" + name, kind: "plugin", scope: "app",
		name: name, argv: p.Command, source: p.Source, sha256: p.SHA256,
		load: string(load), grants: grants,
	})
}

// Load is when a plugin spawns.
type Load string

const (
	Lazy  Load = "lazy"  // on first use — the default
	Eager Load = "eager" // at launch, for one that must watch before you look
)

// The known plugin-protocol op names, for Grants. The vocabulary is
// open — a plugin may define its own ops — so these are convenience,
// not an enum.
const (
	OpItemsList      = "items.list"
	OpItemsAct       = "items.act"
	OpAttentionRaise = "attention.raise"
	OpSessionSpawn   = "session.spawn"
	OpSessionSend    = "session.send"   // type into an agent pane; the ask round trip's last hop
	OpClipboardSet   = "clipboard.set"  // plugin → pasteboard; the human's ⌘V is the last hop
	OpPanesActivity  = "panes.activity" // read pane output rates and last-input ages
)

// ---- first-party plugins: typed declarations ----
//
// The plugins that ship inside the app bundle, declared by FIELD
// instead of by argv — the same reason commands are typed constants:
// nobody should remember a flag to use their own tools. Each lowers
// to a plain Plugin at emit time, so the graph records the exact
// flags it chose (a preset's rule: expand where provenance can see),
// `rook env` diffs the same truth either way, and a hand-written
// Plugin{} stays the escape hatch for any knob without a field here.
//
// Grants default to each plugin's working set. That is a deliberate
// stance for FIRST-PARTY plugins only: choosing rook.Agent{} is
// choosing the agent, and the grants it runs on are shown in the
// apply diff where consent actually happens. Narrow with Grants;
// stage one inert with Grants: []string{}.

const bundleBin = "/Applications/rook.app/Contents/MacOS/"

// Claude is the Claude Code watcher: it reads transcripts, raises
// attention when a session finishes a long turn or looks stuck on an
// approval, and can spawn sessions from the panel.
type Claude struct {
	Grants []string // default: list/act, attention.raise, session.spawn, panes.activity
	Load   Load     // default Eager — a watcher that loads lazily watches nothing
}

func (c Claude) appendTo(e *env) {
	Plugin{
		Name:    "claude",
		Command: []string{bundleBin + "rook-plugin-claude"},
		Load:    eagerUnless(c.Load),
		Grants: grantsOr(c.Grants, []string{
			OpItemsList, OpItemsAct, OpAttentionRaise, OpSessionSpawn, OpPanesActivity,
		}),
	}.appendTo(e)
}

// Agent is the rook agent — the membrane between you and your
// agents. It compresses finished turns into STE digests, drafts and
// expands replies, and hands them back through the clipboard.
type Agent struct {
	// Model names what does the compressing. Empty means
	// "gpt-5.6-luna" — the 2026-08-03 bake-off winner (hardest
	// compression, kept done-vs-todo, cheapest measured bill).
	Model string
	// API is where completions go. The zero value is OpenAI, keyed
	// from ~/.config/rook/openai_key or $OPENAI_API_KEY. See Ollama
	// and APIBase for local servers — those need no key, and models
	// the price table does not know show no cost rather than a
	// made-up one.
	API AgentAPI
	// KeyFile names the file holding the key for the chosen API, for
	// when it is not the OpenAI one. Borrowing the fleet's key (see
	// CloudAPI) means naming the machine token here: the two
	// credentials live in separate files on purpose, because they are
	// minted and revoked in different places by different people.
	// Empty keeps the plugin's default, ~/.config/rook/openai_key.
	KeyFile string
	// MinWords is the shortest reply worth compressing; 0 keeps the
	// plugin's default (120).
	MinWords int
	Grants   []string // default: list/act, clipboard.set
	Load     Load     // default Eager
}

func (a Agent) appendTo(e *env) {
	model := a.Model
	if model == "" {
		model = "gpt-5.6-luna"
	}
	cmd := []string{bundleBin + "rook-plugin-agent", "--model", model}
	if a.API.base != "" {
		cmd = append(cmd, "--api-base", a.API.base)
	}
	if a.KeyFile != "" {
		cmd = append(cmd, "--key-file", a.KeyFile)
	}
	if a.MinWords > 0 {
		cmd = append(cmd, "--min-words", strconv.Itoa(a.MinWords))
	}
	Plugin{
		Name:    "agent",
		Command: cmd,
		Load:    eagerUnless(a.Load),
		Grants:  grantsOr(a.Grants, []string{OpItemsList, OpItemsAct, OpClipboardSet}),
	}.appendTo(e)
}

// AgentAPI is where the rook agent sends completions. The zero value
// is OpenAI; any OpenAI-compatible server is one APIBase call away.
type AgentAPI struct{ base string }

// APIBase points the agent at any OpenAI-compatible endpoint —
// ollama, LM Studio, llama.cpp, vLLM, or a proxy of your own.
func APIBase(url string) AgentAPI { return AgentAPI{base: url} }

// Ollama is ollama's default local endpoint.
var Ollama = APIBase("http://localhost:11434/v1")

// CloudAPI sends the agent's completions through rook-cloud rather than
// straight to OpenAI: the fleet's key pays, the fleet's meter records
// what it cost, and this machine needs no OpenAI key of its own. Same
// OpenAI-compatible wire either way — nothing about the agent changes
// but where it points.
//
// Pair it with the machine token, which is the bearer that endpoint
// authenticates — the cloud token, not an OpenAI one:
//
//	rook.Agent{API: rook.CloudAPI, KeyFile: rook.CloudTokenFile}
//
// The model has to be one the proxy is willing to pay for, and its
// refusal names the list. The zero-value model is on it.
var CloudAPI = APIBase("https://api.rookide.com/v1")

// CloudTokenFile is where the machine token lives, minted once on the
// machines page — the same file the cloud bridge reads.
const CloudTokenFile = "~/.config/rook/cloud_token"

// Cloud is the bridge to cloud.rookide.com: this machine on the fleet
// pages, its needs-input sessions answerable from your phone. Token:
// ~/.config/rook/cloud_token, minted once on the machines page.
type Cloud struct {
	// API overrides the rook-cloud endpoint — a localhost or LAN
	// deployment. Empty means the live cloud, and the panel names
	// any non-default target so "connected to the wrong one" never
	// reads like the right one.
	API    string
	Grants []string // default: list/act, panes.activity, session.send
	Load   Load     // default Eager
}

func (c Cloud) appendTo(e *env) {
	cmd := []string{bundleBin + "rook-plugin-cloud"}
	if c.API != "" {
		cmd = append(cmd, "--api", c.API)
	}
	Plugin{
		Name:    "cloud",
		Command: cmd,
		Load:    eagerUnless(c.Load),
		Grants:  grantsOr(c.Grants, []string{OpItemsList, OpItemsAct, OpPanesActivity, OpSessionSend}),
	}.appendTo(e)
}

// eagerUnless: the first-party plugins are watchers, and a watcher
// that loads lazily watches nothing — so their unset Load means
// Eager, the opposite of Plugin's own default.
func eagerUnless(l Load) Load {
	if l == "" {
		return Eager
	}
	return l
}

func grantsOr(got, def []string) []string {
	if got == nil {
		return def
	}
	return got
}

// ---- presets: identities as bundles ----
//
// A preset EXPANDS at emit time — the graph shows every knob it set,
// which is what future provenance attaches to. These bundles must
// match config.zig's applyPreset (the TOML front end's expansion):
// the golden test here pins this side, the e2e `presetparity`
// scenario diffs both sides on the live app. Declarations after a
// preset override its nodes in place — a preset is a defaults layer.

// PresetTmuxNeovim arranges rook for a tmux+neovim hand: no top strip,
// one bottom bar with the tab list as text (tmux's window list), no
// buffer line (:ls people). Leaders are yours to set.
func PresetTmuxNeovim() Node {
	return Group(
		TopBar(),
		StatusLeft(SegTabs),
		StatusRight(SegWorkspace, SegBranch, SegCwd),
		TabIndexName,
		// false, not "off": the bool spelling is this bundle's pinned
		// byte (the TOML expansion emits the same), and bytes are the
		// preset-parity contract.
		Set("buffer-line", false),
	)
}

// PresetVSCode arranges rook for a VS Code hand — look and feel both:
// editor surfaces carry identity (per-pane buffer line always on),
// sessions demoted to a compact current-tab chip, branch beside it,
// hints in reach, Dark+ colors, the activity-bar icon rail, and files
// that open ready to type (Esc still reaches vim).
func PresetVSCode() Node {
	return Group(
		TopBar(),
		StatusLeft(SegTabs, SegBranch),
		StatusRight(SegCwd, SegHints),
		TabCurrent,
		BufferLineAlways,
		Theme("vscode-dark"),
		EditorInsert,
		ActivityBar(true),
		ExplorerAuto(true),
	)
}

// ---- the accumulator and canonical emission ----

type env struct {
	nodes []node
}

type node struct {
	source  string
	sha256  string
	id      string
	kind    string
	scope   string
	key     string // option, leader
	value   any    // option
	chord   string // keybind
	command string // keybind
	name    string // plugin, workspace
	// plugin
	argv   []string
	load   string
	grants []string
	// workspace
	root string
}

// put appends, or replaces in place when the id already exists — the
// later declaration wins, at the earlier one's position. What makes
// composing environments (a preset, then overrides) mean something.
func (e *env) put(n node) {
	for i := range e.nodes {
		if e.nodes[i].id == n.id {
			e.nodes[i] = n
			return
		}
	}
	e.nodes = append(e.nodes, n)
}

func sortedKeys[V any](m map[string]V) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}

func (e *env) json() []byte {
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
		case "workspace":
			b.WriteString(`,"name":`)
			writeString(&b, n.name)
			b.WriteString(`,"root":`)
			writeString(&b, n.root)
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
				if n.sha256 != "" {
					b.WriteString(`,"sha256":`)
					writeString(&b, n.sha256)
				}
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
