# rook PERF — the scoreboard

What gets written down gets defended (inherited from ../docs/PERF.md, and
so are the rules: like against like, state the load condition and grid,
tails matter more than medians). Reproduce any row with `./bench.sh`;
live numbers anytime via `printf 'stats\n' | nc -U /tmp/rook.sock`.

The instrument: always-on rings/counters (src/stats.zig), zero-alloc on
hot paths. Key latency is TRUE key-to-photon — NSEvent.timestamp (kernel
receipt) to CAMetalDrawable.presentedTime (glass), same clock, consumed
only by a frame that carried the echo (a dirty grid), never by an idle
repaint. The webview app could only ever measure to DOM-commit.

## Current — 2026-07-27, first day of numbers

Machine: Apple M3 Max, 120Hz display. ReleaseFast (dep optimize flows to
ghostty-vt — see the build.zig comment for what happens if it doesn't).
Grid 67×42 (WM-assigned tile), FiraCode Nerd Font Mono 13pt. Single
session, no scrollback viewer yet — re-run as features land.

| metric | value | condition |
|---|---|---|
| key → photon p50 / p95 | **15.5 / 26.4 ms** | quiet prompt, 60 keys @ 80ms, windowed |
| key → photon p50 / p95 | **8.5 / 14.4 ms** | 〃 FULLSCREEN (direct scan-out, no compositor) |
| present lag (commit→photon) p50 | 13.8 ms windowed / **7.0 ms fullscreen** | the display pipeline's share, measured |
| key → commit p50 / p95 | **2.3 / 3.3 ms** | 〃 (CPU-side share incl. pty round-trip) |
| key → photon p50 | **6.9 ms** | UNDER full-width firehose (n=3 — small) |
| sustained pipeline throughput | **190 MB/s** | `yes` full-width lines, parse→glass |
| present interval p50=p95=p99 | **8333 µs** | firehose — 120fps, zero wobble |
| `time cat` 150MB ascii | **0.90–0.92 s** | base64 corpus, in-app shell |
| `time cat` 150MB, TWO panes | **0.904 s** | same 67×42 grid + a live idle split beside it |
| idle frames / GPU work | **0** | dirty-skip: 600 ticks, 0 drawn |
| RSS | **88 MB** | after all benches |
| frame update/fill/encode p50 | 4 / 56 / 37 µs | firehose, per drawn frame |
| GPU time p50 | ~0.3 ms | 〃 |

### Same-machine A/B — cat 150MB ascii (2026-07-27, Seth's hands)

Same M3 Max, same corpus, same day. Window geometries not equalized
(both WM-tiled); Ghostty 1.3.1 stable, ReleaseFast, Metal renderer.

| terminal | total |
|---|---|
| **rook (make prod)** | **0.911 s** |
| Ghostty 1.3.1 | 1.610 s |

**1.77× faster than the installed Ghostty on its signature benchmark,
with a day-old renderer.** Honest caveats: Ghostty nightly is much
faster than 1.3.1 (Mitchell's M4 Max table has it at 0.575s — different
machine), and rook currently does less per cell (no selection layer, no
scrollback viewer, single style face). Re-run this A/B every time a
feature lands that touches the render path.

First re-run under that rule — splits (2026-07-27, the scene refactor:
panes, N sessions, per-region draws): cat into a 67×42 pane with a
second live pane alongside = **0.904s**, quiet-keys key→photon
16.6/26.9ms p50/p95, fill p50 55µs, RSS 88MB. The chrome is free so
far.

Second re-run — status bar + ui.zig (same day): cat **0.902s**, keys
16.9/26.5ms, RSS 80MB, and idle is still zero frames — the HUD
recomputes at 2Hz but only a text CHANGE draws. Two instrument fixes
landed with it: chrome-only frames no longer consume the key→photon
mark (the 2Hz HUD was stealing marks — showed up as a phantom +4ms on
quiet-key p50), and present_interval now drops >500ms gaps (pacing,
not idleness — the ring used to swallow idle stretches as fake slow
frames).

Fourth re-run — tabs (same day): cat **0.912s**, key p95 26.8ms
(p50 in its wobble band). Background tabs are free by construction —
only the active tab is snapshotted/filled/drawn; measured: `yes`
firehosing in a hidden tab for 4s = 1 frame drawn, 480 skipped.

Third re-run — fps semantics + drawable_wait split (same day): cat
**0.893s** (best yet), firehose encode p50 33µs. nextDrawable
backpressure (p50 4.8ms when demand-paced, ~0 when saturated) now has
its own ring instead of polluting frame_encode — it's pacing, not
work. Quiet-key p50 wobbles run-to-run (16.6/16.9/21.4 across today)
while p95 holds ~26.5; likely the 80ms key cadence beating against
the 8.33ms vsync phase — WATCH, don't average away.

Fifth re-run — inverse video + cursor-dirty (2026-07-28, the whitespace
bug): cat **0.887s** (new best), fill p50 38µs (was 37 — the per-cell
inverse branch is noise). The fix set: fillPane applies the inverse
flag (Style.bg/fg deliberately don't — claude code's inverse-space
cursor rendered invisible), DECTCEM hide is respected, and cursor-only
moves (backspace's \b, arrows) now dirty the focused pane by comparing
against the last-drawn cursor — the emulator's dirty tracking is
row-content only, so a frame-skipping renderer must diff the cursor
itself. Idle stays zero frames (a parked cursor compares equal).

Sixth re-run — the EDITOR lands (2026-07-28: pane content union, rope
buffer, vim-core modal machine): cat **0.892s**, idle still 0 frames,
fill p50 38µs — the content switch in the snapshot/fill loops is
noise. Editor keystrokes ride the same key→photon instrument (8.3ms
p50 observed mid-session); an editor pane's echo is synchronous, so
its dirty frame consumes the mark exactly like a pty echo.

Seventh re-run — the TODO.md sweep (2026-07-28 night: faint SGR 2,
cwd inheritance, mouse click/wheel/drag-selection, viewport scrollback
+ copy mode, themes/Nocturne, background-opacity): cat **0.884s**
(new best), fill p50 39µs, idle 0 frames. The selection-range check
and default-bg alpha branch in fillPane are noise. Transparency is
config-gated because a non-opaque layer forfeits direct scan-out —
the ~5-7ms fullscreen present-lag win stays default.

Eighth re-run — tree-sitter + the second sweep (2026-07-28 late: ⌘W,
editor /-search, split-ratio drag, SGR mouse reporting, config live
reload, tree-sitter zig/go): cat **0.888s**, RSS 87MB (the vendored
runtime + two grammar tables cost ~nothing resident), idle 0 frames.
Highlight work is fill-time only on dirty editor frames: full reparse
per buffer version (size-capped 4MB), captures extracted for the
visible byte range only.

Ninth re-run — glass chrome (2026-07-28 morning: transparent titlebar
via fullSizeContentView, chrome bars at window alpha): cat
**0.922/0.923s** across two runs at 67×39 — the first DAYTIME entry
(Seth's live session + apps alongside; quiet-key p50 22ms vs ~17
overnight says machine load, not render path — the opaque path
compiles to identical work: alpha 255, inset 0). Fill p50 40µs, idle
0 frames, RSS 87MB. Two bench honesty fixes landed: bench.sh now PINS
its config (the live config's background-opacity would have silently
benched the compositor path — it only ever ran opaque because the
quoted key didn't parse until today), font pinned to Hack 18pt, which
is what the band was actually measured with (PERF header said
FiraCode 13 — that was day one, before the config file existed). And
the WM tile drifts with desktop state (67×42 overnight → 67×39
today) — state the grid per run, don't chase it.

background-blur (2026-07-28, same day as glass chrome): the backdrop
is a sibling AppKit view UNDER the Metal layer — zero render-path
delta by construction (bench config stays opaque/backdrop-free, and
demand pacing held: 18 drawn / 824 skipped on an idle blurred
instance). The material's own compositing cost lives in WindowServer
where our rings can't see it, EXCEPT present_lag: an occluded
--no-activate probe read p50 19.6ms fullscreen+blur, but occluded
windows get throttled presents (the borderless-probe trap) — a
frontmost measurement is still owed before quoting a blur tax.

Tenth re-run — editor takeover + dir buffers + padding (2026-07-28):
cat **0.904s** at 67×39, back inside the band on a daytime machine;
fill p50 39µs, idle 0 frames, RSS 86MB. The pane-content stash
(`under`), the reap restore branch, and the padded layout rect are
all noise. Found and fixed while verifying: SPAWNED SHELLS INHERITED
EVERY APP FD (pty masters, ctl connections, the listen socket) — a
child now closes 3..getdtablesize() before exec. The symptom that
unmasked it: `press`-driven leader-c spawns a tab mid-connection,
the child held the ctl conn, and nc never saw EOF — looked exactly
like a deadlock; the app was fine all along.

Eleventh re-run — workspace palette + chip annotations (2026-07-28):
cat **0.908s** at 67×39, in band; fill p50 39µs, idle 0 frames, RSS
86MB. The palette draws only while open (one bool branch per frame
closed), the sqlite read happens on open, and the per-tab
cwd→workspace resolve rides the existing 2Hz HUD tick (a proc_pidinfo
per tab, cached on the Tab) — none of it shows.

Twelfth re-run — spaces (2026-07-28: workspace-scoped tab sets, the
tmux-session model): cat **0.915/0.914s** at 67×39, fill p50 42/40µs,
idle 0 frames, RSS 86MB. A hair above the overnight band and fill +1
to +3µs — consistent with today's daytime spread (0.904–0.923), with
possibly ~1µs of real cost from the extra space→tab indirection on
the hot accessors. Background spaces are free by construction (only
the active space's active tab is snapshotted/filled). Watch fill on
the next overnight run; if 42 sticks, cache the active tab pointer
per frame.

Thirteenth re-run — usage cluster + title zone (2026-07-28): cat
**0.890s**, fill p50 39µs, RSS 87MB — back at the overnight band,
which retro-confirms the twelfth run's 0.914/42µs was daytime load,
not the spaces indirection (watch closed). Idle shows exactly ONE
drawn frame per app start: the usage thread's first fetch populating
the cluster (a real text change); steady-state idle is 0 — the 30s
poll only dirties on change.

Context (different machines/corpora — directional only): webview rook
cat = 0.91s (M3 Max, its own scoreboard); Mitchell's 2026-07-06 M4 Max
table: Ghostty nightly 0.575s, Alacritty 1.2s, Ghostty 1.3.2 1.5s,
Kitty 1.7s.

## What the first run caught (why the instrument exists)

1. **Dependency optimize didn't flow**: ghostty-vt built Debug inside a
   ReleaseFast app — ~1.5MB/s cat, 500ms frame stalls. One build.zig
   line. The bench is the only thing that would ever have noticed.
2. **os_unfair_lock starved the renderer**: under firehose the reader
   re-acquired back-to-back; frame_update p95 hit 533ms. Fixed with a
   snapshot-priority flag the reader yields to.
3. **Tick-wait + triple buffering**: key→photon started at 24ms p50.
   Input-kick (render on echo, gated on pending input so firehose stays
   coalesced) + maximumDrawableCount=2 → 15.5ms.

## The presentation pipeline, measured (2026-07-27)

`present_lag` (commit → presentedTime, per frame) is the
direct-to-display detector — no API reports the mode, but the number
can't lie:

| config | present_lag p50 | key→photon p50 |
|---|---|---|
| windowed (titled, WM tile) | 13.8 ms | 15.8 ms |
| windowed + opaque layer | 12.2 ms | 14.9 ms |
| **fullscreen + opaque** | **7.0 ms** | **8.5 ms** |
| fullscreen, framebufferOnly=true | 7.2 ms | 9.3 ms |

Fullscreen drops the WindowServer compose hop: −5 to −7ms, single-hop
scan-out. framebufferOnly is FREE — ctl `shot` keeps working with no
latency cost. The layer is now always opaque (required for direct,
harmless composited). A titled window's rounded corners force
compositing; a borderless-window probe read WORSE (22ms) but was
occluded at launch (`--no-activate` behind other windows — throttled
presents), so windowed-direct via borderless remains OPEN, needs a
frontmost test + a canBecomeKeyWindow override to be usable anyway.

## Known gaps / next levers

- Windowed key→photon keeps ~8ms of compositor. Levers: borderless
  direct (open, above), or race-the-beam (present-time targeting off
  the latch phase) which helps BOTH modes — the fullscreen 7ms lag is
  ~4ms latch-wait + ~3ms scan-out, so targeting could reach p50 ~5ms.
- key_commit p99 has a ~25ms outlier (1 of 63) — unidentified; watch.
- Bench geometry is the WM tile (67×42). Add a fullscreen-geometry run
  (rook benches at 405×113) before quoting numbers publicly.
- No same-machine A/B against Ghostty yet — `time cat` in both is the
  honest first comparison.
- The HUD's fps is CAPABILITY, not cadence: it shows the display's
  rate unless typical frame cost (max of CPU-side p50s and GPU p50)
  exceeds the vsync budget — dirty-skip demand pacing must never read
  as lag (Seth's rule). A dip on the bar means a user would feel it.
