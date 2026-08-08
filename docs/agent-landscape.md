# Agentic-terminal landscape survey — August 2026

Research for rook (native Zig macOS terminal/multiplexer/editor, v0.40.0).
Grounded in STATUS.md, NEXT.md (review-workspace thesis), docs/agent/VISION.md
(membrane/phone/autonomy-ladder), docs/OWED.md (accepted regressions).
Web findings current as of 2026-08-07.

---

## 1. Warp

### Current state
- **Open-sourced May 2026 under AGPL v3** — the single biggest change since rook's
  thesis was written. The full terminal client, not a shell repo.
  [HN thread](https://news.ycombinator.com/item?id=47937349) reaction was mixed:
  credit for shipping it, but the dominant sentiment was "the terminal is now the
  loss leader." [Warp blog](https://www.warp.dev/blog/open-source-and-login-for-warp)
- **Business pivoted to Oz** (launched Feb 2026): a cloud agent orchestration
  platform — "the first control plane that runs Claude Code, Codex, and Warp Agent
  side by side," webhook/cron/Slack triggers, parallel cloud agents, enterprise
  governance/auditability.
  [Oz launch](https://www.warp.dev/newsroom/2026/2/10/warp-launches-oz-the-orchestration-platform-for-cloud-coding-agents),
  [single pane of glass post](https://www.warp.dev/blog/multi-harness-cloud-agent-orchestration),
  [docs](https://docs.warp.dev/agent-platform/)
- **Pricing** ([review roundup](https://dev.to/jovan_chan_9500711396d4e6/warp-terminal-review-2026-open-source-ade-the-20-build-plan-and-who-should-actually-pay-for-it-5cin),
  [graphify](https://graphify.net/ai-coding-tools/warp/)): Free / Build $20/mo
  (1,500 credits, BYOK, 40-repo context) / Max $200/mo / Business $50/seat /
  Enterprise. Platform-credit consumption for cloud agents went live July 1, 2026.
  Credit-based pricing is repeatedly cited as unpredictable for heavy agentic use.
- **Adoption claims**: 700k+ monthly professional developers, "56% of Fortune 500"
  ([G2](https://www.g2.com/products/warp-warp/reviews)).

### What users still hate (post-open-source, from the May 2026 HN thread)
- **Feature bloat / forced AI**: "overwhelming," AI features pushed on terminal
  users; homepage sells agents, hides terminal features.
- **Aggressive Oz upsell popups** during onboarding.
- **Telemetry still opt-out by default**; one user reported it refusing to start
  without internet.
- **UI churn**: redesigns broke keybindings and saved workflows; former paying
  customers left over it.
- **Alacritty fork resentment**: forked Alacritty, raised $50M+, contributed
  nothing back — a moral-economy grievance the HN crowd holds onto.
- Login no longer required (dropped Dec 2024 — [HN](https://news.ycombinator.com/item?id=42247583),
  [itsfoss](https://itsfoss.com/news/warp-terminal-no-login/)), but the reputation
  damage persists ([old telemetry thread](https://news.ycombinator.com/item?id=33910992),
  [careerlimitingmoves](https://www.careerlimitingmoves.com/2022/04/09/warp/)).

### Assessment vs rook
- What Warp has that rook lacks: parallel agent tabs with a first-party agent,
  cloud execution, cross-platform, enterprise governance, a revenue model, code
  review panels, a huge funnel.
- What rook's stance answers: every single recurring complaint. No login, no
  telemetry, no cloud dependency, no upsell, 2.7MB single binary, config-file-first.
  **But note**: Warp open-sourcing under AGPL removed "closed-source" from the
  complaint list. rook's differentiation against Warp is now *restraint and
  native-ness*, not openness.
- Strategic read: Warp itself concluded the terminal is not the business — Oz is.
  That is evidence the "terminal with agents" position monetizes via the
  orchestration/control-plane layer, which is rook-cloud's territory, not the
  terminal's.

---

## 2. Claude Code's own surfaces (the wedge risk)

This is the section where the landscape moved hardest against rook's vision docs.
Anthropic has shipped, in production, a large fraction of what VISION.md describes
as rook's roadmap.

### Shipped TODAY
- **Desktop app rebuilt around parallel sessions** (April 2026,
  [MacRumors](https://www.macrumors.com/2026/04/15/anthropic-rebuilds-claude-code-desktop-app/),
  [docs](https://code.claude.com/docs/en/desktop)):
  - Session sidebar: every active/recent session, filter by status/project/
    environment, group by project. Each session gets its **own git worktree**
    automatically. Two sessions side-by-side with Cmd-click.
  - Drag-and-drop panes: chat, **diff, browser, integrated terminal, file editor,
    plan, tasks, subagent**, iOS Simulator.
  - **Diff review with inline line comments** (click a line, comment, Cmd+Enter
    submits all; Claude revises and you review only the new diff) — this is
    NEXT.md's development loop, shipped by Anthropic in conventional form.
  - **"Review code" button**: Claude reviews the diff and leaves comments in the
    diff view (high-signal only: logic errors, security, bugs).
  - **PR monitoring with auto-fix and auto-merge**, CI status bar, auto-archive
    on merge.
  - **Cross-session awareness**: Claude can list, read, message, rename, and
    archive your other sessions ("which session touched the auth refactor?").
  - Side chats (Cmd+;) that read session context without polluting it; view modes
    (Normal/Verbose/**Summary** — "scan results quickly across sessions").
  - Cloud sessions (Anthropic-managed, survive laptop shutdown), SSH sessions,
    WSL, scheduled tasks/routines, computer use, connectors (GitHub/Slack/Linear).
- **Mobile** ([docs](https://code.claude.com/docs/en/mobile)): the Claude iOS/
  Android app is a client for Code sessions. Three paths:
  - **Cloud sessions**: start/monitor/steer/answer questions from the phone;
    persist across devices.
  - **Remote Control** (launched Feb 2026): `claude remote-control` connects the
    phone to a session running **on your own machine** — execution stays local,
    steering goes mobile. **Push notifications when a task finishes or Claude
    needs a decision; approve/reject permission prompts from the phone**
    (v2.1.110, April 2026). This is, almost verbatim, VISION.md's "the other
    room" and "on a walk" rows.
  - **Dispatch**: message a task from the phone; the desktop app decides how to
    run it and spawns a Code session; push notification on finish/approval.
  - Plus **Channels** (Telegram/Discord/iMessage) and Slack.
- [claude.ai/code](https://claude.ai/code) is the web dashboard for cloud sessions.
- Ecosystem confirms demand: third-party notifier/remote apps proliferate
  ([Claude Code Notifier Companion](https://apps.apple.com/us/app/claude-code-notifier-companion/id6757701908),
  [remote-control guides](https://inventivehq.com/blog/claude-code-remote-control-guide-2026),
  [GH issue #60433](https://github.com/anthropics/claude-code/issues/60433) predating the feature).

### What Anthropic has NOT shipped (rook's remaining daylight)
- **No independent-model membrane.** Summaries/side-chats are Claude reading
  Claude. VISION.md's structural argument — the overseer must not share the
  worker's blind spots, and pennies supervising dollars — is unclaimed.
- **No STE digest grammar / drafted-reply / expand-rough-words.** Mobile steering
  is "type into the session," not "tap the draft the membrane wrote."
- **No verdict ledger / autonomy ladder.** Permission modes are static
  (Manual→Accept edits→Auto→Bypass), not earned per action class from evidence.
- **No attention compression across a fleet.** The sidebar lists sessions; the
  Summary view mode is per-session. Nothing triages *what deserves you*.
- **Provider lock.** All of it requires a claude.ai account and only supervises
  Claude. Codex/opencode/Crush sessions are invisible to it.
- **The terminal itself.** Anthropic's surface is an Electron-family desktop app;
  their own power-user guidance recommends Ghostty
  ([power user tips](https://support.claude.com/en/articles/14554000-claude-code-power-user-tips)).
  Anthropic shows no signal of shipping a terminal emulator.

### Risk verdict
The risk that "Anthropic ships the orchestration layer themselves" has **already
substantially happened** for the mainstream: sessions dashboard ✅, worktree
isolation ✅, diff review ✅, phone answering ✅, cloud persistence ✅. What
rides on rook's plugins/claude + attention + digests today (transcript watching,
STE digests, attention raise) overlaps Anthropic's shipped surface except for the
independent-model compression and the local-first/no-account stance. The wedge
cannot be "you can answer Claude from your phone" — that is now a first-party
feature. It has to be something Anthropic is structurally unlikely to build:
a native terminal, provider-neutral supervision, uncorrelated oversight, and a
review surface better than a conventional diff pane.

---

## 3. Other agent harnesses with real traction

### The direct competitor: cmux
[github.com/manaflow-ai/cmux](https://github.com/manaflow-ai/cmux) — **this is
the product occupying "the terminal for coding agents on macOS" today.**
- Native macOS, Swift/AppKit, **built on libghostty** (first shipping libghostty
  app — [Mitchell's post](https://mitchellh.com/writing/libghostty-is-coming),
  [HN](https://news.ycombinator.com/item?id=46116251)). No Electron. Reads
  existing Ghostty configs.
- Launched Feb 2026 (YC), **25.7k stars, 2.2k forks** as of Aug 2026, nightly
  builds, active Discord.
- Features: vertical tab sidebar showing **git branch, PR status, cwd, listening
  ports, latest notification per workspace**; **notification rings** (agent needs
  attention — via OSC 9/99/777 + hooks for Claude Code/Codex/OpenCode + `cmux
  notify` CLI); splits; **embedded scriptable browser** (snapshots, clicks, JS
  eval — agents verify their own UI work); **SSH workspaces**; **session
  restoration** (layout, dirs, scrollback, agent state); programmable CLI +
  socket API; Claude Code Teams integration.
- GPL-3.0, free; ~$180/yr "Founder's Edition" (early access to AI features,
  **iOS app in beta**, cloud VMs, **voice mode**) — chasing rook's phone/voice
  territory too.
- Lacks: detach/persistence (GUI-only), any editor, Linux/Windows.
- Reviews crown it: [alexdunlop's five-terminal test](https://www.alexdunlop.com/writing/best-terminal-for-claude-code)
  picks cmux as the Mac winner; [agentsroom](https://agentsroom.dev/blog/best-terminal-for-agentic-coding),
  [dev.to](https://dev.to/arshtechpro/cmux-the-native-macos-terminal-built-for-running-ai-coding-agents-52il),
  [explainx](https://www.explainx.ai/blog/cmux-terminal-ai-coding-agents-2026) similar.

### Conductor
[conductor.build](https://conductor.build) — macOS app running Claude Code /
Codex / Cursor agents in parallel, one **isolated git worktree per agent**, with
a review-and-merge UI. YC S24, **$22M Series A**, ~6 people, free today (uses
your existing Claude login), paid collaboration features planned.
([coldiq review](https://coldiq.com/tools/conductor),
[rywalker](https://rywalker.com/research/conductor),
[codepick](https://codepick.dev/en/guides/conductor-build-intro/))

### Vibe Kanban
Most-starred kanban-style orchestrator: cross-platform CLI + web UI, plan tasks,
run agents in parallel, **visual code review on a board**. Web UI means it's
remotely reachable by default.
([augmentcode roundup](https://www.augmentcode.com/tools/open-source-agent-orchestrators),
[nimbalyst](https://nimbalyst.com/blog/best-agent-management-tools-2026/))

### Claude Squad
Terminal-first: **tmux + git worktrees under one TUI**, one isolated workspace
per task, works over SSH on a headless box. The "I already live in tmux" answer.
([parallelcode comparison](https://parallelcode.app/compare/))

### opencode (SST)
[160k+ stars, 900 contributors, claimed 7.5M monthly active devs](https://tech-insider.org/ie/opencode-160k-github-stars-2026/);
MIT; 75+ providers; ships as TUI + Tauri desktop app + VS Code extension. Ranked
#1 in LogRocket's June 2026 AI dev tool power rankings, ahead of Claude Code.
This is a *harness* (Claude Code competitor), not a terminal — but it proves the
provider-neutral, local-first, open-source position has enormous pull.
([developersdigest](https://www.developersdigest.tech/blog/opencode-developer-guide-2026))

### Crush (Charm)
~27k stars (Jan 2026: 20.7k), successor to the original opencode; multi-model,
LSP context, MCP, agent skills. Another harness, not a surface.
([codexpedite](https://codexpedite.com/crush-by-charmbracelet-an-honest-deep-dive-into-the-multi-model-ai-coding-agent/),
[comparison](https://ian729.github.io/silver-umbrella/ai/cli/tools/crushcli/opencode/2026/02/23/crush-cli-comparison.html))

### Aider
Still maintained (release Feb 2026) but positionally faded — cited mainly as the
thing people migrate *from* when they want richer UI, background agents, or team
workflows. ([tembo alternatives](https://www.tembo.io/blog/aider-alternatives))

### Recurring UX patterns across all of them
1. **Git worktree per agent** — universal, from Anthropic to Conductor to Claude
   Squad. rook's `ctl worktree add` is the right primitive; everyone has it.
2. **Diff review with inline comments → agent revises → review the delta** —
   Anthropic desktop, Conductor, Vibe Kanban. All conventional diffs; none do
   NEXT.md's attention compression / classification / conditional approval.
3. **Attention signals**: notification rings (cmux), sidebar badges, status dots,
   OS notifications, push notifications. Table stakes now.
4. **Session restore** (cmux) and **cloud persistence** (Anthropic, Oz).
5. **Approval queues**: permission prompts routed to phone (Anthropic Remote
   Control/Dispatch), policy filters (Oz enterprise controls).
6. **Phone/remote answering exists in**: Anthropic (first-party, free with plan),
   cmux (iOS beta, paid), Vibe Kanban (web UI), plus a cottage industry of
   notifier apps. **It is no longer a differentiator; it is a checkbox.**
7. **Scriptability**: cmux socket API, Oz CLI/webhooks, Claude Squad tmux — the
   power crowd expects to drive the surface programmatically. (rook's `ctl` and
   plugin vocabulary fit this well.)

---

## 4. The switcher map — table stakes for rook's first 1000 users

Target: Ghostty/Alacritty/iTerm power users who live in Claude Code. What the
reviews and threads say they filter on
([alexdunlop's criteria](https://www.alexdunlop.com/writing/best-terminal-for-claude-code),
[HN Ghostty+tmux setup thread](https://news.ycombinator.com/item?id=44470829),
[Ghostty sessions discussion](https://github.com/ghostty-org/ghostty/discussions/9007)):

| Criterion | State of the art | rook today |
|---|---|---|
| Raw latency/perf | Ghostty is the bar | **Ahead** (8.5ms fullscreen, beats Ghostty on cat-test) — rook's one clearly-won axis |
| Agent-attention signals | cmux rings, badges | Partial (plugins/claude attention, pane activity) — needs to be as glanceable as cmux's rings |
| **Session persistence / survive quit** | tmux; cmux restores layout+scrollback; Ghostty sessions **in development** (Mitchell: libghostty-based tmux replacement, teased 2026 — [X](https://x.com/mitchellh/status/2001396290337583268), [discussion #12571](https://github.com/ghostty-org/ghostty/discussions/12571)) | **Missing — accepted regression ("shells die with the app")**. The alexdunlop review calls detach/reattach "irreplaceable" and it's the axis every tool is judged on |
| Remote/SSH workflows | cmux SSH workspaces, Anthropic SSH sessions, Claude Squad over SSH | **Missing — accepted regression** |
| Worktree-per-agent | Universal | Have (`ctl worktree`) |
| Diff/review surface | Anthropic desktop inline comments | Missing (stripped; the thesis) |
| Phone answering | Anthropic first-party | Missing (rails exist, no payloads) |
| Signing/notarization | Everyone else is notarized | **Ad-hoc signed** — a real filter for the curl-averse; also blocks word-of-mouth installs |
| Self-update | Standard | Owed (install.sh re-run) |
| Scriptable API | cmux socket API | Have (ctl, plugin protocol) |
| Editor in the surface | **Nobody has one** (cmux: none; desktop app: spot-edit pane) | **Have — vim-shaped editor + LSP.** rook's second clearly-won axis |

Key tension: the two accepted regressions (no persistence, no remote) are
precisely the top two criteria the switcher reviews rank on. And the substrate
incumbent is closing in: **Ghostty's stated goal is a libghostty-based tmux
replacement with detachable sessions embedded in the GUI** — when that ships,
"Ghostty + sessions" erases much of any latency-adjacent pitch, and cmux (on
libghostty) likely inherits it too.

Also worth naming: the Ghostty+tmux+worktrees pattern is so entrenched that
multiple 2026 guides teach exactly rook's target workflow inside incumbent tools
([bswen guide](https://docs.bswen.com/blog/2026-03-12-best-terminal-setup-claude-code/),
[frr.dev](https://www.frr.dev/posts/claude-code-ghostty-worktrees-mac-setup/),
[andrewbaker](https://andrewbaker.ninja/2026/06/05/ghostty-is-the-terminal-claude-code-deserves/)).
Switching cost is real; a marginally-better terminal won't move them. Something
they can't compose from Ghostty+tmux+scripts might.

---

## 5. Positioning verdict

**"The default terminal for Claude Code" is no longer an open position — cmux is
sitting in it.** Native macOS, libghostty (same perf lineage), free, GPL, YC-
backed, 25k+ stars, six months of mindshare, and it wins the exact reviews that
would have crowned rook. Competing for that title head-on means out-executing a
funded team on their own turf while rook still lacks their table stakes (SSH,
session restore, notarization) and carries regressions (no persistence) that the
category's reviewers explicitly rank on. Meanwhile the phone/orchestration half
of the old wedge got shipped by Anthropic itself (Remote Control, Dispatch,
sessions sidebar) — "answer your agent from your phone" is now a first-party
checkbox, not a moat.

**What the evidence says is still unclaimed:**

1. **The review problem is universally named and nowhere solved.** Every 2026
   trend piece says review is the bottleneck
   ([beyond.addy.ie](https://beyond.addy.ie/2026-trends/)); every tool answers
   with the same conventional diff pane + inline comments. Nobody ships NEXT.md's
   actual ideas: attention compression (classify 5,000 lines down to the 60 that
   need a human), category-specific review strategies, local-vs-global approval,
   conditional approval, whiteboard-not-typewriter annotations, review state that
   survives agent iteration. That thesis is *more* differentiated today than when
   it was written, because the baseline (plain diffs) has commoditized.
2. **Uncorrelated oversight.** Anthropic will never ship a cheaper non-Claude
   model auditing Claude; Warp/Oz sells governance to enterprises, not judgment
   to individuals. The membrane-on-a-different-model + verdict ledger is
   structurally rook's alone.
3. **The editor in the loop.** No agent surface has a real editor. Review that
   ends in "now go fix the nit yourself, in place, with LSP" — without leaving
   the surface — is something neither cmux (no editor) nor the desktop app
   (spot-edit pane) nor Conductor can do. rook already built the hard part.

**Recommended reframe:** keep the terminal as the *delivery vehicle and proof of
craft* (the 8.5ms story earns the switcher's respect and the install), but make
the wedge **"the review surface for agent work"** — the place where a person
spends the 6-hour review day NEXT.md imagines, across N sessions, with attention
compressed by an independent model, verdicts recorded, and a real editor one
keystroke away. Phone answering ships as parity (the rails exist; render
digests on them), marketed as "local-first Remote Control that also works for
Codex/opencode," not as the headline.

**Two non-negotiable payments before any of it lands with the first 1000:**
persistence (the tmux-style split OWED.md already wants — ideally landing before
or alongside Ghostty's own sessions feature, or explicitly interoperating with
tmux) and notarization. The switcher reviews treat detach/reattach as the
category's one irreplaceable feature, and an unsigned binary filters out half
the funnel before the thesis is ever seen.

**Honest caveat:** this reframe is close to what Conductor and the Claude desktop
app describe ("streamlines review and merging"), so the differentiation must be
the *depth* of the review model (compression, categories, conditional approval,
verdicts) — shipped and dogfooded — not the label. If rook ships a conventional
diff pane and calls it a review surface, it loses to five incumbents at once.

---

## 6. cmux teardown (source + issue tracker, 2026-08-07)

Prompted by Seth's pushback: "the actual UX of cmux is kinda terrible... it isn't
an IDE replacement, it's more like tmux for people that don't know about tmux."
Method: shallow clone of [manaflow-ai/cmux](https://github.com/manaflow-ai/cmux)
at `scratchpad/angles/cmux-src` (387MB, GPL-3.0), full source survey, plus issue
tracker mined via `gh` sorted by reactions. No install, no run.

### 6.1 What it actually is (architecture)

**A serious native app, not a wrapper.** ~1.1M lines of Swift; AppKit-first
(513 files import AppKit vs 255 SwiftUI) with SwiftUI leaves; ~70 local SPM
packages (`CmuxTerminal`, `CmuxPanes`, `CmuxSidebar`, `CmuxCommandPalette`,
`CmuxCanvas`, `CmuxDiffComments`, …). Terminal rendering is a **forked
libghostty** (`GhosttyKit.xcframework`, fork documented in `docs/ghostty-fork.md`
— they patched a keyboard copy-mode selection C API back in after upstream
removed it). **~85–90% of the visible UI is native**; WKWebView carries exactly
four surfaces: the diff viewer, markdown viewer, agent-chat panel, and the user
browser pane (React 19 + `@pierre/diffs`, `webviews/` ~18k LOC).

Satellite components that inflate the repo but aren't the Mac app: a **Go remote
daemon** (SSH workspaces only — the sole real persistence in the product), a
separate **Rust TUI multiplexer** (`cmux-tui`, ~470k LOC with vendor, tmux-style
`Ctrl-b` leader — *unreferenced by the Mac app*; it backs `cmux-browser`), a
**full Chromium fork mid-import** (`cmux-browser/`), a shipping **iOS companion
app** (26k LOC, fastlane), a Cloudflare presence service, and a Bun agent-chat
sidecar. The company is visibly building a multi-product surface, not polishing
one.

### 6.2 Interaction surface — deeper than the "dashboard" caricature

Correcting my own first pass and partially correcting Seth:

- **Keyboard model**: ~150 actions in a `ShortcutAction` enum, all
  user-configurable via `~/.config/cmux/cmux.json` + a GUI recorder, with
  **VS Code-style `when` clauses** (a real 630-line expression parser:
  `terminalFocus || browserFocus`, regex, comparisons) and **two-stroke chords**
  (`gg`, `]f`, `[f` ship as diff-viewer defaults). No leader key; everything is
  ⌘/⌃/⌥-modified, macOS-idiomatic. Near-complete keyboard drivability —
  palette (`⌘⇧P`, nucleo fuzzy matcher via Rust FFI, 143 command contribution
  sites), directional pane focus, surface movement, sidebar modes. Notable gap:
  **no keyboard pane-resize** (mouse-drag or CLI only; issue open at 19
  reactions).
- **Copy mode is real vim**: `hjkl`, `v`/`V`, `y`, `gg`/`G`, `0`/`^`/`$`,
  `{`/`}` = jump-by-shell-prompt, `/` + `n`/`N`, `⌃U`/`⌃D`, numeric count
  prefixes (`CmuxTerminalCore/CopyMode/`, 10 files). Plus native `⌘F` scrollback
  search and a global cross-workspace search including browser page text.
- **Splits**: arbitrary nesting (recursive bonsplit tree), zoom (`⌘⇧↩`),
  equalize — and an alternative **freeform canvas mode** ("static splits stop
  scaling past a handful of live agent sessions"). Model: window → workspace
  (vertical sidebar tab) → pane (split region) → surface (horizontal tab).
- **Diff review is more than a viewer**: side-by-side *and* unified, **inline
  comments that re-anchor by line text when the diff regenerates**
  (`anchored | moved | outdated`), and — the interesting part — a
  **comment-submission pool**: saved review comments appear as a `[N comments]`
  chip on every terminal TextBox in the workspace, and whichever prompt submits
  first consumes the pool and appends the comments to the agent's next turn
  (`Sources/DiffCommentSubmissionPool.swift`). That is NEXT.md's
  review→annotate→agent-revises loop in embryo. **But no partial approve/
  reject/stage** — zero staging verbs in the webview's action set; it's a
  viewer + comment layer, and it's a webview, not native.
- **Browser pane**: WKWebView, dual-purpose — user browsing (with cookie/session
  import from 20+ browsers) and a Playwright-shaped automation API for agents
  (49 verbs, accessibility-tree snapshots with stable refs; CDP-only features
  honestly return `not_supported`). Design mode turns live-page edits into a
  formatted agent prompt.

### 6.3 Where Seth's claim is confirmed

- **Local persistence is replay theater.** `SessionPersistence.swift` (2,053
  lines) restores layout, divider positions, cwd, drafts, and **4,000 lines /
  400k chars of scrollback — by writing it to a temp file and having the newly
  spawned shell replay it**. The process is dead; you get pixels back. Agent
  panes get `claude --resume <id>`-style rebinding instead. Only **remote SSH
  ptys** genuinely survive quit (the Go daemon). So cmux has rook's exact
  "shells die with the app" regression, mitigated by replay + agent-resume.
  Users feel it: persistence of tabs/layouts (50 reactions), tmux-resurrect-
  style restore (35), zellij integration "for live process preservation across
  cmd+Q" (23), "workspaces gone on reboot" reports, and — verbatim Seth — a
  user in the favorite-features thread: *"It feels weird if I use tmux inside
  cmux."*
- **The editor is a bare NSTextView.** `FilePreviewTextEditor.swift` (477
  lines): plain text, `⌘S`, soft-wrap toggle. **No syntax highlighting, no
  tree-sitter, no LSP, no Monaco/CodeMirror** (highlighting exists only inside
  the diff webview; a community PR recently added tree-sitter highlighting to
  the *preview* panel). Users ask: "Text editor pane type" (14), "IDE-level file
  editor" — one comment: *"Using something like Vim is very inconvenient; I
  need features like a file tree."* A community fork embeds VS Code *web* in
  the browser pane to fill the hole.
- **And the roadmap declines both, explicitly.** All six `plans/` design docs
  are iOS/cloud/multi-Mac (local-first sync protocol, multi-Mac workspaces,
  iroh P2P transport, cloud VM rollout). `docs/` direction: presence service,
  mobile state sync, remote daemon, custom sidebars. **No editor plan, no
  review-depth plan, anywhere.** Their stated identity is supervising many
  agents; the diff viewer and editor exist to serve that loop, not to grow
  into an IDE.
- **Quality wobbles at daily-driver load** (issues by reactions): flaky
  "Running/Needs Input" sidebar indicators (35 — the *core feature*), flaky
  Claude notifications (20), severe OOM memory leak (22, closed), split-pane
  crashes incl. an Intel TOCTOU still open, key-repeat render freezes,
  **"Input latency is too high" (13, open)** and "cmux+ssh+tmux seriously
  laggy where Ghostty is not" (15) — despite libghostty, the chrome costs
  them the latency crown rook measures itself by. Ghostty-config interop is
  partial (31-reaction thread; IME users report shortcuts dead).
- **A trust incident rook should never repeat**: cmux bundles its own Claude
  wrapper, and update 0.64.0 **forced bypass-permissions mode** (27 reactions,
  closed); a separate issue notes the wrapper blocks Claude's own new agents
  dashboard. Wrapping the harness puts you in the blast radius of every
  harness change — an argument for rook's transcript-watching/PTY-owning seam,
  which needs no wrapper.

### 6.4 Corrected verdict on the two threat claims

**(a) "cmux is a better product for the same job" — true only for the
supervision-dashboard job, and shallower than the stars suggest.** For
spawn/watch/notify across many agents it is genuinely good and genuinely
native. But it is not an IDE replacement and is not trying to become one; its
review is a webview viewer with comments; its editor is TextEdit-with-⌘S; its
persistence is scrollback replay; its measured latency draws open complaints.
Seth's "tmux for people who don't know tmux" is right about the *job* (the top
feature requests are literally tmux features) but slightly underrates the
craft — the copy mode, when-clause keymap, and comment-pool loop are real
work. The correction that matters: **cmux's ceiling is strategic, not
structural.** Native Swift could grow an editor; their roadmap shows they've
chosen iOS/cloud/fleet instead.

**(b) "cmux occupies the label and the funnel regardless of depth" — true and
the operative threat.** Free, GPL, YC, 25.7k stars, wins the category
reviews, ships nightly, has a Discord and an iOS beta. Anyone searching
"terminal for coding agents on macOS" lands there first. rook cannot win a
label fight on sidebar polish, notification rings, or iOS — cmux is ahead and
accelerating on exactly those axes.

**What this means for the wedge:** the label matters less than it appeared,
because holding it hasn't required depth — and the depth cmux skipped is
precisely rook's built strength. The users cmux leaks (its own issue tracker
names them) want: real persistence, real keyboard-first workflows, a real
editor, deeper review, honest latency. That is rook's loop on contact:
**review with a vim editor + LSP one keystroke away, at measured-best latency,
with attention compressed by an independent model** — none of which is on
cmux's roadmap. Two sharp edges to steal/beat: their comment-pool-to-prompt
mechanism is the best shipped fragment of NEXT.md's loop (rook must do it
better — anchored, categorized, verdict-recorded, native); and their forced-
bypass incident is a standing advertisement for rook's no-wrapper,
PTY-and-transcript seam. The deeper loop wins the same users on contact —
*provided* rook pays the persistence and notarization stakes that cmux's own
users list as their top asks.

---

## Source index

- Warp: [G2](https://www.g2.com/products/warp-warp/reviews) ·
  [dev.to review](https://dev.to/jovan_chan_9500711396d4e6/warp-terminal-review-2026-open-source-ade-the-20-build-plan-and-who-should-actually-pay-for-it-5cin) ·
  [open-source HN](https://news.ycombinator.com/item?id=47937349) ·
  [login lifted HN](https://news.ycombinator.com/item?id=42247583) ·
  [Oz launch](https://www.warp.dev/newsroom/2026/2/10/warp-launches-oz-the-orchestration-platform-for-cloud-coding-agents) ·
  [Oz docs](https://docs.warp.dev/agent-platform/) ·
  [SD Times on Oz](https://sdtimes.com/ai/warp-updates-oz-to-help-enterprises-orchestrate-coding-agents-across-any-model-or-harness/)
- Claude Code: [desktop docs](https://code.claude.com/docs/en/desktop) ·
  [mobile docs](https://code.claude.com/docs/en/mobile) ·
  [MacRumors on redesign](https://www.macrumors.com/2026/04/15/anthropic-rebuilds-claude-code-desktop-app/) ·
  [remote control guide](https://aiforanything.io/blog/claude-code-remote-control-guide-2026) ·
  [push notifications](https://claudcod.com/blog/claude-code-push-notifications/) ·
  [GH issue #60433](https://github.com/anthropics/claude-code/issues/60433)
- cmux: [GitHub](https://github.com/manaflow-ai/cmux) ·
  [alexdunlop five-terminal test](https://www.alexdunlop.com/writing/best-terminal-for-claude-code) ·
  [agentsroom](https://agentsroom.dev/blog/best-terminal-for-agentic-coding) ·
  [dev.to](https://dev.to/arshtechpro/cmux-the-native-macos-terminal-built-for-running-ai-coding-agents-52il)
- Orchestrators: [Conductor review](https://coldiq.com/tools/conductor) ·
  [rywalker on Conductor](https://rywalker.com/research/conductor) ·
  [Augment orchestrator roundup](https://www.augmentcode.com/tools/open-source-agent-orchestrators) ·
  [parallelcode comparison](https://parallelcode.app/compare/) ·
  [nimbalyst](https://nimbalyst.com/blog/best-multi-agent-coding-tools-2026/)
- Harnesses: [opencode 160k stars](https://tech-insider.org/ie/opencode-160k-github-stars-2026/) ·
  [opencode guide](https://www.developersdigest.tech/blog/opencode-developer-guide-2026) ·
  [Crush deep dive](https://codexpedite.com/crush-by-charmbracelet-an-honest-deep-dive-into-the-multi-model-ai-coding-agent/) ·
  [aider alternatives](https://www.tembo.io/blog/aider-alternatives)
- Ghostty direction: [libghostty is coming](https://mitchellh.com/writing/libghostty-is-coming) ·
  [Mitchell on tmux replacement](https://x.com/mitchellh/status/2001396290337583268) ·
  [sessions discussion #9007](https://github.com/ghostty-org/ghostty/discussions/9007) ·
  [session mgmt redux #12571](https://github.com/ghostty-org/ghostty/discussions/12571)
- Setups: [HN Ghostty+tmux thread](https://news.ycombinator.com/item?id=44470829) ·
  [bswen setup guide](https://docs.bswen.com/blog/2026-03-12-best-terminal-setup-claude-code/) ·
  [frr.dev worktrees setup](https://www.frr.dev/posts/claude-code-ghostty-worktrees-mac-setup/) ·
  [power user tips](https://support.claude.com/en/articles/14554000-claude-code-power-user-tips)
