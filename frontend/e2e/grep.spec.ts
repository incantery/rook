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
