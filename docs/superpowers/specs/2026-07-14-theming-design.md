# Theming — design

**Date:** 2026-07-14
**Status:** approved, ready for implementation plan (Phase A)

## Problem

rook's colors are hardcoded as **four independent copies** of the Material
Ocean palette:

1. `app.css` `@theme` block — Tailwind utility tokens (`--color-acc/fg/dim/lo/
   amber/red/hot/line/raise`) that generate `text-acc`, `bg-raise`, etc.
2. `app.css` `body { --acc/fg/dim/line/mono }` — CSS vars read by the
   imperative remainder (terminal tree `term/view.ts`, Monaco pane
   `term/editor.ts`, thread glyphs `term/threadview.ts`).
3. `main.ts` `THEME` — the xterm palette (16 ANSI + foreground/cursor/
   selection).
4. `term/monaco.ts` `defineTheme("rook", …)` — the editor's syntax token
   colors and editor-UI colors.

Changing one accent means editing four files by hand. There is no way to
switch themes at runtime, ship more than one built-in, or let users bring
their own. We want dynamic themes (runtime swap), built-ins **and**
user-defined themes, and — the guiding constraint — **maximum reuse of the
existing theme ecosystems** (VS Code/Cursor, base16/base24, terminal themes)
rather than reinventing theming.

## Decision

Collapse the four palettes into **one internal semantic `Palette`**. Everything
that paints color derives from it at runtime. Themes are **imported** from the
big ecosystems into that `Palette`, not authored from scratch.

**VS Code theme JSON is the primary reuse hub**, for one decisive reason:
rook's editor *is* Monaco — VS Code's editor — and a VS Code color theme is
the only single artifact that covers **all three** of rook's surfaces:
`colors["editor.*" / "sideBar.*" / "statusBar.*"]` → chrome, `colors["terminal.
ansi*"]` → xterm, `tokenColors[]` → editor syntax. Cursor uses this format
verbatim. base16/base24 and terminal configs (ghostty/iTerm/alacritty) are
secondary importers.

This design is grounded in a verified research pass (deep-research run
`wf_0cb3ea1e-30d`, 2026-07-14: 106 extracted claims, 75 adversarial
verifications, **zero refuted**). The two findings that shaped it:

- **Monaco's `colors{}` is the editor *subset* of VS Code's keys**, not the
  full workbench set — it takes `editor.*/editorGutter/editorLineNumber/
  editorWidget/editorCursor`, **not** `sideBar.*` (Monaco has no side bar). So
  rook's CSS-var chrome owns everything outside the editor. This already
  matches how rook chrome works.
- **VS Code syntax reuse is lossy for us, and we accept that.** VS Code colors
  **TextMate scopes**; rook's Monaco uses the built-in **Monarch** tokenizer
  (`edcore.main`, no TextMate grammar engine). High-fidelity reuse would mean
  shipping a browser TextMate engine (`monaco-textmate` + `vscode-oniguruma`
  **WASM**) and *excluding* Monaco's built-in tokenizers — a large
  architecture change. **Phase A keeps Monarch and maps TextMate scopes → our
  ~12 coarse tokens (lossy).** Editor-UI, terminal, and chrome colors map
  *exactly*; only fine-grained syntax shading is approximate. We also **ignore
  `semanticTokenColors`** (Monaco+Monarch has no semantic tokens).

## The Palette

One flat record of semantic roles — the single source of truth. Enough to
reproduce today's look *and* to receive any VS Code / base16 theme.

```
type ThemeType = "dark" | "light";

interface Palette {
    type: ThemeType;

    // surfaces
    bg;        // editor + terminal + window base           (editor.background)
    raise;     // raised panel: side panes, titlebar        (sideBar.background)
    overlay;   // floating: palette, widgets, modals         (editorWidget.background)
    line;      // hairlines / borders                        (panel.border / contrastBorder)

    // text
    fg;        // primary UI text (chrome)                   (foreground)
    editorFg;  // editor + terminal body text                (editor.foreground / terminal.foreground)
    dim;       // muted UI text, secondary labels            (descriptionForeground)
    lo;        // faint: line numbers, disabled              (editorLineNumber.foreground)

    // state
    accent;    // primary accent: focus ring, active, links  (focusBorder / textLink.foreground)
    cursor;    // caret                                       (editorCursor.foreground)
    selection; // selection background                        (editor.selectionBackground)

    // hues (accents; also feed syntax + ANSI when those are absent)
    blue; green; yellow; red; magenta; cyan; orange;

    // terminal — the 16 ANSI, explicit when the source has them, else derived
    ansi: [black, red, green, yellow, blue, magenta, cyan, white,
           brightBlack, brightRed, brightGreen, brightYellow,
           brightBlue, brightMagenta, brightCyan, brightWhite];

    // editor syntax — coarse, one per Monaco/Monarch token; default to hues
    syntax: {
        comment; string; number; keyword; type; function; variable;
        constant; operator; tag; attrName; attrValue; regexp;
    };
}

interface Theme { name: string; palette: Palette; }
```

**Correction over today:** rook currently uses one muted grey (`--dim`,
`#8f93a2`) as *both* the editor/terminal foreground *and* muted UI text, while
chrome text is the brighter `#d6deeb`. VS Code separates these
(`editor.foreground` vs `foreground`). The `Palette` splits them —
`editorFg` (editor/terminal body) vs `fg` (UI) vs `dim` (muted UI) — so
imported themes render their editor text faithfully instead of being forced
dim. The Material Ocean built-in reproduces today's look exactly
(`fg=#d6deeb`, `editorFg=#8f93a2`, `dim=#8f93a2`, `lo=#5b6273`).

## Applying a palette (the three consumers)

A `ThemeService` applies one `Palette` to all three surfaces at runtime:

1. **CSS custom properties (chrome + all Tailwind utilities), live and free.**
   Tailwind v4 utilities compile to `var(--color-*)`. Writing the `--color-*`
   tokens **and** the imperative `--fg/--dim/--line/…` vars onto
   `document.documentElement` (inline style, which beats the stylesheet
   `:root`) recolors every `text-acc`/`bg-raise` and every raw-CSS surface
   instantly, with no DOM walk. This is the whole reason chrome theming is
   cheap.
2. **xterm** — `buildXtermTheme(palette)` → `ITheme` (`background/foreground/
   cursor/cursorAccent/selectionBackground` + `black..white` +
   `brightBlack..brightWhite`), assigned to `term.options.theme` on every live
   terminal. All keys optional; alpha supported.
3. **Monaco** — `buildMonacoTheme(palette)` → `IStandaloneThemeData`
   (`base/inherit/rules[{token,foreground,fontStyle}]/colors{}`), via
   `monaco.editor.defineTheme("rook", data)` + `setTheme("rook")`. `rules` come
   from `palette.syntax` keyed on Monarch token names; `colors{}` sets the
   editor-subset UI keys (`editor.background/foreground`, `editorCursor.
   foreground`, `editor.selectionBackground`, `editorLineNumber.foreground`,
   `editorWidget.*`).

The active theme is a store field; changing it re-runs all three appliers. The
choice persists as a `theme = <name>` config key.

## The VS Code importer

`importVSCode(json) → Theme`. Steps, each grounded in a verified finding:

**Parse.** Real themes ship as **JSONC** (Nord, Night Owl carry `//` comments)
— strip comments before `JSON.parse`. Read `name`, `type`, `colors{}`,
`tokenColors[]`. **Ignore `semanticTokenColors`** (out of scope for Monarch).

**Normalize color values.** Every popular theme uses alpha — `#RRGGBBAA` and
`#RGBA` shorthand (One Dark Pro's `editor.selectionBackground` is `#67769660`;
Nord/Tokyo Night use 8-digit throughout). The parser must expand `#RGB`/`#RGBA`
→ 6/8-digit and preserve the alpha channel, never assume opaque 6-digit hex.

**`colors{}` → roles (direct read, with derivation fallback).** Popular themes
populate only ~110–230 of ~600 keys, so **derivation is mandatory**. But they
*do* set the terminal-ANSI and `sideBar.*`/`list.*` keys directly, so those are
read, not guessed. The map:

| Palette role | VS Code key (read) | derive if absent |
|---|---|---|
| `bg` | `editor.background` | — |
| `editorFg` | `editor.foreground` | — |
| `fg` | `foreground` | `editorFg` |
| `raise` | `sideBar.background` | `editorGroupHeader.tabsBackground` → `bg` |
| `overlay` | `editorWidget.background` | `bg` lightened |
| `line` | `panel.border` / `contrastBorder` | `fg` @ low alpha |
| `lo` | `editorLineNumber.foreground` | `editorFg` @ ~0.4 |
| `accent` | `focusBorder` | `blue` |
| `cursor` | `editorCursor.foreground` | `editorFg` |
| `selection` | `editor.selectionBackground` | `accent` @ ~0.3 |
| `ansi[0..15]` | `terminal.ansiBlack..BrightWhite` | base16-style from hues + surfaces |
| terminal bg/fg | `terminal.background`/`.foreground` | `bg` / `editorFg` (commonly omitted) |
| terminal cursor | `terminalCursor.foreground` | terminal fg (often omitted) |

Derivation mirrors VS Code's own model (`transparent()/darken()/lighten()`,
e.g. inactive selection = `transparent(selection, 0.5)`).

**`tokenColors[]` → `syntax` (lossy scope → coarse token).** TextMate rules
target scopes (`keyword.control`, `entity.name.function`, `variable.parameter`)
via specificity/parent-scope selectors that Monarch's flat token names can't
honor. We resolve each of our coarse tokens by looking up the color of the
best-matching scope from a fixed table:

| `syntax` role → Monarch token | best-match TextMate scope(s) |
|---|---|
| `comment` | `comment` |
| `string` | `string` |
| `number` → `number` | `constant.numeric` |
| `keyword` → `keyword` | `keyword`, `storage` |
| `type` → `type` | `entity.name.type`, `support.type` |
| `function` | `entity.name.function`, `support.function` |
| `variable` | `variable` |
| `constant` | `constant.language`, `support.constant` |
| `operator` → `delimiter`/`operator` | `keyword.operator` |
| `tag` | `entity.name.tag` |
| `attrName` → `attribute.name` | `entity.other.attribute-name` |
| `attrValue` → `attribute.value` | `string` |
| `regexp` | `string.regexp` |

Fidelity: coarse. Two keywords the theme shades differently (control vs
storage) collapse to one color. Accepted for Phase A — the editor is a
review/edit surface, not a syntax showcase, and UI+terminal fidelity is exact.

## Built-ins

Phase A ships **Material Ocean** (today's palette, expressed in the new format,
verified pixel-parity) plus **1–2 more** to prove switching — the natural
choices are one popular dark import (e.g. One Dark) and one light, so the
`type: light` path and the importer both get exercised by real data.

## What Phase A does *not* do (Phase B and beyond)

- **User-authored theme files** and **drop-in raw VS Code `theme.json`** from
  `~/.config/rook/themes/` with hot-reload. Phase A is built-ins only; the
  importer is exercised at build time to author them. (When we do add files,
  the format leans toward: accept raw VS Code JSON directly, auto-detected on
  load — reuse over a bespoke format.)
- **base16/base24 and terminal-config importers.** The mapping tables are
  captured (research §3; `tinted-terminal` already templates base16→ghostty/
  iTerm/alacritty), but Phase A only builds the VS Code path.
- **High-fidelity TextMate syntax** (browser oniguruma/WASM). Only if lossy
  Monarch shading proves inadequate in practice.
- **Semantic tokens**, **font/spacing/radius theming** (colors only for now).

## Non-goals / constraints

- No host changes: theming is entirely frontend + a `theme` config scalar (the
  host already hot-reads config). The imperative islands (xterm, Monaco) keep
  raw CSS per the Tailwind migration rule; they read the same `--*` vars.
- Preserve today's look exactly under the "Material Ocean" built-in — a reload
  with the default theme must be indistinguishable from before.
