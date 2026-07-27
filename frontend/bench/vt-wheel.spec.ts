import {expect, test} from "@playwright/test";

// The wheel gate. One trackpad flick, four scenarios (bench/vt-wheel.ts
// explains the profile). Measured numbers print in the run log and belong in
// docs/PERF.md; the assertions are a regression floor, not the measurement.
//
// Two geometries on purpose, per PERF.md rule 1 (grid size is part of every
// number): 405x113 is the canonical 6K-fullscreen size the scoreboard quotes,
// and 232x41 is an ordinary half-screen split — the size a real pane runs at,
// and the one a user's "this feels laggy" is about. The D5 renderer gate
// (vt-render.spec.ts) runs at 120x40 and covers neither.
//
// WHAT THIS FOUND (2026-07-27, M3 Pro, headless chromium). Before row
// recycling, `local`, `scrolled` and `frame` all cost the SAME — ~8ms p50 at
// 232x41, ~37-42ms at 405x113 — because ClientGrid.apply reports every row
// dirty whenever a frame scrolled. True of the cells, false of the DOM. One
// flick blocked the main thread for 0.7s at a split and 3.4-5.6s at
// fullscreen, felt as scroll lag AND as the keystrokes queued behind it.
//
// After: 0.30ms and 0.80-0.90ms p50 respectively, 27-46x. The gates below are
// set to hold that, not to describe it — a ceiling loose enough to let 42ms
// back through would not be a gate.
//
// `frame` is deliberately NOT tightened. A genuinely full-screen rewrite still
// costs ~38ms at 405x113; recycling cannot help when every row really changed,
// and only a cheaper paint primitive (the WebGL bake-off) will move it.

const CANON = {cols: 405, rows: 113};
const SPLIT = {cols: 232, rows: 41};

test("one trackpad flick — local scrollback vs a tracking TUI", async ({page}) => {
    // Six scenarios, and the slow ones are slow BECAUSE of what is being
    // measured: 120 full repaints at 405x113 is ~7s of main thread by itself.
    test.setTimeout(180_000);
    await page.goto("/bench/vt-wheel.html");
    await page.waitForFunction(() => typeof window.wheelBench === "function");

    const runAt = async (g: {cols: number; rows: number}) => ({
        local: await page.evaluate((g) => window.wheelBench("local", g.cols, g.rows), g),
        tracking: await page.evaluate((g) => window.wheelBench("tracking", g.cols, g.rows), g),
        frame: await page.evaluate((g) => window.wheelBench("frame", g.cols, g.rows), g),
        scrolled: await page.evaluate((g) => window.wheelBench("scrolled", g.cols, g.rows), g),
    });

    // Measure BOTH geometries before asserting anything: a failing gate must
    // not cost the run the other half of its own data.
    const all = [];
    for (const g of [SPLIT, CANON]) {
        const r = await runAt(g);
        console.log(`WHEEL local    ${g.cols}x${g.rows}:`, JSON.stringify(r.local));
        console.log(`WHEEL tracking ${g.cols}x${g.rows}:`, JSON.stringify(r.tracking));
        console.log(`WHEEL frame    ${g.cols}x${g.rows}:`, JSON.stringify(r.frame));
        console.log(`WHEEL scrolled ${g.cols}x${g.rows}:`, JSON.stringify(r.scrolled));
        all.push({g, r});
    }

    for (const {g, r} of all) {
        const at = `@${g.cols}x${g.rows}`;

        // The viewport has to have MOVED, or every number is the cost of doing
        // nothing. (It measured 0.01ms/event until the harness sent a real
        // `hist` — see vt-wheel.ts.)
        expect(r.local.scrolled, `lines the local viewport travelled ${at}`).toBeGreaterThan(0);
        expect(r.tracking.scrolled, `a tracking TUI owns the wheel, so locally: 0 ${at}`).toBe(0);

        // Forwarding to a tracking program is main-thread free; it is the
        // repaints the forwarded notches provoke that cost. Guard the cheapness.
        expect(r.tracking.wallMs, `tracking forward, ms for the whole flick ${at}`).toBeLessThan(
            20,
        );

        // Fan-out: one wheel event costs the transport at most ONE write,
        // however many lines it means — the presses are batched into a single
        // ws.send / pty.Write / TUI stdin read. Above 1.0 that batching broke.
        expect(r.tracking.amplification, `onInput calls per wheel event ${at}`).toBeLessThanOrEqual(
            1,
        );

        // getBoundingClientRect is resolved once per EVENT, not once per line:
        // a forced layout read inside the per-line loop is the same defect in
        // another costume.
        expect(r.tracking.layoutReads, `layout reads per gesture ${at}`).toBeLessThanOrEqual(
            r.tracking.inputCalls,
        );

        // Both scroll paths recycle rows, so both must sit inside one 60fps
        // frame with room to spare. Measured 1.2ms and 1.8ms; 16ms is ~10x
        // headroom for a bench sharing a loaded machine, and still an order of
        // magnitude below the ~37ms regression it exists to catch. A gate that
        // flakes gets deleted, which is worse than a loose one.
        expect(r.local.p95, `local scroll p95 main-thread ms/event ${at}`).toBeLessThan(16);
        expect(r.scrolled.p95, `scrolled-frame p95 main-thread ms/frame ${at}`).toBeLessThan(16);

        // The unfixed case, held only against getting worse.
        const fullBudget = g.rows > 60 ? 140 : 32;
        expect(r.frame.p95, `full-rewrite p95 main-thread ms/frame ${at}`).toBeLessThan(fullBudget);
        expect(
            r.scrolled.p50 * 4,
            `a scroll:1 frame must be far cheaper than a full rewrite ${at}`,
        ).toBeLessThan(r.frame.p50);
    }
});
