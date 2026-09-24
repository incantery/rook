package config

import (
	"fmt"
	"regexp"
	"sort"
	"strings"
)

// Style is one set of looks: every field optional, unset meaning "as
// the rule before left it". The same fields make [style] (everywhere,
// home included) and each [[style.match]] (docs/style.md).
type Style struct {
	// ---- colours: a hex colour, an ANSI name, or a role named below
	Accent        *string `toml:"accent" json:"accent,omitempty"`
	Bar           *string `toml:"bar" json:"bar,omitempty"`
	Raised        *string `toml:"raised" json:"raised,omitempty"`
	Selection     *string `toml:"selection" json:"selection,omitempty"`
	Text          *string `toml:"text" json:"text,omitempty"`
	Subtext       *string `toml:"subtext" json:"subtext,omitempty"`
	Muted         *string `toml:"muted" json:"muted,omitempty"`
	Border        *string `toml:"border" json:"border,omitempty"`
	BorderFocused *string `toml:"border_focused" json:"border_focused,omitempty"`
	Attention     *string `toml:"attention" json:"attention,omitempty"`
	Working       *string `toml:"working" json:"working,omitempty"`
	Unread        *string `toml:"unread" json:"unread,omitempty"`
	Success       *string `toml:"success" json:"success,omitempty"`
	Error         *string `toml:"error" json:"error,omitempty"`
	ChipBg        *string `toml:"chip_bg" json:"chip_bg,omitempty"`
	ChipFg        *string `toml:"chip_fg" json:"chip_fg,omitempty"`
	// Tint pulls the chrome — both bars, the raised fills, the seams —
	// toward a colour, TintAmount percent of the way (26 when unset).
	Tint       *string `toml:"tint" json:"tint,omitempty"`
	TintAmount *int    `toml:"tint_amount" json:"tint_amount,omitempty"`

	// ---- shape
	// Chip and Tabs are the caps of the scope chip and the selected
	// tab: plain, bracket, powerline, round, slant.
	Chip *string `toml:"chip" json:"chip,omitempty"`
	Tabs *string `toml:"tabs" json:"tabs,omitempty"`
	// Separator is what stands between the chip and the tabs; "" is none.
	Separator *string `toml:"separator" json:"separator,omitempty"`
	// Fill is what the bars' empty cells are drawn with, repeated.
	Fill *string `toml:"fill" json:"fill,omitempty"`

	// ---- words: templates over {name} {repo} {branch} {dir} {icon},
	// and the same in capitals ({NAME}) for the word upper-cased
	Icon     *string `toml:"icon" json:"icon,omitempty"`
	Label    *string `toml:"label" json:"label,omitempty"`
	BarLabel *string `toml:"bar_label" json:"bar_label,omitempty"`
}

// When is what a [[style.match]] asks of the workspace on the glass.
// Every condition said must hold; one unsaid holds. Globs: `*` is any
// run, `?` one character.
type When struct {
	Home      *bool  `toml:"home" json:"home,omitempty"`
	Workspace string `toml:"workspace" json:"workspace,omitempty"`
	// Dir is the focused pane's directory; `~` is $HOME.
	Dir string `toml:"dir" json:"dir,omitempty"`
	// Repo is its repository's origin, as host/owner/name.
	Repo   string `toml:"repo" json:"repo,omitempty"`
	Branch string `toml:"branch" json:"branch,omitempty"`
	// Program is the focused pane's foreground program.
	Program string `toml:"program" json:"program,omitempty"`
	// Class is a class on the workspace or any pane in it — put there
	// by `rook class`, or by a program with OSC 1337 SetUserVar.
	Class string `toml:"class" json:"class,omitempty"`
	// State is one of rook's own facts of the workspace (States).
	State string `toml:"state" json:"state,omitempty"`
}

// States are what rook knows of a workspace for itself, as a rule may
// ask (mux/src/style.zig State).
var States = []string{"unread", "working", "zoomed", "copy", "popup"}

// Match is one [[style.match]]: its conditions and its looks, side by
// side in one table.
type Match struct {
	When
	Style
}

// EngineStyle is the stylesheet as the engine reads it.
type EngineStyle struct {
	Base  Style        `json:"base"`
	Rules []EngineRule `json:"rules,omitempty"`
}

type EngineRule struct {
	When  When  `json:"when"`
	Style Style `json:"style"`
}

var (
	hexColour  = regexp.MustCompile(`^#([0-9a-fA-F]{3}|[0-9a-fA-F]{6})$`)
	ansiNames  = []string{"black", "red", "green", "yellow", "blue", "magenta", "cyan", "white"}
	roleNames  = []string{"accent", "bar", "raised", "selection", "text", "subtext", "muted", "border", "border_focused", "attention", "working", "unread", "success", "error"}
	capShapes  = []string{"plain", "bracket", "powerline", "round", "slant"}
	templateRe = regexp.MustCompile(`\{([a-zA-Z]+)\}`)
	tokens     = []string{"name", "repo", "branch", "dir", "icon"}
)

func contains(list []string, v string) bool {
	for _, x := range list {
		if x == v {
			return true
		}
	}
	return false
}

func checkColour(where, key string, v *string) error {
	if v == nil {
		return nil
	}
	c := strings.TrimPrefix(*v, "bright-")
	if hexColour.MatchString(c) || contains(ansiNames, c) || contains(roleNames, c) {
		return nil
	}
	return fmt.Errorf("%s %s = %q: a hex colour (#rrggbb), an ANSI name, or a role (%s)", where, key, *v, strings.Join(roleNames, ", "))
}

func checkTemplate(where, key string, v *string) error {
	if v == nil {
		return nil
	}
	for _, m := range templateRe.FindAllStringSubmatch(*v, -1) {
		if !contains(tokens, strings.ToLower(m[1])) {
			return fmt.Errorf("%s %s = %q: no token {%s} (%s)", where, key, *v, m[1], "{"+strings.Join(tokens, "} {")+"}")
		}
	}
	return nil
}

func (s Style) check(where string) error {
	colours := map[string]*string{
		"accent": s.Accent, "bar": s.Bar, "raised": s.Raised, "selection": s.Selection,
		"text": s.Text, "subtext": s.Subtext, "muted": s.Muted, "border": s.Border,
		"border_focused": s.BorderFocused, "attention": s.Attention, "working": s.Working,
		"unread": s.Unread, "success": s.Success, "error": s.Error,
		"chip_bg": s.ChipBg, "chip_fg": s.ChipFg, "tint": s.Tint,
	}
	keys := make([]string, 0, len(colours))
	for k := range colours {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		if err := checkColour(where, k, colours[k]); err != nil {
			return err
		}
	}
	for k, v := range map[string]*string{"chip": s.Chip, "tabs": s.Tabs} {
		if v != nil && !contains(capShapes, *v) {
			return fmt.Errorf("%s %s = %q: one of %s", where, k, *v, strings.Join(capShapes, ", "))
		}
	}
	if s.TintAmount != nil && (*s.TintAmount < 0 || *s.TintAmount > 100) {
		return fmt.Errorf("%s tint_amount = %d: 0 to 100", where, *s.TintAmount)
	}
	for k, v := range map[string]*string{"icon": s.Icon, "label": s.Label, "bar_label": s.BarLabel} {
		if err := checkTemplate(where, k, v); err != nil {
			return err
		}
	}
	return nil
}

func checkStyle(base Style, rules []Match) error {
	if err := base.check("[style]"); err != nil {
		return err
	}
	for i, r := range rules {
		if r.State != "" && !contains(States, r.State) {
			return fmt.Errorf("[[style.match]] %d: state = %q: one of %s", i+1, r.State, strings.Join(States, ", "))
		}
		if err := r.Style.check(fmt.Sprintf("[[style.match]] %d:", i+1)); err != nil {
			return err
		}
	}
	return nil
}

// compileStyle is the stylesheet in the engine's shape. [home] color,
// the older way to colour home, is a rule of its own ahead of the
// file's, so a rule that says otherwise wins.
func (c Config) compileStyle() EngineStyle {
	es := EngineStyle{Base: c.Style.Style}
	if c.Home.Color != "" {
		home := true
		col := c.Home.Color
		es.Rules = append(es.Rules, EngineRule{When: When{Home: &home}, Style: Style{Accent: &col}})
	}
	for _, m := range c.Style.Match {
		es.Rules = append(es.Rules, EngineRule{When: m.When, Style: m.Style})
	}
	return es
}
