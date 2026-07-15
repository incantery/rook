import {expect, test} from "@playwright/test";

// The footprint chip is fed by GET /runtime, which samples the real process
// table — so this covers the whole path: host sensor → gauge → chip. The
// numbers are the machine's, never a fixture, so assert the shape only.
test("mission control reports the live process footprint", async ({page}) => {
    await page.goto("/");
    const chip = page.locator("#home-footprint");
    await expect(chip).toBeVisible({timeout: 15_000});

    // reads as a size — 4.8G / 812M, ⚠-prefixed when WebKit is orphaned
    await expect(chip).toHaveText(/^(⚠ )?\d+(\.\d)?[GM]$/);

    const title = await chip.getAttribute("title");
    expect(title).toMatch(/host: \d+(\.\d)?[GM]/); // rook-host is always running
    expect(title).toMatch(/total: \d+(\.\d)?[GM]/);
});
