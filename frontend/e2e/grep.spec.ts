import {expect, test, type Page} from "@playwright/test";
import * as path from "node:path";

// Live grep end-to-end: the ` / modal over the real host's git grep,
// a hit click landing the editor at the hit's file.

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

async function runCommand(page: Page, title: string) {
    await page.getByRole("button", {name: /commands/}).click();
    await expect(page.getByPlaceholder("Run a command…")).toBeVisible();
    await page.getByPlaceholder("Run a command…").fill(title);
    await page.keyboard.press("Enter");
}

test("grep modal searches the workspace and opens the hit", async ({page}) => {
    test.setTimeout(120_000);
    const ws = `grep-e2e-${Date.now()}`;
    await openWorkspace(page, ws);

    await runCommand(page, "Grep workspace");
    const input = page.getByPlaceholder("Grep the workspace…");
    await expect(input).toBeVisible();

    // a phrase that lives in exactly one place: grep.go's walk comment
    await input.fill("bounded walk-and-scan");
    const hit = page.getByText("internal/host/grep.go:", {exact: false}).first();
    await expect(hit).toBeVisible({timeout: 15_000});

    // click the row (its mousedown picks) — Enter can lose a focus race
    // against the freshly spawned terminal's replay gate
    await hit.click();
    await expect(page.locator(".editor-path")).toContainText("internal/host/grep.go", {
        timeout: 20_000,
    });

    // a miss is a labeled empty state. Built at runtime — a literal would
    // grep-match this very spec file (--untracked searches it too).
    await runCommand(page, "Grep workspace");
    await page.getByPlaceholder("Grep the workspace…").fill(["ZZ", "NOT", "HERE", "ZZ"].join("-"));
    await expect(page.getByText("no matches")).toBeVisible({timeout: 15_000});
    await page.keyboard.press("Escape");
});

test("telescope keys: editor ⌃P/⌃G/⌃S, grep ⌃Q → quickfix, ` f reveal", async ({page}) => {
    test.setTimeout(120_000);
    const ws = `tele-e2e-${Date.now()}`;
    await openWorkspace(page, ws);

    // open a file and wait for vim — the keys under test are editor-scoped
    await runCommand(page, "Open file (read-only)");
    const picker = page.getByPlaceholder("Open file (read-only)…");
    await expect(picker).toBeVisible();
    await picker.fill("internal/host/grep.go");
    await page.getByText("internal/host/grep.go", {exact: true}).click();
    const editorPath = page.locator(".editor-path");
    await expect(editorPath).toContainText("internal/host/grep.go", {timeout: 15_000});
    await expect(page.locator(".editor-vim")).toContainText(/NORMAL/i, {timeout: 15_000});
    await page.locator(".editor-mount").click();

    // relative line numbers: cursor on line 1 shows absolute, line 2 says "1"
    await page.keyboard.type("gg");
    const nums = page.locator(".editor-mount .line-numbers");
    await expect(nums.nth(0)).toHaveText("1");
    await expect(nums.nth(1)).toHaveText("1");
    await expect(nums.nth(2)).toHaveText("2");

    // yy mirrors the yanked line to the system clipboard (unnamedplus)
    await page.context().grantPermissions(["clipboard-read", "clipboard-write"]);
    await page.keyboard.type("yy");
    await expect
        .poll(() => page.evaluate(() => navigator.clipboard.readText()), {timeout: 5_000})
        .toContain("package host");

    // ⌃P — the file picker, from normal mode
    await page.keyboard.press("Control+p");
    await expect(picker).toBeVisible();
    await page.keyboard.press("Escape");

    // ⌃G — the grep picker, empty
    await page.locator(".editor-mount").click();
    await page.keyboard.press("Control+g");
    const grepInput = page.getByPlaceholder("Grep the workspace…");
    await expect(grepInput).toBeVisible();
    await expect(grepInput).toHaveValue("");
    await page.keyboard.press("Escape");

    // ⌃S — grep seeded with the word under the cursor; hits arrive unprompted
    await page.locator(".editor-mount").click();
    await page.keyboard.type("/walkGrep");
    await page.keyboard.press("Enter");
    await page.keyboard.press("Control+s");
    await expect(grepInput).toBeVisible();
    await expect(grepInput).toHaveValue("walkGrep");
    await expect(page.getByText("internal/host/grep.go:", {exact: false}).first()).toBeVisible({
        timeout: 15_000,
    });

    // ⌃Q — the hits become the location list, titled by the query
    await page.keyboard.press("Control+q");
    const pane = page.locator('.side-pane[data-side="bottom"]');
    await expect(pane).toContainText("Grep — walkGrep", {timeout: 15_000});
    await expect(pane).toContainText("grep.go");

    // ` f — the explorer opens with its cursor on the file under edit
    await page.keyboard.press("`");
    await page.keyboard.press("f");
    const cursorRow = page.locator('.side-pane[data-side="left"] [data-cursor="true"]');
    await expect(cursorRow).toBeVisible({timeout: 15_000});
    await expect(cursorRow).toContainText("grep.go");
});
