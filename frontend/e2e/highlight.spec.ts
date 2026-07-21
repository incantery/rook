import {expect, test, type Page} from "@playwright/test";
import * as path from "node:path";

// TextMate highlighting end to end: the real grammars, the real oniguruma
// WASM, the real Monaco pane. Monaco paints each token as <span class="mtkN">
// where N indexes the active theme's color map — so "did this actually get
// highlighted" is answerable by counting distinct mtk classes on a line, and
// "did the right thing get which color" by comparing two tokens' classes.

const REPO = path.resolve(process.cwd(), "..");
const shown = (page: Page, sel: string) => page.locator(`${sel} >> visible=true`).first();
const made: string[] = [];

test.afterEach(async ({page}) => {
    for (const name of made.splice(0)) {
        await page.goto("/");
        await page.getByRole("button", {name: /^workspaces/}).click();
        const card = page
            .locator("#home-workspaces div.group")
            .filter({has: page.getByText(name, {exact: true})});
        await expect(card).toHaveCount(1);
        await card.getByTitle(/^Delete workspace/).click();
        await expect(card).toHaveCount(0);
    }
});

async function openWorkspace(page: Page, name: string) {
    made.push(name);
    await page.goto("/");
    await expect(page.locator("#home")).toBeVisible();
    await page.getByRole("button", {name: /^workspaces/}).click();
    await page.getByRole("button", {name: "New workspace"}).click();
    await expect(page.locator("#ws-modal")).toBeVisible();
    await page.getByPlaceholder("e.g. rook-core").fill(name);
    await page.getByPlaceholder("~/go/src/github.com/incantery/rook").fill(REPO);
    await page.getByRole("button", {name: "Create workspace"}).click();
    await expect(shown(page, ".xterm-screen")).toBeVisible({timeout: 15_000});
}

async function openFile(page: Page, file: string) {
    await page.getByRole("button", {name: /commands/}).click();
    await expect(page.getByPlaceholder("Run a command…")).toBeVisible();
    await page.getByPlaceholder("Run a command…").fill("Open file (read-only)");
    await page.keyboard.press("Enter");
    const picker = page.getByPlaceholder("Open file…");
    await expect(picker).toBeVisible();
    await picker.fill(file);
    await picker.press("Enter");
    await expect(page.locator(".editor-path")).toContainText(file, {timeout: 20_000});
}

/** distinct mtk* classes across the rendered viewport — the blunt "is this
 *  colored at all" measure (plain text renders as a single class). */
async function distinctTokenClasses(page: Page): Promise<string[]> {
    return page.evaluate(() => {
        const out = new Set<string>();
        for (const el of document.querySelectorAll(".editor-mount .view-line span[class^=mtk]")) {
            out.add(el.className);
        }
        return [...out];
    });
}

/** the mtk class of the first token whose text starts with `needle` (Monaco
 *  splits long lines across spans, so prefix beats equality), or null. The
 *  bracket-highlighting decoration rides along in className, so callers
 *  compare the leading mtk class only. */
async function classOf(page: Page, needle: string): Promise<string | null> {
    return page.evaluate((n) => {
        for (const el of document.querySelectorAll(".editor-mount .view-line span[class^=mtk]")) {
            const t = el.textContent ?? "";
            if (t.trim().startsWith(n)) return el.className.split(" ")[0];
        }
        return null;
    }, needle);
}

test("TextMate grammars highlight Go beyond what Monarch could", async ({page}) => {
    test.setTimeout(120_000);
    await openWorkspace(page, `hl-e2e-${Date.now()}`);
    await openFile(page, "internal/host/grep.go");

    // Tokenization is async AND two-stage: Monaco paints with Monarch first,
    // then swaps the whole line DOM when the grammar resolves. So poll the
    // real question — all four tokens present at once — rather than a proxy
    // like "enough distinct classes", which Monarch's first paint satisfies
    // and which then reads a half-replaced DOM.
    const tokens = async () => ({
        kw: await classOf(page, "package"), // keyword
        pkg: await classOf(page, "host"), // the package NAME beside it
        comment: await classOf(page, "//"),
        str: await classOf(page, '"bufio"'), // an import path
    });
    await expect
        .poll(async () => Object.values(await tokens()).filter(Boolean).length, {timeout: 30_000})
        .toBe(4);

    // Four roles, four colors. The kw/pkg pair is the one Monarch could not
    // draw: a keyword-list tokenizer sees both as bare identifiers.
    const {kw, pkg, comment, str} = await tokens();
    expect(new Set([kw, pkg, comment, str]).size).toBe(4);

    // …and the string carries its own quotes: pickScope walks out of
    // punctuation.definition.string onto the enclosing string scope, so
    // "bufio" is one colored run, not a quote/text/quote sandwich.
    const quotesMatchString = await page.evaluate(() => {
        for (const el of document.querySelectorAll(".editor-mount .view-line span[class^=mtk]")) {
            const t = el.textContent ?? "";
            if (t.trim().startsWith('"bufio"')) return t.trim() === '"bufio"';
        }
        return false;
    });
    expect(quotesMatchString).toBe(true);

    await page.screenshot({path: "bin/e2e/highlight-go.png", fullPage: true});
});

test("svelte files highlight at all — Monaco has no language for them", async ({page}) => {
    test.setTimeout(120_000);
    await openWorkspace(page, `hl-svelte-${Date.now()}`);
    await openFile(page, "frontend/src/Finder.svelte");

    // Before the bridge this was plaintext: ONE token class for the whole
    // file. The grammar also registers the language, so this is the crisp
    // before/after of the whole change.
    await expect
        .poll(async () => (await distinctTokenClasses(page)).length, {timeout: 30_000})
        .toBeGreaterThan(3);

    await page.screenshot({path: "bin/e2e/highlight-svelte.png", fullPage: true});
});

test("a language with no vendored grammar still tokenizes on Monarch", async ({page}) => {
    test.setTimeout(120_000);
    await openWorkspace(page, `hl-fallback-${Date.now()}`);
    // .mod has no vendored grammar and no Monaco language — it must open
    // cleanly rather than error, which is the fail-open contract
    await openFile(page, "go.mod");
    await expect(page.locator(".editor-mount .view-line").first()).toBeVisible({timeout: 20_000});
});
