import {expect, test, REPO} from "./harness";
import * as path from "node:path";

// Two things the tree owes a vim user.
//
// `:` — the tree holds the keyboard but has no Monaco behind it, and every ex
// command is registered on the shared Vim singleton and routed by a WeakMap
// keyed by the editor you typed INTO. So `:` in the tree was the one key
// every vim reflex starts with, doing nothing at all.
//
// And opening the tree should LAND you in it — netrw and nerdtree both do,
// and a tree you have to ⌃H into is one you press ,b twice for.

const RE = path.join(REPO, "bin", "e2e", "re");
const tree = (page: import("@playwright/test").Page) =>
    page.locator('[data-side="left"]:visible');

/** `re .` — the greeter with the tree beside it, keyboard on the listing. */
async function openTree(page: import("@playwright/test").Page, rook: any, tag: string) {
    const root = await rook.repo({files: {"a.txt": "alpha\n", "b.txt": "bravo\n"}});
    await rook.open({name: `treeex-${tag}-${Date.now()}`, root});
    await rook.shellReady();
    await rook.ex(`${RE} .; echo "re exit=$?"`);
    await expect(tree(page)).toHaveCount(1, {timeout: 15_000});
    await expect(tree(page)).toContainText("a.txt", {timeout: 10_000});
}

test("` : ` in the tree raises the command line", async ({page, rook}) => {
    await openTree(page, rook, "open");

    await page.keyboard.press(":");
    // the same modal monaco-vim's own prompt uses — there is one keyboard,
    // so there is one prompt
    await expect(page.locator(".vim-cmdline input")).toBeFocused({timeout: 5_000});

    // Escape closes it and hands the keyboard back to the listing, which is
    // the part that makes it usable rather than a trap
    await page.keyboard.press("Escape");
    await expect(page.locator(".vim-cmdline input")).toHaveCount(0);
    await page.keyboard.press("j");
    await page.keyboard.press("Enter");
    await expect(page.locator(".editor-mount .view-lines").first()).toContainText("bravo", {
        timeout: 15_000,
    });

    await page.locator(".editor-mount").first().click();
    await rook.ex(":q");
    await rook.expectScreen(/re exit=0/);
});

test(":q from the tree closes the tree, not the editor", async ({page, rook}) => {
    await openTree(page, rook, "quit");

    // open a file first, then come back to the tree — so there IS an editor
    // for :q to wrongly close if the routing is off
    await page.keyboard.press("Enter");
    await expect(page.locator(".editor-mount .view-lines").first()).toContainText("alpha", {
        timeout: 15_000,
    });
    await page.keyboard.press("Control+h"); // back into the listing
    await expect(tree(page)).toHaveCount(1);

    await rook.ex(":q");
    // netrw's reading: the thing you are IN is the thing that quits
    await expect(tree(page)).toHaveCount(0, {timeout: 10_000});
    await expect(page.locator(".editor-mount")).toHaveCount(1);

    await rook.ex(":q");
    await rook.expectScreen(/re exit=0/);
});

test("a :Command typed at the tree reaches the registry", async ({page, rook}) => {
    await openTree(page, rook, "cmd");

    // :ExplorerToggle is registry.exNames(explorer.toggle) — the tree keeps
    // no list of its own, and the whole point is that this is the SAME map
    // Monaco's :Command bridge uses. A visible effect proves it ran.
    await page.keyboard.press(":");
    await expect(page.locator(".vim-cmdline input")).toBeFocused({timeout: 5_000});
    await page.keyboard.type("ExplorerToggle");
    await page.keyboard.press("Enter");
    await expect(tree(page)).toHaveCount(0, {timeout: 10_000});
});

test("opening the tree lands the keyboard in it", async ({page, rook}) => {
    const root = await rook.repo({files: {"a.txt": "alpha\n", "b.txt": "bravo\n"}});
    await rook.open({name: `treefocus-${Date.now()}`, root});
    await rook.shellReady();
    await rook.ex(`${RE} a.txt; echo "re exit=$?"`);
    await expect(page.locator(".editor-mount .view-lines").first()).toContainText("alpha", {
        timeout: 15_000,
    });

    // ,b opens it — and you should be ON it, with no ⌃H in between
    await page.locator(".editor-mount").first().click();
    await page.keyboard.press(",");
    await page.keyboard.press("b");
    await expect(tree(page)).toHaveCount(1, {timeout: 10_000});
    await expect(tree(page)).toContainText("b.txt", {timeout: 10_000});

    // j/Enter answer immediately: that only works if the listing has focus
    await page.keyboard.press("j");
    await page.keyboard.press("Enter");
    await expect(page.locator(".editor-mount .view-lines").first()).toContainText("bravo", {
        timeout: 15_000,
    });
});

// Landing IN the tree only works if you can also get out of it. The keydown
// handler drops every key that arrives from inside a side pane — the thread
// panel needs that, since comments about code are full of backticks — so
// auto-focus without an exemption makes the tree a room with no door.
// The greeter is what `re` lands on when you name no file, so it is the
// editor as much as a Monaco pane is — but the context leader armed only
// inside .editor-mount and the quickfix strip, which made bare `re` a first
// screen with no verbs on it. Same trap as the tree, one surface over.
test("the editor leader works on the start screen", async ({page, rook}) => {
    const root = await rook.repo({files: {"a.txt": "alpha\n", "b.txt": "bravo\n"}});
    await rook.open({name: `startleader-${Date.now()}`, root});
    await rook.shellReady();
    await rook.ex(`${RE}; echo "re exit=$?"`);
    await expect(page.locator("[data-start-root]")).toBeVisible({timeout: 15_000});

    // ,b from the greeter — dead before this
    await page.keyboard.press(",");
    await page.keyboard.press("b");
    await expect(tree(page)).toHaveCount(1, {timeout: 10_000});
    await expect(tree(page)).toContainText("a.txt", {timeout: 10_000});

    // and it lands you in the listing, so the tree is usable straight away
    await page.keyboard.press("j");
    await page.keyboard.press("Enter");
    await expect(page.locator(".editor-mount .view-lines").first()).toContainText("bravo", {
        timeout: 15_000,
    });

    await page.locator(".editor-mount").first().click();
    await rook.ex(":q");
    await rook.expectScreen(/re exit=0/);
});

test("the leader and ,b still work from inside the tree", async ({page, rook}) => {
    const root = await rook.repo({files: {"a.txt": "alpha\n", "b.txt": "bravo\n"}});
    await rook.open({name: `treeescape-${Date.now()}`, root});
    await rook.shellReady();
    await rook.ex(`${RE} a.txt; echo "re exit=$?"`);
    await expect(page.locator(".editor-mount .view-lines").first()).toContainText("alpha", {
        timeout: 15_000,
    });

    await page.locator(".editor-mount").first().click();
    await page.keyboard.press(",");
    await page.keyboard.press("b");
    await expect(tree(page)).toHaveCount(1, {timeout: 10_000});
    await expect(tree(page)).toContainText("b.txt", {timeout: 10_000});

    // ,b closes the tree you are STANDING in — the context leader has to arm
    // from a surface the auto-focus just put you on
    await page.keyboard.press(",");
    await page.keyboard.press("b");
    await expect(tree(page)).toHaveCount(0, {timeout: 10_000});

    // and the workbench leader reaches past it too: reopen, then ` c opens a
    // new window, which a swallowed backtick could never do
    await page.keyboard.press(",");
    await page.keyboard.press("b");
    await expect(tree(page)).toHaveCount(1, {timeout: 10_000});
    await page.keyboard.press("`");
    await page.keyboard.press("c");
    await expect(tree(page)).toHaveCount(0, {timeout: 10_000});
});
