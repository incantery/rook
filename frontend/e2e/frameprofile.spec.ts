import {expect, test, type Page} from "@playwright/test";
import * as path from "node:path";
import {clickShown, deleteWorkspaces, gotoHome, shellReady, shown} from "./harness";

// Where the client's frame time actually goes: decode → grid apply → paint,
// per frame, in microseconds.
//
// This is the instrument the optimization campaign was missing. Every other
// probe bottoms out somewhere useless: headless lies about pixels, and headed
// the keystroke measurement is quantized by the display's frame clock (both
// renderers landed on 8.3ms at every grid size, docs/PERF.md). Neither can
// tell you whether the TS bridge — wire → decode → object graph → span build —
// is worth moving off the main thread. This can: it measures the work itself,
// at a resolution the display cannot impose on it.
//
// It is therefore the judge for the Worker + OffscreenCanvas change. Those
// three stages are exactly what would move; if their total is already small
// against a 8.3ms frame, the worker buys isolation from OTHER main-thread work
// rather than raw speed, and that is a different (still real) argument.
//
//   ROOK_FRAME_PROFILE=1 make e2e ARGS=e2e/frameprofile.spec.ts
//   (headed is more faithful for paint; headless still measures decode/apply)

const REPO = path.resolve(process.cwd(), "..");
const made: string[] = [];

test.skip(!process.env.ROOK_FRAME_PROFILE, "opt-in: set ROOK_FRAME_PROFILE=1");

test.afterEach(async ({page}) => {
    await deleteWorkspaces(page, made.splice(0));
});

interface Sample {
    bytes: number;
    rows: number;
    decode: number;
    apply: number;
    paint: number;
    total: number;
}

function report(label: string, s: Sample[]) {
    const q = (key: keyof Sample, p: number) => {
        const v = s.map((x) => x[key]).sort((a, b) => a - b);
        return v[Math.min(v.length - 1, Math.floor(p * v.length))];
    };
    const f = (n: number) => n.toFixed(3);
    const sum = (key: keyof Sample) => s.reduce((a, x) => a + x[key], 0);
    console.log(
        `FRAME ${label} n=${s.length} ` +
            `bytes/frame=${Math.round(sum("bytes") / s.length)} ` +
            `rows/frame=${(sum("rows") / s.length).toFixed(1)} | ` +
            `decode p50=${f(q("decode", 0.5))} p95=${f(q("decode", 0.95))} | ` +
            `apply p50=${f(q("apply", 0.5))} p95=${f(q("apply", 0.95))} | ` +
            `paint p50=${f(q("paint", 0.5))} p95=${f(q("paint", 0.95))} | ` +
            `total p50=${f(q("total", 0.5))} p95=${f(q("total", 0.95))} ` +
            `max=${f(q("total", 1))}ms`,
    );
    // share of a 120Hz frame budget the client spends on its own pipeline
    const budget = 1000 / 120;
    console.log(
        `FRAME ${label} p50 total is ${((q("total", 0.5) / budget) * 100).toFixed(1)}% of 8.33ms`,
    );
}

async function profile(page: Page, label: string, cmd: string, settleMs: number) {
    made.push(`fp-${label}`);
    await gotoHome(page);
    await page.getByRole("button", {name: /^workspaces/i}).click();
    await page.getByRole("button", {name: "New workspace"}).click();
    await expect(page.locator("#ws-modal")).toBeVisible();
    await page.getByPlaceholder("e.g. rook-core").fill(`fp-${label}`);
    await page.getByPlaceholder("~/go/src/github.com/incantery/rook").fill(REPO);
    await page.getByRole("button", {name: "Create workspace"}).click();
    await expect(page.locator(`[data-workspace="fp-${label}"]`)).toBeVisible({timeout: 15_000});
    const term = shown(page, ".vt-screen");
    await expect(term).toBeVisible({timeout: 15_000});
    await shellReady(page, term);

    const grid = await term.evaluate((el) => {
        const s = (el as HTMLElement).style;
        return `${s.getPropertyValue("--vt-cols")}x${s.getPropertyValue("--vt-rows")}`;
    });

    // install the sink AFTER the shell settles so its startup frames are out
    await page.evaluate(() => {
        const w = globalThis as unknown as {__rookFrameProbe?: unknown; __frames: unknown[]};
        w.__frames = [];
        w.__rookFrameProbe = (t: unknown) => w.__frames.push(t);
    });

    await clickShown(term);
    await page.keyboard.type(cmd);
    await page.keyboard.press("Enter");
    await page.waitForTimeout(settleMs);

    const samples = (await page.evaluate(() => {
        const w = globalThis as unknown as {__rookFrameProbe?: unknown; __frames: Sample[]};
        w.__rookFrameProbe = undefined;
        return w.__frames;
    })) as unknown as Sample[];

    // stop whatever is running before teardown
    await page.keyboard.press("Control+c");
    await page.waitForTimeout(300);

    expect(samples.length).toBeGreaterThan(20);
    report(`${label} @${grid}`, samples);
}

test.describe("frame profile @ ultrawide geometry", () => {
    // 6880x1440 halves to one 3440x1440 fullscreen pane — the reported
    // ultrawide grid, unsplit. Oversized viewports are honored headed and
    // headless alike; only PAINT is suspect headless (no GPU), and decode +
    // apply are pure CPU and trustworthy either way.
    test.use({viewport: {width: 6880, height: 1440}});

    test("firehose: full-width lines at pty speed", async ({page}) => {
        test.setTimeout(180_000);
        await profile(page, "firehose", `yes "$(printf 'x%.0s' $(seq 1 300))"`, 4_000);
    });

    test("scroll churn: a big file through cat", async ({page}) => {
        test.setTimeout(180_000);
        await profile(page, "cat-src", `cat ${REPO}/frontend/src/App.svelte`, 3_000);
    });

    test("interactive: a slow trickle, the shape of typing", async ({page}) => {
        test.setTimeout(180_000);
        await profile(
            page,
            "trickle",
            `for i in $(seq 1 60); do printf 'line %s\\n' "$i"; sleep 0.05; done`,
            5_000,
        );
    });
});
