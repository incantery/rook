import {expect, test, type Page} from "@playwright/test";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import {deleteWorkspaces, screenText, shellReady} from "./harness";

// The Mitchell Hashimoto cat test: `time cat 150MB` through a live pane at his
// benchmark geometry (6K fullscreen ≈ 405x113 cells). Measures true terminal
// IO throughput — cat finishes when the pty drains, so the number is the whole
// pipeline: pty → gather → parse → frames. Corpus is generated on demand and
// cleaned up; the run costs ~15s and 300MB of temp disk, so it is opt-in:
//
//   ROOK_CAT_BENCH=1 make e2e ARGS=e2e/catbench.spec.ts
//
// Results belong in docs/PERF.md. Grid size is part of the number — the
// viewport below reproduces 405x113; always compare like against like.

const REPO = path.resolve(process.cwd(), "..");
const shown = (page: Page, sel: string) => page.locator(`${sel} >> visible=true`).first();
const made: string[] = [];

test.use({viewport: {width: 4400, height: 2560}});
test.skip(!process.env.ROOK_CAT_BENCH, "opt-in: set ROOK_CAT_BENCH=1");

const DIR = path.join(os.tmpdir(), "rook-cat-bench");
const FILES = {
    "150mb_ascii.txt": "the quick brown fox jumps over the lazy dog while carrying a heavy load\n",
    "150mb_unicode.txt":
        "こんにちは世界 Привет мир مرحبا بالعالم 你好世界 Γειά σου Κόσμε हैलो वर्ल्ड héllo wörld\n",
} as const;

test.beforeAll(() => {
    fs.mkdirSync(DIR, {recursive: true});
    for (const [name, line] of Object.entries(FILES)) {
        const file = path.join(DIR, name);
        if (fs.existsSync(file)) continue;
        const block = line.repeat(Math.ceil((1 << 20) / line.length));
        const fd = fs.openSync(file, "w");
        let written = 0;
        while (written < 150_000_000) {
            written += fs.writeSync(fd, block);
        }
        fs.closeSync(fd);
    }
});
test.afterAll(() => fs.rmSync(DIR, {recursive: true, force: true}));
test.afterEach(async ({page}) => {
    await deleteWorkspaces(page, made.splice(0));
});

test("time cat 150MB at 6K-fullscreen geometry", async ({page}) => {
    test.setTimeout(600_000);
    made.push("cat-bench");
    await page.goto("/");
    await expect(page.locator("#home")).toBeVisible();
    await page.getByRole("button", {name: /^workspaces/}).click();
    await page.getByRole("button", {name: "New workspace"}).click();
    await page.getByPlaceholder("e.g. rook-core").fill("cat-bench");
    await page.getByPlaceholder("~/go/src/github.com/incantery/rook").fill(REPO);
    await page.getByRole("button", {name: "Create workspace"}).click();
    const term = shown(page, ".vt-screen");
    await expect(term).toBeVisible({timeout: 15_000});
    await shellReady(page, term);

    const grid = await term.evaluate((el) => {
        const s = (el as HTMLElement).style;
        return `${s.getPropertyValue("--vt-cols")}x${s.getPropertyValue("--vt-rows")}`;
    });
    console.log(`CAT-BENCH grid: ${grid}`);

    for (const file of Object.keys(FILES)) {
        for (let run = 1; run <= 2; run++) {
            await term.click();
            await page.keyboard.type(`time cat ${path.join(DIR, file)}`);
            await page.keyboard.press("Enter");
            await expect
                .poll(async () => (await screenText(term)).match(/cpu ([\d.:]+)\s+total/)?.[1], {
                    timeout: 300_000,
                })
                .toBeTruthy();
            const m = (await screenText(term)).match(/cpu ([\d.:]+)\s+total/);
            console.log(`CAT-BENCH ${file} run${run}: ${m?.[1]}s`);
            // clear so the next run's regex can't match this run's output
            await page.keyboard.type("clear");
            await page.keyboard.press("Enter");
            await expect
                .poll(async () => (await screenText(term)).includes("total"), {timeout: 15_000})
                .toBe(false);
        }
    }
});
