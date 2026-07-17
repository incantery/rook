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

// Run a palette command by title. Opens the palette via the titlebar button —
// focus-independent, because the leader chord is deliberately dead inside
// side panes (App's inSidePane guard) and the quickfix strip may hold focus.
async function runCommand(page: Page, title: string) {
    await page.getByRole("button", {name: /commands/}).click();
    await expect(page.getByPlaceholder("Run a command…")).toBeVisible();
    await page.getByPlaceholder("Run a command…").fill(title);
    await page.keyboard.press("Enter");
}

test("review pane prepares hunks, dispositions, and moves the gate", async ({page}) => {
    // unique per run: workspace delete doesn't drop its rook_tasks, so a fixed
    // name would carry a prior run's review (and its ids) into this one.
    await openWorkspace(page, `review-e2e-${Date.now()}`);

    // open the review quickfix strip (vim's bottom window)
    await runCommand(page, "Toggle review pane");
    const pane = page.locator('.side-pane[data-side="bottom"]');
    await expect(pane).toContainText("Review");
    await expect(pane).toContainText("j/k move"); // the footer hint = our pane mounted

    // prepare (or re-run) a batch — the rook checkout has changes to diff.
    // Stable label regardless of the ↻/Prepare glyph, so a review persisted
    // in the sandbox db from a prior run doesn't break the lookup.
    await page.getByRole("button", {name: "prepare"}).click();

    // hunk rows land in the generic quickfix list (review is its first tenant)
    const rows = page.locator("#quickfix-list [role=option]");
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
    await expect(page.locator("#quickfix-list")).toContainText("✓", {timeout: 10_000});

    // esc closes the hero and hands the keyboard BACK to the strip
    await page.keyboard.press("Escape");
    await expect(detail).toHaveCount(0);

    // :copen — close the list, reopen via the command, keyboard included:
    // j moves the cursor immediately, no click needed
    await runCommand(page, "Quickfix: close");
    await expect(pane).toHaveCount(0);
    await runCommand(page, "Quickfix: open list");
    await expect(pane).toBeVisible();
    await page.keyboard.press("g"); // top
    await page.keyboard.press("j"); // down one
    await expect(rows.nth(1)).toHaveAttribute("data-cursor", "1");

    // the context leader (vim's maplocalleader): ,q from a TERMINAL toggles
    // the strip. Leaders are deliberately dead inside side panes, so hop to
    // the terminal first — that's also the honest user path.
    await shown(page, ".xterm-screen").click();
    await page.keyboard.press(",");
    await page.keyboard.press("q");
    await expect(pane).toHaveCount(0);
    await page.keyboard.press(",");
    await page.keyboard.press("q");
    await expect(pane).toBeVisible();

    // ,a — the quick-action modal, rendered from the context's verbs
    await shown(page, ".xterm-screen").click();
    await page.keyboard.press(",");
    await page.keyboard.press("a");
    const qa = page.getByRole("dialog", {name: "quick actions"});
    await expect(qa).toBeVisible();
    await page.waitForTimeout(250); // let the fly-in settle for the screenshot
    await page.screenshot({path: "bin/e2e/quick-actions.png", fullPage: true});
    // d defers the current item straight from the modal, which then closes
    await page.keyboard.press("d");
    await expect(qa).toHaveCount(0);
    await expect(page.locator("#quickfix-list")).toContainText("»", {timeout: 10_000});

    // closing the modal hands the keyboard to the STRIP (the surface it acted
    // on): g/j work immediately, no click needed
    await page.keyboard.press("g");
    await page.keyboard.press("j");
    await expect(rows.nth(1)).toHaveAttribute("data-cursor", "1");

    // ,a works FROM the strip too (no text inputs there — leaders exempt);
    // reopen: j moves the SELECTION (Approve → Reject), Enter runs it
    await page.keyboard.press(",");
    await page.keyboard.press("a");
    await expect(qa).toBeVisible();
    await page.keyboard.press("j");
    await page.keyboard.press("Enter");
    await expect(qa).toHaveCount(0);
    await expect(page.locator("#quickfix-list")).toContainText("✗", {timeout: 10_000});

    await page.screenshot({path: "bin/e2e/review-pane.png", fullPage: true});
});
