# Replacing wails-rook: the parity checklist

What the zig app still owes the webview app it replaced. The cutover
has happened — `/Applications/rook.app` IS this app now, and `make
install-web` is the way back — so this stopped being a list of blockers
and became a list of debts, ordered by how much of rook's identity each
one holds. Editor items are deliberately ranked LAST: the zig editor's
job today is to get out of neovim's way, and it already does.

Status as of 2026-07-28, shipped in v0.38.2.

## The decision that shapes the whole list

**Keep rook-host. Make rook its only client and its parent process.**

`internal/host` is 1.2MB of Go that already does threads, review,
asks, attention, transcripts, decisions, worktrees, workflows, cloud
relay, plugins, LSP. `rookctl` and the MCP server talk to it over
localhost HTTP + bearer token, and that is how Claude touches rook.
Porting it *now* buys nothing and costs the product. Porting most of it
eventually is the plan — see §6, which is the destination this checklist
is walking toward.

So the replacement is not a port. It is: **rook grows a host client and
renders host state in its own chrome** — `usage.zig` is the seed of
exactly that (host.json → port + token → HTTP → struct → quads).

Self-contained then means lifecycle, not language:

- rook spawns `rook-host` from inside its own bundle at launch.
- rook SIGTERMs it on quit. Nothing runs while rook is closed.
- `rookctl` and MCP keep working unchanged (they read host.json), and
  they simply find nothing when rook isn't running — which is the
  stated tradeoff for now.

Today's host does the opposite: `hostclient.Info()` *rides* a healthy
daemon and never kills it, deliberately, so sessions outlive app
restarts. That property has to be given up (see §5) or bought back by
the host/client split — the one where ptys move out of rook. Note
that rook does NOT want the host's terminal half: `vt`, `ghostty_term`,
`termframe`, `terminal`, `monitor`'s pty sampling are all dead weight
against an app that owns its own ptys. That's a third of the surface
that never needs a client.

- [x] rook spawns rook-host as a child and SIGTERMs it on quit
      (`src/hostc.zig`). No `shouldRide` port: rook-host is already
      idempotent, so we always spawn and let the Go side keep its own
      identity rule. `owned` = host.json's pid == the pid we forked, and
      we kill only what we own — so a rook running beside the wails app
      during cutover can't take that app's daemon down. ctl `version`
      reports it. Every exit path shuts down, including ctl `quit`,
      which `_exit`s past the will-terminate observer.
- [x] `hostc.zig`: shared GET/POST/JSON over the localhost socket.
      `usage.zig` refactored onto it — 60 lines of duplicated HTTP gone,
      and the usage cluster is the end-to-end proof it works.
- [x] Build identity: `zig build -Dbuild=<id> -Dversion=<v>`, fed the
      same one-per-`make`-run id the Go binaries get (internal/version).
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
- [x] **IME / dead keys** — `RookTextView` conforms to
      NSTextInputClient, the IME gets first refusal on unmodified keys,
      preedit draws at the cursor. ctl `nskey` posts real NSEvents so
      the path is testable; ctl `ime` reports the state.
- [x] **OSC 52** (clipboard write) — yanking in vim or tmux over ssh
      reaches the macOS pasteboard. The library hands it over already
      base64-decoded, and it NEVER forwards read requests (`?`), so no
      program in rook can exfiltrate the clipboard; verified by sending
      one and watching nothing come back down the pty. All three targets
      (`c`/`p`/`s`) collapse onto the one pasteboard, because macOS has
      no primary selection and vim already maps `*` and `+` together
      here. `clipboard-write = allow|deny` (default allow, live-reloads)
      because a write is unprompted: anything that can put bytes on your
      screen can replace what your next ⌘V pastes. Drains per FRAME, not
      on the 2Hz tick the bell rides — a yank can be followed straight
      away by ⌘V. ctl `clipboard` reads the real pasteboard back.
- [x] **Bell** — accent dot on the tab chip that rang + a single dock
      bounce, both suppressed while you're watching that tab; visiting
      the tab is the acknowledgement. `bell = none|visual|audible|all`.
      The cheapest agent-attention signal there is, and until §2's inbox
      lands it is the ONLY way rook can say an agent wants you.
- [x] **Notifications**: OSC 9 / OSC 777 → UNUserNotificationCenter.
      Needed a FORK of ghostty-vt: `osc.zig` decodes both into
      `show_desktop_notification`, but `stream_terminal.zig` dropped it
      in the "no terminal-modifying effect" bucket, so no embedder could
      reach it. incantery/ghostty `rook/vt-desktop-notification` adds a
      `desktop_notification` effect mirroring `bell` (upstream-shaped,
      with tests; the C ABI is deliberately left unwired — new enum tags
      there are the library's call). Guarded on the bundle identifier:
      `currentNotificationCenter` RAISES without one, which is exactly
      how `zig build run` runs.
- [ ] **OSC 8 hyperlinks** + URL/path detection with ⌘-click to open
      (file:line → open in the editor pane; that's the payoff).
- [x] **Pane zoom** (`<leader>z`, tmux's key) — the focused pane takes
      the whole tab. The TREE IS UNTOUCHED; zoom is one `?*Pane` on the
      Tab, so unzooming is exact by construction rather than by
      remembering ratios. Hidden panes get a ZERO rect, which the draw,
      the hit test and the resize already read as "nothing here" — and
      because relayout skips them they keep their grid, so a zoom costs
      no reflow either way. Focusing another pane unzooms (focus must
      never be invisible), but a direction with nothing that way puts
      the zoom back rather than spending it on a no-op. Chip wears
      tmux's `Z`; ctl `zoom` toggles, `panes` marks it.
- [x] **Scrollback search** (`/` in copy mode, `n`/`N` to step) — the
      library does the searching (`vt.search.Screen`); rook adds a
      lifetime, a viewport move and the bar readout. The hit becomes the
      real terminal SELECTION, so it highlights and ⌘C copies it with no
      new render path. Placed half a screen down via an absolute row
      (which clamps at both ends) rather than scroll-to-pin-then-up,
      which would push a bottom-of-buffer hit clean off the viewport.
      Drops itself if a program swaps to the alt screen under it —
      results from the primary shown over the alternate are nonsense.
      Uses the BLOCKING `searchAll`. Measured at the 10MB scrollback
      below (12,408 rows), a full SCAN is free — it finishes inside the
      ctl round-trip. What costs is the number of MATCHES, not the size
      of the buffer (~500ms for a needle hitting every row, since each
      hit builds its own tracked highlight), and that is a degenerate
      search on an explicit Enter. The library's tick/feed path is what
      to reach for if that ever stops being true. ctl `search` reports
      state; `press RET`/`BS` drive the prompt through the real key path.
- [x] **Scrollback: 10MB per pane**, `scrollback = "10mb"` (bytes, with
      kb/mb/gb suffixes; `scrollback-limit` accepted as ghostty spells
      it; 0 = none). Was ~930 rows — `Session.start` never passed
      `max_scrollback`, so it took ghostty-vt's EMBEDDED-LIBRARY default
      of 10,000 *bytes*, a sane floor for a widget on someone else's
      screen and far too little for a terminal you live in. Measured:
      979 → 12,408 retained rows at 92 cols, +9MB RSS for a full one.
      Launch-time only, like font and opacity: a pane's limit is fixed
      when its PageList is built, so a live reload would silently give
      new panes a different depth from the ones already open.
- [ ] Copy mode: full vim motions + visual mode + yank (already on TODO.md).
- [ ] Tab/space **rename** (`,` in tmux) — spaces name themselves from
      cwd today, with no way to override.
- [ ] Font: **ligature** shaping. Fallback, emoji, and wide glyphs are
      done (CoreText cascade + BGRA atlas); ligatures aren't — each cell
      rasterizes its own codepoint.
- [ ] Second **window** (⌘N) and window restore-on-launch.

## 1. Chrome and command surface

- [x] **Command palette (⌘K) over a real command registry.**
      `src/registry.zig` is the table; `App.dispatch` is the ONE switch
      over `Action`, so adding a value fails the build until it is
      handled. Four surfaces agree through it: leader chords, the ⌘
      chords, the palette, and ctl `commands` / `run <id>` — which is
      the agent's tool surface. The ⌘ chords used to call App methods
      directly; routing them through `dispatch` is what makes them
      reachable from the other three. The palette is the SAME widget as
      the workspace picker with a `pal_mode`, so filter/keys/draw stay
      shared. Aliases sit apart from the table so one capability is
      never listed twice, and `tab.select-N` is parameterized rather
      than nine rows (bindable, hidden from the list). `config.zig` no
      longer owns a second copy of the names.
      GOTCHA that shaped the design: the palette's key path runs holding
      `draw_lock` and every dispatch target takes it again, so Enter
      dispatching inline is a SELF-DEADLOCK. It queues `pending_cmd` and
      the three lock-release points drain it. The e2e `commands`
      scenario drives Enter through the socket to keep that honest.
- [ ] Commands for features that do not exist yet: `attention.inbox`,
      `agent.spawn`, `agent.view`, `review.changes`, `threads.toggle`,
      `file.open`, `grep.open`, `explore.trail`, `workspace.manager`,
      `workspace.dashboard`, `workspace.set-root`, `config.settings`.
      Deliberately NOT pre-registered — a palette row that does nothing
      lies about what the app can do. They land with their features.
- [x] Ex-command bridge. `:PaneSplitRight` works in an editor pane.
      A function-pointer hook (`cmd_ctx`/`app_command`), the same shape
      and same reason as the highlighter's, so `editor.zig` stays a pure
      model that headless tests drive with both hooks null and never
      learns what a command is. It sits in `execCommand`'s FALLTHROUGH,
      gated on a LEADING CAPITAL — vim's user-command shape — so no
      derived name can shadow `:w`/`:q`/`:noh` by construction rather
      than by a maintained list, and a lowercase typo still gets the
      editor's own message. Names are derived per lookup
      (`registry.byExName`) rather than cached in a second table that
      could disagree with the first. Same deferred `pending_cmd` route
      as the palette, for the same draw_lock reason.
      The e2e scenario's first version asserted against
      `sh: command not found`: a successful `:PaneSplitRight` MOVES
      FOCUS to the new pane, so everything typed after it went to a
      shell. The focus-moving case goes last now.
- [ ] Config `[commands]` aliases layered onto the ex names (the wails
      `Registry.exNames(aliases)` half). `registry.isExName` is the
      validator it would need; nothing parses the table yet.
- [ ] **Theme engine**: one semantic Palette, 8 builtins, runtime swap,
      **VS Code theme importer**. rook has 2 builtins and a config key.
- [ ] **Settings UI** (⌘,): appearance, keybinds, and the token panes
      (Jira/OpenAI/cloud/relay → keychain). Today: hand-edit TOML.
- [ ] Choose-window picker on `<leader>w` (reserved, unimplemented)
- [x] Side panes (left/right slottable tenants) — the container every
      §2 panel lands in. Built WITH a tenant on purpose (the attention
      inbox, below): "primitives pulled by tenants, never speculative"
      is the rule the UI layer grew under, and a container validated
      against nothing is a guess about what §2 will need.
      What makes it a container rather than a slab painted over the
      panes: opening it RETILES — the terminal beside it gets a new
      column count and a pty resize, which is what the e2e asserts,
      because a decorative overlay would pass every other check.
      Width in COLUMNS not pixels (snapped to whole cells, capped at
      half the window). Window chrome, not a tab's: same panel from
      every tab, never in `panes`. Tenants are placement-agnostic —
      `drawAttention` takes a rect, so `panel.flip` belongs to the
      container. Tenant is an enum + switch like `pal_mode`, NOT a
      vtable: an interface designed against one tenant is a guess.
- [ ] Status bar: workspace/branch/review-gate state, not just perf HUD

## 2. The agent layer — this is the actual product

Each of these is a host API that already works, needing a Zig surface.
Ranked by how much of rook's identity dies without it.

- [x] **Asks / RUI** — the flagship loop works: `rookctl ask` → form in
      the side pane → answer → asker unblocks (exit 0 with the JSON, or
      1 on dismissal). Verified against a real isolated rook-host, not
      just the harness.
      THE BLOCKER NOBODY HAD WRITTEN DOWN: the original flow pushes a
      msgAsk onto the asking session's wire-v3 frame socket and 409s
      when nothing is attached. This app owns its ptys in-process,
      registers NO sessions, and `$ROOK_SESSION` is unset in its shells
      — so `rookctl ask` refused at the source AND delivery was
      impossible, in both directions. The host gained a session-less
      queue (`POST /asks`, `GET /asks`) that rook polls like /attention
      and /usage; `rookctl ask` falls back to it when there is no
      session. Session-scoped asks are untouched, and the queue omits
      them so an app holding both paths cannot double-render one.
      TRADEOFF, on purpose: a queued ask is app-global, not pane-scoped.
      Invisible with one window; revisit at the second.
      Details that are load-bearing rather than decorative:
      `recommended` puts the asker's suggestion under the cursor so
      Enter alone answers; the Other row is always present and typing
      jumps to it (picking your own words is NOT also picking an
      option); ESC posts a real `{"canceled":true}` because silence
      leaves the asker blocked forever; JSON escaping has its own test
      root because a stray quote in a label loses the answer.
- [x] Ask provenance + jump-to-source. A queued ask has no session to
      derive provenance from, so the asker carries its CWD — the one
      fact it always knows — and rook resolves workspace and pane from
      it. ⌃G focuses the pane whose shell cwd best matches (exact beats
      parent, deeper parent beats shallower, so the pane the agent runs
      in outranks a shell at the repo root) and deliberately does NOT
      dismiss: you jump to look, and the form must still be there.
      THREE BUGS ONLY A REAL HOST COULD SHOW, none of them visible to a
      sandbox with no daemon: (1) `realpath` the asker's cwd first —
      paneCwd is the kernel's resolved path and /tmp is a symlink to
      /private/tmp, so the prefix match silently never fired; (2) the
      app MUST POST /asks/{id}/ack — rookctl gives up after 5s, so the
      asker died on its deadline while the human was still reading (the
      push path acked from the frame handler; a poller has to do it
      explicitly); (3) the form HOLDS the ask while open, so switching
      panels stranded a live question with no way back — `ask.show` /
      `<leader>q` recovers it.
- [ ] Name the AGENT, not just the directory, in an ask. Needs
      `/agents/{id}` verbs.
- [~] **Attention inbox** (`/attention`, `<leader>a`) — the "what needs
      me" queue that makes the app worth leaving open. LISTS today, as
      the side pane's first tenant (`src/attention.zig`, shaped after
      usage.zig, fail-open the same way). Does NOT act: jumping to the
      session and answering the ask need `/agents/{id}` verbs and a form
      renderer — they belong with the asks item above.
      Two things it is careful about, both worth preserving in whatever
      replaces it: "nothing waiting" and "host unreachable" RENDER
      DIFFERENTLY (an empty list because the daemon is down would read
      as good news, the worst possible lie for this panel); and idle
      frames stay 0 — it polls 2s but only while OPEN, and only dirties
      the scene on a digest change. Measured after: 6s open, n=0 on
      every frame ring. Overflow is never silent (`+N more` covers both
      the height cap and the 16-item fetch cap).
- [~] **Agent deck** (`/agents`, `<leader>v`) — the flat vim-navigable
      deck is DONE (`src/agents.zig`). Needed no host change, unlike the
      asks loop: the endpoint is plain HTTP and assumes nothing about
      session sockets. Ordered by what needs you (needs_input → working
      → quiet), STABLE within a rank so a poll cannot move the row under
      the cursor. Opens FOCUSED (it is a list you pick from) and ESC
      yields the keys back WITHOUT closing. Enter goes there through the
      same `jumpToCwdLocked` as the ask form's ⌃G — one notion of "go
      there", so they cannot drift. Rows name the WORKSPACE, not the last
      path segment: the first version read this repo's `rook/app` as
      "app", which is true and useless. Wire mapping pinned by a test
      against a real captured /agents response.
- [x] **Session view**: Enter on a deck row opens that agent's
      transcript AS A BUFFER (`src/transcript.zig`). The editor is
      already a renderer with scrolling, search, motions and yank, so a
      timeline is a document rather than a bespoke viewer —
      `Editor.openText` is the seam and `synthetic` makes `:w` refuse.
      The simplification threads will want too.
      Renders `── assistant · model ──`, `⚒ Tool <what it names>`, `→`/`✗`
      results clipped to six lines, `· thinking` for the encrypted
      blocks. JUDGEMENT THAT MATTERS: a tool result is NOT attributed to
      the user — Claude Code sends results back as `user` records, and
      heading them "user" makes a build log read as something the human
      said, which is the one thing this view must not get wrong.
      TWO BUGS IT SURFACED, both in shared tooling: (1) **hostc did not
      decode `Transfer-Encoding: chunked`** — Go switches to it once a
      response outgrows its write buffer, so every earlier panel worked
      and the first big one did not, presenting as a JSON parse error
      that read as the host's fault; `hostc.dechunk` has its own test
      root now, and this would have bitten threads and review too.
      (2) **`shot` never dirtied the scene** and the app draws nothing
      when idle, so a screenshot of a quiet screen timed out AND left
      the request armed, wedging every later shot with `err busy`.
- [ ] Paging further back (`before=` cursor) and live tail (`after=`).
      The window is the last 200 records and says so; both cursors are
      already on the wire.
- [x] **Threads** (`/threads/`, `<leader>t`) — host-projected editable
      docs, and in rook they ARE buffers: `<leader>t` lists, Enter opens
      `thread:{id}`, `:w` saves the draft, `:ThreadNote`/`:ThreadAsk`/
      `:ThreadResolve` go through the ex-command bridge (which is what
      it was built for). `Editor.app_save` is the seam — same
      function-pointer shape as the highlighter and the command bridge,
      so editor.zig still knows about buffers and not about hosts. The
      buffer NAME carries identity, so a save belongs to a PANE rather
      than to some "current thread" two panes would fight over.
      THE CONTRACT, both halves load-bearing: the prefix is `content`
      MINUS `draft`, computed exactly — never by scanning for the
      scissors, since a comment body could contain a scissors-shaped
      line; and a 409 is NOT an error but a concurrent agent reply, so
      rook splices its tail onto the grown history and re-saves (append-
      only, so it always merges).
      FOUND ON REAL DATA: anchors are MULTI-LINE (a newline in a
      single-row list breaks the row — `setOneLine` collapses runs), and
      `deliverError` deserves its own mark because it means submitted-
      but-nobody-was-told, the one failure the old model showed as a
      normal wait.
      ALSO FIXED: the untargeted-input priority lived in TWO places (the
      NSEvent path and ctl) and drifted — the threads panel reached one
      and not the other, so Enter went to the shell. There is one
      `routeChromeKeyLocked` now.
- [ ] Thread CREATION from a buffer (`gt` — go-to-or-create on the line
      under the cursor). Reading and replying work; starting one still
      needs the anchor plumbing.
- [x] **Review / RookTask** (`/tasks/`, `<leader>g`) — the changes list
      and the gate. `src/review.zig`; a/r/d set verdicts, Enter opens the
      finding's file at its line, the gate reads at the top.
      **IT DID NOT NEED A DIFF SURFACE, and that was worth checking
      before building one.** A review's children are anchored FINDINGS —
      path, line range, summary, state — not diff hunks. The finding says
      what is wrong and where, and rook already opens a file at a line,
      so the diff was never what stood between you and a verdict. Still
      worth building as a nicer way to READ a change (§3), just not a
      prerequisite.
      Enter uses `currentStart`, the stored range RE-ANCHORED onto
      today's file; jumping to the line it was written against would land
      on whatever moved into its place. `State.blocks` mirrors the host's
      `reviewBlocking` exactly — a client that disagreed would render a
      gate the host will not honour. Blocking sorts first and riskiest
      first, stably, so a poll cannot move the row mid-triage; a/r/d are
      single letters and advance immediately, because triaging 52
      findings pays every extra keystroke 52 times.
- [ ] Review COMMENTS (a verdict with words — the thread-per-finding
      path). Verdicts work; `pending` state exists for exactly this and
      nothing sets it yet.
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
must clear is "I don't reach for a terminal nvim inside rook", not
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
- [x] **`:w` cannot lose your file.** Atomic replace, permissions
      carried across the new inode, symlinks written through rather
      than replaced — and a refusal to overwrite a file that changed
      underneath the buffer, which in an agent workspace is the normal
      case rather than a corner one. `!` on any write forces it; the
      message names `:e!` too, because whether you want yours or
      theirs is not something the editor can know. Each guarantee has
      a unit test that fails when the guarantee is reverted (checked,
      all three), plus an e2e that drives the refusal through the real
      key path — a guard nobody can reach is theatre.
- [x] **Save-point tracking.** `modified` was a stored flag, and a flag
      can only ever be set: `u` all the way back to what you saved still
      refused `:q`. It is derived now — edits are numbered, the number
      rides through undo and redo, and the number on top of the undo
      stack identifies the buffer's CONTENT STATE rather than how much
      has happened to it. This matters more than it looks: a dirty
      marker that lies teaches the `:q!` reflex, and the person with
      that reflex is the one who will `:w!` past the clobber guard.
- [x] **Long lines cannot abort the app.** `ccol` is an offset into the
      real line, `lineText` returns a truncated copy, and every helper
      indexed the copy with the offset — `A` on a long line or a
      backspace joining onto one crashed in a single keystroke.
      `lineCap` is now the one definition of the editor's reach, typing
      at the clamp is refused rather than dropped mid-line, and the
      status row says `[long line]`. Clamp raised 4KB → 64KB on a
      measurement (40 × 60KB lines fill in 50µs).
- [ ] Unbounded line length: the clamp is a real wall, just a distant
      one. The fix is a horizontal WINDOW — render and do column math
      over `[left, left+cols)` instead of copying whole lines — which is
      its own slice.
- [x] **Indentation the file decides.** `o` / `O` / `cc` / Enter
      inherit the line's leading whitespace verbatim; `>>` and `<<`
      (counts, `>j`/`>k`, `>`/`<` in visual) work in COLUMNS and
      respell the result in whatever the buffer already indents with,
      detected by counting first indent bytes until 200 indented lines
      have been seen — a flat first-N-lines scan reads a Go file's
      licence header and import block and concludes "spaces". No
      setting, because rook's own tree is Zig and Go side by side.
      Blank lines don't shift, and an indent you never typed on is
      taken back on ESC — both are about not putting whitespace noise
      in someone's diff. The take-back fires only when the line is
      still exactly the bytes the editor inserted.
- [x] **`f` `F` `t` `T` `;` `,`** — line-local, because a find that
      walked to the next line makes `dt)` a much worse mistake than it
      looks. A miss cancels a pending operator rather than deleting to
      somewhere arbitrary; `f`/`t` are inclusive for an operator and
      `F`/`T` are not; the key after `f` is literal (`f2` finds a `2`);
      `;` after `t` advances, since the cursor is already parked one
      short and a `;` that does nothing is worse than useless.
- [x] **Text objects** — `iw`/`aw`/`iW`/`aW`, `i"` `i'` `` i` ``, and
      the four bracket pairs with `b`/`B`, each with an `a` form, in
      operators and in visual mode. `i`/`a` become object prefixes only
      when something is waiting for a range, so they still enter insert
      otherwise. Words and quotes are line-local, brackets are not
      (`di{` over a body is the point). Sitting on a CLOSING bracket
      resolves to that pair rather than the one outside it — a
      backward search from past the cursor counts it as a nesting
      level, which is a bug the vacuity check on a redundant branch
      turned up.
- [x] **`.` repeats the last change** — recorded by RESULT, not by key
      table: keys accumulate while a command is in flight and are kept
      only if the buffer version actually moved. So `w` and `yy` leave
      no dot, `cwfoo<esc>` and `vjd` do, and nothing here has to
      maintain a list of which keys count as changes — the list that
      always goes stale. `u`/ctrl-r/`.` are the three explicit
      exceptions: they move the buffer without being changes of their
      own. A count on `.` REPLACES the recorded one (`3dd` then `5.`).
- [x] **Registers and marks.** `"a`–`"z` (uppercase APPENDS, `"_` is
      the black hole: it takes the text and leaves the unnamed register
      alone, so `"_dd` deletes without losing what you were about to
      paste). The unnamed register always gets a copy too — that is
      what makes `p` after any `d` work. A `"a` selection survives
      exactly ONE command, so a stray motion after it does not leave
      the next `x` writing into a. `ma` / `` `a `` / `'a`, both jump
      forms usable as motions (``d`a`` charwise, `d'a` linewise), an
      unset mark cancels the operator rather than running it against a
      position nobody chose, and `` `` ``/`''` return from the last
      jump. `p`/`P` take a count.
- [x] **The motions a day of editing keeps reaching for** — `%`,
      `{`/`}`, `H`/`M`/`L`, `zt`/`zz`/`zb`, `*`/`#`, `ge`. `d%` runs
      from the CURSOR through the match, not from the bracket. `*` is
      a literal search like `/`, so it also finds `foobar` — this
      engine has no word boundaries to anchor with yet. Expectations
      were taken from real vim rather than from memory, which is how
      the backward-inclusive bug below turned up.
- [x] **Backward inclusive motions bumped the wrong end.** `ge` is the
      first inclusive motion that runs BACKWARD, and the operator path
      added the inclusive byte to the target before taking min/max —
      so `dge` deleted the span between the two words instead of the
      span covering them. The bump belongs to whichever end is FAR
      from the cursor.
- [x] **The small edits** — `s` `S` `X` `~` `gJ`, a count on `J`, and
      the case operators `gu` `gU` `g~` with their doubled line forms
      and their visual `u`/`U`/`~`. The case operators ride the
      EXISTING operator plumbing (`op` grew three more letters), so
      they compose with every motion, text object, find and mark for
      free, and they leave the registers alone — nothing came out of
      the buffer to put anywhere. ASCII case only: every substitution
      is one byte for one byte, which is what lets the walk run in
      4KB chunks without rebuilding offsets.
- [x] **`R`** — replace mode, with backspace putting back what it took.
      The history is what each keystroke displaced; once that debt is
      paid, backspace only MOVES, and never deletes text this `R` never
      touched. Any cursor move drops the history, because the offsets
      in it only mean anything for an unbroken run.
- [x] **Insert mode's own keys** — ctrl-w, ctrl-u, ctrl-t/ctrl-d,
      ctrl-r, ctrl-o. `<C-o>` is one normal command then back, and it
      exempts the cursor from the normal-mode clamp for its duration —
      that one line is the whole reason `<C-o>$` appends instead of
      overwriting the last character. It waits for QUIESCENCE rather
      than for one key, so `<C-o>daw` works; and if the command opened
      its own insert (`<C-o>cw`) it stands down instead of trying to
      re-enter later. ctrl-t on a still-empty line indents it, where
      `>>` deliberately would not — diff hygiene is about lines you are
      not typing on.
- [x] **`:[range]s/pat/rep/[gi]`** with `%`, `.`, `$`, `N`, `N,M`,
      `'a` and the `'<,'>` a visual selection leaves behind — `:` out
      of a visual prefills that range, because it is what you were
      about to type. One undo group for the whole command; the pattern
      becomes the search pattern so `n` walks the rest of them.
      Every visual exit now runs through one `leaveVisual`, which is
      what keeps `'<`/`'>` from drifting out of date with whichever
      key ended the selection.
- [x] **Macros** — `q{a-z}` records, `q` stops, `@a` plays, `@@`
      repeats, `10@a` counts. They live in the SAME registers as
      yanks, which is vim's arrangement and a good one: `"ap` prints
      the macro you just recorded and `"ay$` loads one from a line of
      text. Recording is suppressed inside a replay, so a macro
      records the `@b` rather than what b expands to. The depth cap is
      the only thing between a macro that plays itself and the stack —
      removing it crashes the test binary, which is how that one was
      checked.
- [x] **`?`, `gv`, and the numbered registers.** `n` walks the SEARCH
      DIRECTION and `N` walks the other one, which is what makes `N`
      after a `?` go forward; `*`/`#` set it too. `"0` holds the last
      yank and nothing else — a delete must not push the thing you
      were about to paste out of it, which is the whole point of the
      split — and deletes of a line or more shift down the `"1`-`"9`
      ring. `gv` restores the last selection with its MODE, so a
      linewise one comes back linewise.
- [x] **Visual block** — `ctrl-v` with `d` `x` `y` `c` `I` `A` `r` `$`
      and the case operators, plus a `p` that puts a rectangle back as
      a rectangle. The block is measured in RENDER columns, so a tab
      does not knock it out of alignment. `A` pads a line too short to
      reach the column and `I` skips it — appending to a short line is
      a request to reach that far, inserting into one is not, and both
      are vim's. A paste taller than what is left grows the buffer
      rather than dropping its last rows: losing half a paste silently
      is worse than gaining a line.
- [x] **A regex engine** (`regex.zig`), vim-magic syntax, behind `/`
      `?` `n` `N` `*` `#`, the search highlight, and `:s` — with `&`
      and `\1`-`\9` in a replacement and `\r` splitting a line.
      BACKTRACKING rather than a Thompson simulation, because captures
      are the point: `\1` is most of why a regex beats a substring
      search. What that costs is held off two ways — a repeat of a
      single-width atom is ONE instruction with an internal greedy
      loop, so `.*` over a long line uses no stack, and every match
      runs on a step budget that fails closed. Removing the budget
      makes the pathological test run past 90 seconds, which is how
      that one was checked.
- [x] **Searching as you type**, `:g`, `ZZ`/`ZQ`, counts on `u` and
      ctrl-r. The preview always measures from where the prompt OPENED,
      not from the last preview — otherwise deleting a character leaves
      you somewhere the shorter pattern never matched — and ESC puts
      back both the cursor and the pattern that was current before.
      `:g` collects matching lines FIRST and runs them bottom-up, which
      is what makes `:g/x/d` work at all. An ex command is ONE undo:
      `Buffer.newUndoGroup` can be pinned, because the primitives that
      open groups are exactly the ones a global reaches for.
- [x] **Keyword completion** (ctrl-n / ctrl-p), `gd`, and a matching
      bracket mark. Completion offers every word in the buffer sharing
      the prefix, ordered by DIRECTION from the cursor — down first for
      ctrl-n, up first for ctrl-p — deduped, with the text you actually
      typed as the last stop in the ring so cycling past the end does
      not strand you on a word you rejected. Any other key ends the
      ring, because the candidates were built against text that has
      since moved. `gd` is the honest version of "local declaration":
      the first mention of the word from the top of the file, which in
      most files is where it is declared.
- [x] **`f` `t` `r` take whole codepoints**, and the regex takes
      `\{-}`. `f—` has to work in a file full of prose, and this
      project's own docs are full of em-dashes; comparing one byte
      lands on the wrong character, since `—` and `”` share their
      first two. Non-greedy is one bit: for a single-width repeat it
      counts up from the minimum instead of down from the maximum, and
      for a group it swaps which way out the split tries first.
- [x] **A jumplist** on ctrl-o / ctrl-i, and `\%(` / `\zs` / `\ze` in
      the regex. The jumplist holds anchored offsets and rides the same
      `Buffer.on_edit` seam as the marks — one that survived edits only
      by luck is one you learn not to trust. A new jump discards the
      forward history, and stepping off the newest entry parks where
      you were, so ctrl-i can come back to it. `\zs`/`\ze` get capture
      slots of their OWN: the whole-match saves run after the body and
      would overwrite anything the body set.
- [x] **Back-references and the case flags close the regex gaps.**
      `\1`-`\9` inside a pattern match what the group actually took, so
      `s/\(\w\+\) \1/\1/g` de-duplicates a stutter; a reference is the
      one atom whose width is unknown until match time, which is why it
      cannot ride the iterative repeat. A forward reference is a typo
      every time, so it fails to compile rather than matching empty.
      `\c`/`\C` are NOT positional in vim — one anywhere decides the
      whole pattern — so they are lifted out before parsing instead of
      compiled. That is what keeps `\c^func` anchored: compiled as an
      instruction, the `^` would no longer be at the start of the
      pattern and would quietly become a literal caret. A `\c` inside
      `[...]` stays a member of the class, which vim agrees with and is
      the reason the lift has to track bracket expressions.
- [x] **Marks are ANCHORED.** They hold a byte offset, and
      `Buffer.on_edit` tells the editor about every edit — offset,
      bytes removed, bytes added — so a mark moves with the text
      instead of pointing at whatever ends up on line 12. One seam on
      purpose: a position that only SOME edits update is worse than one
      that never updates, because it is right often enough to be
      trusted. Undo and redo fire it too. A mark inside deleted text
      collapses to where that text was, which is the more useful answer
      than throwing it away. This is the seam the git gutter and
      thread reanchoring want next.
- [x] **The rest of the ex line, and ctrl-a/ctrl-x.** `:[range]d`,
      `y`, `m`, `t`/`co`, and `normal` (once per line when it has a
      range). `:m` and `:t` run on the yank/paste path rather than on
      raw offsets, so the end-of-file newline rules stay in the one
      place that already has tests, and the unnamed register is put
      back afterwards — moving lines must not cost you the thing you
      were about to paste. A typed `:e` path now resolves against the
      BUFFER's directory rather than the app cwd, while the paths the
      listing and the app hand in stay untouched: resolving those
      twice is how you get `a/b/a/b/file.txt`.
- [x] **ctrl-a/ctrl-x know what a number is** — bin, octal and hex, on
      vim's default `nrformats`. A leading zero is OCTAL, so `007`
      counts up to `010`; that surprises people and neovim dropped it,
      but an editor advertising vim keys that quietly disagrees with
      vim about what a number *is* would be worse, and `0089` stays
      decimal so the common zero-padded case still behaves. Everything
      about the spelling survives: the `x`/`b` keeps its case, hex
      letters take the case of the LAST letter (`0xaB` -> `0xAC`,
      `0xAb` -> `0xac`), leading zeros hold their width, and the
      non-decimal bases are unsigned and wrap at 64 bits. All 45
      expectations were GENERATED by driving real vim, because at least
      four of these rules are ones I would have written down wrong.
- [x] **Case operators past ASCII.** `gu` `gU` `g~` `~` map per
      CODEPOINT over the scripts vim covers, from a table in
      `unicase.zig` that was GENERATED by driving vim's own operators
      over 13k codepoints. That generation step is the point: vim's
      `toupper()` builtin and its `gU` operator use different tables
      and disagree about `ß` — the builtin leaves it alone, the
      operator gives `ẞ` — so a table built from the convenient source
      would have been wrong at the first character anyone would test.
      Mapping is 1:1, never 1:many, which is also vim. The byte length
      still moves (`İ` is two bytes and lowercases to a one-byte `i`),
      so a chunk is rewritten into a second buffer and the range end is
      carried by the difference; the old in-place byte walk relied on
      one-byte-for-one-byte and could not survive that.
- [x] **Wide glyphs take two columns.** CJK and emoji lay out two
      cells wide, and the width table is GENERATED from ghostty's — the
      one the terminal panes already lay out with — so a pane and an
      editor showing the same Japanese line cannot disagree about where
      it ends. The editor stays free of the C++ deps ghostty-vt brings
      (simdutf, highway) that its headless test root is deliberately
      without; `width_check.zig` is a test root that HAS the dependency
      and re-derives the answer for all 1.1M codepoints on every run, so
      a ghostty upgrade that moves a boundary fails there instead of
      surfacing as a cursor one cell off. The second cell carries the
      STYLE but no codepoint of its own, which is what keeps a selection
      or a search match from coming out striped, and what keeps a text
      dump reading `日本語` rather than `日 本 語 `.
- [x] **Long lines stay editable, and cheap to draw.** The 64KB clamp
      is gone: the shared line buffer is heap-backed and GROWS to meet
      the line, so a 200KB minified line takes `A` and `$` like any
      other. The ceiling that remains (4MB) is a cursor-column limit
      rather than a buffer size, and it still refuses in the one way
      that matters — loudly, rather than by pinning the cursor and
      dropping every further keystroke into the middle of a line you
      cannot see. `lineCap` and `lineText` now come from ONE function,
      because a column derived from a length larger than the slice
      handed back is the exact shape of the abort that got the clamp
      built in the first place.
      Growing the buffer alone would have been a performance
      regression, and a big one: FOUR callers pulled the whole line in
      once per frame each to ask one question about it, so a 2MB line
      cost 6.3MB of copying per frame — more than the line itself. They
      all take a bound now. Measured over 100 frames on a 2MB line:
      629,193,600 bytes copied before, 48,100 after.
- [x] **The unit of movement is a grapheme cluster.** A combining
      mark, a skin tone, a flag's other half and every link of a ZWJ
      chain belong to the character before them, so `x` removes a whole
      character and `l` never stops inside one. This also dissolves the
      zero-width problem rather than solving it: the editor never asks
      for a lone combining mark's width any more, because the mark is
      part of a cluster and the CLUSTER has a width.
      Segmentation comes from ghostty, and getting it meant REVERSING
      the previous entry's decision — the editor now imports ghostty-vt
      instead of carrying a generated copy of its width table. Two
      reasons: `graphemeBreak` is not exported, so a generated table
      would have meant reimplementing UAX #29 against data the library
      does not hand out; and the C++ dependency that justified
      generating measured ~150ms on the editor's test root once cached.
      `width.zig` and `width_check.zig` are gone; the behaviour they
      guaranteed and every test of it stayed.
      NEOVIM is the oracle here, not vim: vim stops at combining marks
      and splits flags, ZWJ sequences and skin tones, which is a
      twenty-year-old approximation rather than a decision.
- [x] **A cluster RENDERS as the character it is.** The old note that
      "grapheme-cluster emoji render blank — only a cell's first
      codepoint rasterizes" is closed: a cell that holds more than one
      codepoint is shaped by CoreText as a line, so a mark sits over its
      base, a flag is a flag, a skin tone applies, and a ZWJ family
      ligates into one glyph. Cells point at their cluster's bytes in a
      per-frame arena rather than carrying them, because a cell is
      copied cols*rows times a frame and a cluster is rare.
      The bug this shipped with, and the reason the e2e now asserts on
      PIXELS: drawing a shaped cluster leaves the graphics context's
      text matrix behind it, and `CTFontDrawGlyphs` positions relative
      to that matrix — so every plain glyph rasterized after the first
      cluster landed outside its slot. Separators and the `d` of `end`
      simply stopped being drawn, while every text assertion stayed
      green, because the MODEL was right and only the raster was wrong.
- [x] **Terminal panes shape clusters too**, on the same path. Agent
      output is where emoji and accented text actually turn up, and a
      terminal cell holds a cluster the way an editor cell does — the
      library keeps the trailing codepoints beside the cell rather than
      in it. Before: `e` plus an accent drew as a bare `e`.
      NOT fixed by this, and a different problem: flags, ZWJ sequences
      and skin tones are still split across cells in a terminal,
      because the emulator only CLUSTERS those under mode 2027 and does
      not enable it by default. That is a decision about column
      accounting for TUIs, not about rasterizing, so it is left alone.
- [ ] The status row still lays out per codepoint (`putStr`), so a
      filename with a combining mark spreads over an extra cell there.
      Cosmetic, and the only place left that has not moved to clusters.
- [x] **Notice a disk change while the buffer is OPEN**, not only at
      `:w`. One stat per editor pane on the existing 1Hz tick, split by
      who has something to lose: an UNMODIFIED buffer reloads (keeping
      your cursor and scroll — landing on line one every time an agent
      touches the file would make the pane useless for watching), a
      MODIFIED one only says so with `[!]` beside your `[+]`. Every
      pane in every space, because a background tab holding a stale
      buffer is the one you would not think to distrust. Measured: 6
      idle seconds with an editor open still draws 0 frames.

## 4. Platform and distribution

- [ ] **Self-update** (`internal/selfupdate`, `/update`, `rookctl update`) —
      today rook ships only via `make install`
- [ ] **Code signing + notarization + DMG**; the bundle is hand-rolled
      in the Makefile
- [ ] **Version stamping / BinHash** — the dev-build trap that ate days
      on the wails side is unsolved here (rook has no build id at all)
- [ ] Crash reporting and a log file (host.log's counterpart)
- [x] **Config: one file, two readers.** rook reads
      `~/.config/rook/config.toml` — the file it does NOT own. Most of
      it is rook-host's (`coder`, `workflow`, `workspace-allow`,
      `[agent]`, `[jira]`, `[lsp]`, `[cloud]`, `[workspaces.*]`), so
      `config.zig` now takes only TOP-LEVEL keys (a key inside any
      `[table]` is someone else's) and is SILENT about ones it doesn't
      know. Being a guest means it can't tell a typo from a host key,
      which costs us warnings on our own typos — the price of one config
      instead of two, and what NEXT.md's layered `config.d/` eventually
      buys back. Keybinds come from the same file: top-level `leader`
      plus `[keybinds]`, in the REGISTRY's vocabulary (`session.new`,
      `workspace.manager`), with unimplemented commands skipped quietly
      — so part of §1's registry arrived early, by necessity.
      `window-padding-x`/`-y` both map to the one knob; theme lookup was
      already case-insensitive.
      Found doing it: a quoted value with a trailing comment never had
      its comment stripped, so `"<leader>c" = "tab.new"  # …` parsed to
      garbage and was dropped in silence. `config.zig` has its own test
      root now, for exactly the reason paste.zig does — everything here
      fails quietly by design.
- [x] **The rename.** The zig app replaced the wails app outright:
      `rook.app` / `com.incantery.rook`, `rook` is the app AND the CLI,
      `/tmp/rook.sock` + `ROOK_SOCK`, `~/.config/rook/`, and `re` is the
      zig editor (claimed from rookctl, which used the same argv[0]
      trick). Info.plist takes its version from the newest tag.
      `rookctl` folds in by EXEC, not reimplementation: `rook <verb>`
      hands anything it doesn't own to the bundled Go binary, so stdio
      and exit status pass through (`rook mcp` is a stdio server) and
      each verb migrates by being handled in Zig and deleted from Go —
      §6's shape, applied to the CLI.
      `rookctl` still installs under its own name, deliberately:
      `claude-plugin` invokes `rookctl mcp` and `rookctl claim`/
      `unclaim` BY NAME, and an installed plugin breaking mid-session is
      not an acceptable cutover cost. It goes once the plugin says
      `rook`.
      FREE, and the reason outright replacement beat a parallel bundle:
      `install.sh`, the release zip name, and `internal/selfupdate`
      already hardcode `rook.app` / `rook-$tag-…zip`, so `rookctl
      update` survives untouched — it IS the rollback lever.
- [ ] E2E: `make e2e` drives the wails app headless. rook has the ctl
      socket (better), but no CI job runs it, and no agent-panel
      coverage exists yet.
- [ ] Accessibility: zero today (NEXT.md wants a semantic element tree;
      the wails app got it free from the DOM)

## 5. Accepted regressions — call these out loud before cutover

- **Shells die with the app.** rook-host owns the ptys today, so a
  wails-app restart reattaches live sessions. rook owns them
  in-process. Until ptys move behind the host/client split, quitting
  rook kills every shell in every space. This is the strongest single
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
rook owns ptys, ghostty-vt owns emulation and width tables,
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

**The sequencing rule: port by coupling to the UI, and only after rook
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

## Order

Cutover first, then panels. The gate on cutover was never §1/§2 —
Claude runs in a terminal pane, and rookctl/MCP reach the host over HTTP
regardless of who renders. It was whether the daemon still *starts*
once `/Applications/rook.app` is gone: `rookctl connect()` reads
host.json and never spawns, so the wails app was the only thing that
started rook-host. Delete it before step 1 and the terminal looks fine
while every hook, MCP tool, and ask silently dies.

- [x] 1. §0 paste + IME (an hour, unblocked exclusive use)
- [x] 2. Host lifecycle + `hostc.zig` + build stamping — the gate
- [x] 3. The rename (§4) — Info.plist, socket, config paths, `re`, the
       CLI folding, and `make install` bundling the two Go binaries
       (without them the app can't start a daemon or answer a verb)
- [x] 3b. `scripts/rook-migrate.sh` — written early because the rename
       needs its `config` phase: the rookz-only settings had to reach
       the shared file or the window would silently lose its glass.
       Phases are separable (`config` / `binaries` / `daemons`) because
       they are not equally reversible — the last one takes live shells
       down with it. STATE IS NEVER TOUCHED: `~/.config/rook/`,
       `~/.local/state/rook/`, `rook.db`. No LaunchAgents exist.
- [x] 4. Merge to main (fast-forward; main had not moved). NOT PUSHED —
       `make release` pushes main with the tag, so the next release
       carries it.
- [x] 5. `make release` assembles the bundle itself instead of calling
       `wails3 task package`. The ZIP'S SHAPE is unchanged on purpose —
       `rook.app` + a top-level `rookctl` — because `install.sh` and
       `internal/selfupdate` both read it, and keeping that contract is
       what let the app underneath change without touching the upgrade
       path. `release-stage` is everything up to the zip with nothing
       irreversible in it, so packaging is testable.
       Caught by testing it: `make install` had symlinked
       `~/.local/bin/rookctl` into the bundle, and `selfupdate.Apply`
       resolves symlinks before overwriting — `rookctl update` would
       have rewritten a sealed binary and invalidated the signature.
       A copy now, both places.
- [ ] 6. Run the migration's `binaries` + `daemons` phases and delete
       `/Applications/rookz.app`
- [x] 7. Restructure: promote `native/` to first class. `native/` →
       `app/` — the name was a contrast with the webview and described
       nothing once the webview was gone. But the rename was the small
       half. **CI had never built a line of Zig**, while running four
       gates (lint, format, typecheck, build) on the retired frontend on
       every PR: the shipping app could break green, and a Svelte type
       error could block a merge. There is a macOS `zig build` + `zig
       build test` job now, and the frontend moved to its own
       path-filtered workflow. The Makefile's first two verbs had the
       same inversion — `build` and `start` drove `wails3`, which
       `make install` stopped needing at the cutover, so both were
       broken on a fresh clone. `build` compiles the app now; the
       retired stack keeps the `-web` suffix that `dev-web` and
       `install-web` already established. `build` deliberately does not
       run anything: every run target has to pass DEV_ENV or it steals
       `/tmp/rook.sock` from the installed app.
       Renaming the package in `build.zig.zon` (`.native` → `.rook`)
       invalidates the fingerprint, since it is derived from the name —
       Zig refuses the build and prints the replacement value.
       The one loss was **`make e2e`, the agent's eyes** — it drove the
       webview through Playwright, so it became `e2e-web` with nothing
       equivalent for the Zig app. Closed immediately after; see below.
- [x] 7b. e2e for the Zig app (`app/e2e/`, `make e2e`). Six scenarios —
       boot, echo, splits, tabs, editor, pixels — each in its OWN
       sandboxed instance (own socket, config, XDG, HOME, /bin/sh, no
       rook-host), ~2s for the suite. `shot` is DECODED through ImageIO
       rather than just written, so pixel assertions are real: a frame
       that drew nothing is one colour, which is the cheap signature the
       atlas-flip bug would have tripped.
       THREE THINGS IT LEARNED, all of them the hard way and all of them
       load-bearing: (1) `start()` round-trips an `echo <marker>` before
       any scenario types, because waiting for a prompt to be DRAWN is
       not the same as a shell READING — the pty buffers, and that race
       is what made the old suite flake on a cold sandbox; (2) the
       sandbox owns `HOME`, because rook starts LOGIN shells and
       /etc/profile overwrites an inherited `PS1` before the first prompt
       — `~/.profile` is the only hook that wins; (3) screen matching
       JOINS the rows, because a pane wraps at its width.
       Two of the first six failures were the TEST being wrong about the
       app, which is the harness paying for itself on day one: `edit`
       TAKES OVER its pane (the shell parks underneath) rather than
       splitting, and `panes` prints two different `*` markers — active
       tab at column 0, focused-within-tab before the id — so matching
       the wrong one made tab switching look like a no-op.
       NOT in `zig build test` and NOT in CI, deliberately: it needs a
       window server, a Metal device, and real shells. Zig 0.16 gotcha,
       hit three times in one file: `std.Thread.sleep`,
       `std.time.milliTimestamp` and `std.fs.cwd` are all gone — the
       harness talks to libc directly for the same reason the app does.
- [ ] 8. Command registry + ⌘K palette (every later panel registers)
- [ ] 9. Asks → attention inbox → agent deck (product identity, in
       that order)
- [ ] 10. Side panes, then threads + review (review pulls in the diff
       viewer — and with Monaco gone it has no fallback, so §3's diff
       surface is on the critical path)
- [ ] 11. Theme engine + settings UI
- [ ] 12. Signing, notarization, crash reporting

Say out loud to anyone driving it daily (§5): **shells die with the
app.** rook-host owns the ptys on main, so a restart reattaches; rook
owns them in-process, so every rebuild-and-relaunch kills every shell in
every space. That bites hardest during exactly this kind of rapid
iteration, and it is the strongest argument for doing the host/client
split sooner.
