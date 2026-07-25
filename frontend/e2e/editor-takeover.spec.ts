import {expect, test, REPO} from "./harness";
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

// Bare `re` used to be vim's unnamed empty buffer. It is now the start
// screen (start.spec.ts covers the greeter itself) — same takeover, same
// exit code, somewhere to go instead of an empty box. `re .` and `re file`
// are unchanged, which is what the two tests around this one hold down.
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

// `re .` is netrw taken literally now that a tree can be a window: the
// DIRECTORY is the thing you asked for, so the tree IS the pane — no empty
// buffer beside it, nothing to look at until you pick something.
test("re . is the tree itself, and q gives the shell back", async ({page, rook}) => {
    const root = await rook.repo({files: {"sub/inner.txt": "alpha\n"}});
    await rook.open({name: `re-dot-${Date.now()}`, root});
    await rook.shellReady();

    await rook.ex(`${RE} .; echo "re exit=$?"`);

    await expect(page.locator(".tree-wrap")).toHaveCount(1, {timeout: 15_000});
    await expect(page.locator(".editor-mount")).toHaveCount(0);

    await page.keyboard.press("q");
    await rook.expectScreen(/re exit=0/);
    await expect(page.locator(".tree-wrap")).toHaveCount(0);
});

test("the tree belongs to its window, like every other pane", async ({page, rook}) => {
    const root = await rook.repo({files: {"sub/inner.txt": "alpha\n"}});
    await rook.open({name: `re-chrome-${Date.now()}`, root});
    await rook.shellReady();

    await rook.ex(`${RE} .; echo "re exit=$?"`);
    await expect(page.locator(".window.active .tree-wrap")).toHaveCount(1, {timeout: 15_000});

    // a NEW window is a different place: the takeover window's tree stays
    // mounted but display:none, exactly as its terminals do
    await page.keyboard.press("`");
    await page.keyboard.press("c");
    await expect(page.locator(".window.active .tree-wrap")).toHaveCount(0);

    // back to the takeover's window — its tree comes back with it
    await page.keyboard.press("`");
    await page.keyboard.press("1");
    await expect(page.locator(".window.active .tree-wrap")).toHaveCount(1);

    await page.locator(".tree-wrap [role='tree']").first().click();
    await page.keyboard.press("q");
    await rook.expectScreen(/re exit=0/);
});

// vim's rule, which is why a takeover owns a SET of panes: `re .` splitting
// into a tree and an editor is still ONE blocked shell, and it comes back
// when the last of them closes — not the first.
test("re . + a file: the shell waits for the last pane", async ({page, rook}) => {
    const root = await rook.repo({files: {"a.txt": "alpha\n"}});
    await rook.open({name: `re-last-${Date.now()}`, root});
    await rook.shellReady();

    await rook.ex(`${RE} .; echo "re exit=$?"`);
    await expect(page.locator(".tree-wrap")).toHaveCount(1, {timeout: 15_000});

    // open a.txt out of the tree — it lands BESIDE the tree, not elsewhere
    await page.locator(".tree-wrap [role='tree']").first().click();
    await page.keyboard.press("Enter");
    await expect(page.locator(".editor-mount .view-lines").first()).toContainText("alpha", {
        timeout: 15_000,
    });
    await expect(page.locator(".tree-wrap")).toHaveCount(1);

    // closing the TREE leaves the editor standing and the shell still blocked
    await page.locator(".tree-wrap [role='tree']").first().click();
    await page.keyboard.press("q");
    await expect(page.locator(".tree-wrap")).toHaveCount(0);
    await expect(page.locator(".editor-mount")).toHaveCount(1);

    // …and the LAST pane is the one that hands the shell back
    await page.locator(".editor-mount").first().click();
    await rook.ex(":q");
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
