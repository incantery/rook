import {expect, test, REPO} from "./harness";
import * as path from "node:path";

// The editor's start screen: bare `re` lands here instead of on an empty
// buffer (alpha-nvim's job, rook's trigger).
//
// The assertions that matter are the lifecycle ones, not the pixels. The
// greeter HOLDS a `re` takeover, so the two ways out of it — q, and picking
// something — both have to settle that blocked shell correctly. A greeter
// that looks right and strands the shell is worse than no greeter.

const RE = path.join(REPO, "bin", "e2e", "re");

test("bare `re` opens the start screen, and q gives the shell back", async ({page, rook}) => {
    const ws = await rook.repo({files: {"main.go": "package main\n"}});
    await rook.open({name: `start-${Date.now()}`, root: ws});
    await rook.shellReady();

    await rook.ex(`${RE}; echo "re exit=$?"`);

    const start = page.locator("[data-start-root]");
    await expect(start).toBeVisible({timeout: 15_000});
    // no empty editor came up in its place
    await expect(page.locator(".editor-mount")).toHaveCount(0);
    // the action rows are real registry commands with live keycaps
    await expect(start).toContainText("Open file");
    await expect(start).toContainText("Recent");

    // q is the greeter's :q — the blocked `re` must exit 0
    await page.keyboard.press("q");
    await rook.expectScreen(/re exit=0/);
});

test("a file opened on the greeter takes over the SAME pane, and :q still releases re", async ({
    page,
    rook,
}) => {
    const ws = await rook.repo({files: {"main.go": "package main\n\nfunc main() {}\n"}});
    await rook.open({name: `start-open-${Date.now()}`, root: ws});
    await rook.shellReady();

    // seed a recent by opening the file once through a normal takeover
    await rook.ex(`${RE} main.go; echo "seed exit=$?"`);
    await expect(page.locator(".editor-mount .view-lines").first()).toBeVisible({timeout: 15_000});
    await rook.ex(":q");
    await rook.expectScreen(/seed exit=0/);

    // now bare `re` — the greeter should remember main.go
    await rook.ex(`${RE}; echo "re exit=$?"`);
    const start = page.locator("[data-start-root]");
    await expect(start).toBeVisible({timeout: 15_000});
    await expect(start).toContainText("main.go", {timeout: 15_000});

    // 1 jumps to the first recent: the greeter becomes the editor IN PLACE
    await page.keyboard.press("1");
    await expect(page.locator(".editor-mount .view-lines").first()).toBeVisible({timeout: 15_000});
    await expect(page.locator("[data-start-root]")).toHaveCount(0);
    // one pane, not a greeter plus a split
    await expect(page.locator(".editor-mount")).toHaveCount(1);

    // and the takeover survived the hand-off: :q settles the SAME `re`
    await page.locator(".editor-mount").first().click();
    await rook.ex(":q");
    await rook.expectScreen(/re exit=0/);
});
