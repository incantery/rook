# Up Next

- [x] Fix the attach replay gap: handleAttach copies the ring, replays, THEN sets s.attach — pty bytes arriving during replay never reach that client. Silent scrollback loss on reload today; constant loss once detach/reattach becomes routine (CHATGPTFEEDBACK.md). Step zero of the background-session detach work.
- [ ] TODO item/ticket tracking — designed: docs/superpowers/specs/2026-07-27-todos-and-workspace-rename-design.md (a `todo` work_type over the existing rook_tasks table, `workspace = ''` meaning unscoped, global = the unfiltered view; ships with workspace rename, which is what makes losing a name expensive)
- [ ] TOML plugin
- [ ] Better Window Naming (maybe AI assisted naming)

# Workspace Switcher

- [x] Vim key-binds (^j/^k + ^n/^p in switcher and palette — bare j/k would type into the filter; bare j/k in the inbox)
- [x] Focus currently always starts at the top and it should start on the active workspace

# Rook Agent

- [ ] The rook agent should have more agency. Right now it does a lot of just "yours to answer".
- [ ] Improve the agent recommendation and response setup. I'm thinking something like having something on the dashboard, or a way to have a more detailed view, where Rook can display a summary of what it's replying to and why. If we dial this in, it will/should let us just run most claude code sessions "in the background" and only attach when we specifically choose to directly attach even though it's running interactive the whole time.
- [ ] Markdown in the svelte session view. Claude writes markdown and the view renders it literally today — fences, lists, headings, bold all show their syntax. It's the difference between a view you'd use and one you'd tolerate, so it gates daily-driving the 90% case. Options: take a dep, reuse Monaco (already chunked, already themed), or write a small renderer for the subset claude actually emits.

# Rook App

- [x] Better total cost tracking in a sort of app wide status bar with more details on the main "workspace manager" screen
- [x] Baked in claude code usage. We still track total "cost" when using a claude subscription, but we want to also keep track of remaining usage for the period for subscription accounts
- [ ] Adding rook cloud shouldn't need a daemon restart. `initCloud` (cloud.go:45) is the one setting decided at boot and never revisited — it returns early when `[cloud] url` or the token is missing, which is why `rookctl set-cloud-token` has to say "then restart rook-host" (main.go:1732). That instruction is worse than it sounds: the host owns the PTYs precisely so the UI can crash and reattach without killing shells (decision 2), so bouncing it to pick up a token kills every shell in every window of every workspace. Everything else is already hot — `config.Load()` re-reads from disk on every call and the call sites read per-use (monitor, plugins, issues, relay, spawntask, workflow, agent); cloud is the lone outlier, and because of HOW it's wired, not what it reads. Shape: make it a supervisor rather than one-shot wiring — always start `runCloud`, re-read config each tick, attach on the transition into configured and detach on the way out. Cheap because `h.cloud` has exactly one reader goroutine (cloud.go:78/89/92, plus usagepush.go:136 which runCloud calls synchronously), so the loop can own the field with no mutex. Two details to place rather than invent: the Whoami "which machine is this token FOR" line moves to the attach transition so it still fires once per attach — and now fires when you add the token, which is when you'd read it — and `enableUsagePush` (usagepush.go:31, documented "called once from initCloud") becomes transition-guarded. Pickup is one idle tick (2 min); a recheck POST from `set-cloud-token` would make it instant, but the poll is what makes it correct and the nudge only makes it fast.

# Issue Tracking

- [ ] One of the next things we should probably setup is some kind of issue tracking integration. Then the rook agent can tie into the list of issues to determine what we should work on next
- [ ] The file tree should be based on CWD rather than workspace I think, but let's dicsuss.
- [x] When dashboard or mission control is open, input keeps going into the most recently open terminal. Both halves fixed, and they needed different fixes: mission control holds focus itself (`Home.focusDeck`, onMount + `focusBack`), while the dashboard renders behind `{#if}` — so mounting IS the open, and it focuses in its own onMount rather than in `toggleDash` (a session-less workspace lands there without passing through it). `#terminals` is never unmounted, so on both surfaces the rule is the same: something must TAKE focus, or the renderer that had it keeps it. Guarded in leader.spec.

# UI refinement (2026-07-22 pass 1 — from the Claude Design "Rook Refinement" boards)

- [x] Nocturne theme (src/theme/nocturne.ts): the boards' palette as a builtin — deep indigo elevation ladder (sunken→bg→raise→overlay), blurple accent, muted semantic hues, full ANSI + syntax. Selectable in Settings → Appearance.
- [x] Chrome B titlebar: named deck tabs (mono number + focused-pane name + agent state dot), flat workspace chip, ONE capsule (the "N needs you" attention pill), telemetry collapsed into the "usage ▾" cluster (usage bars + costs + footprint dropdown).
- [x] Global status bar (StatusBar.svelte): context-sensitive bottom strip on both screens — git branch/dirty (app) or host link + key hints (home) · review progress > agent-working > asks (center) · costs + worst usage window + footprint (right). Fed by a new 10s workspaceStatus poll (app screen only).
- [x] Review language: "N reviewed · M remaining" + progress bar (was "N of M hunks blocking"); rows use the ring vocabulary (hollow pending / filled verdict-colored / pulsing triage) with struck paths when done.
- [x] Mission control: destinations (Agents/Queue/Workspaces, underline tabs) split from status filters (All/Needs you/Working/Quiet chips); scratch/new-workspace actions on the destinations row; queue + workspaces content constrained to 1200px.
- [x] Selection grammar: accent tint + edge = selected ONLY; hovers are neutral washes (Finder/Palette/Picker/Inbox).
- [x] Vim command line in the chrome: the focused editor's monaco-vim node is ADOPTED into the status bar's center zone (term/vimbar.svelte.ts — per-window state, ONE command line, vim's own model); the per-pane 20px strip is gone. Clears when a terminal takes focus or the pane dies.
- [x] Vim status styled (term/vimstatus.ts, a custom monaco-vim StatusBar class): colored mode badge (normal accent / insert green / visual magenta / replace red, from theme vars), Ln/Col in the bar's right zone (vimbar.pos, cursor-listener fed), and the `:`/`/` prompt in a MODAL (.vim-cmdline — light scrim so incremental search stays visible); vim messages (E486, ":set wrap?" answers) stay inline in the bar.
- [x] Editor status-bar zones: Ln/Col (landed with the vim bar above), language, LSP state. The pane publishes what it's SHOWING alongside the cursor — monaco's language id plus the file extension — through the same slot-holder guard, so a background pane can't relabel the bar; `onDidChangeModel` matters as much as focus, since `:e` swaps the buffer under a pane that never loses it. The LSP chip resolves the server whose `filetypes` claim that extension (extensions, not language ids — "ts", not "typescript") and shows ● running vs ○ configured-but-not-started, which is the normal resting state, not a fault. First frontend consumer of `/lsp/status`; refetched on workspace or extension change rather than polled, because those are the only events that move the answer.
- [ ] Agent-pane status-bar zone: model · ctx% · ±lines · auto-mode when a claude pane is focused — rook already reads the jsonl; feed it to the bar.
- [x] Titlebar height: boards say 42px; we stay at 52 (h-13), and here is what pins it. `MacTitleBarHiddenInset` sets `UseToolbar: true`, so the traffic lights are placed by AppKit — centered in the toolbar band, which is the 52px our bar already matches. Shrinking to 42 doesn't move them; it leaves them ~5px low, straddling the bar's bottom edge. 42 is only reachable by repositioning the buttons ourselves (`standardWindowButton` + a frame offset, a Go shim), which is a different and larger job than a height token. Decided 2026-07-26 (Seth): leave it, record the reason, stop re-reading this line as unfinished work. Loose thread, not blocking: `InvisibleTitleBarHeight` is 44, so the bottom 8px of the visible titlebar isn't draggable.
- [ ] Hover suppression while keyboard nav is live (boards 1d: "exactly one row reads as selected").
- [ ] Review drawer: visible resize handle at the strip's top edge (boards 1e). Not the small item it sits next to: SidePane hardcodes w-88/h-72 and there is no drag mechanic anywhere in the frontend, so this is new machinery plus persistence, and it lands generically on the slot rather than on the review tenant.

# Emulator (internal/vt)

- [x] libghostty-vt differential oracle (2026-07-22): `make ghostty-lib` + `go test -tags ghostty ./internal/host/ -run Ghostty`; fixed 16 conformance bug classes on day one (charset/ACS, alt-screen cursor, tab stops, DECALN, REP, wide-pair tearing, combining-mark widths, pending-wrap semantics, …). Benchmarks: their parser 4–6× faster (SIMD — real headroom), our pipeline 4× faster (their per-cell FFI read path drowns it). PERF.md has the table.
- [ ] Parser rework (VT state machine proper): C0 controls EXECUTE inside escape sequences (we abort); C1 as raw bytes/codepoints should execute in 8-bit-tolerant mode (we drop, ghostty stores, xterm executes). Known-divergent classes documented in the fuzz filter.
- [x] Width table (2026-07-22): 64KB BMP table folds go-runewidth + all oracle corrections into one byte-load; UTF-8 batch decode. Unicode pipeline 124→202 MB/s.
- [ ] Scrollback compression (Seth, 2026-07-22): ghostty compresses idle scrollback pages caller-driven — a MEMORY play, not throughput. Our ring is ~4.9MB/session at 405 cols (wide-grid locality item below). Do it as part of the idle-RSS measurement arc: measure first, then decide page compression vs content-stride storage.
- [ ] Ghostty upstream candidates (report when we engage): CSI 0a/0e (HPR/VPR) miss the zero-coercion CSI 0C/0B have. Nothing to fix on our side — escape.go's `p()` already coerces 0→default for `a` and `e` alike; this is a report, not a task.
- [ ] Adapter v2 (only if ever needed as a real backend): per-row dirty flags + bulk row read to fix the 17ms full-screen FFI snapshot; WRITE_PTY effect callback for query responses; scrollback paging parity.

# WebGL Renderer (beamterm) — adoption gaps

- [ ] Window transparency: the canvas paints opaque, so background-opacity doesn't show through. Beamterm's fragment shader already supports it (`u_bg_alpha`, core `set_bg_alpha()` since 0.16.0) — the JS/wasm wrapper just exposes no setter. Decision (2026-07-22): don't file upstream yet; once we're confident in beamterm, file the PR (thin wasm_bindgen delegation).
- [x] Scrollback view on canvas — shared SbStore (sbstore.ts) extracted from the DOM renderer; wheel + Shift+PageUp/Home; host paging works on canvas
- [ ] Mouse forwarding to tracking programs: wheel IS forwarded now (Claude Code scroll works); clicks/drags (vim mouse) still local-only
- [ ] A11y text mirror (canvas has no readable text; DOM renderer is the accessible fallback)
- [x] Theme-change re-read of CSS vars (palette swap needed a reload). `retheme()` joins the renderer seam: the DOM one is a no-op (it paints THROUGH `var(--term-*)`, which is exactly why the gap went unnoticed — the theming code is CSS, and beamterm doesn't read CSS), the GPU one re-samples, drops the style cache and repaints the viewport. Fan-out rides `setPalette`, the one call that already knows a swap happened, and it reaches hidden sessions too — a hidden pane is revealed by `display`, with no repaint of its own. e2e asserts it in light: the canvas's mean luminance has to jump when you pick a light theme.
- [ ] Key-to-pixel latency probe to settle the DOM-vs-WebGL headed measurement asymmetry

# Plugins — PARKED (2026-07-25), and what the discussion actually found

Kind two was designed and then deliberately not built. The 07-20 language spec
deferred the generic plugin API until a second kind existed to design it
against, and the candidate (user "glue" — hooks, sources, composite commands)
had ZERO implementations. Designing against one real case plus one imagined one
is the thing `internal/agent/engine.go` refuses in as many words: *"the shape is
pulled from the pair, not designed ahead of a third."* The draft spec was
written and then deleted on purpose; these four findings are the part that
survives any framing, and each cost real archaeology to reach.

- [ ] **Locus is three questions, not one.** "Is this plugin backend or frontend"
      is the wrong axis — a plugin is a *process*, which is neither. Every
      contribution separately has: where its CODE runs (always out-of-process,
      never the webview), where its DATA comes from (host: fs/git/subprocess/
      network — or frontend: live buffer, cursor, selection, viewport, mode),
      and where its EFFECT lands (host state or the view). `language` proves all
      three can differ: gopls is a host child, the buffer text is frontend data
      shipped in the request's `text` field, the effect is a Monaco hover. The
      design move that follows: rook declares each contribution point's locus;
      a plugin fills in a shape and never picks a side. Host is the right
      default, for a thesis reason before a performance one — a frontend-only
      contribution is invisible to claude and rookctl.
- [ ] **`rows + preview + actions` has three independent witnesses.** `FinderSource`
      (row/preview/actions), `QfContext` (Row/Detail/actions), and the ask form
      (options/preview/selection) converged on the same shape at different times
      for different reasons, with nobody designing a DSL. If there is a
      presentation contract hiding in rook, that is its outline — and the ask
      form already proves the hard half: described as pure JSON by a process
      that knows nothing of rook's tree, rendered natively in a split AND on a
      phone. That makes `presentation` a far better second REAL kind than glue,
      and it is obtained by observing rather than building.
- [ ] **Commands have no parameters, and that breaks three things at once.**
      `Command.run` is `() => void`. So glue can't express arguments (`finder.open`
      — which source?), MCP `tools/list` would project 46 zero-argument tools
      (the interesting agent verbs are all parameterized), and `rookctl cmd run`
      has nowhere to put them. The fix is one artifact serving all three: an
      input schema on `Command`, which is exactly what MCP needs for
      `inputSchema`. Whenever the registry moves host-side, this lands in the
      same slice or not at all.
- [ ] **The repo layer must never supply `exec`.** A `.rook/config` arrives by
      `git clone`. If cloning a repo could register a `file.save` hook that
      execs a binary, rook has shipped arbitrary-code-execution-on-clone.
      `Config.LSPRefused` already enforces the equivalent for argv — but only
      over `lsp*` keys, and that bound is the thing to preserve, not rebuild,
      the moment config-driven behaviour extends past LSP.

Decisions reached in the discussion, unbuilt and non-binding: glue as kind two,
expressed as data (declarative hooks are statically indexable — which is *why*
VS Code needed `activationEvents` and rook wouldn't); the command registry moves
to Go with a `locus: window|host` split, keybinding dispatch staying local so
nothing lands on the keystroke path; live editor state reaches a plugin by being
shipped OUT in the request (LSP's contract generalized), never by plugin code
entering the webview; and third-party-readiness frozen only where retrofitting
is brutal — isolation boundary, plugin-qualified identity, permission scopes,
`api = 1` — leaving the contribution SHAPES explicitly provisional.

- [ ] Revisit trigger: a second REAL kind exists. Watch for it in the
      presentation direction (asks/RUI/"dynamic web interfaces"), which already
      ships, rather than inventing one.
# Rootless workspaces — the boot default that 400s (2026-07-27)

Found by `re <abs-path>` returning `400 workspace has no root` on a fresh
install. Rootless is *intentional*: `App.svelte:2552` says a fresh install
spawns a first shell and "a rootless one opens in $HOME", because opening rook
is opening a terminal. The bug is that nothing carried that intent to the eight
endpoints that require a root — file/changes/diff/write (`review.go`), plus
`grep.go`, `threads.go`, `lsp.go`, `exploretasks.go` — which treat "no root" as
an error rather than as a state.

Boot chain: `manager.ts:215` `current = "main"` → `host.go:1231` `ws = "main"`
→ **`host.go:1237` `upsert(ws, "", false)` hardcodes an empty root**. `upsert`
only ever *fills* a root (`root = CASE WHEN excluded.root != ''`), so nothing
later repairs it and the workspace is permanently rootless. Compounded by
`workspace-allow`: the boot workspace `main` is in nobody's allowlist by
default, so the workspace you are actually sitting in is invisible in the
workspace list — no affordance to notice the sessions went somewhere else.

- [ ] **Adopt a root on first spawn.** After spawning into a rootless
      workspace, set the root from the shell's real cwd. `cwdOf(pid)` is
      already called two lines away (`host.go:1240`) and is portable (lsof on
      darwin, `/proc` on linux). Self-healing: the first session in a workspace
      defines its root.
- [ ] **Make the error actionable.** `400 workspace has no root` is a dead end
      — there is no `rookctl ws` verb at all, so a user reading it has nowhere
      to go. Name the workspace and name the fix.
- [ ] **`re` with an absolute path shouldn't need the workspace root.**
      Confinement needs *a* root, but for an absolute path it can resolve the
      repo top from the path itself (`repoTop`, already used elsewhere). The
      failing request carried a fully absolute path inside a real git repo and
      was rejected anyway — the path was never the problem. Larger change to
      the edit path than the two above; the difference between "self-heals
      eventually" and "never fails in the first place". Related: the
      file-tree-should-follow-CWD question under Issue Tracking.
