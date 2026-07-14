# Theming Phase A — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Read the design first: `docs/superpowers/specs/2026-07-14-theming-design.md`.

**Goal:** Collapse rook's four hardcoded Material Ocean palettes into ONE
semantic `Palette` applied at runtime to chrome (CSS vars), xterm, and Monaco;
ship a VS Code theme importer and 2–3 built-ins switchable live from Settings.
Phase A is built-ins only — user theme *files* are Phase B.

**Architecture:** A pure `theme/` module (types + color math + importers +
per-consumer builders), a `ThemeService` that applies the active `Palette` to
all three surfaces, and thin wiring (main.ts, monaco.ts, manager, Settings,
config). The hard parts are pure functions with vitest coverage; the Svelte/DOM
wiring gates on `pnpm check`/`lint`/`build` + the parity check.

**Tech stack:** TypeScript, Svelte 5, Tailwind v4, vitest (`src/**/*.spec.ts`,
node env). Go only for one config scalar. Frontend gates:
`pnpm check` (0 errors), `pnpm lint`, `pnpm test`, `pnpm run build`,
`pnpm exec oxfmt --check <files>`.

## Global Constraints

- **Pixel parity is the acceptance bar for the plumbing.** After Tasks 1–6 the
  app must look **identical** to today under the default "Material Ocean"
  theme. The Material Ocean built-in reproduces every current hex.
- **Preserve the existing CSS token names.** The `@theme` tokens
  (`--color-acc/grn/fg/dim/lo/amber/red/hot/line/raise`) and the body vars
  (`--acc/--fg/--dim/--line/--mono`) are consumed by existing utilities and the
  imperative islands. The applier writes *these exact names* from `Palette`
  roles — do not rename them.
- **Monaco quirk:** `rules[].foreground` is a **6-digit hex WITHOUT `#`** and
  cannot carry alpha; `colors{}` values DO use `#` and may carry alpha. The
  Monaco builder strips `#` and any alpha from rule foregrounds.
- **Alpha everywhere:** every real theme uses `#RRGGBBAA`/`#RGBA`. All color
  handling normalizes through one helper; never assume opaque 6-digit hex.
- **No new host HTTP.** Only a `theme` config scalar (Task 9), read via the
  existing `config.Service`; the host already hot-reads config.
- **Imperative islands keep raw CSS** (Tailwind migration rule) — they read the
  same `--*` vars the applier writes.
- Colors only — no font/spacing/radius theming in Phase A.

---

### Task 1: Color utilities (`theme/color.ts`)

**Files:**
- Create: `frontend/src/theme/color.ts`
- Test: `frontend/src/theme/color.spec.ts`

**Interfaces:**
- `normalizeHex(input: string): string` — expand `#RGB`/`#RGBA` → `#RRGGBB`/
  `#RRGGBBAA`, lowercase, keep alpha; passthrough valid 6/8-digit; throw on
  garbage.
- `stripAlpha(hex: string): string` — `#RRGGBBAA` → `#RRGGBB` (for Monaco rule
  foregrounds / any opaque sink).
- `noHash(hex: string): string` — drop leading `#` (Monaco rule foregrounds).
- `withAlpha(hex: string, a: number): string` — set alpha (0–1) → `#RRGGBBAA`.
- `mix(hex, hex, t): string`, `lighten(hex, amt)`, `darken(hex, amt)` — for
  derivation; operate on RGB, ignore/drop alpha.

- [ ] **Step 1: Write failing tests** covering: `#abc`→`#aabbcc`, `#abcd`→
  `#aabbccdd`, `#AABBCC`→`#aabbcc`, passthrough `#12345678`, `stripAlpha
  ("#11223344")==="#112233"`, `noHash("#112233")==="112233"`, `withAlpha
  ("#112233",0.5)` ends in the right alpha byte, `mix("#000000","#ffffff",0.5)`
  ≈ `#808080`, throw on `"nope"`.
- [ ] **Step 2:** Run `pnpm test -- color` → FAIL (module missing).
- [ ] **Step 3:** Implement `color.ts`.
- [ ] **Step 4:** `pnpm test -- color` → PASS.

---

### Task 2: Palette + Theme types, and the Material Ocean built-in (`theme/palette.ts`)

**Files:**
- Create: `frontend/src/theme/palette.ts`
- Test: `frontend/src/theme/palette.spec.ts`

**Interfaces:** the `Palette` / `Theme` types from the design spec (surfaces,
text, state, hues, `ansi[16]`, `syntax{}`). Export `MATERIAL_OCEAN: Theme` with
EXACTLY today's values, cross-checked against the current sources:

- from `app.css` @theme: `accent=#82aaff`, `green=#c3e88d`, `fg=#d6deeb`,
  `dim=#8f93a2`, `lo=#5b6273`, `yellow=#ffcb6b`, `red=#ff5370`, `hot=#f07178`,
  `line=rgb(140,150,180)` (→ `#8c96b4`), `raise=rgba(255,255,255,0.035)`.
- from `main.ts` THEME (xterm): `editorFg=#8f93a2`, `cursor=#ffcc00`,
  `selection=#717cb4`, and `ansi` = black `#546e7a`, red `#ff5370`, green
  `#c3e88d`, yellow `#ffcb6b`, blue `#82aaff`, magenta `#c792ea`, cyan
  `#89ddff`, white `#eeffff`, brightBlack `#546e7a`, brightRed `#ff5370`,
  brightGreen `#c3e88d`, brightYellow `#ffcb6b`, brightBlue `#82aaff`,
  brightMagenta `#c792ea`, brightCyan `#89ddff`, brightWhite `#ffffff`.
- from `monaco.ts` (syntax): `comment=#546e7a`, `string=#c3e88d`,
  `number=#f78c6c` (→ `orange`), `keyword=#c792ea` (→ `magenta`),
  `type=#ffcb6b`, `operator=#89ddff` (→ `cyan`), `tag=#ff5370`,
  `attrName=#ffcb6b`, `attrValue=#c3e88d`; `function/variable/constant/regexp`
  default to sensible hues (fill so none are undefined). Surfaces: `bg=#0f111a`,
  `overlay=#151928`. `magenta=#c792ea`, `cyan=#89ddff`, `orange=#f78c6c`.

- [ ] **Step 1: Failing test** — assert `MATERIAL_OCEAN.palette` has every role
  defined (no `undefined`), `ansi.length===16`, and spot-check
  `accent==="#82aaff"`, `bg==="#0f111a"`, `syntax.keyword==="#c792ea"`.
- [ ] **Step 2:** `pnpm test -- palette` → FAIL.
- [ ] **Step 3:** Implement types + `MATERIAL_OCEAN`.
- [ ] **Step 4:** `pnpm test -- palette` → PASS.

---

### Task 3: CSS-var mapping (`theme/cssvars.ts`)

**Files:**
- Create: `frontend/src/theme/cssvars.ts`
- Test: `frontend/src/theme/cssvars.spec.ts`

**Interfaces:**
- `cssVars(p: Palette): Record<string, string>` — PURE map from palette roles
  to the existing CSS custom-property names. Must emit, at minimum:
  `--color-acc`←accent, `--color-grn`←green, `--color-fg`←fg, `--color-dim`←
  dim, `--color-lo`←lo, `--color-amber`←yellow, `--color-red`←red,
  `--color-hot`←hot, `--color-line`←line, `--color-raise`←raise, plus the body
  mirror `--acc/--fg/--dim/--line`. (Grep the codebase for every `--color-*`
  and bare `--*` var actually referenced and cover them ALL — a missed var
  silently keeps a hardcoded color.)

- [ ] **Step 1: Failing test** — `cssVars(MATERIAL_OCEAN.palette)` returns the
  expected name→value pairs (spot-check a few) and includes every var name
  found by `grep -rhoE '\--color-[a-z]+|\bvar\(--[a-z]+' src`.
- [ ] **Step 2:** `pnpm test -- cssvars` → FAIL.
- [ ] **Step 3:** Implement; reconcile against the grep of referenced vars.
- [ ] **Step 4:** `pnpm test -- cssvars` → PASS.

---

### Task 4: xterm theme builder (`theme/xterm.ts`)

**Files:**
- Create: `frontend/src/theme/xterm.ts`
- Test: `frontend/src/theme/xterm.spec.ts`

**Interfaces:**
- `buildXtermTheme(p: Palette): ITheme` — `background` is **transparent**
  (`#00000000`, the page body paints the tint — preserve today's behavior),
  `foreground=editorFg`, `cursor=p.cursor`, `selectionBackground=p.selection`,
  and `black..white`/`brightBlack..brightWhite` from `p.ansi[0..15]`. Import
  `ITheme` type from `@xterm/xterm`.

- [ ] **Step 1: Failing test** — assert mapping: `foreground===editorFg`,
  `blue===ansi[4]`, `brightWhite===ansi[15]`, `background==="#00000000"`.
- [ ] **Step 2:** `pnpm test -- xterm` → FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** `pnpm test -- xterm` → PASS.

---

### Task 5: Monaco theme builder (`theme/monaco-theme.ts`)

**Files:**
- Create: `frontend/src/theme/monaco-theme.ts`
- Test: `frontend/src/theme/monaco-theme.spec.ts`

**Interfaces:**
- `buildMonacoTheme(p: Palette): IStandaloneThemeData` — `base:"vs-dark"`
  (or `"vs"` when `p.type==="light"`), `inherit:true`, `rules` from `p.syntax`
  keyed on Monarch token names (`comment, string, number, keyword, type,
  identifier, delimiter, tag, attribute.name, attribute.value, regexp,
  operator`), foregrounds via `noHash(stripAlpha(...))`, and `colors{}` with
  `editor.background=p.bg`, `editor.foreground=p.editorFg`,
  `editorCursor.foreground=p.cursor`, `editor.selectionBackground=p.selection`,
  `editorLineNumber.foreground=p.lo`, `editorLineNumber.activeForeground=
  p.dim`, `editorWidget.background=p.overlay`, `editorWidget.border=p.line`,
  plus the diff colors currently in `monaco.ts` (derive from green/red at low
  alpha). Type-only import of `IStandaloneThemeData` from `monaco-editor`.

- [ ] **Step 1: Failing test** — a `keyword` rule exists with
  `foreground==="c792ea"` (no `#`), `colors["editor.background"]==="#0f111a"`,
  `base==="vs-dark"`.
- [ ] **Step 2:** `pnpm test -- monaco-theme` → FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** `pnpm test -- monaco-theme` → PASS.

---

### Task 6: ThemeService + wire the three consumers (parity-preserving)

**Files:**
- Create: `frontend/src/theme/service.ts`
- Modify: `frontend/src/main.ts`, `frontend/src/term/monaco.ts`,
  `frontend/src/term/manager.ts`, `frontend/src/term/editor.ts` (Monaco theme),
  `frontend/src/state.svelte.ts` (active theme field)

**Interfaces:**
- `theme/service.ts`: a singleton holding the active `Theme` + the registry of
  built-ins (`{ "Material Ocean": MATERIAL_OCEAN, … }`).
  - `activeTheme(): Theme`, `xtermTheme(): ITheme`, `monacoTheme():
    IStandaloneThemeData`, `builtins(): string[]`.
  - `apply(name: string)`: set active; `applyCssVars(documentElement)` (write
    `cssVars()` via `style.setProperty`, plus body background =
    `withAlpha(bg, cfg.backgroundOpacity)`); retheme all terminals via a new
    `manager.setTerminalTheme(ITheme)`; `monaco.editor.defineTheme("rook", …)`
    + `setTheme("rook")` when Monaco is loaded.
  - Reads the persisted `theme` name at boot (Task 9); defaults to "Material
    Ocean".
- `manager.ts`: `setTerminalTheme(t: ITheme)` — iterate tabs, set
  `tab.term.options.theme = t`. New terminals in `mkTerm` read
  `themeService.xtermTheme()` instead of the module `THEME` const.
- `main.ts`: replace the hardcoded `THEME` usage with the service; body tint
  from `withAlpha(palette.bg, cfg.backgroundOpacity)`.
- `monaco.ts`: replace the inline `defineTheme("rook", …)` with
  `buildMonacoTheme(themeService.activeTheme().palette)` at load; `editor.ts`
  already sets `theme:"rook"`.

- [ ] **Step 1:** Implement `service.ts` (built-ins registry + appliers).
- [ ] **Step 2:** Wire `manager.setTerminalTheme` + `mkTerm` to the service.
- [ ] **Step 3:** Wire `main.ts` (delete `THEME` const) + `monaco.ts` (delete
  inline theme) to the builders.
- [ ] **Step 4: Parity gate** — `pnpm check`/`lint`/`build`; run `make dev` and
  confirm the app is visually IDENTICAL to before (terminal colors, editor
  syntax, chrome, side panes). This is the acceptance bar for the plumbing.

---

### Task 7: VS Code importer (`theme/import-vscode.ts`)

**Files:**
- Create: `frontend/src/theme/import-vscode.ts`
- Test: `frontend/src/theme/import-vscode.spec.ts`
- Fixture: `frontend/src/theme/__fixtures__/mini-vscode-theme.json` (a small
  hand-authored theme exercising: JSONC comments, `#RRGGBBAA`, terminal.ansi*
  present, sideBar/list present, a few tokenColors scopes, one MISSING key to
  force derivation).

**Interfaces:**
- `importVSCode(text: string): Theme` — strip `//`/`/* */` comments, JSON.parse,
  normalize all colors, map `colors{}`→roles (design's table, with derivation
  fallbacks mirroring VS Code's transparent/darken/lighten), map
  `tokenColors[]` scopes→`syntax` via the fixed best-match table (design). Name
  from `name`; `type` from `type`. **Ignore `semanticTokenColors`.**
- Scope matching: for each syntax role, find the tokenColor rule whose `scope`
  (string or array) best-matches the target scope(s) — longest dotted-prefix
  match wins; take its `settings.foreground`.

- [ ] **Step 1: Failing tests** against the fixture — terminal ansi read
  directly, `bg` from `editor.background`, a derived key (e.g. terminal bg
  absent → equals `bg`), `syntax.keyword` from the `keyword` scope rule, alpha
  preserved in `selection`, comments in the JSON don't break parsing.
- [ ] **Step 2:** `pnpm test -- import-vscode` → FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** `pnpm test -- import-vscode` → PASS.

---

### Task 8: Additional built-in themes

**Files:**
- Create: `frontend/src/theme/builtins/` — checked-in `Theme` constants for
  **One Dark** (dark import) and **one light** theme (exercises `type:light` +
  `base:"vs"`). Author them by running a real upstream VS Code `theme.json`
  through `importVSCode` at build time, then paste the resulting `Palette`
  literal (do NOT ship the importer at runtime yet — that's Phase B; but the
  data it produces is fine to commit).
- Modify: `theme/service.ts` (register them).

- [ ] **Step 1:** Produce the two `Palette` literals via `importVSCode` on
  upstream JSON (verify each role populated).
- [ ] **Step 2: Test** — each built-in has all roles defined, `ansi.length===16`,
  and `type` correct.
- [ ] **Step 3:** Register in the service.
- [ ] **Step 4:** `pnpm test` → PASS.

---

### Task 9: Persist the choice — `theme` config scalar

**Files:**
- Modify: `internal/config/config.go` (add `Theme string` field + parse case),
  `internal/config/config_test.go`, `internal/config/write.go` +
  `write_test.go` (SetConfig support for the scalar), `docs/config.sample`
  (+ `TestSampleCoversParser` if it enforces coverage).

**Interfaces:**
- `Config.Theme string` (`json:"theme"`), default `""` (→ frontend uses
  "Material Ocean"). Parsed from `theme = <name>`. `SetConfig` upserts it
  last-wins like the other scalars (Jira URL etc.).

- [ ] **Step 1: Failing test** — `TestLoadTheme` (parse `theme = One Dark`),
  and a `SetConfig` round-trip test preserving comments/other keys.
- [ ] **Step 2:** `go test ./internal/config/ -run 'Theme'` → FAIL.
- [ ] **Step 3:** Add field + parse case + SetConfig case + config.sample line.
- [ ] **Step 4:** `go test ./internal/config/...` → PASS.

---

### Task 10: Settings picker (Appearance)

**Files:**
- Modify: `frontend/src/AppearanceSettings.svelte`, `frontend/src/state.svelte.ts`

**Interfaces:**
- Appearance gains a **Theme** dropdown seeded from `themeService.builtins()`,
  current value from the loaded config's `theme` (fallback "Material Ocean").
  Selecting one calls `themeService.apply(name)` (live, no reload) AND persists
  via `config.SetConfig({theme: name})`. Unlike fonts/opacity, theme swap needs
  NO reload — the appliers are runtime.

- [ ] **Step 1:** Add the dropdown + live `apply` + persist.
- [ ] **Step 2:** `pnpm check`/`lint`/`format`/`build`.
- [ ] **Step 3: Manual (make dev):** switch themes → chrome + terminal + editor
  all recolor instantly; reload → the chosen theme persists; set back to
  Material Ocean → identical to today.

---

### Task 11: Cleanup + final review

- [ ] Remove the now-dead hardcoded palettes: the literal Material Ocean values
  in `app.css` `@theme` and `body{}` remain as the **static defaults** (pre-JS
  paint) but must equal the built-in; confirm no OTHER file still hardcodes a
  Material Ocean hex (grep `82aaff|c792ea|ff5370|c3e88d|0f111a`).
- [ ] `pnpm test` (all green), `pnpm check` (0/0), `pnpm run build`, `pnpm lint`,
  `pnpm exec oxfmt --check .`, `go test ./internal/config/...`.
- [ ] Whole-branch review (correctness + parity); update `docs/config.sample`
  and the `[[rook-theming]]` memory with what landed.

## Verification checklist (Seth, make dev)

- [ ] Default theme is pixel-identical to before (terminal, editor syntax,
  chrome, side panes, palette/overlays).
- [ ] Switching to One Dark recolors chrome + all open terminals + the Monaco
  pane instantly, no reload.
- [ ] The light built-in flips editor `base` to `vs` and reads correctly.
- [ ] Choice persists across a full relaunch (`theme =` in config).
- [ ] Opacity still applies (body tint = themed bg at config opacity).
