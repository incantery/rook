import {expect, test, type Page} from "@playwright/test";
import {booted, summonHome} from "./harness";

// Theming Phase A claimed one palette drives chrome, terminals, and Monaco,
// swappable at runtime with no reload. vitest already covers the pure mapping
// (palette → cssVars/xterm/monaco); what only a browser can show is that the
// vars actually reach :root, that the picker rewrites them live, that the
// choice survives a restart — and that the chrome actually OBEYS them.

const rootVar = (page: Page, name: string) =>
    page.evaluate(
        (n) => getComputedStyle(document.documentElement).getPropertyValue(n).trim(),
        name,
    );

/** Relative luminance (0=black, 1=white) of an element's rendered color.
 *
 *  Don't parse the computed string: Tailwind's opacity utilities compile to
 *  color-mix(), which Chrome reports as `oklab(0.18 0.0015 -0.019 / 0.98)` —
 *  regex the numbers out of that and you read a LIGHTNESS as a red channel and
 *  get a passing test that means nothing. Rasterizing on a 1px canvas is the
 *  honest read.
 *
 *  Composited over BLACK, so for a translucent surface this is a conservative
 *  LOWER bound on how light it really renders (One Light's #ffffff well at /80
 *  reads 0.80 here, not the ~0.96 it shows over the panel it actually sits on).
 *  Thresholds below are set against that, not against the true value — the two
 *  populations are ~0.02 vs ~0.80, so the slack costs nothing. */
async function luma(page: Page, sel: string, prop: "backgroundColor" | "color"): Promise<number> {
    const [r, g, b] = await page.locator(sel).evaluate((el, p) => {
        const css = getComputedStyle(el)[p as "color"];
        const c = document.createElement("canvas");
        c.width = c.height = 1;
        const ctx = c.getContext("2d")!;
        ctx.fillStyle = "#000";
        ctx.fillRect(0, 0, 1, 1);
        ctx.fillStyle = css;
        ctx.fillRect(0, 0, 1, 1);
        return [...ctx.getImageData(0, 0, 1, 1).data].slice(0, 3);
    }, prop);
    return (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255;
}

const surfaceLuma = (page: Page, sel: string) => luma(page, sel, "backgroundColor");

/** Open Settings → Appearance, the way you actually can from mission control:
 *  via the palette. NOT cmd+, — the home screen gates chords down to the two
 *  commands that work without a terminal (App.svelte onKeydown), and
 *  config.settings isn't one of them. */
async function openAppearance(page: Page) {
    await summonHome(page);
    await page.keyboard.press("Meta+k");
    const query = page.getByPlaceholder("Run a command…");
    await expect(query).toBeVisible();
    await query.fill("Settings");
    await page.keyboard.press("Enter");
    await expect(page.locator("#settings")).toBeVisible();
    await page.getByText("Appearance", {exact: true}).click();
    await expect(page.locator("#theme-select")).toBeVisible();
}

/** Put the app in a known theme, leaving Settings open.
 *
 *  The picker is a LIVE PREVIEW only — the app no longer writes config
 *  (ghostty model: the file is user-owned; persist a theme by editing
 *  config.toml). Every spec still establishes its own theme so it never
 *  depends on the sandbox config's default. (The true first-boot default is
 *  a Go concern — config.Default().Theme — and is tested there.) */
async function useTheme(page: Page, name: string) {
    await openAppearance(page);
    await page.locator("#theme-select").selectOption(name);
}

test("applies the Material Ocean palette to :root", async ({page}) => {
    await page.goto("/");
    await useTheme(page, "Material Ocean");
    // The applier writes documentElement inline, so these beat app.css's
    // :root defaults — same values, but proving the runtime path ran.
    expect(await rootVar(page, "--color-acc")).toBe("#82aaff");
    expect(await rootVar(page, "--bg")).toBe("#0f111a");
});

test("picking a theme recolors chrome live, without a reload", async ({page}) => {
    await page.goto("/");
    await useTheme(page, "Material Ocean");

    // A reload would wipe this; its survival is the "no reload" assertion.
    await page.evaluate(() => Object.assign(window, {__mark: true}));

    await page.locator("#theme-select").selectOption("One Light");

    await expect.poll(() => rootVar(page, "--bg")).toBe("#fafafa");
    expect(await rootVar(page, "--color-acc")).toBe("#4078f2");
    expect(await page.evaluate(() => "__mark" in window)).toBe(true);
});

// The regression the Settings sweep fixed. Settings hardcoded bg-[#0a0c14] /
// bg-[#151924] panels, so a light theme flipped --fg dark and left the surface
// dark: dark-on-dark, unreadable. Asserting the var is set is NOT enough — it
// was set correctly before too, and Settings simply ignored it. This asserts
// the rendered pixels.
test("a light theme actually lightens the Settings surfaces", async ({page}) => {
    await page.goto("/");
    await useTheme(page, "Material Ocean");
    expect(await surfaceLuma(page, "#settings")).toBeLessThan(0.2);

    await page.locator("#theme-select").selectOption("One Light");
    await expect.poll(() => rootVar(page, "--bg")).toBe("#fafafa");

    // the panel, and the well the inputs sit in, both follow the palette now
    await expect.poll(() => surfaceLuma(page, "#settings")).toBeGreaterThan(0.7);
    expect(await surfaceLuma(page, "#theme-select")).toBeGreaterThan(0.7);
    // …and the text stayed dark against them, which is the actual readability
    expect(await luma(page, "#theme-select", "color")).toBeLessThan(0.4);
});

// Every built-in must be pickable and coherent — a generated palette (the
// Catppuccin flavours come out of importVSCode, not a human) can carry a role
// that's empty or that collapsed into another. Cheap to check for all of them,
// and it fails the moment a new theme is registered badly.
test("every built-in theme applies coherently", async ({page}) => {
    await page.goto("/");
    await openAppearance(page);
    const names = await page.locator("#theme-select option").allTextContents();
    expect(names).toContain("Catppuccin Mocha");
    expect(names).toContain("Catppuccin Latte");

    for (const name of names) {
        await page.locator("#theme-select").selectOption(name);
        const vars = await page.evaluate(() => {
            const s = getComputedStyle(document.documentElement);
            return ["--bg", "--fg", "--dim", "--acc", "--color-sunken", "--color-on-acc"].map((n) =>
                s.getPropertyValue(n).trim(),
            );
        });
        for (const v of vars) expect(v, `${name} has an unset role`).toMatch(/^#[0-9a-f]{6,8}$/i);
        const [bg, fg, dim] = vars;
        // dim collapsing into fg is exactly what the real Catppuccin JSON does
        // (descriptionForeground === foreground); the importer must not pass it on
        expect(dim, `${name}: dim collapsed into fg`).not.toBe(fg);
        expect(fg, `${name}: fg collapsed into bg`).not.toBe(bg);
    }
});

test("a light Catppuccin flavour lightens the chrome too", async ({page}) => {
    await page.goto("/");
    await useTheme(page, "Catppuccin Latte");
    await expect.poll(() => rootVar(page, "--bg")).toBe("#eff1f5");
    // the sweep's tokens carry a generated palette, not just the authored ones
    await expect.poll(() => surfaceLuma(page, "#settings")).toBeGreaterThan(0.7);
    expect(await luma(page, "#theme-select", "color")).toBeLessThan(0.4);
});

test("the theme picker is a live preview — a reload reverts to config", async ({page}) => {
    await page.goto("/");
    await booted(page);
    const configured = await rootVar(page, "--bg");

    await useTheme(page, "One Dark");
    await expect.poll(() => rootVar(page, "--bg")).toBe("#282c34");

    // The app no longer writes config: a reload re-reads the file, and the
    // previewed theme must NOT have leaked into it.
    await page.reload();
    await booted(page);
    expect(await rootVar(page, "--bg")).toBe(configured);
});
