// The wheel-scroll harness. PERF.md measures keystroke latency on a QUIET
// prompt, and the D5 renderer gate measures frame time at 120x40 — neither
// covers the gesture the user actually complains about, at the geometry
// PERF.md itself calls canonical (405x113).
//
// One trackpad flick is not one event. macOS delivers momentum scroll as a
// ~1s train of ~120 small-delta wheel events, and the paths diverge hard:
//
//   local    — nothing tracking the mouse. Each event moves the viewport and
//              repaints EVERY row (renderer.repaintViewport), because the
//              whole screen slid. Cost: main-thread ms per event.
//   tracking — claude, a pager. Each event becomes N wheel-button presses
//              forwarded to the pty. Client cost is ~nil; what it buys is
//              fan-out — separate onInput calls, each one a ws.send, a
//              pty.Write, and a stdin read the TUI must service.
//   frame    — the CONTROL. Same geometry, a genuinely full-screen repaint
//              (scroll: 0, every row rewritten) driven by host frames instead
//              of the wheel. It separates "the wheel path is doing something
//              extra" from "a 405-col grid is simply expensive to repaint",
//              and it is the floor no row recycling can beat: when every row
//              really did change, every row really must be painted.
//   scrolled — the case that actually happens. A shell printing a line, or a
//              TUI scrolling its view, emits scroll:1 plus ONE new row — yet
//              ClientGrid.apply reports every row dirty ("a scroll moves every
//              row's content"), which is true of the cells and false of the
//              DOM. This is what the renderer's row recycling targets, and
//              the gap between it and `frame` is the whole value of the fix.
//
// Synthetic WheelEvents, not page.mouse.wheel: the flick profile has to be
// reproducible to compare runs, and the handler path is identical
// (renderer.onWheel), getBoundingClientRect calls included. Those are counted
// too — a forced layout read per LINE rather than per event is a defect the
// aggregate ms would hide.

import type {Color, Frame, Run, WCell} from "../src/term/vt/frame";
import {GridRenderer} from "../src/term/vt/renderer";
import "../src/term/vt/renderer.css";

const set = (n: number): Color => (0x80000000 | n) >>> 0;

// A row of printable text with a colour flip every 12 columns, so coalescing
// leaves ~cols/24 styled spans — representative of a real TUI, not a flat wall.
function row(cols: number, y: number, seed: number): Run {
    const cells: WCell[] = [];
    for (let x = 0; x < cols; x++) {
        cells.push({
            content: String.fromCharCode(33 + ((x + seed + y) % 94)),
            fg: Math.floor(x / 12) % 2 === 0 ? set(1 + ((x + seed) % 7)) : 0,
            bg: 0,
            attr: 0,
            width: 1,
        });
    }
    return {x: 0, cells};
}

/** One line scrolling in at the bottom — how history accumulates client-side.
 *  hist and epoch are load bearing, not decoration: SbStore reads hist as the
 *  absolute index of the live top row, and without it `max` is NaN and every
 *  scroll silently clamps to a no-op (which is exactly how the first draft of
 *  this bench measured 0.01ms per "repaint"). */
function scrollFrame(cols: number, rows: number, seed: number, hist: number): Frame {
    return {
        cursor: {x: 0, y: rows - 1, visible: true},
        scroll: 1,
        hist,
        epoch: 1,
        rows: [{y: rows - 1, runs: [row(cols, rows - 1, seed)]}],
    };
}

/** Every row rewritten at once — what a TUI redrawing its whole view emits,
 *  and what the client must repaint per frame. */
function fullFrame(cols: number, rows: number, seed: number, hist: number): Frame {
    const out = [];
    for (let y = 0; y < rows; y++) out.push({y, runs: [row(cols, y, seed)]});
    return {cursor: {x: 0, y: rows - 1, visible: true}, scroll: 0, hist, epoch: 1, rows: out};
}

/** A pool of DISTINCT full frames, built once up front. Building them inside
 *  the timed loop measures the harness allocating 45k cell objects, not the
 *  renderer painting them — which is how the first run of this bench had the
 *  control reading 48ms when the honest number was lower. Consecutive frames
 *  differ, so cycling the pool still dirties every row. */
const POOL = 10;

function framePool(cols: number, rows: number, hist: number): Frame[] {
    return Array.from({length: POOL}, (_, i) => fullFrame(cols, rows, i * 7, hist));
}

/** The frames for `scrolled`: scroll:1 plus one fresh bottom row, the shape a
 *  shell or a scrolling TUI actually emits. Built in full rather than cycled,
 *  because hist must advance monotonically — SbStore reads it as the absolute
 *  index of the live top row, and a hist that jumps backwards is not a state
 *  the host can produce. Only one row each, so building all of them costs
 *  about what a single full frame does. */
function scrolledFrames(cols: number, rows: number, hist0: number, count: number): Frame[] {
    return Array.from({length: count}, (_, i) => scrollFrame(cols, rows, i * 13, hist0 + i + 1));
}

// A macOS trackpad flick: ~120 events over ~1s, delta decaying geometrically
// from the initial fling. Total ~2900px ~ 150 lines at a 19px cell — one
// ordinary flick through a conversation, not a pathological input.
const FLICK_EVENTS = 120;
const FLICK_DELTA0 = 90;
const FLICK_DECAY = 0.97;

function flickDeltas(): number[] {
    const out: number[] = [];
    let d = FLICK_DELTA0;
    for (let i = 0; i < FLICK_EVENTS; i++) {
        out.push(d);
        d *= FLICK_DECAY;
    }
    return out;
}

interface Stats {
    grid: string;
    /** wheel events (or frames) dispatched — one trackpad flick's worth */
    events: number;
    /** onInput calls — each is one ws.send, one pty.Write, one TUI stdin read */
    inputCalls: number;
    inputBytes: number;
    /** onInput calls per wheel event — the fan-out */
    amplification: number;
    /** getBoundingClientRect calls during the gesture (forced layout reads) */
    layoutReads: number;
    /** main-thread ms per event */
    mean: number;
    p50: number;
    p95: number;
    p99: number;
    max: number;
    /** main-thread ms for the whole gesture, wall clock around the loop.
     *  Trust this over the sum of per-event samples: browsers coarsen
     *  performance.now(), so 120 sub-100us samples all read as 0. */
    wallMs: number;
    /** lines the viewport actually travelled — 0 in the local case means the
     *  bench measured nothing and every other number here is meaningless. */
    scrolled: number;
}

/** HISTORY lines of scrollback so a local scroll has real content to page
 *  through rather than blanks (no onSbFetch here — the store keeps what it
 *  captured, which is the BEST case; a fetch round trip only adds). */
const HISTORY = 400;
const WARMUP = 10; // untimed events to settle JIT and the cell measurement

type Scenario = "local" | "tracking" | "frame" | "scrolled";

function run(scenario: Scenario, cols: number, rows: number): Stats {
    const container = document.getElementById("screen")!;
    container.replaceChildren();

    let inputCalls = 0;
    let inputBytes = 0;
    const renderer = new GridRenderer(container, cols, rows, {
        onInput: (data) => {
            inputCalls++;
            inputBytes += data.length;
        },
    });

    // fill the screen, then push HISTORY lines through it into scrollback
    for (let i = 0; i < rows + HISTORY; i++) {
        renderer.applyFrame(scrollFrame(cols, rows, i, i + 1));
    }
    const hist = rows + HISTORY;

    // claude enables normal tracking (level 2) with SGR encoding; a shell does
    // not track at all. This one flag is the whole difference between the paths.
    renderer.setMouseMode(scenario === "tracking" ? 2 : 0, true);

    const rect = container.getBoundingClientRect();
    const clientX = rect.left + 40;
    const clientY = rect.top + 40;
    const deltas = flickDeltas();
    const wheel = (deltaY: number) =>
        new WheelEvent("wheel", {
            deltaY,
            deltaMode: 0,
            clientX,
            clientY,
            bubbles: true,
            cancelable: true,
        });

    const pool = scenario === "frame" ? framePool(cols, rows, hist) : [];
    // WARMUP + the measured run, all with monotonic hist
    const scrollPool =
        scenario === "scrolled" ? scrolledFrames(cols, rows, hist, WARMUP + FLICK_EVENTS) : [];

    // warm up on the same handler, then reset the counters so the measured
    // gesture is the only thing in the numbers
    for (let i = 0; i < WARMUP; i++) {
        if (scenario === "frame") renderer.applyFrame(pool[i % pool.length]);
        else if (scenario === "scrolled") renderer.applyFrame(scrollPool[i]);
        else container.dispatchEvent(wheel(-deltas[0]));
    }
    renderer.scrollToBottom();
    inputCalls = 0;
    inputBytes = 0;

    // count forced layout reads for the measured gesture only
    const realRect = Element.prototype.getBoundingClientRect;
    let layoutReads = 0;
    Element.prototype.getBoundingClientRect = function (this: Element) {
        layoutReads++;
        return realRect.call(this);
    };

    const durs: number[] = [];
    const wall0 = performance.now();
    for (let i = 0; i < deltas.length; i++) {
        const t0 = performance.now();
        if (scenario === "frame") {
            renderer.applyFrame(pool[i % pool.length]);
        } else if (scenario === "scrolled") {
            renderer.applyFrame(scrollPool[WARMUP + i]);
        } else {
            // negative deltaY = scroll up, back through history / earlier messages
            container.dispatchEvent(wheel(-deltas[i]));
        }
        void (container as HTMLElement).offsetHeight; // force layout into the measurement
        durs.push(performance.now() - t0);
    }
    const wallMs = performance.now() - wall0;

    Element.prototype.getBoundingClientRect = realRect;
    const scrolled = renderer.scrollOffset;
    renderer.destroy();

    const sorted = [...durs].sort((a, b) => a - b);
    const at = (q: number) => sorted[Math.min(sorted.length - 1, Math.floor(sorted.length * q))];
    return {
        grid: `${cols}x${rows}`,
        events: durs.length,
        inputCalls,
        inputBytes,
        amplification: inputCalls / durs.length,
        layoutReads,
        mean: durs.reduce((a, b) => a + b, 0) / durs.length,
        p50: at(0.5),
        p95: at(0.95),
        p99: at(0.99),
        max: sorted[sorted.length - 1],
        wallMs,
        scrolled,
    };
}

declare global {
    interface Window {
        wheelBench: (scenario: Scenario, cols?: number, rows?: number) => Stats;
    }
}

// 405x113 is PERF.md's canonical geometry; callers pass their own to compare.
window.wheelBench = (scenario, cols = 405, rows = 113) => run(scenario, cols, rows);
