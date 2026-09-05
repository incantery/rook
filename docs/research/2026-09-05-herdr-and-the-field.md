# rook against herdr, and against the field — 2026-09-05

A second deep pass, written to set the next few days. Sources: herdr
0.8.2 installed here plus a shallow clone of `herdrdev/herdr` at
`6c52aad` (2026-09-05), rook `main` at `c2f2e5c`, and the public
material for cmux, zellij 0.45, tmux 3.7/3.8, Ghostty 1.3, hrdx,
workmux, dmux, claude-squad, Superset, Conductor, Vibe Kanban, amux,
Termdock. Numbers are from `gh api` on the day.

## Where the two stand

| | rook | herdr |
|---|---|---|
| age | mux pivot 08-24 (12 days); repo since 07-11 | 2026-03-27 (5 months) |
| size | 8.2k Zig (`mux/`) + 5.2k Go | 225k Rust, 3,046 tests |
| VT | ghostty-vt, in-process, Zig dep | libghostty-vt 1.3.2 vendored via C bindings, 2 local patches |
| platform | macOS only (`os_unfair_lock`, `proc_pidpath`) | macOS, Linux, Windows |
| stars / cadence | — / brew cask v0.46.0 | 35.5k / stable every 2–3 weeks, preview builds between |
| server | outlives the glass; resurrect opt-in (`[mux] restore`) | outlives the glass; snapshot restore + native agent resume + pty **handoff across binary upgrade** |
| chrome | tab bar, 2-panel left rail (pushed), pins rail | sidebar (spaces + agents, row templates, compact collapse, priority sort, ≤64-col mobile layout), tab bar with right-side status entries, toasts |
| agent awareness | **presence only** (`fgName` = `claude`); state is a producer's job (verad) | 23 agents; TOML screen manifests over the bottom buffer + OSC title + OSC 9;4; hook integrations for 17; five states with done≠idle (seen semantics) |
| notifications | none | toast / terminal / system, delayed re-check, sounds, `open_notification_target` |
| control surface | `state`/`watch` snapshot feed, `capture`, `side`, `popup`, `nav`, `new -q`, worktree verbs | NDJSON socket, `session.snapshot` + `events.subscribe`, pane split/read/send/wait-output, agent start/prompt/wait/explain, layout export/apply, plugins, `herdr --skill` |
| second glass | browser peer client on the same protocol (`web/`) | none (SSH thin client instead) |
| phone | vera iOS (read panes, dictate, tap capabilities) | none |
| worktrees | Go `rook worktree` ls/new/open/merge/rm, conventions copy/link | create/open/remove, grouped under parent in the sidebar, `worktree.*` events |

Both rest on ghostty's VT. herdr's two patches
(`vendor/libghostty-vt.patches.md`) are worth a look: it forces DEC
mode 2027 grapheme clustering on by default so flags and ZWJ families
sit in one cell, and it adds a scalar query for modifyOtherKeys mode 2
so it can request printable key releases without formatting the
screen. Check whether rook's terminals start with 2027 on.

## The field, in one paragraph each

**herdr** is the product rook's `docs/surfaces.md` says rook is the
substrate for. Its bet is agent *state* from the screen, and its open
issue list is the bill: `3467` stale busy title outranks a modal,
`3530` Gemini reads idle while generating, `3657` Cursor reads idle in
a narrow pane, plus fd leaks (`3527`, `3621`) and a launchd respawn
loop (`3626`). The AGENTS.md is instructive: "state is separated from
runtime", "render is pure", multiplicative-path budgeting, and a
"runtime/client boundary guardrail" that says exactly what
`surfaces.md` says: the TUI is one client of a server-owned protocol.

**cmux** (26.8k, Swift + libghostty, macOS) is the native-app answer.
Its notification model is the most developed in the field: sources are
OSC 9/99/777, `cmux notify`, agent hooks and prompt-turn detection;
effects are desktop/sound/pane-flash/record/mark-unread/reorder;
`⌘⇧U` jumps to the latest unread and `⌃⌘U` marks-and-advances. Custom
sidebars are declarative JS/Swift/JSON scene graphs over **pull**
bindings that refresh ~1 s; external programs cannot push. Docs tree
shows where it is going: workspace groups, a "Feed" of inline
approvals, presence, an iOS app, remote daemons.

**zellij 0.45** (08-20) consolidated OSC 9/99/777 desktop
notifications, OSC 133 prompt jumping, kitty graphics, nested sessions,
a mobile PWA web client, `--no-focus` on the CLI. **tmux 3.7/3.8** added
floating panes, built-in light/dark themes, `pane-command-finished`
and `pane-shell-prompt` hooks, monitor hooks that fire when a format
changes. **Ghostty 1.3** (03-09) added command-finish notifications,
scrollback search, key tables (tmux-style modal binds), AppleScript.
Every emulator and mux in the field converged this summer on the same
three signals: the OSC title, OSC 9;4 progress, OSC 9/99/777
notifications.

**hrdx** (Go, 47 stars, 07-31) is the closest philosophical peer:
"minimal and lightweight", real ptys, sidebar spinners from title
substrings, no notification daemon. **workmux / dmux / claude-squad /
ittybitty** are the worktree-per-task layer over tmux; workmux's
dashboard (live preview, diff vs main, patch mode, sort waiting > done
> working) is the best of them and its `.workmux.yaml` copy/symlink
plus `post_create` is rook's `[worktree] copy/link` with hooks.
**Superset / Conductor / Vibe Kanban** are Electron IDEs around the
same worktree model with diff review; Vibe Kanban is sunsetting.
**amux** (Rust over tmux, iOS app) is the control-plane end: kanban,
watchdog that restarts crashed agents and compacts context, REST API.
It lists herdr as an alternative backend to tmux, which is where rook
should want to sit too.

The reviewers agree on the ranking of what matters (agentsroom,
getbeam, amux's matrix): per-agent state first, notifications with
unread second, worktree isolation, persistence, remote or phone.

## What rook has that the field does not

- **The publish-only seam.** herdr's sidebar is built in; cmux's is
  pull-bound and cannot be fed by a process. rook's rail is the only
  one a stranger can write from outside with one JSON line per frame,
  and the state feed hands the same bytes back out. Keep this; it is
  the thesis.
- **Presence without interpretation.** herdr's bug list is the argument
  for rook's line: rook says a session is there, a producer says what
  it is doing. verad's `fleet/liveness.go` reads evidence rook cannot
  see (worktree writes, the Claude hook's Stop/Notification events)
  and produces states rook never has to defend.
- **The browser as a peer client** on the mux protocol, and vera's
  phone. Only amux ships a phone today; cmux is building one.
- **Numbers.** `mux/bench`: 0.69× tmux drain time, 6.9 MB RSS vs
  11.1 MB, input→frame p50 52 µs. And a conformance corpus diffed
  against tmux. herdr publishes no numbers.

## What rook is missing, ranked by cost against value

**1. The VT already tells rook what herdr scrapes for.** In
`mux/src/pane.zig` the handler leaves `.bell`, `.desktop_notification`,
`.title_changed`, `.pwd_changed` and `.progress_report` as `null`.
herdr's highest-priority Claude rule (`osc_title_working`, priority
1100) is the OSC title: a spinner glyph prefix means busy, `✳ ` means
idle; OSC 9;4 `4;0` means done. That is the program telling the
terminal, not rook reading a screen, so publishing it does not cross
rook's "never interprets" line. Publish per pane in the state feed:
`title`, `progress` (state + percent), `notified` (last OSC 9/99/777
body and time), and take `cwd` from OSC 7 when a shell offers it
instead of the 2 s proc drift. Today a Claude `Notification` hook that
emits OSC 777 vanishes inside rook; in Ghostty, zellij, cmux and tmux
it rings. One to two days, and it makes the dead `docs/attention.md`
feed mux-native instead of a jsonl file nobody writes.

**2. Unread is rook's fact, and there is no jump.** The item vocabulary
already has `unread` (the accent ●), but nothing marks it read.
herdr's done≠idle split and cmux's rings both hinge on one thing rook
alone knows: whether the pane was on the glass and focused since the
signal. Own it: a pane becomes unread on a notification, a bell, or a
title flip to idle while not focused; focusing it clears it; publish
`panes[].unread` and paint it on the tab chip and the rail. Then one
verb, `prefix-u`, jumps to the oldest unread pane across workspaces,
the way `⌘⇧U` does in cmux. Rides on 1. The attention verb is the
single feature every review ranks first or second.

**3. A front door agents can drive.** herdr's `--help` ends with "Are
you an AI?" and three URLs, `herdr --skill` prints the skill, and a
Claude inside a pane can `pane split --current --direction right --cwd
"$PWD" --no-focus`, `pane run`, `pane wait-output --match`, `agent
prompt --wait`. rook's wire has `attach_block`/`stdin`/`block_cmd`/
`capture`/`nav`/`popup` and `new -q`, so most of this is verbs on the
Go front door, not engine work: `rook split [--no-focus] [--cwd]`,
`rook send <pane> <text|keys>`, `rook read <pane> [--lines]` (capture
already), `rook wait <pane> --match|--serial`, `rook --skill`, and
`$ROOK_MUX_PANE` documented as the caller's context. One day, and it
is the thesis in `README.md` ("agent-legible") made true at the prompt.

**4. Debris from the pivot** (verified still true today): `README.md`
describes a bare tmux on `-L rook`; `docs/attention.md` says "tmux
session name"; `internal/tmux`, `internal/sessions`,
`internal/attention`, `internal/agents` (2.3k lines) still ship and
shell out to a tmux that is not there, so the worktree TUI's agent
column reads empty. (The `rook claude-hook` wiring in
`~/.claude/settings.json` is already gone.) Half a day, and it stops the
next reader (or fleet agent) from re-deriving the tmux era.

**5. Resume, not just restore.** rook's restore replays sessions,
windows and cwds. herdr and cmux both relaunch the agent's own
conversation (`claude --resume <id>`) from a session id a hook wrote
down. rook should stay dumb about it: a producer that knows the id
pushes `resume` on the pane (verad already receives `SessionEnd` and
has the session id), rook records it beside the cwd, and restore runs
it. Two days, after 1–3.

**6. Upgrade without killing the fleet.** The server outlives the
glass but not the binary: every `brew upgrade` is `rook kill && rook`,
and every pane dies with it. herdr hands ptys to the new server
(experimental, loses in-flight requests); with rook's releases now
biweekly this is the daily-driver pain that will bite first. Phase it:
pass pty fds over the socket with `SCM_RIGHTS`, re-parse from a
capture, accept losing scrollback. Larger; next week's question.

**7. Smaller, cheap, and very rook:** `prefix-e` opens the pane's
scrollback in `$EDITOR` (herdr, one popup); `prefix-?` help sheet
(rook had which-key pre-tmux, the mux has none); non-modal floating
panes (tmux 3.7) are the `overlay` place already in `surfaces.md`;
light/dark via OSC 10/11 answers already landed 08-25, mode 2031
updates would finish it.

**Not now, on purpose:** declared `[[surface]]` blocks and plugin
processes (the design is right and the one producer is verad; write a
second producer before generalising), row templates and custom
sidebars (cmux and herdr both grew them; rook's push model makes them a
producer's problem), Linux (two syscalls and a lock, but nobody but
Seth runs rook yet), layout export/apply (the environment graph will
return when it earns it).

## Done the same day

Items 1–4 landed on 2026-09-05, in one pass: `pane.zig` now hears all
five signals and `Server.pollSignals` publishes them; `unread` is a
pane's own channel, cleared by looking, worn by the tab, the rail and
the worktree manager, with `prefix-u` / `rook jump`; the front door
grew `read/send/run/key/wait/split/window/focus/close-pane`,
`$ROOK_MUX_PANE` became the pane's id, and `rook --skill` prints the
manual; `internal/{tmux,sessions,attention,agents}` are gone and
`README.md` / `docs/attention.md` describe the mux. Next: resume-on-
restore through a producer, then the upgrade handoff.

## The next few days

1. Read the VT's own signals (title, progress, notification, bell, pwd)
   into the state feed.
2. Unread as rook's channel, `prefix-u` to the oldest one, ● on chip
   and rail.
3. The agent front door: split/send/read/wait verbs, `rook --skill`,
   "Are you an AI?" in `--help`.
4. Sweep the tmux-era debris.

Then resume-on-restore through a producer, then the upgrade handoff.
