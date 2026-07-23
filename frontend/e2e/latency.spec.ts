import {expect, test, type Page} from "@playwright/test";
import * as path from "node:path";
import {deleteWorkspaces, gotoHome, screenText, shellReady} from "./harness";

// The keystroke-latency harness — the metric the target audience feels first
// and the judge for every renderer/transport change (perf strategy,
// 2026-07-22). Measures the WHOLE round trip a user feels: keydown → ws →
// pty → shell echo → pty → emulator → frame → ws → DOM commit. A capture-phase
// keydown listener stamps t0 before the renderer's own handler runs; a
// MutationObserver on the live screen stamps t1 at the DOM commit of the echo.
// Keys are spaced widely on a quiet prompt, so "first mutation after t0" IS
// the echo — no content matching needed.
//
// t1 is DOM commit, not pixels: headless WebKit's paint isn't observable, and
// commit→paint is the compositor's ~frame. Treat the numbers as commit
// latency and compare like against like.
//
// The assertion is a loose sanity gate, not the measurement — the measured
// distribution prints in the run log and belongs in docs/PERF.md.

const REPO = path.resolve(process.cwd(), "..");
const shown = (page: Page, sel: string) => page.locator(`${sel} >> visible=true`).first();
const made: string[] = [];
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
    await expect(shown(page, ".vt-screen")).toBeVisible({timeout: 15_000});
}

test("keystroke to DOM commit latency", async ({page}) => {
    await openWorkspace(page, "latency");
    const term = shown(page, ".vt-screen");
    await shellReady(page, term);

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
        new MutationObserver(() => {
            w.__lat.muts.push(performance.now());
        }).observe(live, {childList: true, subtree: true, characterData: true});
    });

    // 30 isolated keystrokes: gaps far exceed any sane echo, so pairing is
    // unambiguous. Letters only — no shift chords, nothing zsh completes.
    await term.click();
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

    expect(lat.length).toBeGreaterThanOrEqual(25); // nearly every key measured
    const sorted = [...lat].sort((a, b) => a - b);
    const q = (p: number) => sorted[Math.min(sorted.length - 1, Math.floor(p * sorted.length))];
    const fmt = (v: number) => `${v.toFixed(1)}ms`;
    console.log(
        `LATENCY keystroke→DOM-commit n=${lat.length} ` +
            `p50=${fmt(q(0.5))} p95=${fmt(q(0.95))} min=${fmt(sorted[0])} max=${fmt(sorted[sorted.length - 1])}`,
    );

    // sanity gate, deliberately loose — the log line is the measurement
    expect(q(0.95)).toBeLessThan(150);
});
