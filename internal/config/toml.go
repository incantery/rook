// TOML config: ~/.config/rook/config.toml, the canonical format. The legacy
// ghostty-style flat file (config, no extension) keeps working — Load()
// prefers the TOML file when it exists and falls back otherwise, per layer:
// the user layer and a repo's .rook/ layer each make the choice
// independently. A malformed TOML file applies nothing (defaults stand,
// fail open) rather than silently reviving the legacy file underneath it.
//
// Triggers in [keybinds] carry an explicit <leader> scope ("<leader>m"),
// or are modifier chords ("cmd+shift+k"), or bare keys/sequences ("K",
// "gd") that fire without the leader. The frontend owns trigger parsing
// and validation, same as the legacy path. Editor keybinds are keyed by
// vim mode first: [editor.keybinds.normal] etc. Unknown modes are carried
// verbatim — an older frontend ignores them, fail open.
package config

import (
	"bytes"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/pelletier/go-toml/v2"
)

// TOMLPath is the canonical config file. Same directory as the legacy Path().
func TOMLPath() string {
	p := Path()
	if p == "" {
		return ""
	}
	return p + ".toml"
}

// tomlFile mirrors the config.toml schema. Every field is a pointer (or a
// map, nil when absent) so present-vs-absent survives decoding — several
// keys give an explicitly empty value a meaning an absent key doesn't have.
type tomlFile struct {
	FontFamily        *string           `toml:"font-family"`
	FontSize          *int              `toml:"font-size"`
	BackgroundOpacity *float64          `toml:"background-opacity"`
	WindowPaddingX    *int              `toml:"window-padding-x"`
	WindowPaddingY    *int              `toml:"window-padding-y"`
	Theme             *string           `toml:"theme"`
	Coder             *string           `toml:"coder"`
	Leader            *string           `toml:"leader"`
	WorkspaceAllow    *[]string         `toml:"workspace-allow"`
	Keybinds          map[string]string `toml:"keybinds"`
	Commands          map[string]string `toml:"commands"`
	Editor            *tomlEditor       `toml:"editor"`
	// Providers is [providers.<name>] — see Config.Providers. Decoded as
	// `any` and stringified rather than typed: a provider's config is its
	// own vocabulary, and a value shape rook did not anticipate must not
	// fail the document (that is how one bad line costs the whole file).
	Providers  map[string]map[string]any `toml:"providers"`
	Relay      *tomlRelay                `toml:"relay"`
	Cloud      *tomlCloud                `toml:"cloud"`
	Workspaces map[string]tomlWorkspace  `toml:"workspaces"`
	LSP        *tomlLSP                  `toml:"lsp"`
}

type tomlEditor struct {
	Leader *string `toml:"leader"`
	// Keybinds is mode → trigger → command (vim's nmap/imap/vmap as
	// tables: [editor.keybinds.normal] etc.).
	Keybinds map[string]map[string]string `toml:"keybinds"`
}

// tomlRelay is [relay] — the rook-server an ask escalates to. Only the URL
// lives here; the token is a secret and belongs in the keychain.
type tomlRelay struct {
	URL *string `toml:"url"`
}

// tomlCloud is [cloud] — the rook-cloud machine API this host reports its
// status to. Same rule as [relay]: only the URL lives here.
type tomlCloud struct {
	URL *string `toml:"url"`
}

type tomlWorkspace struct {
	// BranchPrefix: present-and-empty means "no prefix" (matching a CI
	// naming scheme exactly); absent falls back to rook/.
	BranchPrefix    *string `toml:"branch-prefix"`
	BranchDelimiter *string `toml:"branch-delimiter"`
}

type tomlLSP struct {
	Enable *[]string                `toml:"enable"`
	Server map[string]tomlLSPServer `toml:"server"`
}

// providerValue renders one provider config value as the string it will
// become in the environment. Scalars only: a provider's config is a flat
// set of names, and a table or list here means the author expected rook to
// interpret something it deliberately does not.
func providerValue(v any) string {
	switch t := v.(type) {
	case string:
		return strings.TrimSpace(t)
	case bool:
		if t {
			return "true"
		}
		return "false"
	case int64:
		return strconv.FormatInt(t, 10)
	case float64:
		return strconv.FormatFloat(t, 'f', -1, 64)
	}
	return ""
}

// dropAppLSPScalar removes a TOP-LEVEL `lsp = <scalar>` line.
//
// One file, two readers, and for a while both claimed this name: the app's
// knob was a boolean (`lsp = true`, "run language servers in the editor at
// all") while the host's is the [lsp] table above. TOML lets a name be one
// or the other and never both — so a file carrying the app's old spelling
// failed to DECODE, and applyTOML fails open, which meant losing every
// host setting in the file (coder, theme, workspace-allow, the lot) to a key that
// was not even the host's. Silently, because a config loader has nobody to
// tell.
//
// The app's key is `editor-lsp` now, but files outlive renames. Removing
// the line here is what lets an old one keep working: the app reads the
// file itself and still sees its own line, and the host stops choking on
// it. Both spellings of the mistake are covered — the scalar alone, and
// the scalar sitting above a real [lsp] table, which TOML rejects outright
// ("key lsp should be a table, not a value").
//
// Line-based on purpose, and only ever reached after the document has
// already failed to parse. This mirrors the APP's own reader — top-level
// keys only, everything from the first [table] on is someone else's — so
// the line it drops is exactly the line the app claims.
func dropAppLSPScalar(data []byte) ([]byte, bool) {
	lines := bytes.Split(data, []byte("\n"))
	out, dropped, inTable := make([][]byte, 0, len(lines)), false, false
	for _, raw := range lines {
		line := bytes.TrimSpace(raw)
		switch {
		case len(line) == 0 || line[0] == '#':
		case line[0] == '[':
			inTable = true
		case !inTable:
			if k, _, ok := bytes.Cut(line, []byte("=")); ok && string(bytes.TrimSpace(k)) == "lsp" {
				dropped = true
				continue
			}
		}
		out = append(out, raw)
	}
	return bytes.Join(out, []byte("\n")), dropped
}

type tomlLSPServer struct {
	Command   *string   `toml:"command"`
	Off       *bool     `toml:"off"`
	Filetypes *[]string `toml:"filetypes"`
	Roots     *[]string `toml:"roots"`
	Settings  *string   `toml:"settings"`
}

// applyTOML parses one config.toml over cfg. Returns false only when the
// file doesn't exist (the caller falls back to the legacy flat file); a
// file that exists but fails to parse returns true and applies nothing.
// repoLayer bounds application to the [lsp] section and refuses command
// lines, mirroring the legacy repo-layer trust rule.
func applyTOML(cfg *Config, path string, repoLayer bool) bool {
	if path == "" {
		return false
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return false
	}
	var f tomlFile
	if err := toml.Unmarshal(data, &f); err != nil {
		// One rescue before giving up, because one collision was ours to
		// cause: a top-level `lsp` scalar is the app's old key, and losing
		// the whole file to it would punish the user for our rename.
		clean, dropped := dropAppLSPScalar(data)
		if !dropped {
			// fail open: a broken file changes nothing, and we don't fall
			// back to the legacy file — that would silently apply stale
			// settings the user thinks they replaced.
			return true
		}
		f = tomlFile{}
		if toml.Unmarshal(clean, &f) != nil {
			return true
		}
	}

	if f.LSP != nil {
		applyTOMLLSP(cfg, f.LSP, repoLayer)
	}
	if repoLayer {
		return true // a checked-in file may only touch [lsp]
	}

	setStr := func(dst *string, v *string) {
		if v != nil && *v != "" {
			*dst = *v
		}
	}
	setStr(&cfg.FontFamily, f.FontFamily)
	setStr(&cfg.Theme, f.Theme)
	setStr(&cfg.Coder, f.Coder)
	setStr(&cfg.Leader, f.Leader)
	if f.FontSize != nil && *f.FontSize > 0 {
		cfg.FontSize = *f.FontSize
	}
	if f.BackgroundOpacity != nil && *f.BackgroundOpacity >= 0 && *f.BackgroundOpacity <= 1 {
		cfg.BackgroundOpacity = *f.BackgroundOpacity
	}
	if f.WindowPaddingX != nil && *f.WindowPaddingX >= 0 {
		cfg.WindowPaddingX = *f.WindowPaddingX
	}
	if f.WindowPaddingY != nil && *f.WindowPaddingY >= 0 {
		cfg.WindowPaddingY = *f.WindowPaddingY
	}
	if f.WorkspaceAllow != nil {
		cfg.WorkspaceAllow = *f.WorkspaceAllow
	}
	if len(f.Keybinds) > 0 {
		if cfg.Keybinds == nil {
			cfg.Keybinds = map[string]string{}
		}
		for t, c := range f.Keybinds {
			cfg.Keybinds[strings.TrimSpace(t)] = strings.TrimSpace(c)
		}
	}
	if len(f.Commands) > 0 {
		if cfg.Commands == nil {
			cfg.Commands = map[string]string{}
		}
		for a, c := range f.Commands {
			cfg.Commands[strings.TrimSpace(a)] = strings.TrimSpace(c)
		}
	}
	if f.Editor != nil {
		setStr(&cfg.EditorLeader, f.Editor.Leader)
		if len(f.Editor.Keybinds) > 0 {
			if cfg.EditorKeybinds == nil {
				cfg.EditorKeybinds = map[string]map[string]string{}
			}
			for mode, binds := range f.Editor.Keybinds {
				m := cfg.EditorKeybinds[mode]
				if m == nil {
					m = map[string]string{}
					cfg.EditorKeybinds[mode] = m
				}
				for t, c := range binds {
					m[strings.TrimSpace(t)] = strings.TrimSpace(c)
				}
			}
		}
	}

	if f.Relay != nil && f.Relay.URL != nil {
		cfg.RelayURL = strings.TrimRight(strings.TrimSpace(*f.Relay.URL), "/")
	}
	if f.Cloud != nil && f.Cloud.URL != nil {
		cfg.CloudURL = strings.TrimRight(strings.TrimSpace(*f.Cloud.URL), "/")
	}
	for name, table := range f.Providers {
		name = strings.TrimSpace(name)
		if name == "" {
			continue
		}
		if cfg.Providers == nil {
			cfg.Providers = map[string]map[string]string{}
		}
		if cfg.Providers[name] == nil {
			cfg.Providers[name] = map[string]string{}
		}
		for k, v := range table {
			// An empty table is meaningful — it DECLARES the provider —
			// so the map is created above regardless of what is in it.
			if s := providerValue(v); s != "" {
				cfg.Providers[name][strings.TrimSpace(k)] = s
			}
		}
	}

	for ws, w := range f.Workspaces {
		if w.BranchPrefix != nil {
			if cfg.BranchPrefixes == nil {
				cfg.BranchPrefixes = map[string]string{}
			}
			cfg.BranchPrefixes[ws] = *w.BranchPrefix
		}
		// an empty delimiter is nobody's naming scheme — typo, fall back
		if w.BranchDelimiter != nil && *w.BranchDelimiter != "" {
			if cfg.BranchDelimiters == nil {
				cfg.BranchDelimiters = map[string]string{}
			}
			cfg.BranchDelimiters[ws] = *w.BranchDelimiter
		}
	}
	return true
}

// applyTOMLLSP applies the [lsp] section — the only section a repo layer
// may touch. A repo file's command lines are recorded in LSPRefused and
// never applied (git clone must never supply argv).
func applyTOMLLSP(cfg *Config, l *tomlLSP, repoLayer bool) {
	if l.Enable != nil {
		cfg.LSP = *l.Enable
	}
	if len(l.Server) == 0 {
		return
	}
	if cfg.LSPServers == nil {
		cfg.LSPServers = map[string]LSPServer{}
	}
	for name, in := range l.Server {
		s := cfg.LSPServers[name]
		if in.Off != nil {
			s.Off = *in.Off
			if s.Off {
				s.Command = ""
			}
		}
		if in.Command != nil {
			if repoLayer {
				if *in.Command != "" {
					cfg.LSPRefused = append(cfg.LSPRefused,
						"lsp.server."+name+".command = "+*in.Command)
				}
			} else {
				// a command re-enables a server [lsp.server.X] off'd
				// elsewhere, and an empty one clears back to catalog-managed
				s.Off, s.Command = false, *in.Command
			}
		}
		if in.Filetypes != nil {
			s.Filetypes = *in.Filetypes
		}
		if in.Roots != nil {
			s.Roots = *in.Roots
		}
		if in.Settings != nil {
			s.Settings = *in.Settings
		}
		cfg.LSPServers[name] = s
	}
}

// repoTOMLPath is a repository's checked-in TOML layer, .rook/config.toml.
func repoTOMLPath(repoTop string) string {
	return filepath.Join(repoTop, ".rook", "config.toml")
}
