import {expect, test, type Page} from "@playwright/test";
import * as path from "node:path";
import {clickShown, deleteWorkspaces, gotoHome, screenText, shellReady, shown} from "./harness";

// The keystroke-latency harness (latency.spec.ts), swept across viewport
// WIDTHS — written to chase an ultrawide lag report, and the reason the
// scoreboard's latency row now carries the grid it was measured at (128x36,
// not the 405x113 everything else uses).
//
// Its answer is flat: an idle echo dirties one row, so grid size costs
// nothing, headless or headed. The interesting sweep is the loaded one next
// door (latency-load.spec.ts) — and its headline is a warning, not a number.
// Read docs/PERF.md before quoting either.
//
// Height is pinned at 1440 for the sweep so width is the only variable; the
// 1400x900 row reproduces the number in docs/PERF.md.
//
// Opt-in — the sweep costs ~2min:
//   ROOK_LAT_SWEEP=1 make e2e ARGS=e2e/latency-width.spec.ts
//
// Results belong in docs/PERF.md. The assertion is a loose sanity gate; the
// log lines are the measurement.

const REPO = path.resolve(process.cwd(), "..");
const made: string[] = [];

test.skip(!process.env.ROOK_LAT_SWEEP, "opt-in: set ROOK_LAT_SWEEP=1");

test.afterEach(async ({page}) => {
    await deleteWorkspaces(page, made.splice(0));
});

async function openWorkspace(page: Page, name: string) {
    made.push(name);
    await gotoHome(page);
    await page.getByRole("button", {name: /^workspaces/i}).click();
    await page.getByRole("button", {name: "New workspace"}).click();
    await expect(page.locator("#ws-modal")).toBeVisible();
    await page.getByPlaceholder("e.g. rook-core").fill(name);
    await page.getByPlaceholder("~/go/src/github.com/incantery/rook").fill(REPO);
    await page.getByRole("button", {name: "Create workspace"}).click();
    await expect(page.locator(`[data-workspace="${name}"]`)).toBeVisible({timeout: 15_000});
    await expect(shown(page, ".vt-screen")).toBeVisible({timeout: 15_000});
}

async function measure(page: Page, label: string) {
    await openWorkspace(page, `lat-${label}`);
    const term = shown(page, ".vt-screen");
    await shellReady(page, term);

    const grid = await term.evaluate((el) => {
        const s = (el as HTMLElement).style;
        return {
            cols: Number(s.getPropertyValue("--vt-cols")),
            rows: Number(s.getPropertyValue("--vt-rows")),
        };
    });

    // install the probe AFTER the shell settles, so its own echo isn't counted
    await page.evaluate(() => {
        const w = window as unknown as {__lat: {keys: number[]; muts: number[]}};
        w.__lat = {keys: [], muts: []};
        document.addEventListener(
            "keydown",
            (e) => {
                if (e.key.length === 1) w.__lat.keys.push(performance.now());
            },
            true, // capture: stamp BEFORE the renderer's handler runs
        );
        const screens = [...document.querySelectorAll<HTMLElement>(".vt-screen")];
        const live = screens.find((el) => el.offsetParent !== null);
        if (!live) throw new Error("no visible terminal to observe");
        // the renderer's commit signal (canvas: no DOM mutations)
        const mark = () => w.__lat.muts.push(performance.now());
        new MutationObserver(mark).observe(live, {
            childList: true,
            subtree: true,
            characterData: true,
        });
        live.addEventListener("rook:frame", mark);
    });

    await clickShown(term);
    await page.keyboard.type("abcdefghijklmnopqrstuvwxyzabcd", {delay: 90});
    await expect.poll(() => screenText(term)).toContain("abcdefghijklmnopqrstuvwxyzabcd");

    const lat = await page.evaluate(() => {
        const w = window as unknown as {__lat: {keys: number[]; muts: number[]}};
        const out: number[] = [];
        for (const t0 of w.__lat.keys) {
            const t1 = w.__lat.muts.find((t) => t > t0 && t < t0 + 1000);
            if (t1 !== undefined) out.push(t1 - t0);
        }
        return out;
    });

    expect(lat.length).toBeGreaterThanOrEqual(25);
    const sorted = [...lat].sort((a, b) => a - b);
    const q = (p: number) => sorted[Math.min(sorted.length - 1, Math.floor(p * sorted.length))];
    const fmt = (v: number) => v.toFixed(1);
    console.log(
        `LAT-SWEEP ${label} grid=${grid.cols}x${grid.rows} ` +
            `cells=${grid.cols * grid.rows} ` +
            `n=${lat.length} p50=${fmt(q(0.5))}ms p95=${fmt(q(0.95))}ms ` +
            `min=${fmt(sorted[0])}ms max=${fmt(sorted[sorted.length - 1])}ms`,
    );

    expect(q(0.95)).toBeLessThan(500);
}

// 1400x900 is the PERF.md baseline (the window cmd/rook opens). The rest pin
// height at 1440 and vary width alone: QHD, 21:9 ultrawide, 32:9 super
// ultrawide, and the 6K-fullscreen geometry the cat bench uses.
const SWEEP = [
    {label: "1400x900-baseline", width: 1400, height: 900},
    {label: "1400x1440", width: 1400, height: 1440},
    {label: "2560x1440-qhd", width: 2560, height: 1440},
    {label: "3440x1440-ultrawide", width: 3440, height: 1440},
    {label: "5120x1440-super", width: 5120, height: 1440},
    {label: "4400x2560-6k", width: 4400, height: 2560},
] as const;

for (const {label, width, height} of SWEEP) {
    test.describe(`viewport ${label}`, () => {
        test.use({viewport: {width, height}});
        test(`keystroke to GL submit @ ${label}`, async ({page}) => {
            test.setTimeout(180_000);
            await measure(page, label);
        });
    });
}
