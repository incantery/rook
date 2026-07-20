// Package plugin is rook's plugin substrate (docs/superpowers/specs/
// 2026-07-20-plugins-language-design.md): a curated in-binary catalog of
// plugins the host materializes into its own prefix and runs out-of-process.
// The only kind today is "language" — an LSP server. The generic plugin
// API (external manifests, third-party authoring) is deliberately not
// designed until a second kind exists.
package plugin

import (
	"sort"
	"strings"

	"github.com/incantery/rook/internal/config"
)

// Kind tags a catalog entry's payload — the same kind-tagged-union
// discipline as PaneRef and the rook_tasks anchor.
type Kind string

const KindLanguage Kind = "language"

// Entry is one catalog plugin: rook-shipped code, selectable from either
// config layer, never alterable by config (the trust rule's first tier).
type Entry struct {
	Name    string // catalog key: the language name ("go")
	Kind    Kind
	Version string // pinned; a rook build implies a plugin set
	Lang    *LangEntry
}

// LangEntry is the language kind's payload: which server, how to
// materialize it, and how queries route to it.
type LangEntry struct {
	Server    string   // server name ("gopls") — the lsp-<server> override key
	Args      []string // argv after the binary
	Filetypes []string // extensions, no dot
	Roots     []string // root markers, in resolution order
	Settings  string   // default settings JSON ("" = none)

	// Materialization: delegate to the language's own toolchain, into the
	// manager's prefix — never the user's global environment.
	Method string // "go" | "npm"
	Pkg    string // go: module path; npm: package name
	Bin    string // binary path relative to the version dir
}

// Catalog is the curated set. Small on purpose: the languages rook's own
// users touch, ~10 lines each. The long tail (mason-registry import) is a
// seam, taken only if this set actually constrains.
var Catalog = []Entry{
	{
		Name: "go", Kind: KindLanguage, Version: goplsVersion,
		Lang: &LangEntry{
			Server:    "gopls",
			Args:      []string{"serve"},
			Filetypes: []string{"go", "mod", "work"},
			Roots:     []string{"go.work", "go.mod", ".git"},
			Method:    "go",
			Pkg:       "golang.org/x/tools/gopls",
			Bin:       "bin/gopls",
		},
	},
	{
		Name: "typescript", Kind: KindLanguage, Version: vtslsVersion,
		Lang: &LangEntry{
			Server:    "vtsls",
			Args:      []string{"--stdio"},
			Filetypes: []string{"ts", "tsx", "js", "jsx", "mjs", "cjs"},
			Roots:     []string{"tsconfig.json", "package.json", ".git"},
			Method:    "npm",
			Pkg:       "@vtsls/language-server",
			Bin:       "node_modules/.bin/vtsls",
		},
	},
	{
		Name: "svelte", Kind: KindLanguage, Version: svelteVersion,
		Lang: &LangEntry{
			Server:    "svelteserver",
			Args:      []string{"--stdio"},
			Filetypes: []string{"svelte"},
			Roots:     []string{"package.json", ".git"},
			Method:    "npm",
			Pkg:       "svelte-language-server",
			Bin:       "node_modules/.bin/svelteserver",
		},
	},
}

// The pins. Upgrading rook upgrades these; `rookctl plugin upgrade`
// re-materializes to them. Verified against the real registries when the
// catalog entry lands — a bad pin fails visibly in status, never silently.
const (
	goplsVersion  = "v0.23.0"
	vtslsVersion  = "0.3.0"
	svelteVersion = "0.18.3"
)

// CatalogEntry looks a plugin up by catalog name; nil for unknown.
func CatalogEntry(name string) *Entry {
	for i := range Catalog {
		if Catalog[i].Name == name {
			return &Catalog[i]
		}
	}
	return nil
}

func catalogByName(name string) *Entry { return CatalogEntry(name) }

// catalogByServer finds the entry whose payload runs the named server —
// how an lsp-<server> override key addresses its catalog expansion.
func catalogByServer(server string) *Entry {
	for i := range Catalog {
		if Catalog[i].Lang != nil && Catalog[i].Lang.Server == server {
			return &Catalog[i]
		}
	}
	return nil
}

// ServerSpec is one effective language server after config resolution:
// what to run, on which files, from which roots. Command is argv; for a
// catalog server its first element is the managed binary's absolute path.
type ServerSpec struct {
	Server    string   `json:"server"`
	Plugin    string   `json:"plugin,omitempty"` // catalog name; "" = user-declared
	Tier      string   `json:"tier"`             // "catalog" | "system"
	Command   []string `json:"command"`
	Filetypes []string `json:"filetypes"`
	Roots     []string `json:"roots"`
	Settings  string   `json:"settings,omitempty"`
}

// Issue is a resolution problem worth a status row but never an error:
// an unknown language, a tuning key with no server behind it.
type Issue struct {
	Subject string `json:"subject"`
	Detail  string `json:"detail"`
}

// Resolve turns the config's two tiers into the effective server set.
// The manager supplies managed binary paths; it is not consulted about
// installedness here — a spec exists whether or not its binary does
// (state is the manager's answer, per-server, in status).
func Resolve(cfg config.Config, m *Manager) ([]ServerSpec, []Issue) {
	var specs []ServerSpec
	var issues []Issue
	seen := map[string]bool{}

	// Intent tier: languages through the catalog.
	for _, lang := range cfg.LSP {
		e := catalogByName(lang)
		if e == nil || e.Lang == nil {
			issues = append(issues, Issue{Subject: "lsp = " + lang, Detail: "unknown language (not in this rook's catalog)"})
			continue
		}
		l := e.Lang
		spec := ServerSpec{
			Server:    l.Server,
			Plugin:    e.Name,
			Tier:      "catalog",
			Command:   append([]string{m.BinPath(*e)}, l.Args...),
			Filetypes: append([]string(nil), l.Filetypes...),
			Roots:     append([]string(nil), l.Roots...),
			Settings:  l.Settings,
		}
		applyOverride(&spec, cfg.LSPServers[l.Server])
		if cfg.LSPServers[l.Server].Off {
			continue
		}
		specs = append(specs, spec)
		seen[l.Server] = true
	}

	// Explicit tier: bring-your-own servers, and stray tuning keys.
	names := make([]string, 0, len(cfg.LSPServers))
	for name := range cfg.LSPServers {
		names = append(names, name)
	}
	sort.Strings(names) // deterministic status output
	for _, name := range names {
		o := cfg.LSPServers[name]
		if seen[name] || o.Off {
			continue
		}
		if o.Command == "" {
			// Tuning keys for a catalog server whose language wasn't
			// selected are inert, not an error (a repo may tune gopls it
			// can't select on a machine whose dotfile omits go — fine).
			// A name with no catalog entry and no command can't run.
			if catalogByServer(name) == nil {
				issues = append(issues, Issue{Subject: "lsp-" + name, Detail: "no command and no catalog entry — nothing to run"})
			}
			continue
		}
		spec := ServerSpec{
			Server:    name,
			Tier:      "system",
			Command:   strings.Fields(o.Command),
			Filetypes: append([]string(nil), o.Filetypes...),
			Roots:     append([]string(nil), o.Roots...),
			Settings:  o.Settings,
		}
		if len(spec.Roots) == 0 {
			spec.Roots = []string{".git"}
		}
		if len(spec.Filetypes) == 0 {
			issues = append(issues, Issue{Subject: "lsp-" + name, Detail: "no filetypes — declare lsp-" + name + "-filetypes"})
			continue
		}
		specs = append(specs, spec)
	}
	return specs, issues
}

// applyOverride lays a server's explicit-tier keys over its catalog
// expansion. A command line flips the server to system-provided (rook
// stops managing the binary); list/settings keys replace, not merge.
func applyOverride(spec *ServerSpec, o config.LSPServer) {
	if o.Command != "" {
		spec.Tier = "system"
		spec.Plugin = ""
		spec.Command = strings.Fields(o.Command)
	}
	if len(o.Filetypes) > 0 {
		spec.Filetypes = append([]string(nil), o.Filetypes...)
	}
	if len(o.Roots) > 0 {
		spec.Roots = append([]string(nil), o.Roots...)
	}
	if o.Settings != "" {
		spec.Settings = o.Settings
	}
}
