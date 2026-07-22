import {expect, test} from "@playwright/test";

// The D5 gate. DOM is measured on the two cases it is weakest at — a full-screen
// scrollback scroll and a foreground firehose of ~1000 styled spans per frame —
// on a 120x40 grid. The number that matters is main-thread cost per frame: under
// the 16 ms/60 fps budget with headroom means DOM sustains the daily-driver bar
// and the WebGL escape hatch does not fire. If this ever fails, that failure IS
// the trigger to build the GPU renderer (localized behind the renderer, hybrid).

test("renderer holds the frame budget on scroll and firehose", async ({page}) => {
    await page.goto("/bench/vt-render.html");
    await page.waitForFunction(() => typeof window.vtBench === "function");

    const scroll = await page.evaluate(() => window.vtBench("scroll", 240));
    const firehose = await page.evaluate(() => window.vtBench("firehose", 240));

    console.log("scroll   :", JSON.stringify(scroll));
    console.log("firehose :", JSON.stringify(firehose));

    // Budget: 16 ms is one frame at 60 fps. Gate on percentiles, not max — a
    // GC'd runtime hitches occasionally and that noise is not a rendering
    // failure. p95 under half a frame is the sustained bar (real headroom for a
    // pane's own compositing); p99 under a full frame means <1% of frames ever
    // approach the budget.
    expect(scroll.p95, "scroll p95 main-thread ms/frame").toBeLessThan(8);
    expect(scroll.p99, "scroll p99 main-thread ms/frame").toBeLessThan(16);
    expect(firehose.p95, "firehose p95 main-thread ms/frame").toBeLessThan(8);
    expect(firehose.p99, "firehose p99 main-thread ms/frame").toBeLessThan(16);
});
