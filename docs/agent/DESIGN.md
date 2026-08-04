# The rook experience — design brief

> Status: handoff to design, 2026-08-04. Read `docs/agent/VISION.md`
> first — it is the foundation this brief stands on and the argument
> for why these surfaces are one system. The ask here: **design the
> full rook experience end to end** — the desktop app, the agent
> panel, a full-screen agent dashboard (proposed, not yet committed),
> and the mobile app — as one product with one agent in it.

## The one-paragraph frame

rook is a native macOS terminal/multiplexer/editor whose thesis is
that **human attention is the scarce resource** and that agent
supervision — not code editing — is the primary activity. The rook
agent (VISION.md) is the membrane between the user and their coding
agents: digests in, amplified intent out, more autonomy as it earns
it. The goal state: **run everything from your phone** — execution
stays on the machine, presence travels. Design's job is to make one
recognizable experience out of four surfaces that today range from
"shipped and rough" to "does not exist."

## The four surfaces

### 1. The desktop app (shipped, mature, has its own design language)

The terminal itself: tabs, splits, a status bar, an optional VS Code-
style activity rail, a command palette with a which-key sheet, a side
pane, themes. Two facts shape everything:

- **rook materializes identities.** Config is a declarative graph;
  `preset = rook | tmux-neovim | vscode` re-skins the whole app into
  a persona. Nocturne (deep indigo, blurple accent) is the house
  theme; seven others ship, and any design must survive all eight.
- **Everything is text cells.** A Metal cell renderer: monospace
  runs, rects, rounded rects, hairlines, glass fills. No images, no
  gradients, no DOM. Zero idle frames — nothing animates but the
  cursor. The user picks the font, so no icon-font dependencies;
  plain-unicode glyphs only (`▸ ▾ › ! ↩ ⌘` are proven).

Design's question for this surface is not a restyle — it is **where
the agent lives in it**: how the agent's presence reads in the chrome
(status bar segment? rail badge? attention banners?), and how a user
moves between "I am doing terminal work" and "I am supervising."

### 2. The agent panel (shipped this week, functional, rough)

The side pane's flagship tenant. Renders the item vocabulary
(`docs/plugins/VOCABULARY.md`): digest rows (headline + wrapped
bullets as children), state chips, right-aligned fields (model,
compression, cost), an inline action menu (draft / expand-with-typed-
input / copy / dismiss), fold-to-selected-group, selection-follows
scroll, click, drag-to-resize. The precise anatomy — every palette
slot, mode, and glyph — is preserved at `docs/plugins/DESIGN.md@ba02254`
(deleted as a brief, still accurate as an inventory), along with a
five-minute sandboxed playground that renders fixture digests you can
screenshot.

Known gaps a design pass should resolve (ranked, from dogfooding):
subtitle (session · age) is modeled but never rendered anywhere; all
states share one accent color — the chrome has an error color and
nothing else, no success/progress/needs-human language; the reply
block is a data row faking a section header; empty/loading/onboarding
states are bare words; no scroll affordance; no read/unread.

### 3. The agent dashboard (proposed — design gets to invent this)

The panel is a sidebar; supervision may deserve a *room*. A full-
screen surface (a tab, or a zoomed layout) for when the user's
primary activity is running agents rather than typing into one
session. There is history here: rook's webview era had a "mission
control" — a flat, vim-navigable agent deck — that was deliberately
deleted in the native rewrite, with the intent that it returns as
plugins over the item vocabulary. The vocabulary's surfaces that
"refused to reduce" are this room's furniture waiting to exist:

- **the deck** — every session/task as a card with an honest state,
  j/k-navigable, enter to descend into the live pane;
- **Table** — the decisions/cost ledger: what ran, what it cost,
  what shipped (sortable, summable — it exists to be summed);
- **Series** — spend and usage over time;
- **the debrief** — VISION.md's "returning-home" story: what the
  fort did while you were out, as a readable evidence trail;
- **the trust surface** — the autonomy ladder made glanceable: what
  may the agent do today, on what verdict record.

Open questions design should answer: is this one dashboard or a
persona (`preset = mission-control`)? What is the navigation triangle
between dashboard ↔ panel ↔ session pane? Does the deck REPLACE the
claude-watcher panel or contain it? Constraints are the desktop
app's (cells, themes, zero idle) — this is still the native renderer.

### 4. The mobile app (scaffolded, mostly unbuilt)

rook-cloud's SvelteKit app at `cloud.rookide.com` (routes exist for
login, dashboard, chat, voice — skeletons). This is the "run
everything from your phone" surface, and per VISION.md it renders the
same content types the panel does, in a different register:

- a **digest** arrives as a notification: headline, bullets one tap
  away;
- a **drafted reply** is the approval moment: read it, tap send —
  "yeah that looks good" is a tap, not a walk to the keyboard;
- **expand** is the input method: thumb-typed or dictated rough
  words become the full reply (this is why the phone never needs a
  real keyboard experience);
- an **ask** (rook's remote-asks rail) is a small form; answers
  settle on both surfaces;
- a **task** (rook-cloud's durable Rook Task) has state, evidence,
  and approvals bound to exact action digests with expiries;
- **voice** speaks headlines and takes dictation — STE digests are
  already speech-shaped (short sentences, one idea each). Voice is
  never an authentication factor.

Constraints: it is a web app (SvelteKit, Cloudflare Pages) talking to
`api.rookide.com` — free of the cell grid, but it must read as the
SAME product and the SAME agent as the native surfaces. The mailbox
wire is stateless HTTP with zero idle traffic; design for
asynchronous arrival, not live streams. Local execution authority
means the phone can *request and approve*, never directly execute.

## The unifying design problems (the actual brief)

These are the questions that make it one experience rather than four:

1. **One agent, four rooms.** The rook agent must be recognizably the
   same entity in a terminal side pane, a full-screen dashboard, a
   push notification, and a spoken sentence. What is its consistent
   presence — name, voice, visual signature — within four very
   different materials (text cells vs web vs audio)? Note: no
   mascots, no chat-bubble anthropomorphism; the agent's "face" is
   the quality of its briefings.
2. **One content grammar, many registers.** Digest, draft, ask,
   verdict, banner, task, evidence. Each needs a canonical form that
   scales across: panel row (34–80 monospace columns), dashboard
   card, phone notification, phone detail view, spoken sentence.
   Design the digest card once, in five registers, and most of the
   system falls out.
3. **The attention gradient.** at-keyboard → other room → walk →
   errands. Each step shows less and requires less. What appears at
   each level, and — as important — what deliberately does NOT.
4. **The approval moment.** The single most repeated interaction in
   the product: something wants a yes. Enter in the panel; a tap on
   the phone; "yes, send it" on a walk; absent-with-policy while on
   errands. It must always show: exactly what will happen (the
   action digest), on whose authority (which ladder rung), and what
   it costs. Same ceremony, four intensities.
5. **Trust made visible.** The autonomy ladder is the product's
   spine. Users should always be able to answer "what can it do
   without me, and why is that OK" at a glance — and feel the
   difference when the agent earns a rung.
6. **The state language.** Semantic classes (working / needs-you /
   done-verified / failed / acting-for-you) need one visual language
   spanning theme-derived cell colors on desktop and CSS on mobile.
   The chrome palette currently has `accent` and an error red —
   propose the additions (or derivation rules from the per-theme
   ANSI table) across all eight themes.

## What is decided (design within this)

- One agent identity; "install rook agent" is the user's mental
  model; it ships in the rook core base config.
- The membrane model, the autonomy ladder, and the boundary rule
  (cloud requests, machine decides) — see VISION.md.
- The item vocabulary is the plugin contract: plugins send meaning,
  core owns rendering. Polish generalizes to every plugin.
- Desktop mechanics that are settled: fold/scroll/click/resize in the
  panel, the input editor, the action menu shape.
- Approvals bind to exact action digests with expiry; voice is I/O,
  never auth.

## What is open (design may propose)

- Everything about the dashboard, including whether it exists.
- The state-class color/glyph language.
- Digest card grammar in every register; subtitle placement.
- The phone app's information architecture (notification-first? task-
  first? inbox?).
- Read/unread and arrival semantics across surfaces.
- The debrief's narrative form.
- Whether in-flight work earns the desktop's one animation exception
  (argue it against zero-idle; don't assume it).

## Deliverables that land best

1. An **experience map**: the four surfaces, the attention gradient,
   and every content type's path through them.
2. The **digest card in five registers** (panel 34-col, panel 80-col,
   dashboard card, phone notification + detail, spoken form) — ASCII
   for cell surfaces (the medium is the mockup), anything readable
   for mobile.
3. The **approval moment at four intensities**, with the action-
   digest and rung made visible in each.
4. **Dashboard IA + one full-screen ASCII mockup** (if you conclude
   it should exist — a reasoned "the panel is enough" is acceptable).
5. **Mobile IA + key screens**: inbox/notification, digest detail
   with reply loop, task view with evidence, the debrief.
6. The **state-language proposal**: classes, colors/glyphs, per-theme
   derivation, CSS mapping.
7. A **rung indicator** concept: trust made glanceable.

Precision over polish: specs concrete enough that the renderer and
web work become mechanical. Where you need to see the current state,
the playground in `docs/plugins/DESIGN.md@ba02254` runs in five
minutes and screenshots real pixels; rook-cloud's web app runs from
`rook-cloud/web`.

## Grounding — where things live

| | |
|---|---|
| the vision this serves | `docs/agent/VISION.md` |
| plugin/item contract | `docs/plugins/VOCABULARY.md` |
| panel renderer + inventory | `app/src/macos.zig` (`drawPlugin`); inventory at `docs/plugins/DESIGN.md@ba02254` |
| themes (all 8, palette struct) | `app/src/theme.zig` |
| the agent's content | `plugins/agent/main.go` (`items()`) |
| cloud control plane, supervisor, ADRs | `../rook-cloud/NEXT.md`, `internal/supervisor`, `docs/adr/` |
| mobile web app | `../rook-cloud/web/` (SvelteKit; login/dashboard/chat/voice routes) |
| remote-asks rail | the 3-verb host↔relay mailbox (see rook-cloud README) |
| behavior guards that must stay green | `app/e2e/main.zig` — `plugins`, `panelwrap`, `panelfold` |
