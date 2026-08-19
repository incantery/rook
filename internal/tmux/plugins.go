package tmux

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

// Plugins are cloned by rook itself — there is no TPM in the loop. A
// spec is "owner/repo" on GitHub, the TPM convention, and a plugin is
// wired in by run-shell'ing every *.tmux script in its repo root.
var specRe = regexp.MustCompile(`^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$`)

func pluginRoot() (string, error) {
	dir := os.Getenv("XDG_DATA_HOME")
	if dir == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			return "", err
		}
		dir = filepath.Join(home, ".local", "share")
	}
	return filepath.Join(dir, "rook", "tmux-plugins"), nil
}

// EnsurePlugins clones any missing plugin and returns the scripts to
// run-shell, in spec order. Failures come back as warnings, never
// errors: booting the terminal must not depend on the network, so a
// plugin that cannot be fetched is skipped, not fatal.
func EnsurePlugins(specs []string) (scripts []string, warnings []string) {
	if len(specs) == 0 {
		return nil, nil
	}
	root, err := pluginRoot()
	if err != nil {
		return nil, []string{fmt.Sprintf("plugins disabled: %v", err)}
	}
	if err := os.MkdirAll(root, 0o755); err != nil {
		return nil, []string{fmt.Sprintf("plugins disabled: %v", err)}
	}

	for _, spec := range specs {
		if !specRe.MatchString(spec) {
			warnings = append(warnings, fmt.Sprintf("plugin %q: not an owner/repo spec, skipped", spec))
			continue
		}
		dir := filepath.Join(root, spec[strings.IndexByte(spec, '/')+1:])
		if _, err := os.Stat(dir); os.IsNotExist(err) {
			clone := exec.Command("git", "clone", "--depth", "1",
				"https://github.com/"+spec, dir)
			if out, err := clone.CombinedOutput(); err != nil {
				warnings = append(warnings, fmt.Sprintf("plugin %s: clone failed, skipped: %v\n%s",
					spec, err, strings.TrimSpace(string(out))))
				continue
			}
		}
		found, err := filepath.Glob(filepath.Join(dir, "*.tmux"))
		if err == nil && len(found) == 0 {
			warnings = append(warnings, fmt.Sprintf("plugin %s: no *.tmux script in repo root, nothing to run", spec))
			continue
		}
		sort.Strings(found)
		scripts = append(scripts, found...)
	}
	return scripts, warnings
}
