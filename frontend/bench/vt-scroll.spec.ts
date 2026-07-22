import {expect, test} from "@playwright/test";

// Scrollback, end to end in a real browser. The harness fed L0..L19 through a
// 4-row screen, so L0..L15 are in scrollback and L16..L19 are live.

test.describe("scrollback viewport", () => {
    test.beforeEach(async ({page}) => {
        await page.goto("/bench/vt-scroll.html");
        await page.waitForFunction(() => typeof window.visibleRows === "function");
    });

    test("starts pinned to the live tail", async ({page}) => {
        expect(await page.evaluate(() => window.visibleRows())).toEqual([
            "L16",
            "L17",
            "L18",
            "L19",
        ]);
        expect(await page.evaluate(() => window.scrollOffset())).toBe(0);
    });

    test("scrolling back reveals earlier lines", async ({page}) => {
        await page.evaluate(() => window.scrollBack(4));
        expect(await page.evaluate(() => window.scrollOffset())).toBe(4);
        expect(await page.evaluate(() => window.visibleRows())).toEqual([
            "L12",
            "L13",
            "L14",
            "L15",
        ]);
    });

    test("scrolling past the top clamps to the oldest line", async ({page}) => {
        await page.evaluate(() => window.scrollBack(1000));
        expect(await page.evaluate(() => window.scrollOffset())).toBe(16); // 16 lines of history
        expect(await page.evaluate(() => window.visibleRows())).toEqual(["L0", "L1", "L2", "L3"]);
    });

    test("returning to the bottom shows the live tail again", async ({page}) => {
        await page.evaluate(() => window.scrollBack(8));
        await page.evaluate(() => window.toBottom());
        expect(await page.evaluate(() => window.scrollOffset())).toBe(0);
        expect(await page.evaluate(() => window.visibleRows())).toEqual([
            "L16",
            "L17",
            "L18",
            "L19",
        ]);
    });

    test("Shift+PageUp scrolls history from the keyboard", async ({page}) => {
        await page.locator("#screen").focus();
        await page.keyboard.press("Shift+PageUp"); // one page = rows-1 = 3 lines
        expect(await page.evaluate(() => window.scrollOffset())).toBe(3);
        expect(await page.evaluate(() => window.visibleRows())).toEqual([
            "L13",
            "L14",
            "L15",
            "L16",
        ]);
    });

    test("the mouse wheel scrolls history", async ({page}) => {
        await page.locator("#screen").hover();
        await page.mouse.wheel(0, -200); // wheel up, into history
        expect(await page.evaluate(() => window.scrollOffset())).toBeGreaterThan(0);
        await page.mouse.wheel(0, 400); // wheel down, back toward live
        expect(await page.evaluate(() => window.scrollOffset())).toBe(0);
    });
});
