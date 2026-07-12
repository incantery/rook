package agent

import (
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// The preference store is the user-owned preferences.md (docs/agent.md):
// everything above the learned section is the user's, never touched. The
// extractor appends below the header, and the whole file rides into
// SystemPrompt verbatim — so editing the file IS editing the agent.

const learnedHeader = "## Learned by the drafter"

const learnedNote = `<!-- rook-agent appends here, from your approve/edit/reject verdicts.
     Edit or delete lines freely — a deleted line stays deleted. -->`

// AppendLearned adds bullet lines under the learned section, creating the
// file or the section on first use. Write is atomic (temp + rename): the
// drafter loop reads this file concurrently and must never see a torn one.
func AppendLearned(lines []string) error {
	if len(lines) == 0 {
		return nil
	}
	path := PreferencesPath()
	if path == "" {
		return fmt.Errorf("no home directory")
	}
	raw, err := os.ReadFile(path)
	if err != nil && !os.IsNotExist(err) {
		return err
	}
	content := string(raw)
	if !strings.Contains(content, learnedHeader) {
		if content != "" && !strings.HasSuffix(content, "\n") {
			content += "\n"
		}
		if content != "" {
			content += "\n"
		}
		content += learnedHeader + "\n" + learnedNote + "\n"
	}
	if !strings.HasSuffix(content, "\n") {
		content += "\n"
	}
	for _, l := range lines {
		content += "- " + strings.TrimSpace(l) + "\n"
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(path), ".preferences-*")
	if err != nil {
		return err
	}
	if _, err := tmp.WriteString(content); err != nil {
		tmp.Close()
		os.Remove(tmp.Name())
		return err
	}
	if err := tmp.Close(); err != nil {
		os.Remove(tmp.Name())
		return err
	}
	return os.Rename(tmp.Name(), path)
}

// hasPreference reports whether an equivalent line is already in the store —
// the client-side dedup behind the "never restate" prompt rule.
func hasPreference(content, line string) bool {
	want := normalizePref(line)
	for l := range strings.SplitSeq(content, "\n") {
		if normalizePref(l) == want {
			return true
		}
	}
	return false
}

func normalizePref(l string) string {
	l = strings.TrimSpace(l)
	l = strings.TrimPrefix(l, "-")
	l = strings.TrimSuffix(strings.TrimSpace(l), ".")
	return strings.ToLower(strings.Join(strings.Fields(l), " "))
}

// The extraction cursor — the highest decision ID already considered — lives
// OUTSIDE the store, deliberately: if it lived in preferences.md, deleting
// the file (or a learned line) would invite re-extraction of the very rows
// the user just vetoed. Separate cursor makes deletion final.
func cursorPath() string {
	base := os.Getenv("XDG_STATE_HOME")
	if base == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			return ""
		}
		base = filepath.Join(home, ".local", "state")
	}
	return filepath.Join(base, "rook", "prefs-cursor")
}

func loadCursor() int64 {
	raw, err := os.ReadFile(cursorPath())
	if err != nil {
		return 0
	}
	n, _ := strconv.ParseInt(strings.TrimSpace(string(raw)), 10, 64)
	return n
}

func saveCursor(id int64) error {
	path := cursorPath()
	if path == "" {
		return fmt.Errorf("no home directory")
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	return os.WriteFile(path, []byte(strconv.FormatInt(id, 10)+"\n"), 0o600)
}
