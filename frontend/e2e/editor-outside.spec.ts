import {expect, test, REPO} from "./harness";
import * as fs from "node:fs/promises";
import * as path from "node:path";

// The workspace is an ANCHOR, not a fence. You cd somewhere else in the
// shell, type `re`, and the editor opens that file — reads it, stripes it
// against ITS repo, and saves it. Same for a file that isn't there yet:
// vim opens a named empty buffer and the first :w creates it.
//
// The disk assertions are the honest ones. A green editor pane proves the
// buffer loaded; only reading the file back proves the write door opened.

const RE = path.join(REPO, "bin", "e2e", "re");

test("cd outside the workspace, re, :w — the file out there really changes", async ({
    page,
    rook,
}) => {
    const ws = await rook.repo({files: {"inside.txt": "alpha\n"}});
    // its own repo, so the gutter has something of its own to answer with
    const other = await rook.repo({files: {"outside.txt": "one\ntwo\nthree\n"}});
    await rook.open({name: `re-outside-${Date.now()}`, root: ws});
    await rook.shellReady();

    await rook.ex(`cd ${other} && ${RE} outside.txt; echo "re exit=$?"`);

    const editor = page.locator(".editor-mount .view-lines").first();
    await expect(editor).toBeVisible({timeout: 15_000});
    await expect(editor).toContainText("two", {timeout: 15_000});
    // labeled, not fenced: "external" says where you are, not what you can't do
    const label = page.locator(".editor-path").first();
    await expect(label).toContainText("external");
    await expect(label).not.toContainText("read-only");
    await expect(page.locator(".editor-vim").first()).toContainText(/NORMAL/i, {timeout: 15_000});

    await page.locator(".editor-mount").first().click();
    await page.keyboard.type("2GccSECOND");
    await page.keyboard.press("Escape");
    await page.keyboard.type(":w");
    await page.keyboard.press("Enter");

    // the write landed on disk, outside the workspace
    await expect
        .poll(() => fs.readFile(path.join(other, "outside.txt"), "utf8").catch(() => ""), {
            timeout: 15_000,
        })
        .toContain("SECOND");
    // …and the margin is striped from the OTHER repo's HEAD
    await expect(page.locator(".rook-gutter-mod").first()).toBeVisible({timeout: 15_000});

    await rook.ex(":q");
    await rook.expectScreen(/re exit=0/);
});

test("⌃P from an outside takeover finds that directory's files, and they save", async ({
    page,
    rook,
}) => {
    const ws = await rook.repo({files: {"inside.txt": "alpha\n"}});
    const other = await rook.repo({
        files: {"outside.txt": "one\n", "sibling.txt": "sib one\nsib two\n"},
    });
    await rook.open({name: `re-outside-find-${Date.now()}`, root: ws});
    await rook.shellReady();

    await rook.ex(`cd ${other} && ${RE} outside.txt; echo "re exit=$?"`);
    await expect(page.locator(".editor-mount").first()).toBeVisible({timeout: 15_000});
    await expect(page.locator(".editor-vim").first()).toContainText(/NORMAL/i, {timeout: 15_000});

    // ⌃P inside a takeover scopes to the shell's cwd — which is not the
    // workspace at all here, so the listing has to come from out there
    await page.locator(".editor-mount").first().click();
    await page.keyboard.press("Control+p");
    const picker = page.getByPlaceholder("Open file…");
    await expect(picker).toBeVisible({timeout: 10_000});
    await picker.fill("sibling.txt");
    // the listing itself is the claim: these names can only have come from
    // the cwd, which is nowhere near the workspace root
    await expect(page.locator("[data-finder-row]").first()).toContainText("sibling.txt", {
        timeout: 10_000,
    });
    await picker.press("Enter");

    const label = page.locator(".editor-path").first();
    await expect(label).toContainText("sibling.txt", {timeout: 20_000});
    await expect(label).toContainText("external");
    await expect(page.locator(".editor-vim").first()).toContainText(/NORMAL/i, {timeout: 15_000});

    await page.locator(".editor-mount").first().click();
    await page.keyboard.type("1GccFOUND AND EDITED");
    await page.keyboard.press("Escape");
    await page.keyboard.type(":w");
    await page.keyboard.press("Enter");

    await expect
        .poll(() => fs.readFile(path.join(other, "sibling.txt"), "utf8").catch(() => ""), {
            timeout: 15_000,
        })
        .toContain("FOUND AND EDITED");
});

test("re on a path that doesn't exist yet: an empty buffer the first :w creates", async ({
    page,
    rook,
}) => {
    const ws = await rook.repo({files: {"inside.txt": "alpha\n"}});
    await rook.open({name: `re-newfile-${Date.now()}`, root: ws});
    await rook.shellReady();

    await rook.ex(`${RE} fresh.md; echo "re exit=$?"`);

    await expect(page.locator(".editor-mount").first()).toBeVisible({timeout: 15_000});
    const label = page.locator(".editor-path").first();
    await expect(label).toContainText("fresh.md");
    await expect(label).toContainText("new file");
    // vim first: before initVimMode lands, "i:w" is just text typed into the
    // buffer and nothing ever saves
    await expect(page.locator(".editor-vim").first()).toContainText(/NORMAL/i, {timeout: 15_000});

    await page.locator(".editor-mount").first().click();
    await page.keyboard.type("ihello from a file that did not exist");
    await page.keyboard.press("Escape");
    await page.keyboard.type(":w");
    await page.keyboard.press("Enter");

    await expect
        .poll(() => fs.readFile(path.join(ws, "fresh.md"), "utf8").catch(() => ""), {
            timeout: 15_000,
        })
        .toContain("hello from a file that did not exist");
    // it exists now, so it stops calling itself new
    await expect(label).not.toContainText("new file");

    await rook.ex(":q");
    await rook.expectScreen(/re exit=0/);
});
