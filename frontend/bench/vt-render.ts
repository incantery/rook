// The frame-time harness behind the D5 gate. It mounts the real DOM renderer and
// drives the two cases DOM is weakest at — a full-screen scrollback scroll, and
// a foreground firehose of ~1000 styled-span updates per frame — measuring the
// main-thread cost of each frame (grid apply + coalesce + innerHTML + a forced
// synchronous layout). That main-thread time is the jank source; if it stays
// well under a 16 ms frame budget, DOM sustains 60 fps and WebGL (D5) does not
// fire. bench/vt-render.spec.ts drives this in a real browser via Playwright.

import type {Color, Frame, Run, WCell} from "../src/term/vt/frame";
import {GridRenderer} from "../src/term/vt/renderer";
import "../src/term/vt/renderer.css";

const COLS = 120;
const ROWS = 40;

const set = (n: number): Color => (0x80000000 | n) >>> 0;

function cell(ch: string, fg: Color, attr = 0): WCell {
    return {content: ch, fg, bg: 0, attr, width: 1};
}

// A row of printable text; every `colorEvery` columns the fg flips, so after
// coalescing the row is ~COLS/colorEvery styled spans (0 = one flat span).
function row(y: number, seed: number, colorEvery: number): Run {
    const cells: WCell[] = [];
    for (let x = 0; x < COLS; x++) {
        const ch = String.fromCharCode(33 + ((x + seed + y) % 94));
        const fg =
            colorEvery > 0 && Math.floor(x / colorEvery) % 2 === 0 ? set(1 + ((x + seed) % 7)) : 0;
        cells.push(cell(ch, fg));
    }
    return {x: 0, cells};
}

function fullFrame(seed: number, colorEvery: number): Frame {
    const rows = [];
    for (let y = 0; y < ROWS; y++) rows.push({y, runs: [row(y, seed, colorEvery)]});
    return {cursor: {x: seed % COLS, y: ROWS - 1, visible: true}, scroll: 0, rows};
}

// scroll: every frame rewrites every row (content shifted by one line), the
// worst case for a diff renderer — no coalescing help, a full-screen repaint.
function scrollFrames(n: number): Frame[] {
    return Array.from({length: n}, (_, i) => fullFrame(i, 0));
}

// firehose: every frame rewrites every row with heavily-styled content —
// ~COLS/5 spans per row x ROWS ≈ 960 span updates per frame.
function firehoseFrames(n: number): Frame[] {
    return Array.from({length: n}, (_, i) => fullFrame(i * 7, 5));
}

interface Stats {
    frames: number;
    spansPerFrame: number;
    mean: number;
    p50: number;
    p95: number;
    p99: number;
    max: number;
}

function summarize(durs: number[], spans: number): Stats {
    const sorted = [...durs].sort((a, b) => a - b);
    const at = (q: number) => sorted[Math.min(sorted.length - 1, Math.floor(sorted.length * q))];
    const mean = durs.reduce((a, b) => a + b, 0) / durs.length;
    return {
        frames: durs.length,
        spansPerFrame: spans,
        mean,
        p50: at(0.5),
        p95: at(0.95),
        p99: at(0.99),
        max: sorted[sorted.length - 1],
    };
}

const WARMUP = 15; // untimed frames to settle JIT/layout before measuring

function run(frames: Frame[]): Stats {
    const container = document.getElementById("screen")!;
    container.replaceChildren();
    const renderer = new GridRenderer(container, COLS, ROWS);

    // total styled-span count of a representative frame, for context
    renderer.applyFrame(frames[0]);
    let spans = 0;
    for (let y = 0; y < ROWS; y++) spans += renderer.grid.coalesceRow(y).length;

    const durs: number[] = [];
    for (let i = 0; i < frames.length; i++) {
        const t0 = performance.now();
        renderer.applyFrame(frames[i]);
        void container.offsetHeight; // force synchronous layout into the measurement
        const dt = performance.now() - t0;
        if (i >= WARMUP) durs.push(dt);
    }
    renderer.destroy();
    return summarize(durs, spans);
}

declare global {
    interface Window {
        vtBench: (scenario: "scroll" | "firehose", n?: number) => Stats;
    }
}

window.vtBench = (scenario, n = 180) =>
    run(scenario === "scroll" ? scrollFrames(n) : firehoseFrames(n));
