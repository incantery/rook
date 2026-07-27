import {expect, test} from "@playwright/test";
import * as path from "node:path";
import {deleteWorkspaces, gotoHome, shown} from "./harness";

// The WebGL renderer at retina scale. Default e2e runs at deviceScaleFactor 1,
// where CSS-pixel and device-pixel conventions coincide — which hid a real
// bug: beamterm's resize() takes CSS pixels and scales the backing store by
// dpr itself; handing it device pixels doubled the grid and parked the
// content in the top-left quadrant on every retina display. This pins the
// contract: backing store = CSS size x dpr, exactly.

const REPO = path.resolve(process.cwd(), "..");
const made: string[] = [];
test.use({viewport: {width: 1600, height: 1000}, deviceScaleFactor: 2});
test.afterEach(async ({page}) => {
    await deleteWorkspaces(page, made.splice(0));
});

test("webgl canvas geometry is dpr-correct", async ({page}) => {
    made.push("webgl-dpr");
    await gotoHome(page);
    await page.getByRole("button", {name: /^workspaces/i}).click();
    await page.getByRole("button", {name: "New workspace"}).click();
    await page.getByPlaceholder("e.g. rook-core").fill("webgl-dpr");
    await page.getByPlaceholder("~/go/src/github.com/incantery/rook").fill(REPO);
    await page.getByRole("button", {name: "Create workspace"}).click();
    // Wait for the SWITCH, not just for a shell: until the new workspace
    // is the one displayed, the PREVIOUS one is still what selectors and
    // pickers see. That is how a finder ended up listing ~/Downloads.
    await expect(page.locator(`[data-workspace="webgl-dpr"]`)).toBeVisible({timeout: 15_000});
    await expect(shown(page, ".vt-webgl canvas")).toHaveCount(1, {timeout: 15_000});
    await page.waitForTimeout(1500); // let fit() settle

    const geo = await page.evaluate(() => {
        const box = [...document.querySelectorAll<HTMLElement>(".vt-webgl")].find(
            (el) => el.offsetParent !== null,
        );
        const canvas = box?.querySelector("canvas");
        if (!box || !canvas) throw new Error("no webgl pane");
        return {
            dpr: window.devicePixelRatio,
            boxW: box.clientWidth,
            boxH: box.clientHeight,
            attrW: canvas.width,
            attrH: canvas.height,
            cssW: canvas.clientWidth,
            cssH: canvas.clientHeight,
        };
    });
    expect(geo.dpr).toBe(2);
    // backing store is the CSS size at device resolution — nothing more
    expect(geo.attrW).toBe(geo.cssW * 2);
    expect(geo.attrH).toBe(geo.cssH * 2);
    // and the canvas actually fills the pane (within one cell of slack)
    expect(geo.boxW - geo.cssW).toBeLessThan(24);
    expect(geo.boxH - geo.cssH).toBeLessThan(48);
});
