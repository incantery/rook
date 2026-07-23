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

test("bare re opens the finder; Escape cancels back to the shell", async ({page, rook}) => {
    const root = await rook.repo({files: {"notes.txt": "alpha\n"}});
    await rook.open({name: `re-bare-${Date.now()}`, root});
    await rook.shellReady();

    await rook.ex(`${RE}; echo "re exit=$?"`);

    // bare re = nvim-without-args: the file finder, scoped to the cwd
    await expect(page.getByPlaceholder("Open file…")).toBeVisible({timeout: 15_000});
    await page.keyboard.press("Escape");

    // no pick — the ask resolves as a clean cancel, shell undisturbed
    await rook.expectScreen(/re exit=0/);
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
