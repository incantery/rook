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
	"os"
	"path/filepath"
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
	FontFamily        *string                  `toml:"font-family"`
	FontSize          *int                     `toml:"font-size"`
	BackgroundOpacity *float64                 `toml:"background-opacity"`
	WindowPaddingX    *int                     `toml:"window-padding-x"`
	WindowPaddingY    *int                     `toml:"window-padding-y"`
	Theme             *string                  `toml:"theme"`
	Coder             *string                  `toml:"coder"`
	Leader            *string                  `toml:"leader"`
	Workflow          *[]string                `toml:"workflow"`
	WorkspaceAllow    *[]string                `toml:"workspace-allow"`
	Keybinds          map[string]string        `toml:"keybinds"`
	Commands          map[string]string        `toml:"commands"`
	Editor            *tomlEditor              `toml:"editor"`
	Agent             *tomlAgent               `toml:"agent"`
	Jira              *tomlJira                `toml:"jira"`
	Relay             *tomlRelay               `toml:"relay"`
	Cloud             *tomlCloud               `toml:"cloud"`
	Workspaces        map[string]tomlWorkspace `toml:"workspaces"`
	LSP               *tomlLSP                 `toml:"lsp"`
}

type tomlEditor struct {
	Leader *string `toml:"leader"`
	// Keybinds is mode → trigger → command (vim's nmap/imap/vmap as
	// tables: [editor.keybinds.normal] etc.).
	Keybinds map[string]map[string]string `toml:"keybinds"`
}

type tomlAgent struct {
	Enabled     *bool    `toml:"enabled"`
	Engine      *string  `toml:"engine"`
	Model       *string  `toml:"model"`
	DailyCapUSD *float64 `toml:"daily-cap-usd"`
}

type tomlJira struct {
	URL   *string `toml:"url"`
	Email *string `toml:"email"`
	JQL   *string `toml:"jql"`
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
	JiraProject *string `toml:"jira-project"`
	// BranchPrefix: present-and-empty means "no prefix" (matching a CI
	// naming scheme exactly); absent falls back to rook/.
	BranchPrefix    *string `toml:"branch-prefix"`
	BranchDelimiter *string `toml:"branch-delimiter"`
	// Workflow: present-and-empty is an explicit opt-out of the global
	// pipeline; absent inherits it.
	Workflow *[]string `toml:"workflow"`
}

type tomlLSP struct {
	Enable *[]string                `toml:"enable"`
	Server map[string]tomlLSPServer `toml:"server"`
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
		// fail open: a broken file changes nothing, and we don't fall
		// back to the legacy file — that would silently apply stale
		// settings the user thinks they replaced.
		return true
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
	if f.Workflow != nil {
		cfg.Workflow = *f.Workflow
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

	if f.Agent != nil {
		if f.Agent.Enabled != nil {
			cfg.Agent = *f.Agent.Enabled
		}
		setStr(&cfg.AgentEngine, f.Agent.Engine)
		setStr(&cfg.AgentModel, f.Agent.Model)
		if f.Agent.DailyCapUSD != nil && *f.Agent.DailyCapUSD >= 0 {
			cfg.AgentDailyCapUSD = *f.Agent.DailyCapUSD
		}
	}

	if f.Relay != nil && f.Relay.URL != nil {
		cfg.RelayURL = strings.TrimRight(strings.TrimSpace(*f.Relay.URL), "/")
	}
	if f.Cloud != nil && f.Cloud.URL != nil {
		cfg.CloudURL = strings.TrimRight(strings.TrimSpace(*f.Cloud.URL), "/")
	}
	if f.Jira != nil {
		if f.Jira.URL != nil {
			cfg.JiraURL = strings.TrimRight(*f.Jira.URL, "/")
		}
		if f.Jira.Email != nil {
			cfg.JiraEmail = *f.Jira.Email
		}
		if f.Jira.JQL != nil {
			cfg.JiraJQL = *f.Jira.JQL
		}
	}

	for ws, w := range f.Workspaces {
		if w.JiraProject != nil && *w.JiraProject != "" {
			if cfg.JiraProjects == nil {
				cfg.JiraProjects = map[string]string{}
			}
			cfg.JiraProjects[ws] = *w.JiraProject
		}
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
		if w.Workflow != nil {
			if cfg.Workflows == nil {
				cfg.Workflows = map[string][]string{}
			}
			wf := *w.Workflow
			if wf == nil {
				wf = []string{}
			}
			cfg.Workflows[ws] = wf
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

// exists reports whether a config layer's TOML file is present — the
// per-layer switch between the canonical and legacy formats.
func exists(path string) bool {
	if path == "" {
		return false
	}
	_, err := os.Stat(path)
	return err == nil
}

// repoTOMLPath is a repository's checked-in TOML layer, .rook/config.toml.
func repoTOMLPath(repoTop string) string {
	return filepath.Join(repoTop, ".rook", "config.toml")
}
