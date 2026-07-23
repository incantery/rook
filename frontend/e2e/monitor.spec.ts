import {expect, test, type Page} from "@playwright/test";
import * as path from "node:path";
import {deleteWorkspaces} from "./harness";

// The footprint chip is fed by GET /runtime, which samples the real process
// table — so this covers the whole path: host sensor → gauge → chip. The
// numbers are the machine's, never a fixture, so assert the shape only.
test("mission control reports the live process footprint", async ({page}) => {
    await page.goto("/");
    // ambient telemetry lives in the global status bar now
    const chip = page.locator("#sb-footprint");
    await expect(chip).toBeVisible({timeout: 15_000});

    // reads as a size — 4.8G / 812M, ⚠-prefixed when WebKit is orphaned
    await expect(chip).toHaveText(/^(⚠ )?\d+(\.\d)?[GM]$/);

    const title = await chip.getAttribute("title");
    expect(title).toMatch(/host: \d+(\.\d)?[GM]/); // rook-host is always running
    expect(title).toMatch(/total: \d+(\.\d)?[GM]/);
});

const REPO = path.resolve(process.cwd(), "..");
const made: string[] = [];
test.afterEach(async ({page}) => {
    await deleteWorkspaces(page, made.splice(0));
});

async function openWorkspace(page: Page, name: string) {
    made.push(name);
    await page.goto("/");
    await expect(page.locator("#home")).toBeVisible();
    await page.getByRole("button", {name: /^workspaces/i}).click();
    await page.getByRole("button", {name: "New workspace"}).click();
    await expect(page.locator("#ws-modal")).toBeVisible();
    await page.getByPlaceholder("e.g. rook-core").fill(name);
    await page.getByPlaceholder("~/go/src/github.com/incantery/rook").fill(REPO);
    await page.getByRole("button", {name: "Create workspace"}).click();
    await expect(page.locator(".vt-screen >> visible=true").first()).toBeVisible({
        timeout: 15_000,
    });
}

// Clicking the titlebar footprint chip opens the performance pane: the
// rook-vs-workload headline tiles and the live per-session table, fed by
// /runtime?detail=1 against the real daemon. Charts may still be collecting
// (the stored series ticks at 30s) — the pane itself must not depend on them.
test("the footprint chip opens the performance pane", async ({page}) => {
    await openWorkspace(page, "monitor-pane");
    // the footprint row lives inside the titlebar's usage cluster now
    await page.locator("#tb-usage").click();
    const chip = page.locator("#tb-footprint");
    await expect(chip).toBeVisible({timeout: 15_000});
    await chip.click();

    const pane = page.locator('[data-testid="monitor-pane"]');
    await expect(pane).toBeVisible({timeout: 10_000});
    // the headline split is present and reads as sizes/percentages
    await expect(pane.getByText("workload memory")).toBeVisible();
    await expect(pane.getByText("rook memory")).toBeVisible();
    // the live table names the session this workspace opened
    await expect(pane.getByText("sessions, live")).toBeVisible();
    await expect(pane.locator("table tbody tr").first()).toBeVisible({timeout: 10_000});

    // the chip is a singleton opener: clicking again reveals, not duplicates
    // (the cluster closes itself after opening the pane — reopen it first)
    await page.locator("#tb-usage").click();
    await chip.click();
    await expect(page.locator('[data-testid="monitor-pane"]')).toHaveCount(1);
});
