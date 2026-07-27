import {expect, test} from "@playwright/test";

// The wheel gate. One trackpad flick, three worlds (bench/vt-wheel.ts explains
// the profile). Measured numbers print in the run log and belong in
// docs/PERF.md; the assertions are a regression floor, not the measurement.
//
// Two geometries on purpose, per PERF.md rule 1 (grid size is part of every
// number): 405x113 is the canonical 6K-fullscreen size the scoreboard quotes,
// and 232x41 is an ordinary half-screen split — the size a real pane runs at,
// and the one a user's "this feels laggy" is about. The D5 renderer gate
// (vt-render.spec.ts) runs at 120x40 and has never covered either.
//
// WHAT THIS FOUND, first run (2026-07-27, M3 Pro, headless chromium):
// `local` and `frame` cost the same — 8.7 vs 9.2ms p50 at 232x41, 42 vs 48ms
// at 405x113. So the wheel handler adds nothing; a FULL-VIEWPORT REPAINT is
// simply over the 16ms frame budget at real pane sizes, whoever drives it.
// One flick blocks the main thread for 0.8s at 232x41 and 4.2s at 405x113,
// which is felt as scroll lag AND as the keystrokes queued behind it.
//
// The thresholds below are TODAY'S NUMBERS held as a ceiling, not the target.
// The target is p95 < 16ms at every geometry; getting there means the WebGL
// renderer (PERF.md's pending bake-off) or row-level virtualization, not a
// tweak. Tighten these as that lands.

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
    });

    // Measure BOTH geometries before asserting anything: a failing gate must
    // not cost the run the other half of its own data.
    const all = [];
    for (const g of [SPLIT, CANON]) {
        const r = await runAt(g);
        console.log(`WHEEL local    ${g.cols}x${g.rows}:`, JSON.stringify(r.local));
        console.log(`WHEEL tracking ${g.cols}x${g.rows}:`, JSON.stringify(r.tracking));
        console.log(`WHEEL frame    ${g.cols}x${g.rows}:`, JSON.stringify(r.frame));
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

        // Fan-out: one wheel event costs the transport 1.28 writes today —
        // each a separate ws.send, pty.Write, and TUI stdin read. It should be
        // 1 (batch the per-line presses into one write). Held at today's value
        // so a WORSE fan-out fails; drop to 1 when the batching lands.
        expect(r.tracking.amplification, `onInput calls per wheel event ${at}`).toBeLessThanOrEqual(
            1.3,
        );

        // getBoundingClientRect runs once per LINE (154) rather than once per
        // event (120) — a forced layout read inside the per-line loop, which
        // beamterm.ts already hoists out and renderer.ts does not.
        expect(r.tracking.layoutReads, `layout reads per gesture ${at}`).toBeLessThanOrEqual(
            r.tracking.inputCalls,
        );

        // A wheel event costs a full-viewport repaint, so this is the D5 budget
        // again — 16ms is one frame at 60fps. Both geometries blow it today
        // (p95 ~15ms and ~68ms); these ceilings only catch it getting WORSE,
        // and carry ~2x headroom because a bench sharing a loaded machine
        // swings run to run. A gate that flakes gets deleted, which is worse
        // than a loose one.
        const budget = g.rows > 60 ? 140 : 32;
        expect(r.local.p95, `local scroll p95 main-thread ms/event ${at}`).toBeLessThan(budget);
        expect(r.frame.p95, `host-frame p95 main-thread ms/frame ${at}`).toBeLessThan(budget);
    }
});
