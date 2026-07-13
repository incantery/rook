# Settings page — design

**Date:** 2026-07-13
**Status:** Approved (brainstorm), pending spec review

## Motivation

Setting the Jira API token via the CLI corrupts special characters — underscores
reported, likely others (`$`, backtick, `"`). Root cause: the corruption happens
in the **shell**, before Go sees the value (e.g. passing the token as a shell
argument or through `echo`), not in rook's Go code — `rookctl set-jira-token`
itself pipes stdin byte-exact into `security`. A GUI text field sidesteps shell
tokenization entirely, so a Settings page is the real fix, not a workaround.

Beyond the token, rook config today is hand-edited in `~/.config/rook/config`
(ghostty-style `key = value`). We want to manage tokens **and** settings from the
app: Jira connection, the OpenAI key, and appearance (leader, fonts, keybinds).

## Scope

Full-screen Settings view with a left nav and three sections:

- **Jira** — base URL, email, token, JQL override, per-workspace project mapping.
- **OpenAI** — the drafter API key (replaces the standalone `KeyModal`).
- **Appearance** — leader key, pane font family + size, and a full keybind editor
  (rebind commands, live conflict/reserved detection, unbind, add).

This introduces the **first code that writes `~/.config/rook/config`**. The write
is surgical (preserves comments, unknown keys, ordering) so the "user-owned file"
ethos survives.

Out of scope for v1: window padding, background opacity, agent settings, coder,
branch prefixes, workflows. These stay hand-edited; the surgical writer leaves
them untouched.

## Architecture

All reads and writes go through the Wails **`config.Service`** (desktop → Go),
mirroring the existing OpenAI key path (`KeyModal.svelte` →
`Call.ByName("…/internal/config.Service.SetOpenAIKey")`). **No host HTTP API
changes** — this avoids adding to the host's bearer-token/CORS surface (which
does not even allow `PUT` today) and keeps a single settings code path.

Apply semantics differ by data class:

- **Jira (url/email/jql/projects) + tokens** — the host hot-reads `config.Load()`
  and `config.JiraToken()` on every request (`internal/host/issues.go`
  `trackersFor`), so edits take effect on the **next issue refresh, no reload or
  restart**.
- **Appearance (leader/fonts/keybinds)** — cached at boot in `main.ts` and passed
  as props into `App`, so a change requires `location.reload()` to re-read. Saving
  an appearance change triggers the existing `config.reload` behavior
  (`location.reload()`).

## Backend (Go)

### 1. Secrets — extend `config.Service` (internal/config/config.go)

Mirror the OpenAI trio for Jira:

- `SetJiraToken(token string) error` — `keychain.Set(keychain.Service,
  keychain.JiraAccount, token)` after `TrimSpace`/empty guard.
- `ClearJiraToken() error` — `keychain.Delete(…, JiraAccount)`.
- `JiraTokenStatus() string` — `"keychain"` | `"file"` | `""`, reusing the
  existing `~/.config/rook/jira-token` 0600 fallback check (factor the shared
  logic with `OpenAIKeyStatus`).

The existing package-level `JiraToken()` resolver is unchanged.

### 2. Config-file writer — new internal/config/write.go

`func (s *Service) SetConfig(patch Patch) error` performs a **surgical** upsert:

- Read the existing file into lines (empty/missing file → start fresh).
- **Scalar keys** (`jira-url`, `jira-email`, `jira-jql`, `leader`,
  `font-family`, `font-size`): find the last non-comment line matching
  `^\s*<key>\s*=`; replace its value in place, else append a new line.
- **Prefix-map rows** (`jira-project-<ws>`): upsert per workspace; a removed row
  deletes its line.
- **Keybinds**: treat all `keybind =` lines as one homogeneous block — remove
  every existing `keybind =` line, then append the desired set (one
  `keybind = <trigger>=<command>` per binding, including `<trigger>=` unbind
  lines where a default was cleared).
- Write atomically: temp file in the same dir + `os.Rename`, mode `0644`, create
  `~/.config/rook/` if missing.

`Patch` carries only the fields the UI edits (a struct with optional scalars, a
`map[ws]project` with an explicit delete set, and the full keybind map). Unknown
keys, comments, and out-of-scope settings are never touched.

**Value hygiene:** values are written verbatim after `TrimSpace`. The parser
splits on the first `=` for scalars and last `=` for keybind triggers, so values
may contain `=`; no escaping of `_`/`$`/spaces is needed in the config file
(they are literal). Reject a value containing a newline (would corrupt the
line-oriented format) with a clear error.

### 3. Keychain hardening (internal/keychain)

The token now flows through `keychain.Set` → `quote()` (escapes only `\` and
`"`). Add a round-trip test covering `_ $ " \ ` (backtick) and space; if any
fail, fix `quote()`. `_`/`$`/backtick/space are expected to already pass — this
is defense-in-depth to close the reported-symptom loop with evidence.

### Backend tests

- `write_test.go`: comment + unknown-key preservation; scalar upsert vs append;
  project add/edit/remove; keybind block clear+rewrite; full round-trip
  (`SetConfig` then `Load()` returns the expected `Config`); atomic-write leaves
  no temp file on success.
- `config_test.go`: `JiraTokenStatus` for keychain / file / none.
- `keychain_test.go`: special-char round-trip.

## Frontend

### View registration (three coordinated edits, per existing convention)

1. **Registry command** `config.settings` in `App.svelte` → sets
   `app.screen = "settings"` (full-screen, gated like Home/Dashboard).
2. **Keymap default** — add `["cmd+,", "config.settings"]` to `DEFAULTS` in
   `keymap.ts`: the macOS-standard Preferences chord, unused today (`cmd+shift+,`
   is `config.reload`; bare `cmd+,` is free). Also add a prefix-layer alias if a
   free single key with a good mnemonic exists at implementation time.
3. **State + mount** — `app.screen` value `"settings"`; render `Settings.svelte`
   when active; add the keydown guard alongside existing screen gates.

### Settings.svelte

Left nav (Jira / OpenAI / Appearance) + a content pane. Reuses the shared
`.overlay`/`.pal-panel`/`.ws-form`/`.home-btn` CSS. Reads current config via
`config.Service.Get()` and token/key status via the status methods.

- **Jira** — url, email, masked token (Save/Clear + status pill), jql, and
  per-workspace project rows (workspaces enumerated from config/host). Save writes
  non-secrets via `SetConfig` and the token via `SetJiraToken`. No reload.
- **OpenAI** — key status, Save (`SetOpenAIKey`), Clear (`ClearOpenAIKey`).
  This section **replaces** `KeyModal.svelte`: delete that component and its
  `config.openai-key` registry command/keymap entry.
- **Appearance** — leader, font-family, font-size, and the **keybind editor**.
  The editor lists registry commands with their current display binding, supports
  click-to-capture (a keydown handler builds a trigger via `sigOf`/parse),
  detects conflicts (same layer+key already bound) and reserved triggers by
  reusing `keymap.ts` exports (`parseTrigger`, `parseChord`, `sigOf`, `reserved`,
  `DEFAULTS`), and supports unbind/add. Save writes leader/fonts/keybinds via
  `SetConfig`, then `location.reload()`.

### Keybind editor detail

- Command list comes from the shared registry (the same source the palette uses),
  so every registered command is rebindable and the editor stays in sync as
  commands are added.
- A binding change is expressed as an override entry `{trigger: command}` (and a
  `{trigger: ""}` unbind when clearing a default), exactly the shape `buildKeymap`
  and the config `keybind =` lines already use. This keeps one canonical binding
  model across defaults, config, editor, and writer.
- Conflict/reserved validation is pure and lives in / beside `keymap.ts` so it is
  unit-testable without the DOM.

## Error handling

- Client-side validation disables Save until valid: URL shape, email present,
  font-size positive int, chord parses, no conflict, not reserved.
- Backend `SetConfig`/`SetJiraToken` errors surface inline; a failed atomic write
  does not reload and leaves the file unchanged.
- Fail-open on read: a malformed existing config still loads via `Load()`'s
  lenient parser; the editor shows defaults for anything it can't read.

## Testing strategy

- Go unit tests as listed above (writer round-trip is the core guarantee).
- Keybind conflict/validation covered by pure-function tests around `keymap.ts`
  logic (add a minimal test harness if none exists, else assert via a small
  extracted module).
- End-to-end: use the `verify` / `run` skills to drive the app — set a Jira token
  containing `_`, confirm the queue authenticates; edit URL/projects and confirm
  the next refresh reflects them; rebind a key, reload, confirm it fires.

## Open risks

- The surgical keybind "block replace" loses original positioning of `keybind =`
  lines (acceptable: they're a homogeneous block; comments elsewhere are kept).
- If the frontend has no JS test runner today, keybind-logic tests may need a new
  (small) harness — flagged for the plan.
