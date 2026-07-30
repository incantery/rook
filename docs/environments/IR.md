# The environment graph (IR), v1

> Status: v1 is real and load-bearing (the app loads it at launch, the
> Go SDK emits it), and deliberately tiny — it covers exactly what
> `config.toml` can say today. The direction it grows toward is in
> [VISION.md](VISION.md): preview/drift/apply diffs, provenance,
> capabilities, work modes. Nothing here is final; it versions.

Configuration is a **declarative description of a development
environment**. The user's program (Go today; TypeScript and Python
later) runs at *apply time*, not launch time, and emits this graph.
Rook materializes the graph. The program is Pulumi-shaped; the runtime
is React-shaped: no state file stands between the graph and the live
app — the live tree is the only truth it reconciles against.

## The launch contract

- The app reads `$XDG_CONFIG_HOME/rook/environment.json` (default
  `~/.config/rook/environment.json`... under `rook/`). If the file is
  **absent**, `config.toml` is read exactly as before — TOML remains
  the no-SDK front end, forever.
- If the file is **present and valid**, it replaces the app's view of
  `config.toml` entirely (defaults + graph; no layering — layering is
  what provenance is for, later). rook-host still reads `config.toml`;
  the host side of the graph (`scope: "host"` nodes) is carried but not
  yet consumed — the TOML renderer that feeds the host is a later slice.
- If the file is present and **invalid JSON**, the app says so on
  stderr and falls back to TOML. A broken environment must never brick
  a launch.
- **Fail open** (the host-protocol-skew rule): an unknown `kind`, an
  unknown `key`, an unexpected value type — each is skipped in
  silence, never an error. Old apps must survive new graphs.
- Launch cost is a measured budget, not a hope: the TOML parse this
  replaces costs ~50µs of a ~72ms launch (app/PERF.md, "Startup").
  The graph loader must stay the same order of magnitude. The e2e
  `startup` bench has a batch for each loader; run it when this file's
  loader changes.

## Shape

```json
{
  "rookEnvironment": 1,
  "nodes": [
    {"id": "option:app:font-size", "kind": "option", "scope": "app", "key": "font-size", "value": 18},
    {"id": "leader:app",           "kind": "leader", "scope": "app", "key": "`"},
    {"id": "keybind:app:<leader>v","kind": "keybind","scope": "app", "chord": "<leader>v", "command": "app.split.vertical"},
    {"id": "option:host:coder",    "kind": "option", "scope": "host", "key": "coder", "value": "claude"},
    {"id": "table:host:agent",     "kind": "table",  "scope": "host", "name": "agent", "entries": {"enabled": true}}
  ]
}
```

- `rookEnvironment` — format version. Readers accept newer versions and
  skip what they don't know; they never refuse.
- Every node has a stable `id`, derived `kind:scope:key`-style by the
  SDKs. IDs are what reconciliation and provenance will attach to; two
  nodes with one id means the later one won (the SDKs replace in
  place, which is also TOML's "config lines replace defaults" rule).

### Kinds (v1)

| kind | fields | meaning |
|---|---|---|
| `option` | `scope`, `key`, `value` | one knob. `scope: "app"` keys are config.toml's top-level app keys, same names, dashes or underscores. `scope: "host"` carried, not consumed yet |
| `leader` | `scope`, `key` | the app leader (`scope: "app"`) or editor leader (`"editor"`). One key; `TAB`/`SPACE`/`ESC` accepted |
| `keybind` | `scope`, `chord`, `command` | `scope: "app"` = `[keybinds]` (`<leader>X` chords, commands by registry id). `scope: "editor.normal"` etc. carried, consumed when configurable editor maps land |
| `table` | `scope`, `name`, `entries` | an opaque host table (`[agent]`, `[jira]`, `[lsp]`, …). Carried verbatim for the future TOML renderer |

### Presets

`{"kind": "option", "scope": "app", "key": "preset", "value": "vscode"}`
is a defaults layer: the loader applies its bundle FIRST regardless of
node position, so every explicit option overrides it. SDKs normally
never emit it — `PresetVSCode()` expands to explicit option nodes at
emit time so the graph shows every knob the bundle set (what
provenance will attach to). The bundle exists twice (config.zig's
applyPreset and the SDK); the SDK golden test and the e2e
`presetparity` scenario are the drift guards.

## Canonical bytes

Every SDK emits the same graph as the same bytes, so parity is `diff`
and provenance diffs stay noise-free: compact JSON (no whitespace),
node fields in the order id, kind, scope, key/chord/name, value/command/
entries; `entries` keys sorted; integral floats as integers; no HTML
escaping; UTF-8 raw.

## What v1 deliberately does not have

Provenance, ownership tags, capabilities, views/layouts, workflows —
each argued for in VISION.md, each arriving with the feature that
consumes it. The version field is the promise that they can.
