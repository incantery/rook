package config

import (
	"fmt"
	"regexp"
	"sort"
	"strings"
	"unicode/utf8"
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
	// TabFill is "all" for every tab a filled segment (the unselected a
	// step dimmer), "selected" for only the selected one (rook's).
	TabFill *string `toml:"tab_fill" json:"tab_fill,omitempty"`

	// ---- words: templates over {name} {repo} {branch} {dir} {icon},
	// and the same in capitals ({NAME}) for the word upper-cased
	Icon     *string `toml:"icon" json:"icon,omitempty"`
	Label    *string `toml:"label" json:"label,omitempty"`
	BarLabel *string `toml:"bar_label" json:"bar_label,omitempty"`

	// ---- geometry: these take cells from the work, so only a rule
	// that cannot flicker may set them (no program, class or state)
	// Frame is none, rail, corners or box.
	Frame *string `toml:"frame" json:"frame,omitempty"`
	// FrameColor is a colour like the others; the accent when unset.
	// A colour takes no cells, so any rule may set it.
	FrameColor *string `toml:"frame_color" json:"frame_color,omitempty"`
	// HeaderRule and FooterRule are a row drawn in this character under
	// the tab bar and over the calm bar ("▔", "━", "╌").
	HeaderRule *string `toml:"header_rule" json:"header_rule,omitempty"`
	FooterRule *string `toml:"footer_rule" json:"footer_rule,omitempty"`
	// BarHeight is the tab bar's rows: 1, 2 (a half-block row under the
	// tabs) or 3 (one above and one below, the words centred).
	BarHeight *int `toml:"bar_height" json:"bar_height,omitempty"`
}

var frames = []string{"none", "rail", "corners", "box"}

// geometry is the geometry properties a style says, by name.
func (s Style) geometry() []string {
	var out []string
	if s.Frame != nil {
		out = append(out, "frame")
	}
	if s.HeaderRule != nil {
		out = append(out, "header_rule")
	}
	if s.FooterRule != nil {
		out = append(out, "footer_rule")
	}
	if s.BarHeight != nil {
		out = append(out, "bar_height")
	}
	return out
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
	// Source is where the rule was written: a rice's path and its
	// place in it, or empty for rook.toml's own.
	Source string `toml:"-" json:"-"`
}

// TabStyle is one tab's looks ([[style.tab]]): colour only, so any
// condition may set it.
type TabStyle struct {
	// Color fills the selected tab and, toned down toward the bar,
	// inks the others.
	Color *string `toml:"color" json:"color,omitempty"`
	// ColorInactive is the unselected ink outright.
	ColorInactive *string `toml:"color_inactive" json:"color_inactive,omitempty"`
	// Text is the selected tab's text; light or dark by the fill unsaid.
	Text  *string `toml:"text" json:"text,omitempty"`
	Icon  *string `toml:"icon" json:"icon,omitempty"`
	Label *string `toml:"label" json:"label,omitempty"`
}

// TabMatch is one [[style.tab]]: the workspace's conditions (program,
// class and state asked of the tab), the tab's own name and index, and
// its looks.
type TabMatch struct {
	When
	// Name is the tab's name, a glob.
	Name string `toml:"name" json:"name,omitempty"`
	// Index is its number on the bar, from 1.
	Index *int `toml:"index" json:"index,omitempty"`
	TabStyle
	Source string `toml:"-" json:"-"`
}

// EngineStyle is the stylesheet as the engine reads it.
type EngineStyle struct {
	Base  Style           `json:"base"`
	Rules []EngineRule    `json:"rules,omitempty"`
	Tabs  []EngineTabRule `json:"tabs,omitempty"`
}

type EngineTabRule struct {
	When   When     `json:"when"`
	Name   string   `json:"name,omitempty"`
	Index  *int     `json:"index,omitempty"`
	Style  TabStyle `json:"style"`
	Source string   `json:"source,omitempty"`
}

var tabTokens = []string{"name", "index", "icon", "program", "repo", "branch", "dir"}

func (s TabStyle) check(where string) error {
	for k, v := range map[string]*string{"color": s.Color, "color_inactive": s.ColorInactive, "text": s.Text} {
		if err := checkColour(where, k, v); err != nil {
			return err
		}
	}
	for k, v := range map[string]*string{"icon": s.Icon, "label": s.Label} {
		if v == nil {
			continue
		}
		for _, m := range templateRe.FindAllStringSubmatch(*v, -1) {
			if !contains(tabTokens, strings.ToLower(m[1])) {
				return fmt.Errorf("%s %s = %q: no token {%s} ({%s})", where, k, *v, m[1], strings.Join(tabTokens, "} {"))
			}
		}
	}
	return nil
}

func checkTabs(tabs []TabMatch) error {
	for i, t := range tabs {
		where := fmt.Sprintf("[[style.tab]] %d:", i+1)
		if t.State != "" && !contains(States, t.State) {
			return fmt.Errorf("%s state = %q: one of %s", where, t.State, strings.Join(States, ", "))
		}
		if t.Index != nil && *t.Index < 1 {
			return fmt.Errorf("%s index = %d: tabs count from 1", where, *t.Index)
		}
		if err := t.TabStyle.check(where); err != nil {
			return err
		}
	}
	return nil
}

type EngineRule struct {
	When  When  `json:"when"`
	Style Style `json:"style"`
	// Source is where it was written, for `rook style`; the engine
	// does not read it.
	Source string `json:"source,omitempty"`
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
		"chip_bg": s.ChipBg, "chip_fg": s.ChipFg, "tint": s.Tint, "frame_color": s.FrameColor,
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
	if s.TabFill != nil && *s.TabFill != "all" && *s.TabFill != "selected" {
		return fmt.Errorf("%s tab_fill = %q: \"all\" or \"selected\"", where, *s.TabFill)
	}
	if s.BarHeight != nil && (*s.BarHeight < 1 || *s.BarHeight > 3) {
		return fmt.Errorf("%s bar_height = %d: 1, 2 or 3 rows", where, *s.BarHeight)
	}
	if s.Frame != nil && !contains(frames, *s.Frame) {
		return fmt.Errorf("%s frame = %q: one of %s", where, *s.Frame, strings.Join(frames, ", "))
	}
	for k, v := range map[string]*string{"header_rule": s.HeaderRule, "footer_rule": s.FooterRule} {
		if v != nil && utf8.RuneCountInString(*v) != 1 {
			return fmt.Errorf("%s %s = %q: one character, drawn the width of the glass", where, k, *v)
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
		if g := r.Style.geometry(); len(g) > 0 && (r.Program != "" || r.Class != "" || r.State != "") {
			return fmt.Errorf("[[style.match]] %d: %s takes cells, and a rule on program, class or state flickers: "+
				"it would resize every program in the workspace each time — set it in a rule on home, workspace, dir, repo or branch "+
				"(frame_color, and every other colour, may follow a class)", i+1, strings.Join(g, ", "))
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
		es.Rules = append(es.Rules, EngineRule{When: When{Home: &home}, Style: Style{Accent: &col}, Source: "[home] color"})
	}
	for _, m := range c.Style.Match {
		es.Rules = append(es.Rules, EngineRule{When: m.When, Style: m.Style, Source: m.Source})
	}
	for _, t := range c.Style.Tab {
		es.Tabs = append(es.Tabs, EngineTabRule{When: t.When, Name: t.Name, Index: t.Index, Style: t.TabStyle, Source: t.Source})
	}
	return es
}
