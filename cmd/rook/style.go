package main

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"sort"
	"strings"

	"github.com/incantery/rook/internal/config"
	"github.com/incantery/rook/internal/mux"
)

// styleFeed is the state feed's `style`: what the engine saw, which
// rules held, and what won (mux/src/statefeed.zig).
type styleFeed struct {
	Scope string `json:"scope"`
	Style struct {
		Facts struct {
			Home      bool   `json:"home"`
			Workspace string `json:"workspace"`
			Dir       string `json:"dir"`
			Repo      string `json:"repo"`
			Branch    string `json:"branch"`
			Program   string `json:"program"`
		} `json:"facts"`
		Rules []struct {
			Source  string `json:"source"`
			Index   int    `json:"index"`
			Matched bool   `json:"matched"`
		} `json:"rules"`
		Computed map[string]any    `json:"computed"`
		From     map[string]string `json:"from"`
	} `json:"style"`
}

// runStyle is `rook style`: the stylesheet explained for the workspace
// on the glass — the devtools "computed" panel for rook's chrome.
func runStyle(args []string) error {
	raw, err := mux.State()
	if err != nil {
		return err
	}
	var st styleFeed
	if err := json.Unmarshal([]byte(raw), &st); err != nil {
		return fmt.Errorf("the engine's state: %w", err)
	}
	if len(args) > 0 && args[0] == "--json" {
		b, _ := json.MarshalIndent(st.Style, "", "  ")
		fmt.Println(string(b))
		return nil
	}
	var rules []config.EngineRule
	if path, err := config.Path(); err == nil {
		if c, err := config.Load(path); err == nil {
			rules = c.Compile().Style.Rules
		}
	}
	explain(os.Stdout, st, rules)
	return nil
}

// builtinWhen describes rook's own rules, in the engine's order
// (style.builtin).
var builtinWhen = []string{"home = true"}

func explain(w io.Writer, st styleFeed, rules []config.EngineRule) {
	f := st.Style.Facts
	where := "a space"
	if f.Home {
		where = "home"
	}
	fmt.Fprintf(w, "%s (%s)\n", f.Workspace, where)
	for _, kv := range [][2]string{{"dir", f.Dir}, {"repo", f.Repo}, {"branch", f.Branch}, {"program", f.Program}} {
		v := kv[1]
		if v == "" {
			v = "—"
		}
		fmt.Fprintf(w, "  %-8s %s\n", kv[0], v)
	}
	fmt.Fprintln(w, "\nrules, in order (a later one wins)")
	for _, r := range st.Style.Rules {
		mark := "✗"
		if r.Matched {
			mark = "✓"
		}
		desc := ""
		if r.Source == "rook" {
			if r.Index < len(builtinWhen) {
				desc = builtinWhen[r.Index]
			}
			fmt.Fprintf(w, "  %s rook:%d     %s\n", mark, r.Index, desc)
			continue
		}
		if r.Index < len(rules) {
			desc = whenString(rules[r.Index].When)
		}
		fmt.Fprintf(w, "  %s config:%d   %s\n", mark, r.Index, desc)
	}
	fmt.Fprintln(w, "\ncomputed")
	keys := make([]string, 0, len(st.Style.Computed))
	for k := range st.Style.Computed {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		fmt.Fprintf(w, "  %-15s %-24v %s\n", k, st.Style.Computed[k], st.Style.From[k])
	}
	if len(keys) == 0 {
		fmt.Fprintln(w, "  (rook's defaults: nothing said)")
	}
}

// whenString is a rule's conditions as the file says them; config:N
// counts [home] color's rule, when there is one, ahead of the file's.
func whenString(w config.When) string {
	var parts []string
	if w.Home != nil {
		parts = append(parts, fmt.Sprintf("home = %v", *w.Home))
	}
	for _, kv := range [][2]string{{"workspace", w.Workspace}, {"dir", w.Dir}, {"repo", w.Repo}, {"branch", w.Branch}, {"program", w.Program}} {
		if kv[1] != "" {
			parts = append(parts, fmt.Sprintf("%s = %q", kv[0], kv[1]))
		}
	}
	if len(parts) == 0 {
		return "(always)"
	}
	return strings.Join(parts, ", ")
}
