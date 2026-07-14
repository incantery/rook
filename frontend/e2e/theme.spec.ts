import {expect, test, type Page} from "@playwright/test";

// Theming Phase A claimed one palette drives chrome, terminals, and Monaco,
// swappable at runtime with no reload. vitest already covers the pure mapping
// (palette → cssVars/xterm/monaco); what only a browser can show is that the
// vars actually reach :root, that the picker rewrites them live, and that the
// choice survives a restart. That's what's here.

const rootVar = (page: Page, name: string) =>
    page.evaluate(
        (n) => getComputedStyle(document.documentElement).getPropertyValue(n).trim(),
        name,
    );

/** Open Settings → Appearance, the way you actually can from mission control:
 *  via the palette. NOT cmd+, — the home screen gates chords down to the two
 *  commands that work without a terminal (App.svelte onKeydown), and
 *  config.settings isn't one of them. */
async function openAppearance(page: Page) {
    await expect(page.locator("#home")).toBeVisible();
    await page.keyboard.press("Meta+k");
    const query = page.getByPlaceholder("Run a command…");
    await expect(query).toBeVisible();
    await query.fill("Settings");
    await page.keyboard.press("Enter");
    await expect(page.locator("#settings")).toBeVisible();
    await page.getByText("Appearance", {exact: true}).click();
    await expect(page.locator("#theme-select")).toBeVisible();
}

test("boots with the Material Ocean palette on :root", async ({page}) => {
    await page.goto("/");
    await expect(page.locator("#home")).toBeVisible();
    // The applier writes documentElement inline, so these beat app.css's
    // :root defaults — same values, but proving the runtime path ran.
    expect(await rootVar(page, "--color-acc")).toBe("#82aaff");
    expect(await rootVar(page, "--bg")).toBe("#0f111a");
});

test("picking a theme recolors chrome live, without a reload", async ({page}) => {
    await page.goto("/");
    await openAppearance(page);

    // A reload would wipe this; its survival is the "no reload" assertion.
    await page.evaluate(() => Object.assign(window, {__mark: true}));

    await page.locator("#theme-select").selectOption("One Light");

    await expect.poll(() => rootVar(page, "--bg")).toBe("#fafafa");
    expect(await rootVar(page, "--color-acc")).toBe("#4078f2");
    expect(await page.evaluate(() => "__mark" in window)).toBe(true);
});

test("the theme choice survives a restart", async ({page}) => {
    await page.goto("/");
    await openAppearance(page);
    await page.locator("#theme-select").selectOption("One Dark");
    await expect.poll(() => rootVar(page, "--bg")).toBe("#282c34");

    // Reload re-reads config from disk: this covers the SetConfig write
    // through config.Service, not just the in-memory swap above.
    await page.reload();
    await expect(page.locator("#home")).toBeVisible();
    expect(await rootVar(page, "--bg")).toBe("#282c34");

    // Leave the sandbox on the default so other specs see a clean slate.
    await openAppearance(page);
    await page.locator("#theme-select").selectOption("Material Ocean");
    await expect.poll(() => rootVar(page, "--bg")).toBe("#0f111a");
});
