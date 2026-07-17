import {expect, test, type Page} from "@playwright/test";
import * as path from "node:path";

// The review pane end-to-end: open a workspace rooted at the rook checkout
// (which always has some working-tree state to diff), open the Review side
// pane, prepare a batch, and drive a disposition. This is the real host —
// prepareReview shells git in the sandbox, the gate is the daemon's.

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

// Open the command palette (leader `k`) and run a command by its title.
async function runCommand(page: Page, title: string) {
    await page.keyboard.press("Backquote");
    await page.keyboard.press("k");
    await expect(page.getByPlaceholder("Run a command…")).toBeVisible();
    await page.getByPlaceholder("Run a command…").fill(title);
    await page.keyboard.press("Enter");
}

test("review pane prepares hunks, dispositions, and moves the gate", async ({page}) => {
    // unique per run: workspace delete doesn't drop its rook_tasks, so a fixed
    // name would carry a prior run's review (and its ids) into this one.
    await openWorkspace(page, `review-e2e-${Date.now()}`);

    // open the Review side pane
    await runCommand(page, "Toggle review pane");
    const pane = page.locator('.side-pane[data-side="left"]');
    await expect(pane).toContainText("Review");
    await expect(pane).toContainText("j/k move"); // the footer hint = our pane mounted

    // prepare (or re-run) a batch — the rook checkout has changes to diff.
    // Stable label regardless of the ↻/Prepare glyph, so a review persisted
    // in the sandbox db from a prior run doesn't break the lookup.
    await page.getByRole("button", {name: "prepare review"}).click();

    // hunk rows land (each row shows a repo-relative path in mono)
    const rows = page.locator("#review-hunks [role=option]");
    await expect(rows.first()).toBeVisible({timeout: 10_000});
    expect(await rows.count()).toBeGreaterThan(0);

    // the gate reports its hunk count
    await expect(pane).toContainText(/hunks/);

    // clicking a hunk opens the bespoke detail overlay (NOT Monaco): the hunk
    // as a decision object — analysis, its own diff, disposition.
    await rows.first().click();
    const detail = page.getByRole("dialog", {name: "review hunk"});
    await expect(detail).toBeVisible();
    await expect(detail.getByRole("button", {name: /Approve/})).toBeVisible();

    // approve from the overlay (it holds the keyboard); a hunk goes ✓ in the
    // list and the gate moves.
    await page.keyboard.press("a");
    await expect(page.locator("#review-hunks")).toContainText("✓", {timeout: 10_000});

    await page.screenshot({path: "bin/e2e/review-pane.png", fullPage: true});
});
