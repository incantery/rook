import {expect, test, type Page} from "@playwright/test";
import * as path from "node:path";
import {deleteWorkspaces, gotoHome, screenText, shellReady, shellRun} from "./harness";

// Scrollback is host-backed and paged (reverse-paginated virtualized
// scrolling): the client caches what it watches scroll by, and FETCHES what it
// never saw. The honest way to exercise the fetch path is history from before
// the attach — reload the page (fresh renderer, empty cache; the host ring
// unbroken) and scroll up. Everything above the snapshot can only come from
// msgSbFetch/msgSbChunk round trips.

const REPO = path.resolve(process.cwd(), "..");
const shown = (page: Page, sel: string) => page.locator(`${sel} >> visible=true`).first();
const made: string[] = [];

test.afterEach(async ({page}) => {
    await deleteWorkspaces(page, made.splice(0));
});

async function openWorkspace(page: Page, name: string) {
    made.push(name);
    await gotoHome(page);
    await page.getByRole("button", {name: /^workspaces/i}).click();
    await page.getByRole("button", {name: "New workspace"}).click();
    await expect(page.locator("#ws-modal")).toBeVisible();
    await page.getByPlaceholder("e.g. rook-core").fill(name);
    await page.getByPlaceholder("~/go/src/github.com/incantery/rook").fill(REPO);
    await page.getByRole("button", {name: "Create workspace"}).click();
    await expect(shown(page, ".vt-screen")).toBeVisible({timeout: 15_000});
}

test("pre-attach history pages in from the host ring", async ({page}) => {
    await openWorkspace(page, "sb-paging");
    const term = shown(page, ".vt-screen");
    await shellReady(page, term);

    // 300 lines through a ~30-row screen: the command's echo line lands ~300
    // lines deep in the host ring, far beyond any client capture.
    await shellRun(page, term, "seq 1 300");

    // A rook relaunch as the user performs it: the renderer restarts with an
    // empty cache and boot lands straight back in the workspace; the host
    // session (and its ring) lives on.
    await page.reload();
    const term2 = shown(page, ".vt-screen");
    await expect(term2).toBeVisible({timeout: 15_000});

    // the snapshot is the live tail — the echo line is NOT on screen, so the
    // assertion below can only be satisfied by fetched history
    await expect.poll(() => screenText(term2), {timeout: 15_000}).toContain("300");
    expect(await screenText(term2)).not.toContain("seq 1 300");

    // jump to the top of history; the pages arrive and paint
    await term2.click();
    await page.keyboard.press("Shift+Home");
    await expect.poll(() => screenText(term2), {timeout: 15_000}).toContain("seq 1 300");

    // and back to the live screen
    await page.keyboard.press("Shift+End");
    await expect.poll(() => screenText(term2), {timeout: 15_000}).toContain("300");
});

test("webgl: pre-attach history pages in and paints on canvas", async ({page}) => {
    // same journey as above, on the WebGL renderer — the SbStore is shared,
    // but the canvas paint path (repaintViewport, padding, cursor gating) and
    // the Shift-key bindings are beamterm's own.
    await page.addInitScript(() => localStorage.setItem("rook.renderer", "webgl"));
    await openWorkspace(page, "sb-webgl");
    // visible-scoped: the boot shell in "main" keeps its pane mounted
    // (hidden) behind this workspace, canvas and all
    await expect(page.locator(".vt-webgl canvas >> visible=true")).toHaveCount(1, {
        timeout: 15_000,
    });

    const webglText = () =>
        page.evaluate(() => {
            const el = [...document.querySelectorAll<HTMLElement>(".vt-webgl")].find(
                (e) => e.offsetParent !== null,
            ) as (HTMLElement & {__screenText?: () => string}) | undefined;
            return el?.__screenText?.() ?? "";
        });
    const term = shown(page, ".vt-webgl");
    await term.click();
    await page.keyboard.type("echo rdy$((6*7))");
    await page.keyboard.press("Enter");
    await expect.poll(webglText, {timeout: 60_000}).toContain("rdy42");

    await page.keyboard.type("seq 1 300");
    await page.keyboard.press("Enter");
    await page.keyboard.type("echo dn$((6*8))");
    await page.keyboard.press("Enter");
    await expect.poll(webglText, {timeout: 15_000}).toContain("dn48");

    await page.reload(); // boot lands straight back in sb-webgl
    await expect(page.locator(".vt-webgl canvas >> visible=true")).toHaveCount(1, {
        timeout: 15_000,
    });

    // the snapshot is the live tail; the command echo is only in host history
    await expect.poll(webglText, {timeout: 15_000}).toContain("dn48");
    expect(await webglText()).not.toContain("seq 1 300");

    await shown(page, ".vt-webgl").click();
    await page.keyboard.press("Shift+Home");
    await expect.poll(webglText, {timeout: 15_000}).toContain("seq 1 300");

    await page.keyboard.press("Shift+End");
    await expect.poll(webglText, {timeout: 15_000}).toContain("dn48");
});

test("output produced while a window is hidden lands on reveal", async ({page}) => {
    await openWorkspace(page, "sb-reveal");
    const term = shown(page, ".vt-screen");
    await shellReady(page, term);

    // start delayed output, then hide the window before it prints — the host
    // render loop pauses the pane (msgVis 0), so everything below happens
    // frameless; the reveal must ship it as one net diff.
    await term.click();
    await page.keyboard.type("sleep 1 && seq 1 40");
    await page.keyboard.press("Enter");
    await page.keyboard.press("Backquote");
    await page.keyboard.press("c"); // new window: the first one is now hidden
    await expect(shown(page, ".vt-screen")).toBeVisible({timeout: 15_000});
    await page.waitForTimeout(2500); // seq definitely finished while hidden

    await page.keyboard.press("Backquote");
    await page.keyboard.press("1"); // back to window 1
    await expect
        .poll(() => screenText(shown(page, ".vt-screen")), {timeout: 15_000})
        .toContain("40");
});
