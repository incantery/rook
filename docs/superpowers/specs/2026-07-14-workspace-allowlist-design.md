# Workspace allowlist — design

**Date:** 2026-07-14
**Status:** approved, ready for implementation plan

## Problem

During recordings, demos, and screenshots the mission-control dashboard shows
every workspace the host has ever registered — including personal, unrelated,
or sensitive ones. There is no way to curate what appears on screen. The
primary use case is presentation hygiene for demos; the same knob is useful for
anyone who wants a clean, focused view.

## Decision

Add a **presentation-only allowlist** keyed on workspace name. When set, the
host's workspace list returns only the named workspaces (plus their worktree
descendants); when unset, behavior is unchanged.

This is a visibility filter, not access control and not a registration gate.
Workspaces still auto-register, sessions still work, and per-workspace endpoints
are not blocked. The design was chosen over a registration gate (option B in
brainstorming) because the need is presentational and must be trivially
reversible mid-demo without destroying or altering any data.

Scope is deliberately limited to an **allowlist only** — no denylist for now. An
allowlist is the safer primitive for recordings: the default is hidden, so a
sensitive workspace created *after* the list is set cannot accidentally leak in.

## Config surface

One new key, comma-separated, mirroring the existing `workflow` key exactly:

```
workspace-allow = rook, dora
```

- Parsed into `Config.WorkspaceAllow []string` using the existing `splitList`
  helper (items trimmed, empties dropped, always non-nil).
- Empty or unset (the default) means the feature is **off** — every workspace
  shows, byte-for-byte identical to today.
- No separate mode flag: an empty list is "off," a non-empty list is "demo
  mode."

## Behavior

A single guard at the top of `Host.workspaceList()` (`internal/host/host.go`),
which is the sole base layer feeding `GET /workspaces`, the dashboard, mission
control, and `GET /overview`:

1. Read the allowlist fresh via `config.Load().WorkspaceAllow` — the same
   hot-read pattern every other per-workspace host knob uses (`issues.go`,
   `workflow.go`, `spawntask.go`). This is what makes the filter hot-reload
   mid-demo with no restart and no extra plumbing.
2. If the list is empty, return the full list unchanged.
3. Otherwise build a `map[string]bool` set from the entries and keep a
   workspace `ws` iff `set[ws.Name]` **or** `set[ws.WorktreeOf]`.

The `ws.Name` *or* `ws.WorktreeOf` check is the exact name-or-worktree-source
pattern already used in `issues.go:53` and `workflow.go:30`. Allowing `rook`
therefore also admits any worktree carved from it (e.g. `rook-t1`, which carries
`WorktreeOf: "rook"`), so spawning a worktree mid-demo does not make it vanish.

The filter also applies to the "live sessions in unregistered workspaces"
branch of `workspaceList()` (the pre-registry fallback) so a stray session in an
un-allowed workspace cannot leak past demo mode.

## Non-goals

- **No denylist** — allowlist only for this slice.
- **No registration gate** — denied directories still register as workspaces.
- **No endpoint gating** — `/workspace/<name>/...` remains reachable if the name
  is already known. This is presentation, not authorization.
- **No UI for editing the list** — it is a config-file key, edited like every
  other rook config knob. (A Settings-page control could follow later but is out
  of scope.)

## Implementation sketch

- `internal/config/config.go`: add `WorkspaceAllow []string` field with a doc
  comment; add a `case "workspace-allow": cfg.WorkspaceAllow = splitList(value)`
  to the parse switch.
- `internal/host/host.go`: extract the allow check into a small helper (e.g.
  `allowWorkspace(name, worktreeOf string, allow map[string]bool) bool`, or a
  filter over the assembled slice) and call it in `workspaceList()`.

## Testing

- Config: extend the config parse test to cover `workspace-allow` →
  `WorkspaceAllow` (present, empty, absent).
- Filter helper — table test:
  - empty allowlist → all workspaces pass;
  - a named workspace → included;
  - a worktree whose `WorktreeOf` is a named source → included;
  - an un-named workspace → excluded;
  - an unregistered live session, allowlist set → excluded.
