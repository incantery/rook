package config

import (
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"strings"

	"github.com/BurntSushi/toml"
)

// A rice is a stylesheet in a file of its own, for sharing:
//
//	include = ["~/.config/rook/rices/*.toml", "grafana.toml"]
//
// at the top of rook.toml (paths relative to the file that includes
// them; `~` and globs work). A rice holds [style], [[style.match]] and
// its own include — nothing else: it can recolour and reshape the
// chrome, never bind a key, float a program or seed home, so one from
// anywhere is safe to try. Its rules come before the including file's,
// in the order included, so your own file always has the last word.

// riceFile is what a rice may say.
type riceFile struct {
	Include []string   `toml:"include"`
	Style   StyleTable `toml:"style"`
}

const maxIncludeDepth = 8

// includes reads what `include` names, depth first, into one sheet:
// every file's [style] merged in order and every file's rules in
// order, each rule remembering the file it came from. `seen` is the
// chain being read, to refuse a cycle; `files` collects every file
// read, for a watcher.
func includes(from string, names []string, depth int, seen map[string]bool, files *[]string) (Style, []Match, []TabMatch, error) {
	var base Style
	var rules []Match
	var tabs []TabMatch
	if depth > maxIncludeDepth {
		return base, nil, nil, fmt.Errorf("%s: includes nest deeper than %d", from, maxIncludeDepth)
	}
	for _, name := range names {
		paths, err := expandInclude(from, name)
		if err != nil {
			return base, nil, nil, err
		}
		for _, p := range paths {
			if seen[p] {
				return base, nil, nil, fmt.Errorf("%s: include %q comes back to itself", from, name)
			}
			var rf riceFile
			md, err := toml.DecodeFile(p, &rf)
			if err != nil {
				return base, nil, nil, fmt.Errorf("%s: %w", p, err)
			}
			if undecoded := md.Undecoded(); len(undecoded) > 0 {
				keys := make([]string, len(undecoded))
				for i, k := range undecoded {
					keys[i] = k.String()
				}
				return base, nil, nil, fmt.Errorf("%s: %s: a rice holds [style], [[style.match]], [[style.tab]] and include, nothing else", p, strings.Join(keys, ", "))
			}
			if err := checkStyle(rf.Style.Style, rf.Style.Match); err != nil {
				return base, nil, nil, fmt.Errorf("%s: %w", p, err)
			}
			if err := checkTabs(rf.Style.Tab); err != nil {
				return base, nil, nil, fmt.Errorf("%s: %w", p, err)
			}
			*files = append(*files, p)
			seen[p] = true
			ib, ir, it, err := includes(p, rf.Include, depth+1, seen, files)
			delete(seen, p)
			if err != nil {
				return base, nil, nil, err
			}
			base = mergeStyle(base, ib)
			rules = append(rules, ir...)
			tabs = append(tabs, it...)
			base = mergeStyle(base, rf.Style.Style)
			for i, m := range rf.Style.Match {
				m.Source = fmt.Sprintf("%s #%d", p, i+1)
				rules = append(rules, m)
			}
			for i, t := range rf.Style.Tab {
				t.Source = fmt.Sprintf("%s tab #%d", p, i+1)
				tabs = append(tabs, t)
			}
		}
	}
	return base, rules, tabs, nil
}

// expandInclude is one include entry as the files it names: `~` is
// $HOME, a relative path is from the including file's directory, and
// a glob is its matches in order. A plain path that is not there is an
// error; a glob that matches nothing is not.
func expandInclude(from, name string) ([]string, error) {
	p := name
	if p == "~" || strings.HasPrefix(p, "~/") {
		home, _ := os.UserHomeDir()
		p = filepath.Join(home, strings.TrimPrefix(p, "~"))
	} else if !filepath.IsAbs(p) {
		p = filepath.Join(filepath.Dir(from), p)
	}
	if strings.ContainsAny(p, "*?[") {
		m, err := filepath.Glob(p)
		if err != nil {
			return nil, fmt.Errorf("%s: include %q: %w", from, name, err)
		}
		sort.Strings(m)
		return m, nil
	}
	if _, err := os.Stat(p); err != nil {
		return nil, fmt.Errorf("%s: include %q: %w", from, name, err)
	}
	return []string{p}, nil
}

// mergeStyle is `over` on top of `base`: each property `over` says wins.
func mergeStyle(base, over Style) Style {
	b := reflect.ValueOf(&base).Elem()
	o := reflect.ValueOf(over)
	for i := 0; i < o.NumField(); i++ {
		if f := o.Field(i); !f.IsNil() {
			b.Field(i).Set(f)
		}
	}
	return base
}
