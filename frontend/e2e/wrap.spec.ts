import {expect, test, type Page} from "@playwright/test";
import * as path from "node:path";
import {deleteWorkspaces} from "./harness";

// `:set wrap` end to end. Wrapping is not readable from the DOM as a flag, so
// these assert the thing you'd actually notice: whether any rendered line is
// wider than the box it sits in. Monaco lays each DISPLAY line out as its own
// .view-line, so with wrapping on no line can overflow, and with it off a long
// one does.

const REPO = path.resolve(process.cwd(), "..");
const shown = (page: Page, sel: string) => page.locator(`${sel} >> visible=true`).first();
const made: string[] = [];

test.afterEach(async ({page}) => {
    await deleteWorkspaces(page, made.splice(0));
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
    await expect(page.locator(".editor-path", {hasText: file})).toHaveCount(1, {timeout: 20_000});
}

async function ex(page: Page, cmd: string) {
    await page.keyboard.type(cmd);
    await page.keyboard.press("Enter");
}

/** Is the pane wrapped? true/false, or null when the editor is not yet
 *  measurable (no box, no rendered lines).
 *
 *  The null matters. An earlier version of this returned a plain number and
 *  used -1 as "cannot tell", which every `<= 0` assertion happily read as
 *  "wrapped" — so the tests passed against code that never applied wrap at
 *  all. Anything unmeasurable must satisfy NEITHER expectation, so a poll
 *  keeps waiting instead of concluding. */
async function wrapped(page: Page): Promise<boolean | null> {
    return page.evaluate(() => {
        const box = document.querySelector(".editor-mount .monaco-scrollable-element");
        const lines = [...document.querySelectorAll(".editor-mount .view-line")];
        if (!box || !lines.length) return null;
        const widest = Math.max(...lines.map((l) => (l as HTMLElement).scrollWidth));
        return widest - box.clientWidth <= 0;
    });
}

test("`:set wrap` wraps the file pane, and `:set nowrap` puts it back", async ({page}) => {
    test.setTimeout(120_000);
    await openWorkspace(page, `wrap-${Date.now()}`);
    // NOTES.md has prose lines several hundred characters long — far past any
    // plausible viewport, so "does it overflow" is not a near thing
    await openFile(page, "NOTES.md");

    await expect.poll(() => wrapped(page), {timeout: 20_000}).toBe(false);

    await page.locator(".editor-mount .view-lines").click();
    await ex(page, ":set wrap");
    await expect.poll(() => wrapped(page), {timeout: 10_000}).toBe(true);

    await ex(page, ":set nowrap");
    await expect.poll(() => wrapped(page), {timeout: 10_000}).toBe(false);
});

test("`:set wrap?` reads the option back", async ({page}) => {
    test.setTimeout(120_000);
    await openWorkspace(page, `wrap-q-${Date.now()}`);
    await openFile(page, "NOTES.md");
    await page.locator(".editor-mount .view-lines").click();

    // vim's own spelling for a boolean read: " wrap" when on, " nowrap" when
    // off. It lands in monaco-vim's status bar, which rook mounts as .editor-vim.
    const bar = shown(page, ".editor-vim");
    await ex(page, ":set wrap?");
    await expect(bar).toContainText("nowrap", {timeout: 10_000});

    await ex(page, ":set wrap");
    await ex(page, ":set wrap?");
    await expect(bar).toContainText(/(^|[^o])wrap/, {timeout: 10_000});
});

test("wrap belongs to the pane, and survives retargeting it to another file", async ({page}) => {
    test.setTimeout(120_000);
    await openWorkspace(page, `wrap-e-${Date.now()}`);
    await openFile(page, "NOTES.md");
    await page.locator(".editor-mount .view-lines").click();
    await ex(page, ":set wrap");
    await expect.poll(() => wrapped(page), {timeout: 10_000}).toBe(true);

    // the same pane, pointed at a different document — 'wrap' is a property of
    // the window in vim, not of the buffer, so it must still hold
    await page.keyboard.press("Control+p");
    const picker = page.getByPlaceholder("Open file…");
    await expect(picker).toBeVisible({timeout: 10_000});
    await picker.fill("docs/e2e.md");
    await page.waitForTimeout(400);
    await picker.press("Enter");
    // one pane still: the file pane RETARGETED rather than splitting, which
    // is what makes this a test of window-local state and not of two windows
    await expect(page.locator(".editor-mount")).toHaveCount(1);
    await expect(page.locator(".editor-path", {hasText: "docs/e2e.md"})).toHaveCount(1);
    await expect.poll(() => wrapped(page), {timeout: 10_000}).toBe(true);
});

test("a pane opened after `:set wrap` inherits it — global scope is the default", async ({
    page,
}) => {
    test.setTimeout(120_000);
    await openWorkspace(page, `wrap-g-${Date.now()}`);
    await openFile(page, "NOTES.md");
    await page.locator(".editor-mount .view-lines").click();

    // `:set` with no scope writes BOTH scopes, which is vim's own rule: the
    // window you typed in changes now, and later windows start from it.
    await ex(page, ":set wrap");
    await expect.poll(() => wrapped(page), {timeout: 10_000}).toBe(true);

    await ex(page, ":q");
    await expect(page.locator(".editor-mount")).toHaveCount(0, {timeout: 10_000});

    // a genuinely new pane — its wrap field is seeded from the global default,
    // and this is what proves the seed reaches Monaco rather than just being
    // reported back by `:set wrap?`
    await openFile(page, "NOTES.md");
    await expect.poll(() => wrapped(page), {timeout: 20_000}).toBe(true);
});
