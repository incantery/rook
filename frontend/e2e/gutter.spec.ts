import {expect, test, type Page} from "@playwright/test";
import {execSync} from "node:child_process";
import * as fs from "node:fs";
import * as path from "node:path";
import {deleteWorkspaces, gotoHome} from "./harness";

// The git gutter in NORMAL buffers: edit a file, and the margin says which
// lines moved vs HEAD — added green, modified accent, a marker on each
// deletion boundary. ]c/[c walk the stripes. This is what lets review
// reading happen in the real file instead of a diff mode.

const REPO = path.resolve(process.cwd(), "..");
const shown = (page: Page, sel: string) => page.locator(`${sel} >> visible=true`).first();
const made: string[] = [];

test.afterEach(async ({page}) => {
    await deleteWorkspaces(page, made.splice(0));
});

/** A scratch repo of its own — the suite must never dirty the real tree. */
function mkRepo(): string {
    const dir = path.join(REPO, "bin", "e2e", `gutter-repo-${Date.now()}`);
    fs.mkdirSync(dir, {recursive: true});
    const lines = Array.from({length: 12}, (_, i) => `line ${i + 1}`).join("\n") + "\n";
    fs.writeFileSync(path.join(dir, "notes.txt"), lines);
    const git = (cmd: string) => execSync(`git ${cmd}`, {cwd: dir});
    git("init -qb main");
    git("add .");
    git('-c user.email=t@t -c user.name=t commit -qm init');
    return dir;
}

async function openWorkspaceAt(page: Page, name: string, root: string) {
    made.push(name);
    await gotoHome(page);
    await page.getByRole("button", {name: /^workspaces/i}).click();
    await page.getByRole("button", {name: "New workspace"}).click();
    await expect(page.locator("#ws-modal")).toBeVisible();
    await page.getByPlaceholder("e.g. rook-core").fill(name);
    await page.getByPlaceholder("~/go/src/github.com/incantery/rook").fill(root);
    await page.getByRole("button", {name: "Create workspace"}).click();
    await expect(shown(page, ".vt-screen")).toBeVisible({timeout: 15_000});
}

async function runCommand(page: Page, title: string) {
    await page.getByRole("button", {name: /commands/}).click();
    await expect(page.getByPlaceholder("Run a command…")).toBeVisible();
    await page.getByPlaceholder("Run a command…").fill(title);
    await page.keyboard.press("Enter");
}

test("editing a file paints stripes, and ]c walks them", async ({page}) => {
    test.setTimeout(120_000);
    const repo = mkRepo();
    const ws = `gutter-e2e-${Date.now()}`;
    await openWorkspaceAt(page, ws, repo);

    await runCommand(page, "Open file");
    const picker = page.getByPlaceholder("Open file…");
    await expect(picker).toBeVisible();
    await picker.fill("notes.txt");
    await picker.press("Enter");
    await expect(page.locator(".editor-path").first()).toContainText("notes.txt", {
        timeout: 20_000,
    });
    await expect(page.locator(".editor-vim").first()).toContainText(/NORMAL/i, {timeout: 15_000});

    // a clean file wears no stripes
    await expect(page.locator(".rook-gutter-mod")).toHaveCount(0);

    // modify line 5, append a line, save — the margin answers
    await page.locator(".editor-mount").first().click();
    await page.keyboard.type("5GccCHANGED five");
    await page.keyboard.press("Escape");
    await page.keyboard.type("GoBRAND NEW LINE");
    await page.keyboard.press("Escape");
    await page.keyboard.type(":w");
    await page.keyboard.press("Enter");

    await expect(page.locator(".rook-gutter-mod").first()).toBeVisible({timeout: 15_000});
    await expect(page.locator(".rook-gutter-add").first()).toBeVisible({timeout: 15_000});
    await page.screenshot({path: "bin/e2e/gutter-stripes.png", fullPage: true});

    // ]c from the top jumps to the first stripe (line 5); ]c again to the
    // appended line; [c walks back
    await page.keyboard.type("gg");
    await page.keyboard.type("]c");
    const statusbar = page.locator("#statusbar");
    await expect(statusbar).toContainText("Ln 5,", {timeout: 15_000});
    await page.keyboard.type("]c");
    await expect(statusbar).toContainText("Ln 13,", {timeout: 15_000});
    await page.keyboard.type("]c"); // no wrap — stays put
    await expect(statusbar).toContainText("Ln 13,");
    await page.keyboard.type("[c");
    await expect(statusbar).toContainText("Ln 5,", {timeout: 15_000});
});
