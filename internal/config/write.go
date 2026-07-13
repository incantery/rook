package config

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
)

// Patch is the subset of config the Settings UI edits. A nil pointer / nil map
// means "leave untouched"; a non-nil value (even empty) is applied. Everything
// not named here — comments, blank lines, out-of-scope keys — is preserved.
type Patch struct {
	JiraURL    *string `json:"jiraUrl,omitempty"`
	JiraEmail  *string `json:"jiraEmail,omitempty"`
	JiraJQL    *string `json:"jiraJql,omitempty"`
	Leader     *string `json:"leader,omitempty"`
	FontFamily *string `json:"fontFamily,omitempty"`
	FontSize   *int    `json:"fontSize,omitempty"`
	// Projects: the full desired jira-project-<ws> map. Rows not present are
	// deleted; rows present are upserted.
	Projects map[string]string `json:"projects,omitempty"`
	// Keybinds: the full desired keybind set (trigger -> command; "" command =
	// unbind line). Replaces the entire keybind block.
	Keybinds map[string]string `json:"keybinds,omitempty"`
}

// SetConfig applies a Patch surgically to the config file.
func (s *Service) SetConfig(p Patch) error {
	path := Path()
	if path == "" {
		return errors.New("config: no home directory")
	}
	lines, err := readLines(path)
	if err != nil {
		return err
	}

	set := func(key, val string) error {
		if strings.ContainsAny(val, "\n\r") {
			return fmt.Errorf("config: %s value must be a single line", key)
		}
		lines = upsertScalar(lines, key, val)
		return nil
	}
	if p.JiraURL != nil {
		if err := set("jira-url", strings.TrimRight(*p.JiraURL, "/")); err != nil {
			return err
		}
	}
	if p.JiraEmail != nil {
		if err := set("jira-email", *p.JiraEmail); err != nil {
			return err
		}
	}
	if p.JiraJQL != nil {
		if err := set("jira-jql", *p.JiraJQL); err != nil {
			return err
		}
	}
	if p.Leader != nil {
		if err := set("leader", *p.Leader); err != nil {
			return err
		}
	}
	if p.FontFamily != nil {
		if err := set("font-family", *p.FontFamily); err != nil {
			return err
		}
	}
	if p.FontSize != nil {
		if err := set("font-size", strconv.Itoa(*p.FontSize)); err != nil {
			return err
		}
	}
	if p.Projects != nil {
		if lines, err = reconcilePrefix(lines, "jira-project-", p.Projects); err != nil {
			return err
		}
	}
	if p.Keybinds != nil {
		if err := replaceKeybinds(&lines, p.Keybinds); err != nil {
			return err
		}
	}
	return writeLines(path, lines)
}

// readLines returns the file's lines (no trailing empty element); a missing
// file yields an empty slice, other errors propagate.
func readLines(path string) ([]string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, nil
		}
		return nil, fmt.Errorf("config read: %w", err)
	}
	lines := strings.Split(string(data), "\n")
	if n := len(lines); n > 0 && lines[n-1] == "" {
		lines = lines[:n-1]
	}
	return lines, nil
}

// cutKey mirrors Load()'s parse: the trimmed key of a `key = value` line, or
// ok=false for blank/comment/non-kv lines.
func cutKey(line string) (key string, ok bool) {
	t := strings.TrimSpace(line)
	if t == "" || strings.HasPrefix(t, "#") {
		return "", false
	}
	k, _, ok := strings.Cut(t, "=")
	if !ok {
		return "", false
	}
	return strings.TrimSpace(k), true
}

// upsertScalar replaces the value on the LAST `key = ...` line (Load()'s
// last-wins), or appends a new line if the key is absent.
func upsertScalar(lines []string, key, val string) []string {
	idx := -1
	for i, ln := range lines {
		if k, ok := cutKey(ln); ok && k == key {
			idx = i
		}
	}
	newLine := key + " = " + val
	if idx == -1 {
		return append(lines, newLine)
	}
	lines[idx] = newLine
	return lines
}

// reconcilePrefix makes the `<prefix><name> = value` lines exactly match want:
// prefixed lines whose name is in want are updated in place; prefixed lines not
// in want are dropped; names in want with no line are appended (sorted). Any
// name or value containing a newline is rejected before mutating so a JSON
// value can't inject a rogue physical line (e.g. a `keybind =` directive).
func reconcilePrefix(lines []string, prefix string, want map[string]string) ([]string, error) {
	for name, val := range want {
		if strings.ContainsAny(name, "\n\r") {
			return nil, fmt.Errorf("config: jira-project %q name must be a single line", name)
		}
		if strings.ContainsAny(val, "\n\r") {
			return nil, fmt.Errorf("config: jira-project %q value must be a single line", name)
		}
	}
	seen := map[string]bool{}
	out := make([]string, 0, len(lines))
	for _, ln := range lines {
		if k, ok := cutKey(ln); ok && strings.HasPrefix(k, prefix) {
			name := strings.TrimPrefix(k, prefix)
			if val, keep := want[name]; keep {
				out = append(out, prefix+name+" = "+val)
				seen[name] = true
			}
			continue // not wanted → drop
		}
		out = append(out, ln)
	}
	names := make([]string, 0, len(want))
	for name := range want {
		if !seen[name] {
			names = append(names, name)
		}
	}
	sort.Strings(names)
	for _, name := range names {
		out = append(out, prefix+name+" = "+want[name])
	}
	return out, nil
}

// replaceKeybinds removes every `keybind = ...` line and appends the desired
// set as `keybind = <trigger>=<command>` (sorted for stable output).
func replaceKeybinds(lines *[]string, want map[string]string) error {
	out := make([]string, 0, len(*lines))
	for _, ln := range *lines {
		if k, ok := cutKey(ln); ok && k == "keybind" {
			continue
		}
		out = append(out, ln)
	}
	triggers := make([]string, 0, len(want))
	for t := range want {
		// Only newlines are rejected — "=" stays a valid trigger. Writing
		// `keybind = ==<cmd>` round-trips through Load(), which splits on the
		// LAST "=" (commands never contain "="), so this is unambiguous.
		if strings.ContainsAny(t, "\n\r") {
			return fmt.Errorf("config: bad keybind trigger %q", t)
		}
		triggers = append(triggers, t)
	}
	sort.Strings(triggers)
	for _, t := range triggers {
		cmd := want[t]
		if strings.ContainsAny(cmd, "\n\r") {
			return fmt.Errorf("config: bad keybind command %q", cmd)
		}
		out = append(out, "keybind = "+t+"="+cmd)
	}
	*lines = out
	return nil
}

// writeLines atomically writes the config (temp file + rename), 0644, creating
// the directory if needed.
func writeLines(path string, lines []string) error {
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return fmt.Errorf("config mkdir: %w", err)
	}
	content := strings.Join(lines, "\n")
	if content != "" {
		content += "\n"
	}
	tmp, err := os.CreateTemp(dir, ".config-*")
	if err != nil {
		return fmt.Errorf("config tmp: %w", err)
	}
	tmpName := tmp.Name()
	defer os.Remove(tmpName) // no-op once renamed away
	if _, err := tmp.WriteString(content); err != nil {
		tmp.Close()
		return fmt.Errorf("config write: %w", err)
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	if err := os.Chmod(tmpName, 0o644); err != nil {
		return err
	}
	if err := os.Rename(tmpName, path); err != nil {
		return fmt.Errorf("config rename: %w", err)
	}
	return nil
}
