import {expect, test} from "./harness";

// Click forwarding to mouse-tracking programs — vim's click-to-position, tmux
// pane select, htop's rows, Claude Code's scroll regions.
//
// This exists because the renderer swap (2026-07-27, DOM renderer deleted)
// silently dropped it: beamterm forwarded only the wheel, so scrolling still
// felt right while every click stopped reaching the program. Nothing in the
// suite noticed, which is the whole argument for this file.
//
// The probe is `cat -v`, which renders control bytes visibly: with tracking
// enabled, a click arrives at the pty as an SGR report and `cat -v` prints it
// as ^[[<0;COL;ROWM. Asserting on the pty's own echo means the test can only
// pass if the bytes really left the browser.

test("a click reaches a mouse-tracking program", async ({page, rook}) => {
    test.setTimeout(120_000);
    await rook.open({name: `mouse-${Date.now()}`});
    await rook.shellReady();

    // ?1000h normal tracking (press+release), ?1006h SGR encoding — what a
    // modern TUI asks for. Then cat -v to make the reports readable.
    await rook.ex(`printf '\\033[?1000h\\033[?1006h'; cat -v`);
    // the host has to see the DECSET and push the level down as msgState
    // before the renderer will forward anything, so give the round trip a beat
    await page.waitForTimeout(1_000);

    const term = rook.term();
    const box = await term.boundingBox();
    if (!box) throw new Error("terminal has no box");
    // well inside the grid, away from row 0 so the report is unambiguous
    await page.mouse.click(box.x + box.width / 3, box.y + box.height / 3);

    // ^[[< is the SGR press; the release follows as ...m. Button 0 = left.
    await rook.expectScreen(/\^\[\[<0;\d+;\d+M/);
    await rook.expectScreen(/\^\[\[<0;\d+;\d+m/);

    // ctrl-c out of cat so teardown isn't racing a live reader
    await page.keyboard.press("Control+c");
});

test("without tracking, a click selects instead of reporting", async ({page, rook}) => {
    test.setTimeout(120_000);
    await rook.open({name: `mouse-off-${Date.now()}`});
    await rook.shellReady();

    // same probe, tracking NOT enabled: the click is the browser's / the
    // renderer's own selection, and no report may reach the pty
    await rook.ex(`cat -v`);
    await page.waitForTimeout(500);

    const term = rook.term();
    const box = await term.boundingBox();
    if (!box) throw new Error("terminal has no box");
    await page.mouse.click(box.x + box.width / 3, box.y + box.height / 3);
    await page.waitForTimeout(500);

    expect(await rook.screen()).not.toMatch(/\^\[\[</);
    await page.keyboard.press("Control+c");
});
