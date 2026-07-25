import {expect, test, type Page} from "@playwright/test";
import * as path from "node:path";
import {deleteWorkspaces, gotoHome} from "./harness";

// TextMate highlighting end to end: the real grammars, the real oniguruma
// WASM, the real Monaco pane. Monaco paints each token as <span class="mtkN">
// where N indexes the active theme's color map — so "did this actually get
// highlighted" is answerable by counting distinct mtk classes on a line, and
// "did the right thing get which color" by comparing two tokens' classes.

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

async function openFile(page: Page, file: string) {
    await page.getByRole("button", {name: /commands/}).click();
    await expect(page.getByPlaceholder("Run a command…")).toBeVisible();
    await page.getByPlaceholder("Run a command…").fill("Open file");
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

/** the FULL className of the first token whose text starts with `needle`.
 *  Monaco writes the color as mtk<id> and each font style as a separate
 *  class (mtkb/mtki/mtku/mtks), so the whole string is the paint.
 *
 *  Monaco renders every space as U+00A0 to hold the column width, so a needle
 *  with a space in it can never match raw textContent — the heading above
 *  reads "# End-to-end tests" in the DOM. classOf above got away
 *  without this only because every needle it was ever given is one word. */
async function fullClassOf(page: Page, needle: string): Promise<string | null> {
    return page.evaluate((n) => {
        const flat = (s: string) => s.replace(/\u00a0/g, " ").trim();
        for (const el of document.querySelectorAll(".editor-mount .view-line span[class^=mtk]")) {
            if (flat(el.textContent ?? "").startsWith(n)) return el.className;
        }
        return null;
    }, needle);
}

test("markdown prose is painted, not just its code fences", async ({page}) => {
    test.setTimeout(120_000);
    await openWorkspace(page, `hl-md-${Date.now()}`);
    // short, and its first 20 lines carry a heading, body prose, a code span
    // and a bold run — everything this asserts, above the fold
    await openFile(page, "docs/e2e.md");

    // Needles carry their markers because Monaco MERGES adjacent tokens that
    // share metadata: the grammar emits ` / make e2e / ` as three tokens, all
    // resolving to markup.inline.raw, so one span reading "`make e2e`" is what
    // reaches the DOM. Same for the ** around a bold run and the # of a
    // heading — which is the fall-outward contract working, visible in the
    // markup.
    const probes = async () => ({
        heading: await fullClassOf(page, "# End-to-end tests"),
        body: await fullClassOf(page, "drives the real rook"),
        span: await fullClassOf(page, "`make e2e`"),
        bold: await fullClassOf(page, "**server mode**"),
    });
    await expect
        .poll(async () => Object.values(await probes()).filter(Boolean).length, {timeout: 30_000})
        .toBe(4);

    const {heading, body, span, bold} = await probes();

    // The regression this whole change exists to prevent. Until markup.* was
    // claimed, every one of these resolved to the same class: markdown
    // tokenized correctly and then rendered as one flat color, because the
    // scope table only knew code roles. Fences looked fine and hid it.
    expect(heading).not.toBe(body);
    expect(span).not.toBe(body);

    // Headings carry weight as well as hue.
    expect(heading).toContain(" mtkb");

    // Emphasis is the OPPOSITE case: markup.bold is a style-only rule, so it
    // takes body color and adds weight. Monaco resolves each token's single
    // scope independently, so the color falls through the trie to the default
    // rather than to whatever construct enclosed it — asserting the exact
    // body class here is what pins that down.
    expect(bold).toBe(`${body} mtkb`);

    await page.screenshot({path: "bin/e2e/highlight-markdown.png", fullPage: true});
});

test("a language with no vendored grammar still tokenizes on Monarch", async ({page}) => {
    test.setTimeout(120_000);
    await openWorkspace(page, `hl-fallback-${Date.now()}`);
    // .mod has no vendored grammar and no Monaco language — it must open
    // cleanly rather than error, which is the fail-open contract
    await openFile(page, "go.mod");
    await expect(page.locator(".editor-mount .view-line").first()).toBeVisible({timeout: 20_000});
});
