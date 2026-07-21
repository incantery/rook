import {expect, test, type Page} from "@playwright/test";
import * as path from "node:path";

// The explore work-type end-to-end: start an investigation, navigate (a
// picker open + a grep hit), and the breadcrumb trail shows the visits in
// the quickfix; finishing closes it.

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

test("an investigation collects breadcrumbs from navigation", async ({page}) => {
    test.setTimeout(120_000);
    const ws = `explore-e2e-${Date.now()}`;
    await openWorkspace(page, ws);

    // start: the question modal
    await runCommand(page, "Explore: start investigation");
    const q = page.getByPlaceholder("What are you trying to find out?");
    await expect(q).toBeVisible();
    await q.fill("where do breadcrumbs come from?");
    await q.press("Enter");

    // breadcrumb 1: a picker open
    await runCommand(page, "Open file (read-only)");
    const picker = page.getByPlaceholder("Open file…");
    await expect(picker).toBeVisible();
    await picker.fill("internal/host/exploretasks.go");
    await page.getByText("internal/host/exploretasks.go", {exact: true}).click();
    await expect(page.locator(".editor-path")).toContainText("exploretasks.go", {timeout: 15_000});

    // breadcrumb 2: a grep hit lands at its line
    await runCommand(page, "Grep workspace");
    const grep = page.getByPlaceholder("Grep the workspace…");
    await expect(grep).toBeVisible();
    await grep.fill("bounded walk-and-scan");
    const hit = page.getByText("internal/host/grep.go:", {exact: false}).first();
    await expect(hit).toBeVisible({timeout: 15_000});
    await hit.click();
    await expect(page.locator(".editor-path")).toContainText("internal/host/grep.go", {
        timeout: 20_000,
    });

    // the trail shows the question and both visits
    await runCommand(page, "Explore: show trail");
    const pane = page.locator('.side-pane[data-side="bottom"]');
    await expect(pane).toContainText("where do breadcrumbs come from?", {timeout: 15_000});
    await expect(pane).toContainText("internal/host/exploretasks.go", {timeout: 15_000});
    await expect(pane).toContainText("internal/host/grep.go");

    await page.screenshot({path: "bin/e2e/explore-trail.png", fullPage: true});

    // finish closes the investigation; the trail empties on re-open
    await runCommand(page, "Explore: finish investigation");
    await runCommand(page, "Explore: show trail");
    await expect(pane).toContainText("No breadcrumbs yet", {timeout: 15_000});
});
