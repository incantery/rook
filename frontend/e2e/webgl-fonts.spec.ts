import {expect, test} from "@playwright/test";
import * as path from "node:path";
import {clickShown, deleteWorkspaces, gotoHome, shown} from "./harness";

// The WebGL renderer's font supply line. WebKit's canvas 2D ignores
// user-installed fonts (DOM text renders them; fillText silently falls back),
// so beamterm's glyph atlas would lose the terminal font and draw tofu for
// every nerd-font icon — which is exactly how it shipped in v0.16.x. The fix:
// the Go side serves the configured family's bytes (/rookfont, internal/
// fontdir) and boot re-registers them as FontFaces under the same family
// name, which canvas IS allowed to use.
//
// Default e2e runs Chromium, whose canvas sees user fonts either way — the
// rendering half of this bug is only visible under --browser=webkit (where
// this spec also passes). What Chromium CAN pin is the supply line itself:
// the endpoint serves real bytes and boot registers loaded faces.

const REPO = path.resolve(process.cwd(), "..");
const made: string[] = [];
test.afterEach(async ({page}) => {
    await deleteWorkspaces(page, made.splice(0));
});

test("webgl boot registers the terminal font for canvas", async ({page}) => {
    made.push("webgl-fonts");
    await page.addInitScript(() => localStorage.setItem("rook.renderer", "webgl"));
    await gotoHome(page);

    // the configured family, as boot resolved it onto :root
    const family = await page.evaluate(() => {
        const stack = getComputedStyle(document.documentElement).getPropertyValue("--vt-font");
        return stack.split(",")[0].trim().replace(/^"|"$/g, "");
    });
    expect(family.length).toBeGreaterThan(0);

    // the endpoint hands over real font bytes
    const served = await page.evaluate(async (fam: string) => {
        const r = await fetch(`/rookfont?family=${encodeURIComponent(fam)}&style=regular`);
        return {ok: r.ok, bytes: r.ok ? (await r.arrayBuffer()).byteLength : 0};
    }, family);
    expect(served.ok).toBe(true);
    expect(served.bytes).toBeGreaterThan(10_000);

    // and boot already registered loaded FontFaces under the same name
    const faces = await page.evaluate((fam: string) => {
        const out: string[] = [];
        document.fonts.forEach((f) => {
            if (f.family.replace(/^"|"$/g, "") === fam) out.push(`${f.status}`);
        });
        return out;
    }, family);
    expect(faces.length).toBeGreaterThan(0);
    for (const status of faces) expect(status).toBe("loaded");

    // the pane comes up on the webgl renderer with the fonts in place
    await page.getByRole("button", {name: /^workspaces/i}).click();
    await page.getByRole("button", {name: "New workspace"}).click();
    await page.getByPlaceholder("e.g. rook-core").fill("webgl-fonts");
    await page.getByPlaceholder("~/go/src/github.com/incantery/rook").fill(REPO);
    await page.getByRole("button", {name: "Create workspace"}).click();
    // Wait for the SWITCH, not just for a shell: until the new workspace
    // is the one displayed, the PREVIOUS one is still what selectors and
    // pickers see. That is how a finder ended up listing ~/Downloads.
    await expect(page.locator(`[data-workspace="webgl-fonts"]`)).toBeVisible({timeout: 15_000});
    await expect(shown(page, ".vt-webgl canvas")).toHaveCount(1, {timeout: 15_000});

    // glyph gauntlet reaches the grid intact (PUA, astral PUA, CJK, emoji);
    // ASCII escapes only — typed unicode literals never reach the pty
    const webglText = async () =>
        page.evaluate(() => {
            const el = [...document.querySelectorAll<HTMLElement>(".vt-webgl")].find(
                (e) => e.offsetParent !== null,
            ) as (HTMLElement & {__screenText?: () => string}) | undefined;
            return el?.__screenText?.() ?? "";
        });
    const term = page.locator(".vt-webgl >> visible=true").first();
    await clickShown(term);
    await page.keyboard.type("echo rdy$((6*7))");
    await page.keyboard.press("Enter");
    await expect.poll(webglText, {timeout: 60_000}).toContain("rdy42");
    await page.keyboard.type(String.raw`printf 'GA \uE62B \U000F024B GZ\n'`);
    await page.keyboard.press("Enter");
    await expect
        .poll(async () => {
            const line = (await webglText())
                .split("\n")
                .find((l) => l.includes("GA ") && !l.includes("printf"));
            return line ? [...line].map((c) => c.codePointAt(0)!.toString(16)).join(" ") : "";
        })
        .toContain("47 41 20 e62b 20 f024b 20 47 5a");
});
