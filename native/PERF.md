# rookz PERF — the scoreboard

What gets written down gets defended (inherited from ../docs/PERF.md, and
so are the rules: like against like, state the load condition and grid,
tails matter more than medians). Reproduce any row with `./bench.sh`;
live numbers anytime via `printf 'stats\n' | nc -U /tmp/rookz.sock`.

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
| **rookz (make prod)** | **0.911 s** |
| Ghostty 1.3.1 | 1.610 s |

**1.77× faster than the installed Ghostty on its signature benchmark,
with a day-old renderer.** Honest caveats: Ghostty nightly is much
faster than 1.3.1 (Mitchell's M4 Max table has it at 0.575s — different
machine), and rookz currently does less per cell (no selection layer, no
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
