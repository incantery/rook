# Plugins — Language Support First

*Rook's plugin system, born with one supported type. A plugin is declared in
config, materialized into a rook-owned prefix, run out-of-process, and
surfaced through host APIs. The `language` type carries LSP: declare a
language, rook materializes the server, and the index is legible to Monaco,
rookctl, and claude alike.*

## Thesis

Exploration is the editor's job in rook, and exploration's motor skills are
go-to-definition, find-references, and hover. Neovim gets these from LSP; rook
gets nothing today (Monaco is deliberately assembled with zero language
services). This spec adds them — but the mechanism is deliberately bigger than
the feature: **this is the plugin system, whose only supported type on day one
is language support.**

The experience target is VS Code's: `lsp = go` in config and it just works —
rook installs and manages the server. The mechanism target is nix's: config
declares intent, the system realizes it reproducibly. The architecture target
is README decision 8's, made concrete for the first time: plugins are
**out-of-process children speaking a protocol to the host**, never code loaded
into rook. A language server is the purest possible first instance — the
protocol (LSP) already exists and rook only had to learn to speak it.

The host speaks LSP so nothing else has to: Monaco is merely the first client
of four plain HTTP endpoints, and `rookctl def` makes the same index
agent-legible — the rook thesis applied to navigation. The human and the agent
explore the same code through the same substrate.

---

## The plugin substrate (generic)

What every plugin type shares. Built now, because language support needs all
of it; kept honest by naming it what it is.

**Identity & manifest.** A plugin is a name + a type + a type-tagged payload —
the same kind-tagged-union discipline as `PaneRef` and the rook_tasks anchor.
Day one, manifests are Go structs compiled into the host (the **catalog**);
there is no external manifest file format until third-party authoring exists,
so we can't freeze a wrong one.

**Catalog.** Curated, in-binary, small: the plugins rook's own users touch.
Each entry pins a version and knows how to materialize itself. The long tail
(importing mason-registry's community catalog for languages) is a seam, taken
only if the curated set actually constrains.

**Materialization.** `~/.local/share/rook/plugins/<name>/<version>/`
(XDG_DATA_HOME). Installation delegates to toolchains (`go install`, `npm`
into the prefix) or a pinned release download; never the user's global
environment. Uninstall is `rm -rf`. Versions are pinned in the catalog, so a
rook build implies a plugin set; `rookctl plugin upgrade` re-materializes to
current pins and prunes old versions. No lockfile — the binary is the lock.

**Process model.** A plugin runs as a supervised host child (`agentproc.go`
style: restart with backoff, killed by the host lifecycle ctx — children die
with the daemon). The host is the only speaker of the plugin's protocol;
frontend and rookctl see rook-shaped HTTP.

**Trust tiers.** The generic rule, stated once:

1. *Catalog* — rook-shipped code. Either config layer may **select** it;
   neither can alter what it execs.
2. *User-declared* — the dotfile may point rook at an arbitrary binary
   (same trust as your shell rc). Rook runs it as found, never installs it.
3. *Repo-requested* — `.rook/config` arrives via `git clone`, so it may
   select catalog entries and tune them, but a command line from the repo
   layer is **ignored and surfaced as refused**. Bespoke-per-repo binaries
   get a direnv-style trust prompt someday; never silent exec.

**Config.** Plugin types get **ergonomic, type-scoped keys** in the existing
ghostty flat file — `lsp = go`, not `plugin = go`. The plugin system is
internal architecture; config stays domain-shaped. (A future theme type reads
`theme = …`; the theming direction is the likely second type and the first
test of this substrate.)

**Status.** Every declared plugin reports: tier, state
(`ready`/`installing`/`needs <toolchain>`/`missing`/`off`), managed version or
resolved PATH binary, refused repo-layer lines. `GET /plugins` +
`rookctl plugin list` read it; Settings renders it.

**Not built until a second type demands it:** an external manifest format,
third-party authoring, a marketplace, UI contribution points, plugin-to-plugin
deps, per-plugin token scopes. The revisit trigger is concrete — the second
plugin type is where the generic API gets designed against two real cases
instead of one.

---

## Principles (language type)

1. **Two tiers: intent and explicit.** `lsp = go, typescript` names languages;
   rook expands each through the catalog (server, install method, pinned
   version, filetypes, roots, default settings). `lsp-<server>-*` keys address
   a specific server for overrides or bring-your-own declarations. Intent is
   the daily surface; explicit is the escape hatch.

2. **Config is the whole truth.** A server runs because a config line implies
   it — no auto-detection, no silent defaults. Copy the config file to a new
   machine and rook converges to the same setup: same languages, same pinned
   versions, materialized on demand.

3. **Layering is parse order.** The existing config parser is last-wins over
   `key = value` lines. The repo layer is therefore free: parse
   `~/.config/rook/config`, then parse `<root>/.rook/config` over it. No merge
   engine — the second file's lines win. Same parser, same fail-open unknown
   keys. First checked-in config precedent in rook.

4. **Roots, not directory config.** Per-directory needs (a Go module and a TS
   app in one repo) are handled by root markers, the way LSP already thinks: a
   file's server instance is keyed by the nearest ancestor containing a root
   marker. One server may run several instances per workspace. No third config
   layer.

5. **Hand-rolled LSP client.** JSON-RPC over stdio in the host (~200 lines:
   Content-Length framing, id correlation, `initialize`, `didOpen`/
   `didChange`). No jsonrpc dep, matching house practice.

---

## Config

```
# ~/.config/rook/config  (user layer)

# Intent tier — catalog plugins; rook installs and manages these.
lsp = go, typescript, svelte

# Explicit tier — override a catalog expansion per key…
lsp-gopls-settings  = {"gopls":{"staticcheck":true}}

# …or bring your own server. A command line marks the server system-provided:
# rook execs it from PATH and never installs or upgrades it.
lsp-zls           = zls
lsp-zls-filetypes = zig
lsp-zls-roots     = build.zig, .git
```

```
# <workspace-root>/.rook/config  (repo layer — checked in)

lsp = go, typescript                                  # catalog only — safe
lsp-gopls-settings = {"gopls":{"buildFlags":["-tags","server"]}}
lsp-vtsls          = off                              # disable per-repo
```

Semantics:

- `lsp = <languages>` — each name expands to its catalog entry (managed
  command, filetypes, roots, default settings). Unknown language → status
  row, not an error. Last-wins like every key: a repo's `lsp` line states
  that repo's languages wholesale.
- `lsp-<server> = <command>` — explicit server, system-provided. `off`
  disables the server regardless of tier. In the repo layer, only `off` is
  honored (trust tier 3).
- `lsp-<server>-filetypes` — extensions, comma-separated (extension-based
  mapping; no filetype-detection engine).
- `lsp-<server>-roots` — ordered markers; nearest ancestor directory
  containing any of them, bounded by the workspace root, keys the instance.
  No marker found → workspace root.
- `lsp-<server>-settings` — opaque JSON handed to the server
  (`workspace/didChangeConfiguration`); rook never interprets it. Replaces
  the catalog default wholesale (never a JSON merge — rook would have to
  interpret); one-line JSON is the price of the flat file.

`Load()` already re-reads on every call, so config edits apply on the next
spawn; `rookctl lsp restart <server>` bounces a running instance deliberately.

Day-one catalog (`type: language`):

| plugin       | server         | method                                  |
|--------------|----------------|-----------------------------------------|
| `go`         | `gopls`        | `go install golang.org/x/tools/gopls@vX` (GOBIN → prefix) |
| `typescript` | `vtsls`        | `npm install` into prefix               |
| `svelte`     | `svelteserver` | `npm install` into prefix               |

Install is lazy: the first query touching a language whose server is absent
triggers materialization as a host child (logged, status `installing`);
queries return empty meanwhile (fail open). Toolchain absent (`go`, `node`) →
status `needs go toolchain`, no retry storm.

---

## Runtime

**Instance = (server, root dir).** Spawned lazily on the first query that maps
to it, supervised per the substrate's process model. Idle shutdown is
deferred; instances live until host shutdown or explicit restart.

**Document sync.** Query requests may carry the current buffer text
(`text` field). The host tracks per-instance open documents: first sight of a
path → `didOpen` (text from the request, else disk); subsequent sight with
changed text → `didChange` (full sync, `TextDocumentSyncKind.Full`). No
incremental diffs — full text per change is well within gopls/vtsls tolerance
and keeps the client dumb. A request without `text` serves from disk, which is
correct after `:w` — the vim habit rook's editor already encourages.

**Positions.** LSP columns are UTF-16 code units unless the server accepts
`positionEncoding: utf-8` (negotiated at initialize). Monaco columns are also
UTF-16-based, so the frontend path is aligned by default; the host converts
for utf-8-negotiated servers. rookctl accepts byte-ish human columns and lets
the host convert — off-by-one on an emoji line is acceptable for slice one.

**Failure posture.** Per the host-protocol-skew rule, everything fails open:
no server for a filetype → empty result, installing/missing → empty result +
status row, server crash mid-query → error result once, empty after. The
editor must feel like "no LSP here", never like "LSP is broken and shouting".

---

## Host API

House style: workspace-scoped paths, anonymous-struct decode, `writeJSON`,
`http.Error`.

```
GET  /plugins                              lifecycle: catalog + declared, states, versions
GET  /workspaces/{name}/lsp/status         runtime: effective servers, instances, refusals
POST /workspaces/{name}/lsp/definition     {path, line, col, text?}
POST /workspaces/{name}/lsp/references     {path, line, col, text?}
POST /workspaces/{name}/lsp/hover          {path, line, col, text?}
```

Paths are workspace-relative in requests and responses. Definition/references
return `[{path, startLine, startCol, endLine, endCol}]`; hover returns
`{contents, range?}` with contents as markdown text.

## rookctl surface

```
rookctl plugin list                          lifecycle (generic, all types)
rookctl plugin install <name>|--all          materialize now instead of lazily
rookctl plugin upgrade [<name>]              re-materialize to current pins
rookctl lsp status  [-w ws]                  runtime (language type)
rookctl lsp restart <server> [-w ws]
rookctl def   <path>:<line>[:<col>] [-w ws]
rookctl refs  <path>:<line>[:<col>] [-w ws]
rookctl hover <path>:<line>[:<col>] [-w ws]
```

Lifecycle verbs are `plugin` (they will serve every type); capability verbs
are domain-named. `def`/`refs` print `path:line:col  <line text>` —
grep-shaped, pipe-friendly, and exactly what a claude session wants to read.
This is the point: the scorer, the thread responder, and the future explore
work-type all get navigation for free the day this lands.

## Frontend surface

- Register Monaco `DefinitionProvider` / `ReferenceProvider` / `HoverProvider`
  for the union of configured filetypes (fetched from status at editor init),
  each a thin fetch to the endpoints above, sending the current model text as
  `text` when the buffer is dirty.
- Cross-file definition needs an opener: Monaco resolves a Location in a
  foreign model via the editor-opener seam, which we point at the existing
  `openFile` ladder (reveal → retarget → mint pane). This is also where the
  future jumplist hooks — every opener transition is a jump.
- `gd` / `gr` in vim-mode map to Monaco's `editor.action.revealDefinition` /
  `editor.action.goToReferences`; ⌘-click and F12 come along free.
- Status renders in Settings (plugin / state / version), not a new surface.

---

## What slice one ships

- The substrate: in-binary catalog, materialization prefix, lazy install,
  supervision, trust tiers, `GET /plugins`, `rookctl plugin
  list|install|upgrade` — exercised by exactly one type.
- Config keys (intent + explicit tiers, user + repo layers), `.rook/config`
  parsing bounded to `lsp*` keys.
- The `language` type: catalog entries `go`/`typescript`/`svelte`; the LSP
  client (initialize, didOpen/didChange full sync, definition, references,
  hover); per-root supervised instances.
- The four workspace endpoints + `rookctl lsp status|restart` +
  `def|refs|hover`.
- Monaco providers, the opener→openFile seam, `gd`/`gr`, Settings status.
- Dogfood: `lsp = go, typescript, svelte` in Seth's dotfile; rook's own repo
  gains `.rook/config` with the e2e build-tags gopls settings — the first
  checked-in repo config, in this repo, day one.

## Deferred (seams, not built)

- **The generic plugin API.** External manifest format, third-party
  authoring, marketplace, UI contribution points, per-plugin token scopes —
  designed when the **second type** exists (theming is the likely candidate),
  against two real cases instead of one.
- **Diagnostics.** Highest-value next LSP step, but push-shaped and the host
  has no event bus (the attach websocket is terminal-bytes only). Seam: a
  pull endpoint (`GET /lsp/diagnostics?path=`) polled after save fits the
  house polling pattern; a real push channel is a separate decision.
- **Completion / rename / code actions / formatting.** Editing-faster
  features; the editor is the exploration surface first. Formatting stays
  with oxfmt/gofmt on save outside LSP.
- **Catalog long tail.** Importing mason-registry (community-maintained
  machine-readable catalog: npm/go/cargo/github-release sources) if the
  curated set constrains.
- **Github-release install method** (rust-analyzer et al. — binaries with no
  toolchain dependency). Add with the first language that needs it.
- **Repo-declared commands via trust prompt.** direnv-style
  `rookctl plugin allow`.
- **Idle shutdown / memory caps** for instances.
- **Breadcrumbs.** The opener seam is where an explore work-type will record
  visited anchors; nothing stored yet.

---

## Decisions (v1 — dogfood first)

1. **This is the plugin system; language support is its only day-one type.**
   The substrate (catalog, prefix, lifecycle, supervision, trust tiers) is
   named and built generically; the generic *API* is not designed until type
   two. *Revisit when:* the second type arrives (theming direction) — that is
   the deliberate design moment, not a failure of this spec.
2. **Config keys are type-scoped and ergonomic** (`lsp = go`, someday
   `theme = …`), never a generic `plugin =` key. *Revisit when:* a type has
   no natural domain word — unlikely.
3. **Curated in-binary catalog; rook installs into its own prefix.** No
   community registry, no arbitrary install commands from config. *Revisit
   when:* a language you need isn't in the catalog twice in one month — then
   import mason-registry rather than growing bespoke entries.
4. **Repo layer selects catalog entries and tunes; never supplies commands.**
   *Revisit when:* a real repo needs a binary rook can't materialize — then
   add the trust prompt, still never silent exec.
5. **Two layers, no per-dir config.** Root markers give per-dir servers.
   *Revisit when:* two dirs under one root genuinely need different settings.
6. **Lazy install on first query, fail-open while installing.** *Revisit
   when:* the cold-start silence (empty results during a first `go install`)
   reads as breakage rather than warmup.
7. **Full-text sync, request-carried buffers, disk otherwise.** *Revisit
   when:* didChange latency on a large file is perceptible in hover.
8. **Def/refs/hover only; no diagnostics or completion in slice one.**
   *Revisit when:* daily driving makes the absence of red squiggles the thing
   you miss most — then build the pull-after-save endpoint first, not the
   push bus.
