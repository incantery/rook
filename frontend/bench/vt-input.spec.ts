import {expect, test} from "@playwright/test";

// Input forwarding and resize, in a real browser: press real keys and read back
// the pty bytes the renderer forwarded through its onInput sink, and resize the
// grid and check the DOM reshaped.

test.describe("input + resize", () => {
    test.beforeEach(async ({page}) => {
        await page.goto("/bench/vt-input.html");
        await page.waitForFunction(() => typeof window.sentInput === "function");
        await page.locator("#screen").focus();
        await page.evaluate(() => window.clearInput());
    });

    test("printable keys forward as themselves", async ({page}) => {
        await page.keyboard.type("hi!");
        expect(await page.evaluate(() => window.sentInput())).toEqual(["h", "i", "!"]);
    });

    test("named keys forward their escape sequences", async ({page}) => {
        await page.keyboard.press("Enter");
        await page.keyboard.press("ArrowUp");
        await page.keyboard.press("Backspace");
        expect(await page.evaluate(() => window.sentInput())).toEqual(["\r", "\x1b[A", "\x7f"]);
    });

    test("Ctrl+C forwards SIGINT when nothing is selected", async ({page}) => {
        await page.keyboard.press("Control+c");
        expect(await page.evaluate(() => window.sentInput())).toEqual(["\x03"]);
    });

    test("resize reshapes the grid and the DOM rows", async ({page}) => {
        await page.evaluate(() => window.doResize(40, 6));
        expect(await page.evaluate(() => window.gridSize())).toEqual({
            cols: 40,
            rows: 6,
            rowEls: 6,
        });
        // a frame at the new width paints on the new grid
        await page.evaluate(() => window.applyRow(5, "0123456789abcdefghijklmnopqrstuvwxyz0123"));
        expect(await page.evaluate(() => window.rowText(5))).toBe(
            "0123456789abcdefghijklmnopqrstuvwxyz0123",
        );
    });

    test("input still forwards after a resize", async ({page}) => {
        await page.evaluate(() => window.doResize(40, 6));
        await page.locator("#screen").focus();
        await page.keyboard.type("z");
        expect(await page.evaluate(() => window.sentInput())).toEqual(["z"]);
    });
});
