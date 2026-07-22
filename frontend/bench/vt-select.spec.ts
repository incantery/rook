import {expect, test} from "@playwright/test";

// Selection and copy, end to end in a real browser: real mouse drags at exact
// cell coordinates through the renderer's own listeners, and a real clipboard
// round-trip. Content is "hello world" / "second line here" / "foo(bar) baz".

async function drag(
    page: import("@playwright/test").Page,
    from: [number, number],
    to: [number, number],
) {
    const a = await page.evaluate(([x, y]) => window.cellCenter(x, y), from);
    const b = await page.evaluate(([x, y]) => window.cellCenter(x, y), to);
    await page.mouse.move(a.x, a.y);
    await page.mouse.down();
    await page.mouse.move(b.x, b.y, {steps: 6});
    await page.mouse.up();
}

test.describe("selection and copy", () => {
    test.beforeEach(async ({page}) => {
        await page.goto("/bench/vt-select.html");
        await page.waitForFunction(() => typeof window.getSel === "function");
    });

    test("drag selects a single-line span", async ({page}) => {
        await drag(page, [0, 0], [4, 0]); // h e l l o
        expect(await page.evaluate(() => window.getSel())).toBe("hello");
    });

    test("drag across rows selects in reading order with trimmed lines", async ({page}) => {
        await drag(page, [6, 0], [5, 1]); // "world" -> end of row 0, then start of row 1 "second"
        expect(await page.evaluate(() => window.getSel())).toBe("world\nsecond");
    });

    test("double-click selects the word", async ({page}) => {
        const p = await page.evaluate(() => window.cellCenter(2, 0)); // inside "hello"
        await page.mouse.dblclick(p.x, p.y);
        expect(await page.evaluate(() => window.getSel())).toBe("hello");
    });

    test("double-click stops at separators", async ({page}) => {
        const p = await page.evaluate(() => window.cellCenter(5, 2)); // "bar" inside foo(bar)
        await page.mouse.dblclick(p.x, p.y);
        expect(await page.evaluate(() => window.getSel())).toBe("bar");
    });

    test("triple-click selects the whole line, trailing blanks trimmed", async ({page}) => {
        const p = await page.evaluate(() => window.cellCenter(3, 1));
        await page.mouse.click(p.x, p.y, {clickCount: 3});
        expect(await page.evaluate(() => window.getSel())).toBe("second line here");
    });

    test("a plain click clears the selection", async ({page}) => {
        await drag(page, [0, 0], [4, 0]);
        expect(await page.evaluate(() => window.getSel())).toBe("hello");
        const p = await page.evaluate(() => window.cellCenter(0, 2));
        await page.mouse.click(p.x, p.y);
        expect(await page.evaluate(() => window.getSel())).toBe("");
    });

    test("Cmd/Ctrl+C copies the selection to the clipboard", async ({page, context}) => {
        await context.grantPermissions(["clipboard-read", "clipboard-write"]);
        await drag(page, [0, 0], [4, 0]);
        await page.locator("#screen").focus();
        await page.keyboard.press(process.platform === "darwin" ? "Meta+c" : "Control+c");
        const clip = await page.evaluate(() => navigator.clipboard.readText());
        expect(clip).toBe("hello");
    });
});
