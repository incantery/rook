# The agent panel — design brief

> Status: handoff to design, 2026-08-03. Everything described as
> "current" is landed on main (`bb73637`) and verifiable with the
> playground at the bottom. The ask: polish the whole experience —
> visual hierarchy, state language, empty/loading states, and the
> handful of open questions listed at the end. Function is done and
> e2e-covered; this pass is about how it *reads*.

## What you are polishing, in one paragraph

rook is a native macOS terminal/multiplexer/editor (one Zig binary, a
Metal-backed cell renderer — everything on screen is monospace text
cells, rects, and rounded rects; no images, no gradients, no DOM). Its
thesis: **human attention is the scarce resource**, and agents should
be legible at a glance. The surface here is the **plugin side panel**,
whose flagship tenant is the **agent plugin**: it watches Claude Code
transcripts, compresses every finished long turn into an STE digest
(headline + ≤5 bullets), and carries a reply loop — draft a suggested
reply, or expand the user's rough words into the reply they meant,
then copy it to the clipboard for ⌘V into the session. A second
tenant, the claude watcher, lists every session with an honest state.
Both feed one item vocabulary; the panel renders it.

## Hard constraints (the ones that are not up for debate)

1. **Semantic state in, theme out.** Plugins send *meaning* — a state
   string, typed fields, action ids — never colors, glyphs, or layout.
   Core owns every pixel (`docs/plugins/VOCABULARY.md`). Any polish is
   a change to how CORE renders the vocabulary, applied to every
   plugin at once.
2. **Theme-derived color only.** Eight builtin themes (Nocturne is the
   house default; vscode-dark, catppuccin, etc.). The chrome palette
   is small and semantic — see "Palette" below. New visual roles mean
   new palette slots with fallbacks across all eight themes; prefer
   composing the existing slots. Known trap: `bar_bg` paints panels
   too — themes must never tint it expecting only the status bar.
3. **Cell-grid rendering.** Primitives: `ui.text` (one style per run),
   `ui.textOver`, `ui.rect`, `ui.roundRect`, glass-translucent fills
   via `glassBg()`. Column widths are cell counts. Glyphs must ship in
   common monospace fonts — the user picks their font (`font-family`),
   so no nerd-font-only icons in core chrome. `▸ ▾ › ! ↩ ⌘` are safe.
4. **Zero idle frames.** Nothing animates except the cursor. A polish
   that wants motion (spinners, fades) must justify every frame; the
   render loop draws only on `scene_dirty`. Prefer state-change
   repaints (a chip that changes text) over animation.
5. **Blind verifiability.** Every visual state must be assertable
   without eyes: `ctl sidepane` prints the drawn rows, `ctl shot`
   captures real pixels, and the e2e suite (`plugins`, `panelwrap`,
   `panelfold` scenarios in `app/e2e/main.zig`) guards behavior.
   Design that cannot be asserted cannot ship.
6. **The wrap/fold/scroll mechanics are settled.** Children wrap as
   prose; children fold into the selected group; the list scrolls to
   the selection; the divider drags (20 cols … half-window). Polish
   their *appearance*, not their behavior.

## Current anatomy, precisely

### The panel container (`drawSidePane`, macos.zig)

- Full content height, right side by default, glass `bar_bg` fill,
  hairline `sep` on the pane-facing edge, divider = drag handle.
- Header row: tenant name (`agent`, `SEARCH`, `PENDING CONFIG`) in
  `bar_value`, then a `sep` hairline. Focus telegraph: a 1px `accent`
  line across the panel TOP when the panel holds the keys.
- No footer; the app status bar below is separate chrome.

### Rows (`drawPlugin`)

Flat item list, two depths (parent, child), drawn top to bottom from
the scroll position:

- **Parent row** (a digest, a session): optional state chip in
  `accent` at the left edge, then `▸`/`▾` in `bar_fg` when it has
  children (`▸` collapsed — every group except the selected one — with
  `▸+N` count visible only in the ctl dump, NOT drawn), then the title
  in `bar_value`, one line, clipped with `…`. Fields right-aligned on
  the same row in `bar_fg`, values only, shed whole off the left of
  the run when width runs out (declared least-important-first, so the
  last — cost — survives longest).
- **Child row** (a bullet, a reply chunk): indented 2 cells per depth,
  wraps at word boundaries (first line stops short of any fields,
  continuations run the full row), drawn in `bar_fg` — one shade down
  from parent titles.
- **Group gap**: `m.gap * 2` px of air before each parent after the
  first.
- **Selection**: `roundRect` in `chip_active_bg`, inset by `m.gap`
  from the panel edges, covering all wrapped lines of the row.
- **Action menu**: hangs under the selected row. Each action row:
  `›` in `accent` (or `!` in `ed_err` for a confirm action), label in
  `bar_fg` (`bar_value` when selected). Confirm appends
  `confirm? y/n` in `ed_err`. An INPUT_TEXT action in input mode
  appends the typed text in `bar_value` with a thin `accent` caret;
  the tail scrolls so the caret stays visible.
- **Message row** (bottom of list): what the last action said —
  "dismissed", "drafting…", a refusal — plain `bar_fg` text.
- **Status rows**: "asking…" while loading, "no answer"/plugin error
  in `ed_err`, "nothing to show" when live-and-empty, `+N more` when
  the wire truncated.

### The agent's content, concretely

A digest row set in the wild looks like (colors annotated):

```
agent                                        ← header, bar_value
────────────────────────────────────────────
▾ The bind fails because macOS limits Unix   ← bar_value, selected
  socket paths to 104 bytes.    gpt-5.6-luna 256w→65w $0.0002
                                 ↑ fields, bar_fg, right-aligned
    Move the socket into /tmp to ensure a    ← child, bar_fg, wraps
    short path.
    Add startup validation that detects...
    ↩ suggested reply:                       ← marker child, bar_fg
    Keep the immediate /tmp fix, since it    ← reply chunks, bar_fg
    is the simplest and already verified...
  › copy reply                               ← menu when open
  › expand my reply…
  › redraft
  › dismiss
▸ Luna won the bake-off and the price...     ← collapsed group
▸ The panel folds prose and the divider...
```

State chips a digest can wear (drawn in `accent`, whatever the word):
`drafting`, `ready`, `copied`, `clip refused`, `draft failed`,
`error` (a failed summarize — the whole row is the failure message).
The claude watcher's chips: `needs you`, `blocked?`, `working`,
`idle`.

### Modes and input

`rows` → Enter/click-on-selected → `actions` → Enter on a confirm
action → `confirm` (y/n only) — or Enter on an INPUT_TEXT action →
`input` (modal one-line editor: every printable is text, `j` is a
letter, ESC drops, empty Enter refuses). j/k/g/G/arrows navigate,
`r` refetches, `y` copies a plugin's pin, ESC walks up one level and
finally yields the keys. Mouse: click selects, click-the-selected
opens the menu, divider drags.

## Palette (theme.zig `Theme`)

Chrome slots available to this work: `sep`, `accent`, `on_accent`,
`bar_bg`, `bar_fg`, `bar_value`, `chip_active_bg`, plus editor slots
sometimes borrowed by chrome: `ed_err` (the only "danger" color the
chrome has), `ed_dim`. Optional per-theme status-bar overrides exist
(`status_*`) as precedent for adding optional slots with fallbacks.
Note what does NOT exist: a success color, a warning color, a
progress color — the chrome currently says everything non-error in
`accent`.

## Findings — the rough edges this pass should address

These are ranked by how often they bite in real use.

1. **Subtitle is modeled but never rendered.** Every digest carries
   `sessionTitle · age` ("pane-dim release · 4m") and every session
   row a subtitle; the panel draws neither, anywhere. So a wall of
   digests gives no clue WHICH session or WHEN. This is the largest
   information gap in the panel. Where should it live — second line
   under the title? inline after the title in `bar_fg`? only on the
   expanded group?
2. **All states look the same.** `ready`, `clip refused`, `needs
   you`, and `drafting` are all `accent` text. The semantic classes
   are obvious (progress / success / needs-human / failure) but the
   chrome has no color language for them — `ed_err` exists for
   danger, nothing else. Decide: new optional palette slots (with
   graceful fallback per constraint 2)? Or a non-color language —
   glyph prefixes, weight? Note the plugin may send arbitrary state
   strings; any classification is core's, by convention on known
   words, with unknown states falling back to today's look.
3. **The reply section is structurally a hack that reads like one.**
   "↩ suggested reply:" is a *data child row* faking a section
   header. The reply deserves a real visual identity distinct from
   bullets — it is the thing you're about to send as yourself.
4. **Empty and loading states are bare words.** "nothing to show",
   "asking…", "drafting…" — correct, honest, and charmless. Also the
   first-run state (no OpenAI key) is an error-red row explaining
   setup; it reads as breakage, not onboarding.
5. **No scroll affordance.** When the list is scrolled, nothing says
   content exists above/below the window. (`shown:a-b` exists in ctl
   only.)
6. **The collapsed-group child count (`▸+N`) is not drawn** — it
   exists only in the ctl dump. Should the human see it?
7. **Field labels are invisible.** Values-only right-aligned fields
   ("gpt-5.6-luna 256w→65w $0.0002") are compact but cryptic —
   `len`'s value explains itself, `cost`'s mostly does, but the rule
   only works while every field's value is self-describing.
8. **No read/unread.** New digests since you last looked are
   indistinguishable from old ones. The panel refreshes every 2s
   while open; arrival is silent.
9. **Message row placement.** The last action's answer sits at the
   very bottom of the panel, far from the row you acted on, easy to
   miss entirely.
10. **`error` rows conflate levels.** A failed summarize row uses its
    title for the error message and loses the turn it failed on.

## Explicit questions for design

- State language: color classes vs glyph language vs both? If colors:
  propose the slot names, semantics, and values for all 8 themes (or
  a derivation rule from existing slots — e.g. success = terminal
  ANSI green? The `ansi` table exists per theme).
- Digest row grammar: where do subtitle, state, fields, and the fold
  glyph live so a 34-col panel and an 80-col panel both read well?
  (The panel is resizable now; design for both extremes. Fields shed
  today — is shedding still the right response when width is user-
  chosen?)
- The reply block: propose its visual identity (indent? leading
  hairline? `on_accent`-on-`accent` header chip? quote-bar glyphs?)
  within the cell-grid constraints.
- Onboarding/empty voice: the no-key state, the no-digests-yet state
  ("watching 3 sessions — the next long turn lands here"?), and the
  loading beat.
- Scroll affordance that costs no rows (edge fade is impossible —
  cells — but a `⋯` half-row, a scrollbar hairline on the edge, or a
  count in the header are all cheap).
- Should acting/drafting get the ONE animation exception (a braille
  spinner in the chip, repainted at 4Hz only while work is in
  flight)? Argue it against constraint 4, don't assume it.

Deliverable that lands best: a marked-up row-grammar spec (which slot,
which column, which width rules, per state) + the palette additions if
any — precise enough that the renderer changes are mechanical. ASCII
mockups at 34 and 60 columns beat pictures; the medium IS the mockup.

## The playground — see it live in five minutes

Everything below is copy-paste. It launches a sandboxed rook (never
touches the daily driver), feeds it a fake plugin with digest-shaped
content, and screenshots it. Requires a built tree: `cd app && zig
build`.

```sh
SB=/tmp/rook-design && rm -rf $SB && mkdir -p $SB/cfg
cat > /tmp/design-stub.sh <<'EOF'
while IFS= read -r line; do
  id=`expr "$line" : '.*"id":\([0-9]*\)'`
  case "$line" in
    *'"op":"describe"'*)
      printf '{"v":1,"id":%s,"ok":true,"result":{"name":"agent","version":"1.0","capabilities":["items.list"]}}\n' "$id" ;;
    *'"op":"items.list"'*)
      printf '{"v":1,"id":%s,"ok":true,"result":{"items":[{"id":"d1","title":"The bind fails because macOS limits Unix socket paths to 104 bytes.","state":"ready","fields":[{"key":"model","kind":"TEXT","value":"gpt-5.6-luna"},{"key":"len","kind":"TEXT","value":"256w → 65w"},{"key":"cost","kind":"MONEY","value":"$0.0002"}],"actions":[{"id":"copy","label":"copy reply"},{"id":"expand","label":"expand my reply…","input":"INPUT_TEXT"},{"id":"dismiss","label":"dismiss"}],"children":[{"id":"d1b0","title":"Move the socket into /tmp to ensure a short path."},{"id":"d1b1","title":"Add startup validation that detects paths over 104 bytes and fails loudly."},{"id":"d1r0","title":"↩ suggested reply:"},{"id":"d1r1","title":"Keep the immediate /tmp fix, since it is the simplest and already verified, and retain the new regression test."}]},{"id":"d2","title":"Luna won the bake-off: hardest compression at the lowest measured bill.","state":"copied","fields":[{"key":"cost","kind":"MONEY","value":"$0.0003"}],"actions":[{"id":"dismiss","label":"dismiss"}],"children":[{"id":"d2b0","title":"gpt-5.6-luna beat mini on compression and nano on fidelity."}]},{"id":"d3","title":"summarize failed — rate limit exceeded","state":"error","actions":[{"id":"dismiss","label":"dismiss"}]}]}}\n' "$id" ;;
    *) printf '{"v":1,"id":%s,"ok":false,"error":"no"}\n' "$id" ;;
  esac
done
EOF
cat > $SB/cfg/environment.json <<'EOF'
{"rookEnvironment":1,"nodes":[{"id":"plugin:agent","kind":"plugin","scope":"app","name":"agent","command":["/bin/sh","/tmp/design-stub.sh"],"load":"lazy","grants":["items.list","items.act"]}]}
EOF
ROOK_SOCK=$SB/s.sock XDG_CONFIG_HOME=$SB/xc XDG_DATA_HOME=$SB/xd \
  XDG_STATE_HOME=/dev/null/no-host HOME=$SB \
  ./app/zig-out/bin/rook win --config=$SB/cfg --no-activate \
  > $SB/app.log 2>&1 &
sleep 2
ctl() { printf "$1\n" | nc -U $SB/s.sock; }
ctl "plugin-show agent"; sleep 1
ctl "shot $SB/panel.png"          # ← open this
ctl "sidepane"                    # ← the same panel, as text
```

Iterate: edit `drawPlugin`/`drawSidePane` in `app/src/macos.zig` (or
`theme.zig`), `zig build`, kill and relaunch the sandbox, re-shot.
Drive states: `ctl "key 6a"` (j), `"key 0d"` (Enter → menu),
`"click X Y"`, `"drag X Y X2 Y2"` (divider). Theme check: add
`{"id":"opt.app.theme","kind":"option","scope":"app","key":"theme","value":"vscode-dark"}`
to the nodes. **Traps already paid for:** unix socket paths >104
bytes fail silently (keep `$SB` short, under /tmp); the window's real
geometry lands ~400ms after launch (screenshot after, or wait for a
stable `sidepane` rect); `--no-activate` means no cursor blink.

## Verification loop for whatever you change

- `cd app && zig build test` — unit tests (WrapIter, clip, palette).
- `zig build e2e -- panelwrap` / `-- panelfold` / `-- plugins` — the
  panel's behavior guards. They assert content presence, wrap
  geometry, fold/scroll/click and the input editor — they do NOT pin
  exact pixels or colors, so restyling passes them unless it breaks
  behavior. If you change what `ctl sidepane` prints, update the
  scenarios' expectations with it.
- Full sweep before handing back: `zig build e2e` (44 scenarios) and
  `go test ./plugins/...` from the repo root.

## Code map

| thing | where |
|---|---|
| panel container, header, row renderer, selection, menu, input line | `app/src/macos.zig` — `drawSidePane`, `drawPlugin`, `drawRowSelection`, `plugRowLines`, `plugShedFields` |
| word wrap / clip | `app/src/ui.zig` — `WrapIter`, `clip` |
| themes, palette struct, all 8 builtins | `app/src/theme.zig` |
| item model, wire intake, caps | `app/src/plugins.zig` — `Item`, `shape`, `Snapshot` |
| blind introspection | `app/src/ctl.zig` — the `sidepane` verb |
| the agent's content (states, fields, actions, reply chunks) | `plugins/agent/main.go` — `items()` |
| behavior guards | `app/e2e/main.zig` — `plugins`, `panelwrap`, `panelfold` |
| the vocabulary contract | `docs/plugins/VOCABULARY.md` |
| user-facing docs to keep true | `man 7 rook-plugin` (`docs/man/rook-plugin.7`) |
