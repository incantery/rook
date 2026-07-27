import {expect, test, type Page} from "@playwright/test";
import * as fs from "node:fs";
import * as path from "node:path";
import {clickShown, deleteWorkspaces, gotoHome, shellReady, shown} from "./harness";

// Keystroke latency measured on a pane that is NOT the one doing work — the
// condition an ultrawide user actually lives in: a split, one half streaming
// output, and you typing in the other. The idle sweep next door
// (latency-width.spec.ts) is flat because an echo dirties one row; this one
// loads the renderer with full-screen frames and measures what the typist
// pays for them.
//
// ⚠ READ THIS BEFORE TRUSTING A NUMBER FROM THIS FILE. Run headless, it
// reports a clean, monotonic, reproducible cliff above ~10k cells per pane —
// keystroke p95 5ms → 50ms — and the cliff is not real. Headless WebKit has
// no GPU and software-rasterizes every cell on the main thread; the curve is
// a portrait of Playwright. Run headed with every cell actually on screen
// (MODE=density below) it is flat to 32k cells. The whole
// episode is written up in docs/PERF.md, 2026-07-27.
//
// So: headed, always, for anything quotable.
//
//   ROOK_LAT_LOAD=1 make e2e ARGS="--headed e2e/latency-load.spec.ts"
//   ROOK_LAT_LOAD=1 ROOK_LAT_MODE=density \
//       make e2e ARGS="--headed e2e/latency-load.spec.ts"
//
// Results belong in docs/PERF.md. The assertion is a loose sanity gate; the
// log lines are the measurement.

const REPO = path.resolve(process.cwd(), "..");
const made: string[] = [];

test.skip(!process.env.ROOK_LAT_LOAD, "opt-in: set ROOK_LAT_LOAD=1");

// ROOK_LAT_MODE=density holds the viewport at a size that FITS the physical
// screen and reaches big grids by shrinking the font instead. That exists
// because the viewport sweep can't be trusted headed: an oversized window is
// mostly offscreen, and a compositor is free not to rasterize tiles nobody
// can see — which would flatten the curve for a reason that has nothing to do
// with the renderer. Same cell counts, every cell genuinely on screen.
// Confound to state when quoting it: a 6px cell rasterizes less glyph than an
// 18px one, so this isolates cell COUNT, not total painted area.
const MODE = process.env.ROOK_LAT_MODE === "density" ? "density" : "viewport";

// The sandbox's config (frontend/e2e/serve.sh writes it each boot). Rewritten
// per test in density mode; config.Service.Get re-reads on every call, so a
// navigation picks the new size up without restarting the app.
const CFG = path.join(REPO, "bin", "e2e", "xdg", "config", "rook", "config");

function setFontSize(px: number | null) {
    const lines = fs
        .readFileSync(CFG, "utf8")
        .split("\n")
        .filter((l) => !l.startsWith("font-size"));
    if (px !== null) lines.push(`font-size = ${px}`);
    fs.writeFileSync(CFG, lines.filter(Boolean).join("\n") + "\n");
}

test.afterAll(() => setFontSize(null)); // never leave the sandbox resized

test.afterEach(async ({page}) => {
    await deleteWorkspaces(page, made.splice(0));
});

/** Type at whichever pane holds the keyboard and wait for the echo — the
 *  harness's shellReady watches the FIRST visible terminal, which in a split
 *  is not where the keyboard is. */
async function readyHere(page: Page, seq: {n: number}) {
    // Read every visible pane through the renderer seam rather than the
    // window's innerText: the WebGL renderer's panes are canvases with no
    // text nodes, so a toContainText on .window.active is empty forever.
    const allPanes = () =>
        page.evaluate(() =>
            [...document.querySelectorAll<HTMLElement>(".vt-screen")]
                .filter((el) => el.offsetParent !== null)
                .map((el) => {
                    const probe = (el as HTMLElement & {__screenText?: () => string}).__screenText;
                    return probe ? probe() : el.innerText;
                })
                .join("\n"),
        );
    for (let i = 0; i < 30; i++) {
        const tag = `rdy${seq.n++}x${i}`;
        await page.keyboard.type(`echo ${tag}$((6*7))`);
        await page.keyboard.press("Enter");
        try {
            await expect.poll(allPanes, {timeout: 2_000}).toContain(`${tag}42`);
            return;
        } catch {
            /* cold shell ate the probe — try again */
        }
    }
    throw new Error("shell never became ready");
}

async function measure(page: Page, label: string, fontSize?: number) {
    made.push(`latload-${label}`);
    if (fontSize !== undefined) setFontSize(fontSize);
    await gotoHome(page);
    await page.getByRole("button", {name: /^workspaces/i}).click();
    await page.getByRole("button", {name: "New workspace"}).click();
    await expect(page.locator("#ws-modal")).toBeVisible();
    await page.getByPlaceholder("e.g. rook-core").fill(`latload-${label}`);
    await page.getByPlaceholder("~/go/src/github.com/incantery/rook").fill(REPO);
    await page.getByRole("button", {name: "Create workspace"}).click();
    await expect(page.locator(`[data-workspace="latload-${label}"]`)).toBeVisible({
        timeout: 15_000,
    });
    await expect(shown(page, ".vt-screen")).toBeVisible({timeout: 15_000});
    await shellReady(page, shown(page, ".vt-screen"));

    // ` % — tmux vertical split; the new (right) half gets focus + a shell
    await page.keyboard.press("`");
    await page.keyboard.press("%");
    await expect(page.locator(".vt-screen:visible")).toHaveCount(2, {timeout: 15_000});
    const seq = {n: 0};
    await readyHere(page, seq);

    const grid = await page.evaluate(() => {
        const live = [...document.querySelectorAll<HTMLElement>(".vt-screen")].filter(
            (el) => el.offsetParent !== null,
        );
        return live.map((el) => ({
            cols: Number(el.style.getPropertyValue("--vt-cols")),
            rows: Number(el.style.getPropertyValue("--vt-rows")),
            x: Math.round(el.getBoundingClientRect().x),
        }));
    });

    // The RIGHT half becomes the producer: full-width lines at pty speed, the
    // shape of output a coding agent or a build log makes.
    await page.keyboard.type(`yes "$(printf 'x%.0s' $(seq 1 400))"`);
    await page.keyboard.press("Enter");
    await page.waitForTimeout(1_500); // let the firehose reach steady state

    // cross to the LEFT (quiet) shell — that is where we type and measure
    await page.keyboard.press("Control+h");
    await readyHere(page, seq);

    // Probe the LEFTMOST visible screen only: the producer's own pane mutates
    // continuously, so "first mutation after t0" is only the echo over here.
    await page.evaluate(() => {
        const w = window as unknown as {__lat: {keys: number[]; muts: number[]; raf: number[]}};
        w.__lat = {keys: [], muts: [], raf: []};
        // rAF gaps alongside the echo timings: if the keystroke tail is the
        // main thread being busy painting the OTHER pane, the frame clock
        // stalls by the same amount at the same geometry. That is what
        // separates "the webview is blocked" from "the wire is slow".
        const tick = (t: number) => {
            w.__lat.raf.push(t);
            requestAnimationFrame(tick);
        };
        requestAnimationFrame(tick);
        document.addEventListener(
            "keydown",
            (e) => {
                if (e.key.length === 1) w.__lat.keys.push(performance.now());
            },
            true, // capture: stamp BEFORE the renderer's handler runs
        );
        const live = [...document.querySelectorAll<HTMLElement>(".vt-screen")]
            .filter((el) => el.offsetParent !== null)
            .sort((a, b) => a.getBoundingClientRect().x - b.getBoundingClientRect().x);
        if (!live.length) throw new Error("no visible terminal to observe");
        // Both renderers' commit signal. The DOM renderer commits by mutating
        // nodes; a canvas renderer mutates nothing and fires rook:frame after
        // GL submission instead. Listening for both is what makes one spec
        // measure both sides of the seam — but note the two t1s are NOT the
        // same pipeline point (DOM = innerHTML set, paint still pending;
        // WebGL = after submission, nearly pixels), the same caveat the
        // beamterm spike carries in docs/PERF.md.
        const mark = () => w.__lat.muts.push(performance.now());
        new MutationObserver(mark).observe(live[0], {
            childList: true,
            subtree: true,
            characterData: true,
        });
        live[0].addEventListener("rook:frame", mark);
    });

    // 120 keystrokes, not 30: the interesting statistic here is the TAIL, and
    // a p95 off 30 samples is the 28th-of-30 value — it swung 7→24ms run to
    // run. Keys are spaced far wider than any echo, so pairing stays
    // unambiguous; the line wrapping mid-way is fine (the first mutation
    // after t0 is still the echo).
    await page.keyboard.type("abcdefghijklmnopqrstuvwxyz".repeat(5).slice(0, 120), {delay: 60});
    await page.waitForTimeout(500);

    const {lat, gaps} = await page.evaluate(() => {
        const w = window as unknown as {__lat: {keys: number[]; muts: number[]; raf: number[]}};
        const lat: number[] = [];
        for (const t0 of w.__lat.keys) {
            const t1 = w.__lat.muts.find((t) => t > t0 && t < t0 + 1000);
            if (t1 !== undefined) lat.push(t1 - t0);
        }
        const gaps: number[] = [];
        for (let i = 1; i < w.__lat.raf.length; i++) gaps.push(w.__lat.raf[i] - w.__lat.raf[i - 1]);
        return {lat, gaps};
    });

    // stop the firehose before teardown, or workspace delete races a busy pty
    await page.keyboard.press("Control+l");
    await clickShown(page.locator(".vt-screen").nth(1));
    await page.keyboard.press("Control+c");
    await page.waitForTimeout(500);

    expect(lat.length).toBeGreaterThanOrEqual(100);
    const sorted = [...lat].sort((a, b) => a - b);
    const q = (p: number) => sorted[Math.min(sorted.length - 1, Math.floor(p * sorted.length))];
    const fmt = (v: number) => v.toFixed(1);
    const g = grid.map((c) => `${c.cols}x${c.rows}`).join("+");
    const rafSorted = [...gaps].sort((a, b) => a - b);
    const rq = (p: number) =>
        rafSorted[Math.min(rafSorted.length - 1, Math.floor(p * rafSorted.length))];
    console.log(
        `LAT-LOAD[${MODE}] ${label} panes=${g} ` +
            `cells/pane=${grid[0].cols * grid[0].rows} n=${lat.length} ` +
            `p50=${fmt(q(0.5))}ms p95=${fmt(q(0.95))}ms p99=${fmt(q(0.99))}ms ` +
            `min=${fmt(sorted[0])}ms max=${fmt(sorted[sorted.length - 1])}ms | ` +
            `rAF-gap p50=${fmt(rq(0.5))}ms p95=${fmt(rq(0.95))}ms ` +
            `max=${fmt(rafSorted[rafSorted.length - 1])}ms`,
    );

    expect(q(0.95)).toBeLessThan(2_000);
}

// The last two rows separate the variables: wide-and-short has ~the cell
// count of 2560x1440 but ultrawide columns; narrow-and-tall has ~the cell
// count of 3440x1440 at baseline columns. If the cost tracks columns rather
// than cells, those two disagree.
const SWEEP = [
    {label: "1400x900-baseline", width: 1400, height: 900},
    {label: "2560x1440-qhd", width: 2560, height: 1440},
    {label: "3440x1440-ultrawide", width: 3440, height: 1440},
    {label: "5120x1440-super", width: 5120, height: 1440},
    {label: "5120x760-wide-short", width: 5120, height: 760},
    {label: "1400x2560-narrow-tall", width: 1400, height: 2560},
    // half of 6880 is one fullscreen 3440x1440 pane: the grid an ultrawide
    // user gets UNSPLIT, which is where the reports come from.
    {label: "6880x1440-uw-fullscreen-equiv", width: 6880, height: 1440},
    {label: "4400x2560-6k", width: 4400, height: 2560},
] as const;

// Density mode: one viewport that fits a laptop screen (so a headed run
// really rasterizes every cell), font size as the knob. The sizes were picked
// to land on roughly the same cells/pane as the viewport sweep above, so the
// two tables can be read side by side.
const DENSITY = [
    {label: "font18", fontSize: 18},
    {label: "font12", fontSize: 12},
    {label: "font9", fontSize: 9},
    {label: "font7", fontSize: 7},
    {label: "font6", fontSize: 6},
    {label: "font5", fontSize: 5},
] as const;

if (MODE === "density") {
    test.describe("loaded density @ 1400x900", () => {
        test.use({viewport: {width: 1400, height: 900}});
        for (const {label, fontSize} of DENSITY) {
            test(`keystroke latency beside a firehose @ ${label}`, async ({page}) => {
                test.setTimeout(180_000);
                await measure(page, label, fontSize);
            });
        }
    });
} else {
    for (const {label, width, height} of SWEEP) {
        test.describe(`loaded viewport ${label}`, () => {
            test.use({viewport: {width, height}});
            test(`keystroke latency beside a firehose @ ${label}`, async ({page}) => {
                test.setTimeout(180_000);
                await measure(page, label);
            });
        });
    }
}
