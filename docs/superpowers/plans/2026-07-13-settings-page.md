# Settings Page Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a full-screen in-app Settings surface to manage the Jira connection, the OpenAI key, and appearance (leader, fonts, keybinds) — writing secrets to the keychain and non-secret config surgically to `~/.config/rook/config`.

**Architecture:** All reads/writes go through the Wails `config.Service` (desktop→Go), mirroring today's OpenAI `KeyModal`. No host HTTP changes. The host hot-reads config per request, so Jira edits apply on the next issue refresh; appearance edits are cached at boot, so saving them triggers `location.reload()`. A new surgical config writer preserves comments, unknown keys, and out-of-scope settings.

**Tech Stack:** Go 1.25 (backend, `internal/config`, `internal/keychain`); Svelte 5 runes + Vite + Wails 3 (frontend, `frontend/src`); macOS `security` tool for the keychain.

## Global Constraints

- Secrets (Jira token, OpenAI key) go to the macOS keychain ONLY, never the config file. The config file stays user-owned.
- The config writer must be surgical: never touch comments, blank lines, unknown keys, or out-of-scope settings (window padding, opacity, agent, coder, branch-prefix, workflow).
- Config values are single-line; reject any value containing `\n`/`\r`.
- Config file format is ghostty-style `key = value`; scalars split on the FIRST `=`, `keybind` triggers split on the LAST `=` (see `config.Load`).
- Frontend calls new Go methods via `Call.ByName("github.com/incantery/rook/internal/config.Service.<Method>", ...)` — no binding regen required (Wails binds exported methods at runtime).
- Frontend has no JS test runner. Frontend tasks verify with `pnpm check` (svelte-check), `pnpm lint`, `pnpm build`, and live app checks. Keep testable logic as pure exported functions in `.ts`.
- Reserved keybind triggers (never rebindable): digits and the literal backtick (`keymap.ts` `reserved()`).
- All Go commands run from repo root `/Users/sethlowie/go/src/github.com/incantery/rook`. All frontend commands run from `frontend/`.

---

### Task 1: Jira secret methods on `config.Service`

Add `SetJiraToken`, `ClearJiraToken`, and `JiraTokenStatus` mirroring the OpenAI trio, and factor the shared status-probe so the two stay identical.

**Files:**
- Modify: `internal/config/config.go` (after `OpenAIKeyStatus`, ~line 278-287)
- Test: `internal/config/config_test.go` (create)

**Interfaces:**
- Consumes: `keychain.Set/Delete/Get`, `keychain.Service`, `keychain.JiraAccount`, `keychain.OpenAIAccount`, `Path()`.
- Produces:
  - `func (s *Service) SetJiraToken(token string) error`
  - `func (s *Service) ClearJiraToken() error`
  - `func (s *Service) JiraTokenStatus() string` — `"keychain"` | `"file"` | `""`

- [ ] **Step 1: Write the failing test**

Create `internal/config/config_test.go`:

```go
package config

import (
	"os"
	"path/filepath"
	"testing"
)

// JiraTokenStatus's file branch is cross-platform (keychain is darwin-only and
// tested there); point Path() at a temp dir via XDG and exercise file/none.
func TestJiraTokenStatusFile(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("XDG_CONFIG_HOME", dir)
	if err := os.MkdirAll(filepath.Join(dir, "rook"), 0o755); err != nil {
		t.Fatal(err)
	}
	var s Service

	// none: no keychain item (test env), no file
	if got := s.JiraTokenStatus(); got != "" && got != "keychain" {
		t.Fatalf("clean env should be \"\" (or a stray keychain item); got %q", got)
	}

	// file, but world-readable → must be ignored (0600-tight rule)
	tok := filepath.Join(dir, "rook", "jira-token")
	if err := os.WriteFile(tok, []byte("abc_def\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if got := s.JiraTokenStatus(); got == "file" {
		t.Fatalf("loose-perm token file must not count as a source")
	}

	// file, 0600 → "file" (assuming no keychain item shadowing it)
	if err := os.Chmod(tok, 0o600); err != nil {
		t.Fatal(err)
	}
	got := s.JiraTokenStatus()
	if got != "file" && got != "keychain" {
		t.Fatalf("tight token file should read as \"file\"; got %q", got)
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `go test ./internal/config/ -run TestJiraTokenStatusFile -v`
Expected: FAIL — `s.JiraTokenStatus undefined (type *Service has no field or method JiraTokenStatus)`

- [ ] **Step 3: Write minimal implementation**

In `internal/config/config.go`, add after `OpenAIKeyStatus` (end of file). Also refactor the shared probe:

```go
// keyStatus reports where a usable secret lives: "keychain" if the keychain
// holds it, else "file" if a 0600-tight fallback file exists and is non-empty,
// else "". Shared by the OpenAI and Jira status methods.
func keyStatus(account, fileName string) string {
	if k, err := keychain.Get(keychain.Service, account); err == nil && k != "" {
		return "keychain"
	}
	f := filepath.Join(filepath.Dir(Path()), fileName)
	if st, err := os.Stat(f); err == nil && st.Mode().Perm()&0o077 == 0 && st.Size() > 0 {
		return "file"
	}
	return ""
}

// SetJiraToken stores the Jira API token in the login keychain (service rook,
// account jira). Entering it here — not on a shell — is why special characters
// like underscores survive.
func (s *Service) SetJiraToken(token string) error {
	token = strings.TrimSpace(token)
	if token == "" {
		return errors.New("empty token")
	}
	return keychain.Set(keychain.Service, keychain.JiraAccount, token)
}

func (s *Service) ClearJiraToken() error {
	return keychain.Delete(keychain.Service, keychain.JiraAccount)
}

// JiraTokenStatus reports where the token lives: "keychain", "file"
// (~/.config/rook/jira-token, 0600), or "" for none.
func (s *Service) JiraTokenStatus() string {
	return keyStatus(keychain.JiraAccount, "jira-token")
}
```

Then simplify the existing `OpenAIKeyStatus` to reuse the helper (replace its body):

```go
// OpenAIKeyStatus reports where a usable key currently lives: "keychain",
// "file" (the ~/.config/rook/openai-key fallback), or "" for none.
func (s *Service) OpenAIKeyStatus() string {
	return keyStatus(keychain.OpenAIAccount, "openai-key")
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `go test ./internal/config/ -v && go vet ./internal/config/`
Expected: PASS (all config tests), vet clean.

- [ ] **Step 5: Commit**

```bash
git add internal/config/config.go internal/config/config_test.go
git commit -m "config: SetJiraToken/ClearJiraToken/JiraTokenStatus + shared keyStatus"
```

---

### Task 2: Harden the keychain escaper for token special characters

Prove (and, if needed, fix) that `_ $ ` (backtick) and space round-trip through `keychain.Set`/`quote()`. This closes the reported underscore symptom with evidence.

**Files:**
- Modify: `internal/keychain/keychain_test.go:20` (the `secret` literal)
- Modify (only if the test fails): `internal/keychain/keychain.go` `quote()`

**Interfaces:**
- Consumes: existing `Set`/`Get`/`Delete`.
- Produces: nothing new; strengthens the round-trip guarantee.

- [ ] **Step 1: Extend the failing test**

In `internal/keychain/keychain_test.go`, replace line 20:

```go
	secret := "sk-tr\"icky\\va lue_with_$ and `backtick` 09"
```

- [ ] **Step 2: Run the test**

Run: `go test ./internal/keychain/ -run TestRoundTrip -v`
Expected on darwin: PASS — the token comes back byte-exact. If it FAILS (a char is mangled), proceed to Step 3; otherwise skip to Step 4.

- [ ] **Step 3: Fix `quote()` only if Step 2 failed**

`quote()` (`internal/keychain/keychain.go:45-49`) wraps in double quotes and escapes `\` and `"`. Inside `security -i`'s tokenizer a double-quoted string is literal (no `$`/backtick expansion), so `_ $ backtick space` should already pass. If a specific character failed, add it to the escape set, e.g.:

```go
func quote(s string) string {
	s = strings.ReplaceAll(s, `\`, `\\`)
	s = strings.ReplaceAll(s, `"`, `\"`)
	return `"` + s + `"`
}
```

(Leave as-is if Step 2 passed — do not add escapes the test proves unnecessary.)

- [ ] **Step 4: Commit**

```bash
git add internal/keychain/keychain_test.go internal/keychain/keychain.go
git commit -m "keychain: round-trip test covers _ \$ backtick space (jira-token chars)"
```

---

### Task 3: Surgical config writer (`config.Service.SetConfig`)

Introduce the first code that writes `~/.config/rook/config`, preserving everything it doesn't touch.

**Files:**
- Create: `internal/config/write.go`
- Test: `internal/config/write_test.go`

**Interfaces:**
- Consumes: `Path()`, `Load()`.
- Produces:
  - `type Patch struct { JiraURL, JiraEmail, JiraJQL, Leader, FontFamily *string; FontSize *int; Projects, Keybinds map[string]string }` (all JSON-tagged, all optional)
  - `func (s *Service) SetConfig(p Patch) error`

- [ ] **Step 1: Write the failing test**

Create `internal/config/write_test.go`:

```go
package config

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func ptr(s string) *string { return &s }

func writeExisting(t *testing.T, dir, body string) string {
	t.Helper()
	if err := os.MkdirAll(filepath.Join(dir, "rook"), 0o755); err != nil {
		t.Fatal(err)
	}
	p := filepath.Join(dir, "rook", "config")
	if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	return p
}

func read(t *testing.T, p string) string {
	t.Helper()
	b, err := os.ReadFile(p)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

// Comments, blank lines, and out-of-scope keys survive a scalar upsert; the
// edited key changes in place; a round-trip through Load() reflects it.
func TestSetConfigScalarUpsertPreserves(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("XDG_CONFIG_HOME", dir)
	p := writeExisting(t, dir, "# my config\nfont-size = 14\n\nbackground-opacity = 0.8\njira-url = https://old.atlassian.net\n")

	var s Service
	if err := s.SetConfig(Patch{
		JiraURL:  ptr("https://new.atlassian.net/"), // trailing slash trimmed like Load()
		JiraEmail: ptr("me@org.com"),                // appended (absent before)
	}); err != nil {
		t.Fatal(err)
	}

	out := read(t, p)
	if !strings.Contains(out, "# my config") || !strings.Contains(out, "background-opacity = 0.8") {
		t.Fatalf("comment / out-of-scope key lost:\n%s", out)
	}
	if strings.Contains(out, "old.atlassian.net") {
		t.Fatalf("old value not replaced:\n%s", out)
	}
	cfg := Load()
	if cfg.JiraURL != "https://new.atlassian.net" {
		t.Fatalf("jira-url = %q", cfg.JiraURL)
	}
	if cfg.JiraEmail != "me@org.com" {
		t.Fatalf("jira-email = %q", cfg.JiraEmail)
	}
	if cfg.FontSize != 14 {
		t.Fatalf("untouched font-size changed: %d", cfg.FontSize)
	}
}

// Projects reconcile: existing kept-row updates, missing row is added, a row
// absent from the patch map is deleted.
func TestSetConfigProjectsReconcile(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("XDG_CONFIG_HOME", dir)
	writeExisting(t, dir, "jira-project-rook = OLD\njira-project-stale = ZZ\n")

	var s Service
	if err := s.SetConfig(Patch{Projects: map[string]string{
		"rook":     "INF",
		"x-darwin": "XD",
	}}); err != nil {
		t.Fatal(err)
	}
	cfg := Load()
	if cfg.JiraProjects["rook"] != "INF" || cfg.JiraProjects["x-darwin"] != "XD" {
		t.Fatalf("projects wrong: %+v", cfg.JiraProjects)
	}
	if _, ok := cfg.JiraProjects["stale"]; ok {
		t.Fatalf("stale project not deleted: %+v", cfg.JiraProjects)
	}
}

// Keybinds are a block: all existing keybind lines are replaced by the set.
func TestSetConfigKeybindsBlockReplace(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("XDG_CONFIG_HOME", dir)
	writeExisting(t, dir, "keybind = g=review.changes\nkeybind = e=file.open\nleader = `\n")

	var s Service
	if err := s.SetConfig(Patch{Keybinds: map[string]string{
		"g": "",             // unbind
		"cmd+shift+p": "palette.toggle",
	}}); err != nil {
		t.Fatal(err)
	}
	cfg := Load()
	if cfg.Keybinds["g"] != "" {
		t.Fatalf("g should be unbound, got %q", cfg.Keybinds["g"])
	}
	if cfg.Keybinds["cmd+shift+p"] != "palette.toggle" {
		t.Fatalf("new bind missing: %+v", cfg.Keybinds)
	}
	if _, ok := cfg.Keybinds["e"]; ok {
		t.Fatalf("old keybind line not cleared: %+v", cfg.Keybinds)
	}
	if cfg.Leader != "`" {
		t.Fatalf("leader clobbered: %q", cfg.Leader)
	}
}

// Writing into a fresh (missing) file creates it and leaves no temp file.
func TestSetConfigCreatesFileAtomically(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("XDG_CONFIG_HOME", dir)

	var s Service
	if err := s.SetConfig(Patch{Leader: ptr("ctrl+b")}); err != nil {
		t.Fatal(err)
	}
	if Load().Leader != "ctrl+b" {
		t.Fatalf("leader not written")
	}
	entries, _ := os.ReadDir(filepath.Join(dir, "rook"))
	for _, e := range entries {
		if strings.HasPrefix(e.Name(), ".config-") {
			t.Fatalf("temp file left behind: %s", e.Name())
		}
	}

	// A newline in a value is rejected.
	if err := s.SetConfig(Patch{JiraJQL: ptr("a\nb")}); err == nil {
		t.Fatalf("newline value must be rejected")
	}
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `go test ./internal/config/ -run TestSetConfig -v`
Expected: FAIL — `undefined: Patch` / `s.SetConfig undefined`.

- [ ] **Step 3: Write the implementation**

Create `internal/config/write.go`:

```go
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
		lines = reconcilePrefix(lines, "jira-project-", p.Projects)
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
// in want are dropped; names in want with no line are appended (sorted).
func reconcilePrefix(lines []string, prefix string, want map[string]string) []string {
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
	return out
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
		if strings.ContainsAny(t, "\n\r=") {
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `go test ./internal/config/ -v && go vet ./internal/config/`
Expected: PASS (all config tests incl. the four new ones), vet clean.

- [ ] **Step 5: Commit**

```bash
git add internal/config/write.go internal/config/write_test.go
git commit -m "config: surgical SetConfig writer (scalars, projects, keybind block)"
```

---

### Task 4: Settings shell — full-screen view, registration, remove KeyModal

Scaffold the full-screen Settings view with a left nav and three (initially stub) sections, wire it into the app, bind `cmd+,`, and fold the OpenAI `KeyModal` command away (its logic moves to Task 6).

**Files:**
- Create: `frontend/src/Settings.svelte`
- Modify: `frontend/src/state.svelte.ts` (add `settingsOpen`)
- Modify: `frontend/src/App.svelte` (import, command, keydown guard, mount, remove KeyModal)
- Modify: `frontend/src/keymap.ts:30` (add `cmd+,` default)
- Delete: `frontend/src/KeyModal.svelte`

**Interfaces:**
- Consumes: `app` store, `config.Service` methods (Tasks 1, 3), Wails `Call.ByName`, the config bindings `Service.Get`.
- Produces: `Settings.svelte` accepting `{onclose: () => void}`; `app.settingsOpen: boolean`.

- [ ] **Step 1: Add the state flag**

In `frontend/src/state.svelte.ts`, add to the overlays block (after `keyOpen = $state(false);`, line 24):

```ts
    settingsOpen = $state(false);
```

Add it to `anyOverlayOpen` (in the `return (...)` at line 44-51, add `|| this.settingsOpen`) and to `closeOverlays()` (line 54-61, add `this.settingsOpen = false;`).

- [ ] **Step 2: Create the Settings shell**

Create `frontend/src/Settings.svelte`:

```svelte
<!-- The Settings view: full-screen, left nav (Jira / OpenAI / Appearance).
     Every write goes through config.Service — secrets to the keychain, the
     rest surgically into ~/.config/rook/config. Jira edits apply on the next
     host request; appearance edits are boot-cached, so their section reloads
     the page after saving. -->
<script lang="ts">
    import {Service as Config} from "../bindings/github.com/incantery/rook/internal/config";
    import type {Config as ConfigModel} from "../bindings/github.com/incantery/rook/internal/config/models";
    import JiraSettings from "./JiraSettings.svelte";
    import OpenAISettings from "./OpenAISettings.svelte";
    import AppearanceSettings from "./AppearanceSettings.svelte";

    let {onclose}: {onclose: () => void} = $props();

    type Section = "jira" | "openai" | "appearance";
    let section = $state<Section>("jira");
    let cfg = $state<ConfigModel | null>(null);

    $effect(() => {
        Config.Get().then(
            (c) => (cfg = c),
            (err) => console.error("settings: config load failed", err),
        );
    });

    function onKeydown(e: KeyboardEvent) {
        if (e.key === "Escape") onclose();
        e.stopPropagation();
    }

    const nav: {id: Section; label: string}[] = [
        {id: "jira", label: "Jira"},
        {id: "openai", label: "OpenAI"},
        {id: "appearance", label: "Appearance"},
    ];
</script>

<div id="settings" class="settings-screen" onkeydown={onKeydown} role="presentation">
    <div class="settings-bar">
        <div class="settings-title">Settings</div>
        <button class="home-btn settings-close" onclick={onclose}>Close (Esc)</button>
    </div>
    <div class="settings-body">
        <nav class="settings-nav">
            {#each nav as n (n.id)}
                <button
                    class="settings-nav-item"
                    class:active={section === n.id}
                    onclick={() => (section = n.id)}>{n.label}</button
                >
            {/each}
        </nav>
        <section class="settings-pane">
            {#if cfg == null}
                <div class="settings-loading">loading…</div>
            {:else if section === "jira"}
                <JiraSettings {cfg} />
            {:else if section === "openai"}
                <OpenAISettings />
            {:else}
                <AppearanceSettings {cfg} />
            {/if}
        </section>
    </div>
</div>
```

- [ ] **Step 3: Create placeholder section components**

So the shell compiles before Tasks 5-8 fill them. Create three files:

`frontend/src/JiraSettings.svelte`:
```svelte
<script lang="ts">
    import type {Config as ConfigModel} from "../bindings/github.com/incantery/rook/internal/config/models";
    let {cfg}: {cfg: ConfigModel} = $props();
</script>

<div class="ws-form"><div class="settings-loading">Jira — {cfg.jiraUrl || "unset"}</div></div>
```

`frontend/src/OpenAISettings.svelte`:
```svelte
<div class="ws-form"><div class="settings-loading">OpenAI</div></div>
```

`frontend/src/AppearanceSettings.svelte`:
```svelte
<script lang="ts">
    import type {Config as ConfigModel} from "../bindings/github.com/incantery/rook/internal/config/models";
    let {cfg}: {cfg: ConfigModel} = $props();
</script>

<div class="ws-form"><div class="settings-loading">Appearance — leader {cfg.leader}</div></div>
```

- [ ] **Step 4: Add the keymap default**

In `frontend/src/keymap.ts`, add to the `DEFAULTS` array (after line 34, near the other `config.*` binds):

```ts
  ["cmd+,", "config.settings"],
```

- [ ] **Step 5: Wire into App.svelte**

In `frontend/src/App.svelte`:

(a) Replace the `KeyModal` import (line 23) with:
```ts
    import Settings from "./Settings.svelte";
```

(b) Replace the `config.openai-key` command (lines 298-305) with:
```ts
        {
            id: "config.settings",
            title: "Settings…",
            category: "Config",
            keys: keymap.display("config.settings"),
            run: () => {
                app.settingsOpen = true;
            },
        },
```

(c) In `onKeydown`, extend the modal guard (line 410) so Settings owns its keys:
```ts
        if (app.keyOpen || app.spawnOpen || app.settingsOpen) return; // modals own their keys
```

(d) Replace the `{#if app.keyOpen}<KeyModal .../>{/if}` block (lines 701-708) with:
```svelte
{#if app.settingsOpen}
    <Settings
        onclose={() => {
            app.settingsOpen = false;
            focusBack();
        }}
    />
{/if}
```

- [ ] **Step 6: Delete KeyModal**

```bash
git rm frontend/src/KeyModal.svelte
```

- [ ] **Step 7: Add Settings CSS**

Append to `frontend/src/app.css`:

```css
/* Settings: full-screen surface with a left nav. Reuses .overlay tints via
   its own opaque backdrop so terminals underneath don't bleed through. */
.settings-screen {
    position: fixed;
    inset: 0;
    z-index: 50;
    display: flex;
    flex-direction: column;
    background: rgba(15, 17, 26, 0.98);
    color: #8f93a2;
}
.settings-bar {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 12px 16px;
    border-bottom: 1px solid #2a2e3d;
}
.settings-title {
    font-size: 15px;
    color: #eeffff;
}
.settings-body {
    flex: 1;
    display: flex;
    min-height: 0;
}
.settings-nav {
    width: 160px;
    border-right: 1px solid #2a2e3d;
    padding: 12px 8px;
    display: flex;
    flex-direction: column;
    gap: 4px;
}
.settings-nav-item {
    text-align: left;
    padding: 8px 12px;
    border: none;
    background: none;
    color: #8f93a2;
    border-radius: 6px;
    cursor: pointer;
}
.settings-nav-item.active {
    background: #262b3a;
    color: #eeffff;
}
.settings-pane {
    flex: 1;
    padding: 20px 24px;
    overflow-y: auto;
}
.settings-loading {
    color: #6b7089;
}
.settings-row {
    display: flex;
    align-items: center;
    gap: 8px;
    margin: 8px 0;
}
.settings-row input[type="text"],
.settings-row input[type="password"],
.settings-row input[type="number"] {
    flex: 1;
    min-width: 0;
}
.settings-status {
    color: #6b7089;
    margin: 6px 0 14px;
}
.settings-status.ok {
    color: #c3e88d;
}
.settings-error {
    color: #ff5370;
    margin-top: 8px;
}
.settings-saved {
    color: #c3e88d;
    margin-left: 8px;
}
.settings-conflict {
    color: #ff5370;
}
```

- [ ] **Step 8: Verify build + check + lint**

Run:
```bash
cd frontend && pnpm check && pnpm build && pnpm lint
```
Expected: svelte-check reports 0 errors; build succeeds; lint clean. (If `../bindings/.../config/models` lacks the `Config` type export, import the model via the path used elsewhere — confirm with `grep -r "config/models" src`.)

- [ ] **Step 9: Commit**

```bash
git add frontend/src/Settings.svelte frontend/src/JiraSettings.svelte frontend/src/OpenAISettings.svelte frontend/src/AppearanceSettings.svelte frontend/src/state.svelte.ts frontend/src/App.svelte frontend/src/keymap.ts frontend/src/app.css
git commit -m "frontend: settings shell (full-screen, nav), cmd+, ; drop KeyModal"
```

---

### Task 5: Jira settings section

Read/edit URL, email, JQL, per-workspace projects, and the token; save non-secrets via `SetConfig` and the token via `SetJiraToken`.

**Files:**
- Modify: `frontend/src/JiraSettings.svelte` (replace the stub)

**Interfaces:**
- Consumes: `cfg: ConfigModel` prop (from the shell), `Call.ByName` for `SetConfig`/`SetJiraToken`/`ClearJiraToken`/`JiraTokenStatus`, `app.workspaces` (for the project rows).
- Produces: nothing consumed downstream.

- [ ] **Step 1: Implement the section**

Replace `frontend/src/JiraSettings.svelte` with:

```svelte
<!-- Jira connection. URL/email/JQL/projects write to the config file via
     SetConfig; the token goes to the keychain via SetJiraToken. Nothing here
     needs a reload — the host hot-reads config + token on the next refresh. -->
<script lang="ts">
    import {Call} from "@wailsio/runtime";
    import type {Config as ConfigModel} from "../bindings/github.com/incantery/rook/internal/config/models";
    import {app} from "./state.svelte";

    const SVC = "github.com/incantery/rook/internal/config.Service.";

    let {cfg}: {cfg: ConfigModel} = $props();

    let url = $state(cfg.jiraUrl ?? "");
    let email = $state(cfg.jiraEmail ?? "");
    let jql = $state(cfg.jiraJql ?? "");
    // project rows keyed by workspace name; start from config, offer a row per
    // known workspace so mapping is discoverable
    let projects = $state<Record<string, string>>({...(cfg.jiraProjects ?? {})});
    let token = $state("");
    let tokenStatus = $state("checking…");
    let tokenOk = $state(false);
    let error = $state("");
    let saved = $state(false);

    const workspaceNames = $derived(
        [...new Set([...app.workspaces.map((w) => w.name), ...Object.keys(projects)])].sort(),
    );

    $effect(() => {
        Call.ByName(SVC + "JiraTokenStatus").then(
            (s: string) => {
                tokenStatus =
                    s === "keychain"
                        ? "✓ a token is stored in the keychain — saving replaces it"
                        : s === "file"
                          ? "a token file exists (~/.config/rook/jira-token) — the keychain wins once set"
                          : "no token configured — the Jira queue stays off until one exists";
                tokenOk = !!s;
            },
            () => (tokenStatus = ""),
        );
    });

    async function save() {
        error = "";
        saved = false;
        // only send non-empty project rows; omitted rows are deleted by SetConfig
        const proj: Record<string, string> = {};
        for (const [ws, key] of Object.entries(projects)) {
            if (key.trim()) proj[ws] = key.trim();
        }
        try {
            await Call.ByName(SVC + "SetConfig", {
                jiraUrl: url.trim(),
                jiraEmail: email.trim(),
                jiraJql: jql.trim(),
                projects: proj,
            });
            const t = token.trim();
            if (t) {
                await Call.ByName(SVC + "SetJiraToken", t);
                token = "";
                tokenOk = true;
                tokenStatus = "✓ a token is stored in the keychain — saving replaces it";
            }
            saved = true;
        } catch (err) {
            error = `save failed: ${err}`;
        }
    }

    async function clearToken() {
        try {
            await Call.ByName(SVC + "ClearJiraToken");
            tokenOk = false;
            tokenStatus = "no token configured — the Jira queue stays off until one exists";
        } catch (err) {
            error = `clear failed: ${err}`;
        }
    }
</script>

<div class="ws-form">
    <div class="ws-modal-title">Jira connection</div>

    <label class="settings-row"><span>Base URL</span>
        <input type="text" placeholder="https://org.atlassian.net" bind:value={url} spellcheck="false" autocomplete="off" />
    </label>
    <label class="settings-row"><span>Email</span>
        <input type="text" placeholder="you@org.com" bind:value={email} spellcheck="false" autocomplete="off" />
    </label>
    <label class="settings-row"><span>JQL override</span>
        <input type="text" placeholder="(optional)" bind:value={jql} spellcheck="false" autocomplete="off" />
    </label>

    <div class="settings-status" class:ok={tokenOk}>{tokenStatus}</div>
    <div class="settings-row"><span>API token</span>
        <input type="password" placeholder="paste token (underscores welcome)" bind:value={token} spellcheck="false" autocomplete="off" />
        <button class="home-btn" onclick={() => void clearToken()}>Remove</button>
    </div>

    <div class="ws-modal-title">Project mapping</div>
    {#each workspaceNames as ws (ws)}
        <label class="settings-row"><span>{ws}</span>
            <input type="text" placeholder="PROJECTKEY (blank = off)" spellcheck="false" autocomplete="off"
                value={projects[ws] ?? ""}
                oninput={(e) => (projects = {...projects, [ws]: (e.target as HTMLInputElement).value})} />
        </label>
    {/each}

    {#if error}<div class="settings-error">{error}</div>{/if}
    <div class="ws-modal-foot">
        <span class="home-spacer"></span>
        {#if saved}<span class="settings-saved">saved ✓</span>{/if}
        <button class="home-btn primary" onclick={() => void save()}>Save</button>
    </div>
</div>
```

- [ ] **Step 2: Verify build + check**

Run: `cd frontend && pnpm check && pnpm build`
Expected: 0 errors; build succeeds.

- [ ] **Step 3: Commit**

```bash
git add frontend/src/JiraSettings.svelte
git commit -m "frontend: Jira settings section (url/email/jql/projects/token)"
```

---

### Task 6: OpenAI settings section

Port the deleted `KeyModal` logic into the OpenAI section.

**Files:**
- Modify: `frontend/src/OpenAISettings.svelte` (replace the stub)

**Interfaces:**
- Consumes: `Call.ByName` for `OpenAIKeyStatus`/`SetOpenAIKey`/`ClearOpenAIKey`.

- [ ] **Step 1: Implement the section**

Replace `frontend/src/OpenAISettings.svelte` with:

```svelte
<!-- OpenAI drafter key — keychain only (replaces the old KeyModal). -->
<script lang="ts">
    import {Call} from "@wailsio/runtime";

    const SVC = "github.com/incantery/rook/internal/config.Service.";

    let key = $state("");
    let status = $state("checking…");
    let statusOk = $state(false);
    let error = $state("");
    let saved = $state(false);

    $effect(() => {
        Call.ByName(SVC + "OpenAIKeyStatus").then(
            (s: string) => {
                status =
                    s === "keychain"
                        ? "✓ a key is stored in the keychain — saving replaces it"
                        : s === "file"
                          ? "a key file exists (~/.config/rook/openai-key) — the keychain takes precedence once set"
                          : "no key configured — the agent idles until one exists (and agent = on in the config)";
                statusOk = !!s;
            },
            () => (status = ""),
        );
    });

    async function save() {
        error = "";
        saved = false;
        const k = key.trim();
        if (!k) return;
        try {
            await Call.ByName(SVC + "SetOpenAIKey", k);
            key = "";
            statusOk = true;
            status = "✓ a key is stored in the keychain — saving replaces it";
            saved = true;
        } catch (err) {
            error = `keychain write failed: ${err}`;
        }
    }

    async function clear() {
        try {
            await Call.ByName(SVC + "ClearOpenAIKey");
            statusOk = false;
            status = "no key configured — the agent idles until one exists (and agent = on in the config)";
        } catch (err) {
            error = `keychain delete failed: ${err}`;
        }
    }
</script>

<div class="ws-form">
    <div class="ws-modal-title">OpenAI API key — the drafter's credential</div>
    <div class="settings-status" class:ok={statusOk}>{status}</div>
    <label class="settings-row"><span>Key</span>
        <input type="password" placeholder="sk-…" bind:value={key} spellcheck="false" autocomplete="off" />
        <button class="home-btn" onclick={() => void clear()}>Remove</button>
    </label>
    {#if error}<div class="settings-error">{error}</div>{/if}
    <div class="ws-modal-foot">
        <span class="home-spacer"></span>
        {#if saved}<span class="settings-saved">saved ✓</span>{/if}
        <button class="home-btn primary" onclick={() => void save()}>Save to keychain</button>
    </div>
</div>
```

- [ ] **Step 2: Verify build + check**

Run: `cd frontend && pnpm check && pnpm build`
Expected: 0 errors; build succeeds.

- [ ] **Step 3: Commit**

```bash
git add frontend/src/OpenAISettings.svelte
git commit -m "frontend: OpenAI key section (ported from KeyModal)"
```

---

### Task 7: Keybind override math (pure function + test-by-reasoning)

Add the pure function the Appearance keybind editor uses to turn an edited binding table into a minimal config override map. Kept separate so it is simple to reason about.

**Files:**
- Modify: `frontend/src/keymap.ts` (add exports `type KeybindRow`, `computeKeybindOverrides`, `triggerSig`)

**Interfaces:**
- Consumes: `DEFAULTS`, `parseTrigger`, `reserved` (already in `keymap.ts`).
- Produces:
  - `export interface KeybindRow { trigger: string; command: string }`
  - `export function triggerSig(trigger: string): string | null` — a conflict/identity signature (`"layer:key"`), or `null` if the trigger doesn't parse.
  - `export function isReservedTrigger(trigger: string): boolean` — true if the trigger is reserved (digits / literal backtick) and would be dropped by `buildKeymap`.
  - `export function computeKeybindOverrides(rows: KeybindRow[]): Record<string, string>`

- [ ] **Step 1: Add the functions**

Append to `frontend/src/keymap.ts`:

```ts
export interface KeybindRow {
  trigger: string;
  command: string;
}

// A stable identity for a trigger: two triggers collide iff they resolve to
// the same layer+lookup key (e.g. "cmd+d" and "cmd+D" without shift). null
// means the trigger doesn't parse (the editor shows it as invalid).
export function triggerSig(trigger: string): string | null {
  const b = parseTrigger(trigger.trim());
  if (!b) return null;
  return b.layer + ":" + b.key;
}

// True if the trigger is reserved (digits, the literal backtick) — buildKeymap
// drops these from config, so the editor must flag them instead of saving.
export function isReservedTrigger(trigger: string): boolean {
  const b = parseTrigger(trigger.trim());
  return b ? reserved(b) : false;
}

// Turn the editor's desired binding rows into the minimal config `keybind`
// override map (trigger -> command; "" command = unbind a default). buildKeymap
// applies DEFAULTS first then these overrides, so we only need to emit the
// diff: changed/new triggers, and unbinds for default triggers no longer used.
export function computeKeybindOverrides(rows: KeybindRow[]): Record<string, string> {
  const overrides: Record<string, string> = {};
  const defByTrigger = new Map<string, string>();
  for (const [t, c] of DEFAULTS) defByTrigger.set(t, c);

  const rowTriggers = new Set<string>();
  for (const {trigger, command} of rows) {
    const t = trigger.trim();
    if (!t || !command) continue;
    rowTriggers.add(t);
    if (defByTrigger.get(t) !== command) overrides[t] = command; // new or changed
  }
  for (const [t] of DEFAULTS) {
    if (!rowTriggers.has(t)) overrides[t] = ""; // a default trigger was removed
  }
  return overrides;
}
```

- [ ] **Step 2: Verify by reasoning + type-check**

There is no JS test runner. Confirm the contract by inspection against `buildKeymap`:
- A row equal to a default (same trigger→command) ⇒ not in `overrides` ⇒ preserved by DEFAULTS. ✓
- A row with a default trigger but a new command ⇒ `overrides[t]=newCmd` ⇒ replaces. ✓
- A brand-new trigger ⇒ `overrides[t]=cmd` ⇒ added. ✓
- A default trigger with no row ⇒ `overrides[t]=""` ⇒ unbound. ✓

Run: `cd frontend && pnpm check && pnpm lint`
Expected: 0 errors, lint clean.

- [ ] **Step 3: Commit**

```bash
git add frontend/src/keymap.ts
git commit -m "keymap: computeKeybindOverrides + triggerSig for the editor"
```

---

### Task 8: Appearance settings section (leader, fonts, keybind editor)

Edit leader, font family/size, and rebind commands with live conflict/reserved detection. Saving writes via `SetConfig` then reloads (these are boot-cached).

**Files:**
- Modify: `frontend/src/AppearanceSettings.svelte` (replace the stub)

**Interfaces:**
- Consumes: `cfg: ConfigModel`, `Call.ByName` for `SetConfig`, and from `keymap.ts`: `DEFAULTS`, `effectiveKeybindRows`, `computeKeybindOverrides`, `triggerSig`, `isReservedTrigger`, `type KeybindRow`.
- The keybind editor is **trigger-centric**: rows are seeded from `effectiveKeybindRows(cfg.keybinds ?? {})` (one row per bound trigger, so dual-bound commands like `palette.toggle` = `cmd+k` + `k` keep every row and an unrelated save never strips a binding). On save, `computeKeybindOverrides(rows)` diffs back to the minimal override map. `DEFAULTS` command ids feed the "add binding" picker (every command that ships with a binding; the full runtime registry is a follow-up).

- [ ] **Step 1: Implement the section**

Replace `frontend/src/AppearanceSettings.svelte` with:

```svelte
<!-- Appearance: leader, pane font, and the keybind editor. These are read at
     boot (main.ts) and passed as props, so saving reloads the page to re-read.
     The keybind editor is trigger-centric — one row per bound trigger, seeded
     from effectiveKeybindRows so multi-trigger commands keep every binding —
     and reuses keymap.ts for parsing, conflict, reserved, and override math. -->
<script lang="ts">
    import {Call} from "@wailsio/runtime";
    import type {Config as ConfigModel} from "../bindings/github.com/incantery/rook/internal/config/models";
    import {
        DEFAULTS,
        effectiveKeybindRows,
        computeKeybindOverrides,
        triggerSig,
        isReservedTrigger,
        type KeybindRow,
    } from "./keymap";

    const SVC = "github.com/incantery/rook/internal/config.Service.";

    let {cfg}: {cfg: ConfigModel} = $props();

    // svelte-ignore state_referenced_locally
    let leader = $state(cfg.leader || "`");
    // svelte-ignore state_referenced_locally
    let fontFamily = $state(cfg.fontFamily || "");
    // svelte-ignore state_referenced_locally
    let fontSize = $state(cfg.fontSize || 18);
    // svelte-ignore state_referenced_locally — seeded once; the shell reloads cfg on open
    let rows = $state<KeybindRow[]>(effectiveKeybindRows(cfg.keybinds ?? {}));

    let error = $state("");
    let saved = $state(false);
    // index of the row currently capturing a chord, or -1
    let capturing = $state(-1);

    // the "add binding" command picker: every command that ships with a default
    const allCommands = [...new Set(DEFAULTS.map(([, c]) => c))].sort();
    let addCommand = $state("");

    // per-row problem: "reserved", "unparsable", or "conflict" (sig shared by
    // 2+ rows). Empty-trigger rows are ignored (dropped on save), not flagged.
    const problems = $derived.by(() => {
        const bySig = new Map<string, number[]>();
        const out: Record<number, string> = {};
        rows.forEach((r, i) => {
            if (!r.trigger) return; // unbound row — ignored on save
            if (isReservedTrigger(r.trigger)) {
                out[i] = "reserved";
                return;
            }
            const sig = triggerSig(r.trigger);
            if (sig == null) {
                out[i] = "unparsable";
                return;
            }
            bySig.set(sig, [...(bySig.get(sig) ?? []), i]);
        });
        for (const idxs of bySig.values()) {
            if (idxs.length > 1) for (const i of idxs) out[i] ??= "conflict";
        }
        return out;
    });
    const hasProblem = $derived(Object.keys(problems).length > 0);

    // Turn a keydown into a trigger string keymap.ts can parse. Named keys
    // (arrows) map to keymap's short names; bare modifiers wait for the real key.
    function triggerFromEvent(e: KeyboardEvent): string | null {
        const named: Record<string, string> = {
            arrowup: "up",
            arrowdown: "down",
            arrowleft: "left",
            arrowright: "right",
        };
        const base = named[e.key.toLowerCase()] ?? e.key.toLowerCase();
        if (["shift", "meta", "alt", "control"].includes(base)) return null;
        const mods: string[] = [];
        if (e.metaKey) mods.push("cmd");
        if (e.ctrlKey) mods.push("ctrl");
        if (e.altKey) mods.push("alt");
        if (e.shiftKey) mods.push("shift");
        return mods.length ? [...mods, base].join("+") : base;
    }

    function onCaptureKey(e: KeyboardEvent, i: number) {
        if (capturing !== i) return;
        e.preventDefault();
        e.stopPropagation(); // don't let Escape bubble to the shell (which would close Settings)
        if (e.key === "Escape") {
            capturing = -1;
            return;
        }
        const trigger = triggerFromEvent(e);
        if (trigger == null) return; // bare modifier — keep waiting
        rows[i] = {...rows[i], trigger};
        rows = [...rows];
        capturing = -1;
    }

    function removeRow(i: number) {
        rows = rows.filter((_, j) => j !== i);
    }

    function addRow() {
        if (!addCommand) return;
        rows = [...rows, {command: addCommand, trigger: ""}];
        addCommand = "";
    }

    async function save() {
        error = "";
        saved = false;
        if (hasProblem) {
            error = "resolve keybind conflicts before saving";
            return;
        }
        const size = Number(fontSize);
        if (!Number.isInteger(size) || size <= 0) {
            error = "font size must be a positive integer";
            return;
        }
        try {
            await Call.ByName(SVC + "SetConfig", {
                leader: leader.trim() || "`",
                fontFamily: fontFamily.trim(),
                fontSize: size,
                keybinds: computeKeybindOverrides(rows),
            });
            saved = true;
            // leader/font/keybinds are boot-cached — reload to re-read
            setTimeout(() => location.reload(), 300);
        } catch (err) {
            error = `save failed: ${err}`;
        }
    }
</script>

<div class="ws-form">
    <div class="ws-modal-title">Appearance</div>
    <label class="settings-row"><span>Leader</span>
        <input type="text" placeholder="` or ctrl+b" bind:value={leader} spellcheck="false" autocomplete="off" />
    </label>
    <label class="settings-row"><span>Font family</span>
        <input type="text" placeholder="Hack Nerd Font Mono" bind:value={fontFamily} spellcheck="false" autocomplete="off" />
    </label>
    <label class="settings-row"><span>Font size</span>
        <input type="number" min="6" max="72" bind:value={fontSize} />
    </label>

    <div class="ws-modal-title">Keybinds</div>
    {#each rows as row, i (i)}
        <div class="settings-row">
            <span>{row.command}</span>
            <input
                type="text"
                readonly
                value={capturing === i ? "press keys…" : row.trigger || "(unbound)"}
                onclick={() => (capturing = i)}
                onkeydown={(e) => onCaptureKey(e, i)}
            />
            {#if problems[i]}<span class="settings-conflict">⚠ {problems[i]}</span>{/if}
            <button class="home-btn" onclick={() => removeRow(i)}>Remove</button>
        </div>
    {/each}

    <div class="settings-row">
        <select bind:value={addCommand}>
            <option value="">+ add binding…</option>
            {#each allCommands as c (c)}
                <option value={c}>{c}</option>
            {/each}
        </select>
        <button class="home-btn" disabled={!addCommand} onclick={addRow}>Add</button>
    </div>

    {#if error}<div class="settings-error">{error}</div>{/if}
    <div class="ws-modal-foot">
        <span class="home-spacer"></span>
        {#if saved}<span class="settings-saved">saved — reloading…</span>{/if}
        <button class="home-btn primary" disabled={hasProblem} onclick={() => void save()}>Save &amp; reload</button>
    </div>
</div>
```

- [ ] **Step 2: Verify build + check + lint**

Run: `cd frontend && pnpm check && pnpm build && pnpm lint`
Expected: 0 errors; build succeeds; lint clean.

- [ ] **Step 3: Commit**

```bash
git add frontend/src/AppearanceSettings.svelte
git commit -m "frontend: Appearance section — leader, fonts, keybind editor"
```

---

### Task 9: End-to-end verification

Drive the real app to confirm the underscore fix and each section, using the `verify`/`run` skills.

**Files:** none (verification only).

- [ ] **Step 1: Full Go test + vet**

Run: `go test ./... && go vet ./...`
Expected: all packages PASS, vet clean.

- [ ] **Step 2: Frontend gates**

Run: `cd frontend && pnpm check && pnpm build && pnpm lint && pnpm format:check`
Expected: all clean. Run `pnpm format` and re-commit if `format:check` fails.

- [ ] **Step 3: Live verification (invoke the `run` or `verify` skill)**

Launch the app and confirm:
1. `cmd+,` (and palette → "Settings…") opens the full-screen Settings view; Esc / Close returns.
2. **Jira**: set a token containing underscores (e.g. `AbC_123_def`), URL, email, and a project for the current workspace; Save. Trigger an issue refresh and confirm the queue authenticates (no 401, no 410) — proving the underscore survives and the endpoint fix (from earlier work) holds.
3. Inspect `~/.config/rook/config`: comments and out-of-scope keys are intact; `jira-url`/`jira-email`/`jira-project-<ws>` reflect the edits.
4. **OpenAI**: set/clear the key; status pill updates.
5. **Appearance**: change font size, rebind a command (e.g. move `file.open` off `e`), confirm the conflict warning appears if you collide two commands, Save & reload; confirm the new binding fires and the old one doesn't.

- [ ] **Step 4: Update the memory index**

Append to `/Users/sethlowie/.claude/projects/-Users-sethlowie-go-src-github-com-incantery-rook/memory/rook-daily-driver.md` a note that a full Settings page (Jira/OpenAI/Appearance) landed, config file now has a surgical writer (`config.SetConfig`), OpenAI `KeyModal` was folded into Settings, and the Jira token underscore issue is resolved by the GUI field. Add the one-line pointer if a new memory file is created instead.

- [ ] **Step 5: Final commit (if any verification fixes were needed)**

```bash
git add -A
git commit -m "settings: verification fixes"
```

---

## Notes for the implementer

- **Bindings model import path:** Tasks reference `../bindings/github.com/incantery/rook/internal/config/models`. Confirm the exact model export with `grep -rn "config/models" frontend/src` before Task 4; adjust the import to match the codebase's convention if it differs.
- **`app.workspaces` in Jira projects:** populated by App.svelte's 15s poll; on first open it may be empty, so the project list unions config keys with the live workspace list. That's expected — reopening after the poll shows more rows.
- **Keybind editor scope:** one row per command that ships with a DEFAULT binding. Commands registered only at runtime (e.g. `workspace.scratch`, which has no default) are not listed in v1; surfacing the full registry is a follow-up.
