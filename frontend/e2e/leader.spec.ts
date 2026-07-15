import {expect, test, type Page} from "@playwright/test";
import * as path from "node:path";

// The leader's send-prefix, in both pane kinds.
//
// tmux's `` ` `` costs you a printable character everywhere, in every app, in
// every vim mode. `send-prefix` is what makes that affordable: press it twice
// and the byte reaches the app, which reads it in ITS own mode — insert mode
// inserts, normal mode jumps to a mark. rook inherits the leader (parity.md
// calls it "muscle memory"), so it inherits the debt: `` ` ` `` must produce a
// backtick in whatever pane has focus, or the leader is a character you can
// simply never type.
//
// Only a browser can show this. The whole path is DOM: a capture-phase
// listener on window (App.svelte onKeydown) decides, and xterm's and Monaco's
// hidden textareas are what it decides FOR. A unit test would have to mock the
// thing under test.

const REPO = path.resolve(process.cwd(), "..");

// A workspace's non-active windows keep their panes in the DOM, hidden, and a
// session the sandbox daemon restored is parked there too. Terminal locators
// filter to the visible one — .first() finds whichever came first, which is
// not the same thing and is not always on screen.
const shown = (page: Page, sel: string) => page.locator(`${sel} >> visible=true`).first();

// Workspaces this file created, for afterEach to take back out.
const made: string[] = [];

// The sandbox's database and its host daemon both outlive the page, so a
// workspace left here is one boot.spec's "No workspaces yet" finds — and that
// canary is how you'd notice the suite talking to your REAL database (see
// docs/e2e.md). This is the first spec that needs a workspace at all, so it's
// the first that has to hand one back. Deleting through the same ✕ a user
// clicks kills the workspace's shells too, which is what keeps a later spec
// from finding this one's terminals restored and parked in the DOM.
test.afterEach(async ({page}) => {
    for (const name of made.splice(0)) {
        await page.goto("/");
        const card = page
            .locator("#home-scroll div.group")
            .filter({has: page.getByText(name, {exact: true})});
        // Wait for the card rather than testing for it: #home renders before
        // listWorkspaces resolves, so an immediate count() reads 0 for a
        // workspace that is very much there, and a cleanup that treats that as
        // "nothing to do" leaves the mess it was written to prevent — silently,
        // which is how it reaches boot.spec instead of this line.
        await expect(card).toHaveCount(1);
        await card.getByTitle(/^Delete workspace/).click();
        await expect(card).toHaveCount(0);
    }
});

/** Into a workspace rooted at the rook checkout, shell running. The root has
 *  to be a real repo: the file picker lists git's view of it. */
async function openWorkspace(page: Page, name: string) {
    made.push(name);
    await page.goto("/");
    await expect(page.locator("#home")).toBeVisible();
    await page.getByRole("button", {name: "New workspace"}).click();
    await expect(page.locator("#ws-modal")).toBeVisible();
    await page.getByPlaceholder("e.g. rook-core").fill(name);
    await page.getByPlaceholder("~/go/src/github.com/incantery/rook").fill(REPO);
    await page.getByRole("button", {name: "Create workspace"}).click();
    // the shell is the app screen's proof of life
    await expect(shown(page, ".xterm-screen")).toBeVisible({timeout: 15_000});
}

/** ` e → picker → open a file in Monaco, with vim attached. */
async function openFile(page: Page, file: string) {
    await page.keyboard.press("Backquote");
    await page.keyboard.press("e");
    const query = page.getByPlaceholder("Open file (read-only)…");
    await expect(query).toBeVisible();
    await query.fill(file);
    // The picker renders before api.listFiles resolves, so Enter can beat the
    // list and open nothing (pick(undefined) is a silent no-op). .sel marks
    // the row Enter would take — its arrival is what makes the key meaningful.
    // A human typing a filename never loses this race; a robot always does.
    await expect(page.locator(".sel")).toHaveText(file);
    await page.keyboard.press("Enter");
    await expect(page.locator(".editor-mount")).toBeVisible();
    // monaco-vim loads async (editor.ts attachVim); its status bar is the
    // signal that the modal keymap is live and will read the keys below.
    await expect(page.locator(".editor-vim")).toBeAttached();
}

// The bug, stated as the user meets it: you cannot type a backtick in a file.
//
// Typed here as x``y, so the assertion separates "swallowed" from "doubled":
// the first ` arms the prefix, the second must fall through as a literal, and
// x`y is the only correct answer. xy means the leader ate it; x``y means the
// arm never happened at all.
test("` ` types a literal backtick into the editor", async ({page}) => {
    await openWorkspace(page, "leader-editor");
    await openFile(page, "NOTES.md");

    await page.locator(".editor-mount").click();
    await page.keyboard.press("g");
    await page.keyboard.press("g"); // vim: to the top, wherever the click landed
    await page.keyboard.press("I"); // insert at the line's first non-blank
    await expect(page.locator(".editor-vim")).toContainText("INSERT");

    await page.keyboard.type("x``y");

    await expect(page.locator(".editor-mount .view-lines")).toContainText("x`y");
});

// The same gesture in the pane kind that already worked — the guard on the
// fix. This case used to be served by a direct write to the focused session's
// websocket; the fall-through has to reach the PTY by a different road
// (xterm's own textarea → onData), and the shell echoing the character back
// is the proof it made the whole round trip.
test("` ` still types a literal backtick into a terminal", async ({page}) => {
    await openWorkspace(page, "leader-term");

    await shown(page, ".xterm-screen").click();
    await page.keyboard.type("x``y");

    await expect(shown(page, ".xterm-rows")).toContainText("x`y", {timeout: 10_000});
});
