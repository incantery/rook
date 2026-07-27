import {expect, test, type Page} from "./harness";

// A theme swap has to reach the GPU renderer.
//
// The DOM renderer emits `var(--term-fg)` and friends, so writing the vars on
// :root re-tints it for free — which is exactly why this gap existed unnoticed:
// the code that "handles" theming is CSS, and beamterm doesn't read CSS. It
// samples --term-* once, into wasm CellStyle objects and two default colors,
// and then paints from GPU state. Until retheme() it kept painting the old
// palette until you reloaded the app.
//
// Only pixels can show this. The vars ARE correct in both worlds (theme.spec
// asserts that), the store is correct, the canvas is wrong — so the assertion
// has to be made of light: switching to a light theme must make the terminal
// visibly lighter, with no reload in between.

/** Mean relative luminance of what an element actually RENDERS, 0..1.
 *
 *  Round-trip through a screenshot rather than reading the canvas in-page:
 *  drawImage() off a WebGL canvas depends on preserveDrawingBuffer, which
 *  beamterm doesn't set, so the honest read is the composited image the
 *  browser already produced. Node has no PNG decoder here — the page does. */
async function paintedLuma(page: Page, sel: string): Promise<number> {
    const shot = await page.locator(sel).screenshot();
    const url = `data:image/png;base64,${shot.toString("base64")}`;
    return page.evaluate(async (u) => {
        const img = new Image();
        img.src = u;
        await img.decode();
        const c = document.createElement("canvas");
        c.width = img.width;
        c.height = img.height;
        const ctx = c.getContext("2d")!;
        ctx.drawImage(img, 0, 0);
        const d = ctx.getImageData(0, 0, c.width, c.height).data;
        let sum = 0;
        for (let i = 0; i < d.length; i += 4) {
            sum += 0.2126 * d[i] + 0.7152 * d[i + 1] + 0.0722 * d[i + 2];
        }
        return sum / (d.length / 4) / 255;
    }, url);
}

/** Pick a theme from Settings and close it again, leaving the app screen —
 *  and the terminal — on display. The palette is a live preview (theme.spec:
 *  a reload reverts to config), which is precisely the path under test. */
async function pickTheme(page: Page, name: string) {
    await page.keyboard.press("Meta+k");
    const query = page.getByPlaceholder("Run a command…");
    await expect(query).toBeVisible();
    await query.fill("Settings");
    await page.keyboard.press("Enter");
    await expect(page.locator("#settings")).toBeVisible();
    await page.getByText("Appearance", {exact: true}).click();
    await page.locator("#theme-select").selectOption(name);
    await page.keyboard.press("Escape");
    await expect(page.locator("#settings")).toHaveCount(0);
}

test("a theme swap repaints the WebGL terminal, with no reload", async ({page, rook}) => {
    test.setTimeout(120_000);
    await rook.open({name: "webgl-theme"});
    const canvas = ".window.active .vt-webgl canvas";
    await expect(page.locator(canvas)).toHaveCount(1, {timeout: 15_000});
    await page.waitForTimeout(1500); // fit() settles, the prompt lands

    await pickTheme(page, "One Dark");
    const dark = await paintedLuma(page, canvas);

    await pickTheme(page, "One Light");
    const light = await paintedLuma(page, canvas);

    // A terminal is mostly background, so this is mostly a --term-bg check —
    // which is the one that was stuck. The gap between the two is enormous
    // (≈0.03 vs ≈0.9); a threshold this loose only fires on "nothing moved".
    expect(light - dark).toBeGreaterThan(0.3);
});
