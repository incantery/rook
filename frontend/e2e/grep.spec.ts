import {expect, test, type Page} from "@playwright/test";
import * as path from "node:path";
import {deleteWorkspaces, gotoHome, screenText, shellReady, shellRun} from "./harness";

// Live grep end-to-end: the ` / modal over the real host's git grep,
// a hit click landing the editor at the hit's file.

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
    const hit = page.locator("[data-finder-row]", {hasText: "internal/host/grep.go:"}).first();
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
    await expect(page.locator("[data-finder-list]")).toContainText("no matches", {
        timeout: 15_000,
    });
    await page.keyboard.press("Escape");
});

test("telescope keys: editor ⌃P/⌃G/⌃S, grep ⌃Q → quickfix, ` f reveal", async ({page}) => {
    test.setTimeout(120_000);
    const ws = `tele-e2e-${Date.now()}`;
    await openWorkspace(page, ws);

    // open a file and wait for vim — the keys under test are editor-scoped
    await runCommand(page, "Open file (read-only)");
    const picker = page.getByPlaceholder("Open file…");
    await expect(picker).toBeVisible();
    await picker.fill("internal/host/grep.go");
    await page.locator("[data-finder-row]").first().click();
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
    await expect(
        page.locator("[data-finder-row]", {hasText: "internal/host/grep.go:"}).first(),
    ).toBeVisible({timeout: 15_000});

    // ⌃Q — the hits become the location list, titled by the query
    await page.keyboard.press("Control+q");
    const pane = page.locator('.side-pane[data-side="bottom"]');
    await expect(pane).toContainText("Grep — walkGrep", {timeout: 15_000});
    await expect(pane).toContainText("grep.go");

    // ,f — the explorer opens with its cursor on the file under edit. The
    // tree is editor furniture now, so its key rides the editor leader —
    // armed here from the quickfix strip, one of the editor's own surfaces
    await page.keyboard.press(",");
    await page.keyboard.press("f");
    const cursorRow = page.locator(".tree-wrap [data-cursor=\"true\"]");
    await expect(cursorRow).toBeVisible({timeout: 15_000});
    await expect(cursorRow).toContainText("grep.go");

    // cwd scoping: cd into a subdir in the shell, and the pickers root there
    // (the vim experience) — names shorten, opens still resolve ws-relative.
    // The terminal lives in strip window 1 (the editor minted window 2) —
    // switch via the strip button, the prefix is dropped inside side panes.
    // named tabs: the accessible name is now "1 <pane name>", so match the
    // leading window number instead of the exact digit
    const stripOne = page.getByRole("button", {name: /^1\b/});
    await stripOne.click();
    const term = shown(page, ".vt-screen");
    // The shell may not be reading yet — a cold sandbox pays oh-my-zsh's
    // plugin compilation on its first run, and a cd typed into that goes
    // nowhere in time. This used to be a flat 800ms sleep, which is what made
    // the test fail cold and pass warm.
    await shellReady(page, term);
    await shellRun(page, term, "cd internal/host");
    // and prove the shell actually moved before asking the picker where it is
    await page.keyboard.type("pwd");
    await page.keyboard.press("Enter");
    await expect.poll(() => screenText(term), {timeout: 15_000}).toMatch(/\/internal\/host/);
    await page.keyboard.press("Control+p");
    await expect(picker).toBeVisible();
    await expect(page.getByText("in internal/host")).toBeVisible({timeout: 15_000});
    await picker.fill("grep.go");
    // Enter, not a row click — the explorer (still open from ` f) also shows
    // a "grep.go" text under the overlay's backdrop and steals the locator
    await picker.press("Enter");
    await expect(editorPath).toContainText("internal/host/grep.go", {timeout: 15_000});

    await stripOne.click();
    await term.click();
    await page.keyboard.press("Control+g");
    await expect(grepInput).toBeVisible();
    await grepInput.fill("bounded walk-and-scan");
    await expect(page.getByText("in internal/host")).toBeVisible({timeout: 15_000});
    const scopedHit = page.locator("[data-finder-row]", {hasText: "grep.go:"}).first();
    await expect(scopedHit).toBeVisible({timeout: 15_000});
    await page.keyboard.press("Escape");
});

test("the finder previews the row under the cursor, and ⌃y hides it", async ({page}) => {
    test.setTimeout(120_000);
    const ws = `preview-e2e-${Date.now()}`;
    await openWorkspace(page, ws);

    // Needles are BUILT AT RUNTIME and pick out a single Go definition. A
    // literal here would match this very spec file (--untracked greps it),
    // and the preview would faithfully show the spec instead of the source —
    // which is how the first draft of this test failed.
    const walk = ["func", "walkGrep(root"].join(" ");
    const safe = ["func", "promptSafe(s"].join(" ");

    // Grep, because a grep preview must prove BOTH halves: that it loads the
    // right file, and that it lands on the right line.
    await runCommand(page, "Grep workspace");
    const input = page.getByPlaceholder("Grep the workspace…");
    await input.fill(walk);
    await expect(page.locator("[data-finder-row]").first()).toBeVisible({timeout: 15_000});

    // the preview is a Monaco instance inside the overlay, holding content
    // the row itself never renders
    const preview = page.locator(".fixed .monaco-editor").first();
    await expect(preview).toBeVisible({timeout: 20_000});
    await expect(preview).toHaveAttribute("data-uri", /grep\.go$/, {timeout: 20_000});

    // it centered the HIT, not the top of the file — grep.go is ~200 lines
    // and walkGrep is near the end, so an unscrolled preview can't show it
    await expect(preview).toContainText("walkGrep", {timeout: 20_000});
    await expect(page.locator(".finder-hit-line").first()).toBeVisible({timeout: 10_000});

    // ⌃y collapses it — a narrow window sometimes wants all the rows
    await page.keyboard.press("Control+y");
    await expect(preview).toBeHidden({timeout: 10_000});
    await page.keyboard.press("Control+y");
    await expect(preview).toBeVisible({timeout: 10_000});

    // a new query retargets the preview in place rather than rebuilding it
    await input.fill(safe);
    await expect(page.locator("[data-finder-row]").first()).toBeVisible({timeout: 15_000});
    await expect(page.locator(".fixed .monaco-editor").first()).toHaveAttribute(
        "data-uri",
        /threads\.go$/,
        {timeout: 20_000},
    );

    await page.keyboard.press("Escape");
});
