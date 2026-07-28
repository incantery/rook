# Replacing wails-rook: the parity checklist

What `rookz` still owes before `/Applications/rook.app` can be deleted.
Status as of 2026-07-28 (`1a2dba6`). Editor items are deliberately
ranked LAST — the zig editor's job today is to get out of neovim's way,
and it already does.

## The decision that shapes the whole list

**Keep rook-host. Make rookz its only client and its parent process.**

`internal/host` is 1.2MB of Go that already does threads, review,
asks, attention, transcripts, decisions, worktrees, workflows, cloud
relay, plugins, LSP. `rookctl` and the MCP server talk to it over
localhost HTTP + bearer token, and that is how Claude touches rook.
Porting it *now* buys nothing and costs the product. Porting most of it
eventually is the plan — see §6, which is the destination this checklist
is walking toward.

So the replacement is not a port. It is: **rookz grows a host client and
renders host state in its own chrome** — `usage.zig` is the seed of
exactly that (host.json → port + token → HTTP → struct → quads).

Self-contained then means lifecycle, not language:

- rookz spawns `rook-host` from inside its own bundle at launch.
- rookz SIGTERMs it on quit. Nothing runs while rook is closed.
- `rookctl` and MCP keep working unchanged (they read host.json), and
  they simply find nothing when rook isn't running — which is the
  stated tradeoff for now.

Today's host does the opposite: `hostclient.Info()` *rides* a healthy
daemon and never kills it, deliberately, so sessions outlive app
restarts. That property has to be given up (see §5) or bought back by
the host/client split — the one where ptys move out of rookz. Note
that rookz does NOT want the host's terminal half: `vt`, `ghostty_term`,
`termframe`, `terminal`, `monitor`'s pty sampling are all dead weight
against an app that owns its own ptys. That's a third of the surface
that never needs a client.

- [ ] rookz spawns rook-host as a child (bundle-relative path, same
      binary-identity check as `shouldRide` so a stale daemon gets
      replaced), reads host.json, SIGTERM on `applicationWillTerminate`
- [ ] `hostc.zig`: shared GET/POST/JSON over the localhost socket —
      generalize `usage.zig`'s hand-rolled HTTP/1.1 into one client
- [ ] Long-poll or websocket for push (asks doorbell, attention,
      thread/review changes). The 30s usage poll is fine; a doorbell is not.
- [ ] Decide what happens to host state that assumes a daemon:
      `/update` self-update checks, `usagepush`, `prwatch`, `relay`
      (all currently run on host start — they become app-lifetime work)

## 0. Terminal floor — the things you'd hit in the first hour

These are small, and every one of them is a "wait, really?" moment for
a daily driver.

- [x] **⌘V paste** — `src/paste.zig` (xterm's strip set + fencing +
      CR conversion, own test root), editor takes it as a register not
      as keys, ctl `paste` drives the same path
- [ ] Paste **confirmation** for unframed multiline pastes.
      `paste.isSafe` is written and nothing gates on it; needs a
      confirm modal (the palette is the primitive) and a config knob.
- [ ] **IME / dead keys.** No `NSTextInputClient`, no `interpretKeyEvents`.
      Accented characters, CJK, and emoji picker input can't reach a pty.
- [ ] **OSC 52** (clipboard write): `session.zig` sets `.clipboard_write = null`.
      Copying from a remote tmux/vim over ssh silently fails.
- [ ] **Bell** (`.bell = null`): no audible/visual bell, and no dock badge.
      This is also the cheapest agent-attention signal there is.
- [ ] **Notifications**: OSC 9 / OSC 777 → `NSUserNotification`. Claude
      finishing in a background space should say so.
- [ ] **OSC 8 hyperlinks** + URL/path detection with ⌘-click to open
      (file:line → open in the editor pane; that's the payoff).
- [ ] **Pane zoom** (`<leader>z`) — tmux muscle memory, missing entirely.
- [ ] **Scrollback search** (`/` in copy mode). Copy mode scrolls but
      can't find.
- [ ] Copy mode: full vim motions + visual mode + yank (already on TODO.md).
- [ ] Tab/space **rename** (`,` in tmux) — spaces name themselves from
      cwd today, with no way to override.
- [ ] Font: **ligature** shaping. Fallback, emoji, and wide glyphs are
      done (CoreText cascade + BGRA atlas); ligatures aren't — each cell
      rasterizes its own codepoint.
- [ ] Second **window** (⌘N) and window restore-on-launch.

## 1. Chrome and command surface

- [ ] **Command palette (⌘K) over a real command registry.** The wails
      app's spine: every action is a named command; keybinds dispatch
      commands, the palette lists them, and the agent's tool surface IS
      the registry (`frontend/src/registry.ts`). rookz has the palette
      *widget* (workspace picker) but no registry behind it — and
      `config.zig`'s `Action` enum is 13 hardcoded values against the
      wails keymap's ~30 commands.
- [ ] Keybind parity for the missing commands: `palette.toggle`,
      `pane.zoom`, `attention.inbox`, `agent.spawn`, `agent.view`,
      `review.changes`, `threads.toggle`, `file.open`, `grep.open`,
      `explore.trail`, `workspace.manager`, `workspace.dashboard`,
      `workspace.set-root`, `config.settings`, `session.close`
- [ ] Ex-command bridge (`:PaneSplitRight` etc. — `exNameOf`) so the
      editor and agents can drive commands by name
- [ ] **Theme engine**: one semantic Palette, 8 builtins, runtime swap,
      **VS Code theme importer**. rookz has 2 builtins and a config key.
- [ ] **Settings UI** (⌘,): appearance, keybinds, and the token panes
      (Jira/OpenAI/cloud/relay → keychain). Today: hand-edit TOML.
- [ ] Choose-window picker on `<leader>w` (reserved, unimplemented)
- [ ] Side panes (left/right slottable tenants) — the container every
      §2 panel lands in. `SidePane.svelte` + `winchrome` on main.
- [ ] Status bar: workspace/branch/review-gate state, not just perf HUD

## 2. The agent layer — this is the actual product

Each of these is a host API that already works, needing a Zig surface.
Ranked by how much of rook's identity dies without it.

- [ ] **Asks / RUI** (`/asks/`, doorbell, answers drain, MCP `ask` tool).
      Claude asking a question and getting an answer is the flagship
      loop. Needs a form renderer (radio/multi/text) in a pane.
- [ ] **Attention inbox** (`/attention`, `<leader>a`) — the "what needs
      me" queue that makes the app worth leaving open.
- [ ] **Agent deck / session view** (`/sessions`, `/agents`, `<leader>v`):
      transcript jsonl → rendered timeline, flat vim-navigable deck.
      Biggest single UI build on the list; `internal/transcript` +
      `transcriptapi` do the parsing.
- [ ] **Threads** (`/threads/`, `<leader>t`): host-projected editable
      docs. In rookz these are *buffers* — the editor already is the
      renderer, which is a genuine simplification over Monaco.
- [ ] **Review / RookTask** (`/tasks/`, `/edits/`, `<leader>g`): the
      changes list, the gate, approve/reject/comment, review rings.
      Needs a diff surface (see §3).
- [ ] **Spawn** (`/agents`, `<leader>n`) + workflows + issue queue +
      worktree create/switch (`worktree.go`, `exploretasks.go`)
- [ ] **Dashboard / Home / Start** (`/overview`, `<leader>d`): the
      workspace landing surfaces
- [ ] **Decisions ledger** (`/decisions`) — the verdict trail that earns
      autonomy
- [ ] **Costs** (`/costs`) beside the usage cluster in the title zone
- [ ] **Monitor** (`/runtime`, MonitorView/MonitorChart) — host + agent
      process load
- [ ] **Explore trail** (`<leader>i`, `rookctl explore`)
- [ ] **Quick actions** / spawn modal / picker primitives
- [ ] Plugins (`/plugins`) + `install-hooks` + `notify-hook` surfacing
- [ ] Cloud / relay / remote asks: works while rook is open, dead while
      closed (see §5)

## 3. Editor — secondary, and honestly already ahead for neovim users

The zig editor exists to be a *good enough* in-app buffer. The bar it
must clear is "I don't reach for a terminal nvim inside rookz", not
"it replaces Monaco feature for feature".

- [ ] **Diff / review viewer** — required by §2's review panel, so it's
      the one editor item on the critical path
- [ ] **Finder** (⌃P) — pluggable sources + preview. The workspace
      palette is already the primitive; this is a second source.
- [ ] **Grep** (⌃G, host `/grep`) + **quickfix** pane (TODO.md has the
      in-pane container model specced)
- [ ] **Git gutter** (host `gutter.go`) — added/modified/deleted marks
- [ ] **LSP** (`internal/lsp`, `rookctl lsp`): diagnostics → gutter,
      go-to-def, hover, completion. Lazy activation per NEXT.md.
- [ ] More grammars: ts/tsx/md/toml/json/rust/python (drop parser.c +
      highlights.scm in vendor/, two lines in syntax.zig)
- [ ] Markdown rendering in a pane (top item on wails' own backlog)
- [ ] Editor debts already logged: save-point tracking, autoindent,
      registers, wide glyphs = 1 column, 4KB line clamp, relative `:e`
      resolves against app cwd

## 4. Platform and distribution

- [ ] **Self-update** (`internal/selfupdate`, `/update`, `rookctl update`) —
      today rookz ships only via `make install`
- [ ] **Code signing + notarization + DMG**; the bundle is hand-rolled
      in the Makefile
- [ ] **Version stamping / BinHash** — the dev-build trap that ate days
      on the wails side is unsolved here (rookz has no build id at all)
- [ ] Crash reporting and a log file (host.log's counterpart)
- [ ] Config **migration**: `~/.config/rook/*` keybinds + theme →
      `~/.config/rookz/config.toml`, or teach rookz to read rook's own
      config so there's one file (preferred — see NEXT.md's layered
      `config.d/` direction)
- [ ] Name collision: `rook` vs `rookz`, `re` symlink already claimed
      from rookctl. Decide the final CLI names before cutover.
- [ ] E2E: `make e2e` drives the wails app headless. rookz has the ctl
      socket (better), but no CI job runs it, and no agent-panel
      coverage exists yet.
- [ ] Accessibility: zero today (NEXT.md wants a semantic element tree;
      the wails app got it free from the DOM)

## 5. Accepted regressions — call these out loud before cutover

- **Shells die with the app.** rook-host owns the ptys today, so a
  wails-app restart reattaches live sessions. rookz owns them
  in-process. Until ptys move behind the host/client split, quitting
  rookz kills every shell in every space. This is the strongest single
  argument for doing that split sooner.
- **Nothing happens while rook is closed** — by explicit choice. No
  remote asks landing on the phone, no PR watcher, no usage push, no
  scheduled workflows. Fine for rapid iteration; it is not the
  long-term shape.
- **No web/remote projection.** The webview version could in principle
  be reached from anywhere; a Metal app cannot.

## 6. Medium term: the Go recedes

The destination is a rookide with little or no Go in it. Anything that
stays Go lives in **its own repo behind an artifact** — a binary rook
spawns and speaks a protocol to. That is a design goal, not a cleanup
chore, and it is worth stating now so the checklist above is understood
as a step toward it rather than an endorsement of two languages forever.

**Why port at all.** Not tidiness — identity. Rook wants a UI whose
elements have stable semantic ids that rookctl and agents can address,
where the review gate, the thread doc, and the verdict ledger *are* the
things on screen. Across a process boundary the UI always renders a
copy: state is serialized, the copy drifts, and "what does the pane
show" and "what does the host believe" become two questions. In-process,
a thread is a buffer, a review anchor is a mark in that buffer, and the
ledger is the same object the renderer draws.

**Most of the dependency tree dies at cutover anyway.** `wails/v3`,
`creack/pty`, `charmbracelet/{ultraviolet,ansi,vt}`, `go-runewidth`,
`mattn/go-sqlite3`, `pelletier/go-toml` are all webview-era scaffolding:
rookz owns ptys, ghostty-vt owns emulation and width tables,
`workspaces.zig` already speaks to system libsqlite3, `config.zig`
already parses TOML. What genuinely needs Go is narrow — `connectrpc` +
`protobuf` + TLS + websockets, i.e. cloud, relay, edge signing,
trackers, self-update. Everything else in the host is filesystem,
subprocess, and JSON. Even git is shelled out (`git -C dir status
--porcelain=v2`), so review/gutter/worktree port as spawn-and-parse.

**The Go that survives is not a wart.** NEXT.md already wants
capabilities delivered as external protocol services (LSP, DAP, MCP,
agent protocols, purpose-built processes over a typed rook protocol). A
`rook-cloud` binary in its own repo, spawned lazily when a remote ask
needs to leave the machine, is exactly that shape — the residual Go
becomes the first tenant of rook's own extension boundary, and the best
available pressure on it.

**What Go is buying today, that Zig has to earn.** Three things, ranked
honestly. (1) Mature TLS and third-party API plumbing — real, but
confined to the edge, so the separate-repo rule already solves it.
(2) A GC over a long-lived, heavily-mutated object graph (threads,
anchors, review state) under concurrent access from watchers and
handlers, for days at a time. That is a different discipline from a
renderer where a frame's allocations die at the frame boundary; the
lifetime design is the real cost of the port, not the typing.
(3) Encoded behavior in tests — `threads_test.go` is 29KB,
`transcriptwatch_test.go` 17KB, `review_test.go` 14KB. Porting discards
years of edge cases and re-earns them in production, on the daily
driver. That argues against a big-bang rewrite, not against porting.

**The sequencing rule: port by coupling to the UI, and only after rookz
already renders the thing.** `workspaces.zig` is the proof — ~130 lines
of sqlite replaced a whole Go API surface because the palette needed
exactly one query and no more. Ported first, it would have reproduced
the Go shape. Build the client, ship the panel, learn what the UI
actually needs, then collapse the service at the size the UI proved.

Rough classification:

- **Port first** (want to be in-process): threads → buffers,
  review/reanchor/tasks → marks in those buffers, attention, decisions,
  gutter, grep, worktree, LSP
- **Port eventually** (local, low UI coupling): transcripts, usage
  prober, monitor, overview, workload
- **Stays Go, own repo** (network edge): cloud/relay/edge/edgesign,
  GitHub + Jira trackers, self-update

Two constraints on timing. Zig 0.16 is pre-1.0 and std churns —
`trimRight`→`trimEnd` and the `Io.Dir` reshuffle already landed on a
small surface, and 20k lines of service code makes every release a
migration; that argues for porting late, nearer 1.0. And the HTTP wire
survives regardless, because rookctl and MCP reach rook over it: it is
the agent surface, a product feature, not an implementation detail.

Which is what makes this a non-decision today. Build `hostc.zig`
against the wire, ship the panels, and the server's language stays
invisible behind it. The port then becomes a series of quiet,
individually reversible moves: reimplement one endpoint in Zig, flip
the client to the in-process call, delete the Go. No flag day, and each
move is justified by a UI that already exists and is already verifiable
through the ctl socket.

## Suggested order

1. §0 paste + bracketed paste + IME (an hour, unblocks exclusive use)
2. Host child-process lifecycle + `hostc.zig` (the spine for §2)
3. Command registry + ⌘K palette (every later panel registers into it)
4. Asks → attention inbox → agent deck (product identity, in that order)
5. Side panes, then threads + review (review pulls the diff viewer in)
6. Theme engine + settings UI
7. Distribution (signing, self-update, version stamping)
