import {expect, test, REPO} from "./harness";
import * as path from "node:path";

// Two takeovers in two windows — the dogfood bugs of 07-24: the second
// editor's keyboard raced monaco-vim's init (focus fell to body, or stayed
// on the FIRST editor, whose vim then answered :q — "quitting closed my
// other editors"), and the sandbox's symlinked tmpdir demoted workspace
// files to external read-only (/var vs /private/var).

const RE = path.join(REPO, "bin", "e2e", "re");

test("two takeovers: keyboard, furniture and :q stay with their editor", async ({page, rook}) => {
    test.setTimeout(120_000);
    const root = await rook.repo({files: {"a.txt": "alpha\n", "b.txt": "bravo\n"}});
    await rook.open({name: `iso-${Date.now()}`, root});
    await rook.shellReady();

    // window 1: takeover on a.txt
    await rook.ex(`${RE} a.txt; echo "first exit=$?"`);
    const editors = page.locator(".editor-mount");
    await expect(editors.first()).toBeVisible({timeout: 15_000});
    // canonical paths: a workspace file through a symlinked cwd is still
    // workspace-relative — editable, never "external · read-only"
    await expect(page.getByText("external · read-only")).toHaveCount(0);

    // window 2: fresh shell, second takeover
    await page.keyboard.press("`");
    await page.keyboard.press("c");
    await rook.shellReady();
    await rook.ex(`${RE} b.txt; echo "second exit=$?"`);
    await expect(page.locator(".window.active .editor-mount")).toBeVisible({timeout: 15_000});
    await expect(page.getByText("external · read-only")).toHaveCount(0);

    // the keyboard belongs to the SECOND editor now — its furniture toggles
    await page.keyboard.press(",");
    await page.keyboard.press("b");
    await expect(page.getByText("Explorer").first()).toBeVisible({timeout: 5_000});
    await page.keyboard.press(",");
    await page.keyboard.press("b");
    await expect(page.getByText("Explorer")).toHaveCount(0);

    // …and its :q ends THIS takeover only: shell 2 back, editor 1 alive
    await rook.ex(":q");
    await rook.expectScreen(/second exit=0/);
    await page.keyboard.press("`");
    await page.keyboard.press("1");
    await expect(page.locator(".window.active .editor-mount")).toBeVisible({timeout: 5_000});

    // window 1's editor still owns its own loop
    await rook.ex(":q");
    await rook.expectScreen(/first exit=0/);
});
