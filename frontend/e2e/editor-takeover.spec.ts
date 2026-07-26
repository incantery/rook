import {REPO, expect, shown, test} from "./harness";
import * as path from "node:path";

// `re` — the vim-shaped editor entry: typed in a rook shell, it takes over
// THAT pane with the editor, blocks the shell, and :q hands the pane back
// with the editor's exit code. This drives the whole loop end-to-end the
// way a user does: shell keystrokes → rookctl (as `re`, argv[0] dispatch)
// → host edit endpoint → frame-socket push → pane takeover → :q → restore
// → the blocked `re` exits. The echoed $? is the honest assertion: it can
// only print after rookctl unblocked, with the code the editor reported.

const RE = path.join(REPO, "bin", "e2e", "re");

test("re takes over the pane; :q restores the shell with exit 0", async ({page, rook}) => {
    const root = await rook.repo({files: {"notes.txt": "alpha\nbravo\ncharlie\n"}});
    await rook.open({name: `re-edit-${Date.now()}`, root});
    await rook.shellReady();

    await rook.ex(`${RE} notes.txt; echo "re exit=$?"`);

    // the editor takes the pane — the file's text, in Monaco, not the term
    const editor = page.locator(".editor-mount .view-lines").first();
    await expect(editor).toBeVisible({timeout: 15_000});
    await expect(editor).toContainText("bravo", {timeout: 15_000});

    // :q — the shell comes back and the blocked `re` exits clean
    await rook.ex(":q");
    await rook.expectScreen(/re exit=0/);
});

test(":cq aborts — the shell sees a nonzero exit", async ({page, rook}) => {
    const root = await rook.repo({files: {"notes.txt": "alpha\n"}});
    await rook.open({name: `re-abort-${Date.now()}`, root});
    await rook.shellReady();

    await rook.ex(`${RE} notes.txt; echo "re exit=$?"`);
    await expect(page.locator(".editor-mount .view-lines").first()).toBeVisible({
        timeout: 15_000,
    });

    await rook.ex(":cq");
    await rook.expectScreen(/re exit=1/);
});

// Naming no file used to give you vim's unnamed empty buffer. It is now the
// start screen (start.spec.ts covers the greeter itself) — same takeover,
// same exit code, somewhere to go instead of an empty box. That covers BOTH
// bare `re` and `re .`: the tree is a sidebar, so it can't be the whole pane
// and something has to sit behind it. `re file` is unchanged, which is what
// the test above this one holds down.
test("bare re is the start screen, and it still owns the takeover", async ({page, rook}) => {
    const root = await rook.repo({files: {"notes.txt": "alpha\n"}});
    await rook.open({name: `re-bare-${Date.now()}`, root});
    await rook.shellReady();

    await rook.ex(`${RE}; echo "re exit=$?"`);

    // no finder, no chrome question — you land on the greeter, not a buffer
    await expect(page.locator("[data-start-root]")).toBeVisible({timeout: 15_000});
    await expect(page.locator(".editor-mount")).toHaveCount(0);

    await page.keyboard.press("q");
    await rook.expectScreen(/re exit=0/);
});

test("re . is the greeter with the tree beside it, netrw-style", async ({page, rook}) => {
    const root = await rook.repo({files: {"a.txt": "alpha\n"}});
    await rook.open({name: `re-dot-${Date.now()}`, root});
    await rook.shellReady();

    await rook.ex(`${RE} .; echo "re exit=$?"`);

    // the tree opens beside the greeter — no buffer, because none was named
    const tree = shown(page, '[data-side="left"]');
    await expect(tree).toHaveCount(1, {timeout: 15_000});
    await expect(page.locator("[data-start-root]")).toBeVisible();
    await expect(page.locator(".editor-mount")).toHaveCount(0);

    // Focus starts on the listing (netrw), and opening a file from THERE has
    // to hand the same takeover to the editor — minting a pane instead would
    // leave the greeter holding a `re` nobody can reach. Wait for the rows:
    // the sidebar is on screen before its listing has loaded, and Enter on an
    // empty listing does nothing at all.
    await expect(tree).toContainText("a.txt", {timeout: 10_000});
    await page.keyboard.press("Enter");
    await expect(page.locator(".editor-mount .view-lines").first()).toContainText("alpha", {
        timeout: 15_000,
    });
    await expect(page.locator("[data-start-root]")).toHaveCount(0);

    await page.locator(".editor-mount").first().click();
    await rook.ex(":q");
    await rook.expectScreen(/re exit=0/);
    // the editor's furniture leaves with it
    await expect(shown(page, '[data-side="left"]')).toHaveCount(0);
});

test("furniture is per window — the tree stays with its editor", async ({page, rook}) => {
    const root = await rook.repo({files: {"sub/inner.txt": "alpha\n"}});
    await rook.open({name: `re-chrome-${Date.now()}`, root});
    await rook.shellReady();

    await rook.ex(`${RE} .; echo "re exit=$?"`);
    await expect(shown(page, '[data-side="left"]')).toHaveCount(1, {timeout: 15_000});

    // leaders are dead inside the tree — cross out of it first, then open a
    // NEW window: a different place, no visible tree (the takeover window's
    // instance stays mounted, display:none)
    await page.keyboard.press("Control+l");
    await page.keyboard.press("`");
    await page.keyboard.press("c");
    await expect(shown(page, '[data-side="left"]')).toHaveCount(0);

    // back to the takeover's window — its tree comes back with it
    await page.keyboard.press("`");
    await page.keyboard.press("1");
    await expect(shown(page, '[data-side="left"]')).toHaveCount(1);

    // the pane behind the tree is the greeter, so `q` is what finishes it
    await page.locator("[data-start-root]").click();
    await page.keyboard.press("q");
    await rook.expectScreen(/re exit=0/);
});

test("the editor leader stays inside the editor — a shell comma is a comma", async ({rook}) => {
    const root = await rook.repo({files: {"notes.txt": "alpha\n"}});
    await rook.open({name: `re-comma-${Date.now()}`, root});
    await rook.shellReady();

    // before isolation, the global context leader ate the first comma
    await rook.ex(`echo tuple=a,b,c`);
    await rook.expectScreen(/tuple=a,b,c/);
});

test("re outside a rook pty fails with a message, not a hang", async ({rook}) => {
    // Strip ROOK_SESSION explicitly: when this suite itself runs inside a
    // rook terminal (dogfood), the runner inherits a real one.
    const {execFile} = await import("node:child_process");
    const {promisify} = await import("node:util");
    void rook; // the fixture boots the app; this test only needs the binary
    const env = {...process.env};
    delete env.ROOK_SESSION;
    const run = promisify(execFile);
    await expect(run(RE, ["notes.txt"], {env})).rejects.toThrow(/ROOK_SESSION/);
});
