import {expect, test, REPO} from "./harness";
import * as path from "node:path";

const RE = path.join(REPO, "bin", "e2e", "re");

// Vim handler isolation, across topologies: every editor's :q must end its
// OWN loop and nobody else's. The third dogfood report (":q still kills all
// open editors") came down to the same-file case at the bottom — a per-pane
// model-URI counter collided in Monaco's global registry, the second editor
// never loaded, never took the keyboard, and :q executed in whichever
// editor still held focus.

test("three takeovers: :q the middle one only", async ({page, rook}) => {
    test.setTimeout(120_000);
    const root = await rook.repo({
        files: {"a.txt": "alpha\n", "b.txt": "bravo\n", "c.txt": "charlie\n"},
    });
    await rook.open({name: `three-${Date.now()}`, root});

    const takeover = async (file: string, tag: string) => {
        await rook.shellReady();
        await rook.ex(`${RE} ${file}; echo "${tag} exit=$?"`);
        await expect(page.locator(".window.active .editor-mount .view-lines")).toBeVisible({
            timeout: 15_000,
        });
    };

    await takeover("a.txt", "first");
    await page.keyboard.press("`");
    await page.keyboard.press("c");
    await takeover("b.txt", "second");
    await page.keyboard.press("`");
    await page.keyboard.press("c");
    await takeover("c.txt", "third");

    // window 2: :q — ONLY b.txt's takeover ends
    await page.keyboard.press("`");
    await page.keyboard.press("2");
    await rook.ex(":q");
    await rook.expectScreen(/second exit=0/);

    // windows 1 and 3 still hold their editors
    await page.keyboard.press("`");
    await page.keyboard.press("1");
    await expect(page.locator(".window.active .editor-mount .view-lines")).toBeVisible();
    await expect(page.locator(".window.active .editor-mount")).toContainText("alpha");
    await page.keyboard.press("`");
    await page.keyboard.press("3");
    await expect(page.locator(".window.active .editor-mount .view-lines")).toBeVisible();
    await expect(page.locator(".window.active .editor-mount")).toContainText("charlie");

    // and each still resolves its own shell
    await rook.ex(":q");
    await rook.expectScreen(/third exit=0/);
    await page.keyboard.press("`");
    await page.keyboard.press("1");
    await rook.ex(":q");
    await rook.expectScreen(/first exit=0/);
});

test("split window, two takeovers: :q one half only", async ({page, rook}) => {
    test.setTimeout(120_000);
    const win = page.locator(".window.active");
    // split-aware shell probe: the harness's shellReady watches the FIRST
    // visible terminal, which in a split is not where the keyboard is
    let seq = 0;
    const readyHere = async () => {
        for (let i = 0; i < 30; i++) {
            const tag = `rdy${seq++}x${i}`;
            await page.keyboard.type(`echo ${tag}$((6*7))`);
            await page.keyboard.press("Enter");
            try {
                await expect(win).toContainText(`${tag}42`, {timeout: 2_000});
                return;
            } catch {
                /* cold shell ate the probe — try again */
            }
        }
        throw new Error("shell never became ready");
    };

    const root = await rook.repo({files: {"a.txt": "alpha\n", "b.txt": "bravo\n"}});
    await rook.open({name: `split-${Date.now()}`, root});
    await rook.shellReady();

    // ` % — tmux vertical split; the new (right) half gets focus + a shell
    await page.keyboard.press("`");
    await page.keyboard.press("%");
    await expect(page.locator(".vt-screen:visible")).toHaveCount(2, {timeout: 15_000});
    await readyHere();

    // takeover in the RIGHT pane (tags are single tokens — terminal text
    // renders spaces as nbsp, so a spaced tag can't be matched)
    await rook.ex(`${RE} b.txt; echo "rightexit=$?"`);
    await expect(page.locator(".editor-mount .view-lines")).toHaveCount(1, {timeout: 15_000});

    // cross to the LEFT shell, takeover there too
    await page.keyboard.press("Control+h");
    await readyHere();
    await rook.ex(`${RE} a.txt; echo "leftexit=$?"`);
    await expect(page.locator(".editor-mount .view-lines")).toHaveCount(2, {timeout: 15_000});

    // :q the LEFT takeover — the right one must survive
    await rook.ex(":q");
    await expect(win).toContainText("leftexit=0", {timeout: 15_000});
    await expect(page.locator(".editor-mount .view-lines")).toHaveCount(1);
    await expect(page.locator(".editor-mount")).toContainText("bravo");

    // the right editor still answers its own :q
    await page.keyboard.press("Control+l");
    await rook.ex(":q");
    await expect(win).toContainText("rightexit=0", {timeout: 15_000});
});

test("the SAME file in two takeovers — each :q minds its own", async ({page, rook}) => {
    test.setTimeout(120_000);
    const root = await rook.repo({files: {"notes.txt": "alpha\n"}});
    await rook.open({name: `same-${Date.now()}`, root});
    await rook.shellReady();

    await rook.ex(`${RE} notes.txt; echo "firstexit=$?"`);
    await expect(page.locator(".window.active .editor-mount .view-lines")).toBeVisible({
        timeout: 15_000,
    });

    await page.keyboard.press("`");
    await page.keyboard.press("c");
    await rook.shellReady();
    await rook.ex(`${RE} notes.txt; echo "secondexit=$?"`);
    // the second editor must LOAD (duplicate model URI broke this) …
    await expect(page.locator(".window.active .editor-mount .view-lines")).toBeVisible({
        timeout: 15_000,
    });
    await expect(page.locator(".window.active .editor-mount")).toContainText("alpha");

    // …and :q must end THIS takeover, not the hidden first one
    await rook.ex(":q");
    await rook.expectScreen(/secondexit=0/);
    await page.keyboard.press("`");
    await page.keyboard.press("1");
    await expect(page.locator(".window.active .editor-mount .view-lines")).toBeVisible();
    await rook.ex(":q");
    await rook.expectScreen(/firstexit=0/);
});

test(":qa stays in its own window — another window's editor is another vim", async ({
    page,
    rook,
}) => {
    test.setTimeout(120_000);
    const root = await rook.repo({files: {"a.txt": "alpha\n", "b.txt": "bravo\n"}});
    await rook.open({name: `qa-${Date.now()}`, root});
    await rook.shellReady();

    await rook.ex(`${RE} a.txt; echo "firstexit=$?"`);
    await expect(page.locator(".window.active .editor-mount .view-lines")).toBeVisible({
        timeout: 15_000,
    });

    await page.keyboard.press("`");
    await page.keyboard.press("c");
    await rook.shellReady();
    await rook.ex(`${RE} b.txt; echo "secondexit=$?"`);
    await expect(page.locator(".window.active .editor-mount .view-lines")).toBeVisible({
        timeout: 15_000,
    });

    // :qa — the whole PLACE quits, but the place is THIS window
    await rook.ex(":qa");
    await rook.expectScreen(/secondexit=0/);

    // window 1's editor is another vim — untouched, and still :q-able
    await page.keyboard.press("`");
    await page.keyboard.press("1");
    await expect(page.locator(".window.active .editor-mount .view-lines")).toBeVisible();
    await rook.ex(":q");
    await rook.expectScreen(/firstexit=0/);
});
