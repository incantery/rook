import {expect, test, REPO} from "./harness";
import * as path from "node:path";

// The tree is furniture, not a query — dogfood bugs of 07-23: every layout
// changed() rebuilt the tab snapshot, whose fresh objects re-triggered the
// explorer's load effect (open a file → the whole tree refetched and
// re-rendered), the Changed scope auto-pick seeded an expand-all, and
// Monaco's deferred focus latch yanked the keyboard off the listing that
// `re .` had just landed it on.

const RE = path.join(REPO, "bin", "e2e", "re");

test("re . keeps the keyboard on the listing; opening a file does not reload the tree", async ({
    page,
    rook,
}) => {
    test.setTimeout(120_000);
    const root = await rook.repo({
        files: {"a.txt": "alpha\n", "b.txt": "bravo\n", "sub/c.txt": "charlie\n"},
        dirty: {"b.txt": "bravo changed\n"},
    });
    await rook.open({name: `treestable-${Date.now()}`, root});
    await rook.shellReady();

    const fileReqs: string[] = [];
    page.on("request", (r) => {
        if (r.url().includes("/files")) fileReqs.push(r.url());
    });

    await rook.ex(`${RE} .; echo "re exit=$?"`);
    const tree = page.locator('[data-side="left"]:visible');
    await expect(tree).toHaveCount(1, {timeout: 15_000});
    // default scope is All — an unchanged file is listed even with a diff
    await expect(tree).toContainText("a.txt", {timeout: 10_000});
    // …and the listing starts collapsed: sub/ is closed, its child hidden
    await expect(tree).not.toContainText("c.txt");

    // Monaco's init must not steal the keyboard off the listing: the tree
    // itself answers j/Enter (this fails if focus fell into the editor)
    await page.waitForTimeout(600); // let the editor finish loading first
    const before = fileReqs.length;
    await page.keyboard.press("j"); // sub → a.txt (dirs sort first)
    await page.keyboard.press("Enter");

    const editor = page.locator(".editor-mount .view-lines").first();
    await expect(editor).toContainText("alpha", {timeout: 15_000});

    // the tree did NOT reload: no refetch, rows still there, no spinner
    await page.waitForTimeout(500);
    expect(fileReqs.length).toBe(before);
    await expect(tree).toContainText("b.txt");

    await rook.ex(":q");
    await rook.expectScreen(/re exit=0/);
});
