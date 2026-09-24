package config

import (
	"encoding/json"
	"fmt"
	"path/filepath"
	"strings"
)

// Mux is the [mux] table: the engine's knobs. Unset fields are nil or
// empty and mean the engine's own default; nothing here restates one.
type Mux struct {
	// NavOwners are programs that keep Ctrl-hjkl for themselves.
	NavOwners    []string `toml:"nav_owners" json:"nav_owners,omitempty"`
	ScrollbackMB *int     `toml:"scrollback_mb" json:"scrollback_mb,omitempty"`
	// Accent is the one chrome colour: a hex colour or an ANSI name.
	Accent  string `toml:"accent" json:"accent,omitempty"`
	Restore *bool  `toml:"restore" json:"restore,omitempty"`
	// SidebarMode is the legacy side panel: open, collapsed, hidden.
	SidebarMode string `toml:"sidebar_mode" json:"sidebar_mode,omitempty"`
	// Sidebar is SidebarMode's older spelling: true is open.
	Sidebar      *bool    `toml:"sidebar" json:"sidebar,omitempty"`
	SidebarWidth *int     `toml:"sidebar_width" json:"sidebar_width,omitempty"`
	Agents       []string `toml:"agents" json:"agents,omitempty"`
	Bar          *bool    `toml:"bar" json:"bar,omitempty"`
	// Glyphs is "unicode" or "ascii".
	Glyphs string `toml:"glyphs" json:"glyphs,omitempty"`
	// StatusSpace is the calm bar's modules; "-" starts the right side.
	StatusSpace []string `toml:"status_space" json:"status_space,omitempty"`
	// Status is StatusSpace's short spelling.
	Status []string `toml:"status" json:"-"`
	// Startup is where plain `rook` lands: "home" or "last-space".
	Startup string `toml:"startup" json:"startup,omitempty"`

	// Accepted and ignored: the root they configured is gone (docs/home.md).
	StatusHome []string `toml:"status_home" json:"-"`
	ZoomView   string   `toml:"zoom_view" json:"-"`
}

// Engine is the config as the engine reads it: `rook config json`, at
// boot and on every reload. One parser owns rook.toml — this one — and
// the engine is handed its half already checked. Field names are the
// file's own, so a reader of either sees the same words.
type Engine struct {
	V         int               `json:"v"`
	Prefix    string            `json:"prefix,omitempty"`
	Mux       Mux               `json:"mux"`
	Companion string            `json:"companion,omitempty"`
	Keys      map[string]string `json:"keys,omitempty"`
	Home      EngineHome        `json:"home"`
	Style     EngineStyle       `json:"style"`
}

// EngineHome is [home] with its short and long pane forms made one.
type EngineHome struct {
	OnEmpty string         `json:"on_empty,omitempty"`
	Color   string         `json:"color,omitempty"`
	Dir     string         `json:"dir,omitempty"`
	Windows []EngineWindow `json:"windows,omitempty"`
}

type EngineWindow struct {
	Name  string     `json:"name,omitempty"`
	Dir   string     `json:"dir,omitempty"`
	Panes []HomePane `json:"panes,omitempty"`
}

// EngineVersion is bumped when the engine must refuse an older shape.
const EngineVersion = 1

// Compile turns a loaded config into the engine's document.
func (c Config) Compile() Engine {
	m := c.Mux
	if len(m.StatusSpace) == 0 {
		m.StatusSpace = m.Status
	}
	e := Engine{
		V:         EngineVersion,
		Prefix:    c.Tmux.Prefix,
		Mux:       m,
		Companion: c.Companion.program(),
		Keys:      c.Keys,
		Style:     c.compileStyle(),
		Home: EngineHome{
			OnEmpty: c.Home.OnEmpty,
			Color:   c.Home.Color,
			Dir:     c.Home.Dir,
		},
	}
	for _, w := range c.Home.Window {
		ew := EngineWindow{Name: w.Name, Dir: w.Dir}
		for _, cmd := range w.Panes {
			ew.Panes = append(ew.Panes, HomePane{Command: cmd})
		}
		ew.Panes = append(ew.Panes, w.Pane...)
		e.Home.Windows = append(e.Home.Windows, ew)
	}
	return e
}

// JSON is the compiled document, one line.
func (e Engine) JSON() []byte {
	b, _ := json.Marshal(e)
	return b
}

// program is the companion's program name, in the precedence the
// engine used to work out for itself: `program` said outright, then
// the first word of `command`, then `name`. A `program = ""` said
// outright turns the slot off, which TOML cannot tell from unset —
// so `program` is looked at through `programSet`.
func (c Companion) program() string {
	if c.programSet {
		if w := firstWord(c.Program); w != "" {
			return filepath.Base(w)
		}
		return ""
	}
	for _, v := range []string{c.Command, c.Name} {
		if w := firstWord(v); w != "" {
			return filepath.Base(w)
		}
	}
	return ""
}

func firstWord(s string) string {
	f := strings.Fields(s)
	if len(f) == 0 {
		return ""
	}
	return f[0]
}

// checkMux refuses what the engine would quietly misread.
func checkMux(m Mux) error {
	oneOf := func(key, v string, ok ...string) error {
		if v == "" {
			return nil
		}
		for _, o := range ok {
			if v == o {
				return nil
			}
		}
		return fmt.Errorf("[mux] %s = %q: one of %s", key, v, strings.Join(ok, ", "))
	}
	if err := oneOf("sidebar_mode", m.SidebarMode, "open", "collapsed", "hidden"); err != nil {
		return err
	}
	if err := oneOf("glyphs", m.Glyphs, "unicode", "ascii"); err != nil {
		return err
	}
	if err := oneOf("startup", m.Startup, "home", "global", "last-space", "last_space", "space"); err != nil {
		return err
	}
	return nil
}
