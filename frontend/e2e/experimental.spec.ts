import {expect, test, type Page} from "@playwright/test";
import * as path from "node:path";
import {deleteWorkspaces} from "./harness";

// Settings → Experimental: the renderer toggle, exercised the way a user
// reaches it (palette → Settings — prod builds have no devtools, this UI is
// the only door). The flag applies at boot, so the flow is choose → reload →
// verify the pane actually runs the chosen renderer, then back again.

const REPO = path.resolve(process.cwd(), "..");
const shown = (page: Page, sel: string) => page.locator(`${sel} >> visible=true`).first();
const made: string[] = [];
test.afterEach(async ({page}) => {
    await deleteWorkspaces(page, made.splice(0));
});

async function openExperimental(page: Page) {
    await expect(page.locator("#home")).toBeVisible();
    await page.keyboard.press("Meta+k");
    const query = page.getByPlaceholder("Run a command…");
    await expect(query).toBeVisible();
    await query.fill("Settings");
    await page.keyboard.press("Enter");
    await expect(page.locator("#settings")).toBeVisible();
    await page.getByText("Experimental", {exact: true}).click();
    await expect(page.getByText("Terminal renderer")).toBeVisible();
}

async function openWorkspace(page: Page, name: string) {
    made.push(name);
    await page.getByRole("button", {name: /^workspaces/}).click();
    await page.getByRole("button", {name: "New workspace"}).click();
    await expect(page.locator("#ws-modal")).toBeVisible();
    await page.getByPlaceholder("e.g. rook-core").fill(name);
    await page.getByPlaceholder("~/go/src/github.com/incantery/rook").fill(REPO);
    await page.getByRole("button", {name: "Create workspace"}).click();
    await expect(shown(page, ".vt-screen")).toBeVisible({timeout: 15_000});
}

test("the experimental renderer toggle swaps and swaps back", async ({page}) => {
    await page.goto("/");
    await openExperimental(page);

    // choose WebGL; the reload affordance appears only when it would change
    // the running session
    await page.getByRole("radio").nth(1).check();
    await page.getByRole("button", {name: "Reload to apply"}).click();

    await openWorkspace(page, "exp-toggle");
    await expect(page.locator(".vt-webgl canvas")).toHaveCount(1, {timeout: 10_000});

    // and back: the toggle must be a two-way door
    await page.keyboard.press("Meta+k");
    await page.getByPlaceholder("Run a command…").fill("Settings");
    await page.keyboard.press("Enter");
    await page.getByText("Experimental", {exact: true}).click();
    await page.getByRole("radio").nth(0).check();
    await page.getByRole("button", {name: "Reload to apply"}).click();

    await expect(page.locator("#home")).toBeVisible({timeout: 15_000});
    await page.getByRole("button", {name: /^workspaces/}).click();
    await page
        .locator("#home-workspaces div.group")
        .filter({has: page.getByText("exp-toggle", {exact: true})})
        .first()
        .click();
    await expect(shown(page, ".vt-screen")).toBeVisible({timeout: 15_000});
    await expect(page.locator(".vt-webgl")).toHaveCount(0);
    await expect(shown(page, ".vt-screen").locator(".vt-row").first()).toBeAttached();
});
