import {expect, test, type Page} from "@playwright/test";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

// Code intelligence end-to-end: a real gopls behind the sandbox host, the
// real Monaco pane in front. The sandbox config is hot-read, so the spec
// writes the explicit tier pointing at the machine's own gopls (no install
// path here — that's covered by the plugin manager's tests and skipped when
// the machine has no gopls). Covers: vim gd across files through the
// openFile ladder, and gr filling the refs quickfix.

const REPO = path.resolve(process.cwd(), "..");
const SANDBOX = path.join(REPO, "bin", "e2e", "xdg");
const GOPLS = path.join(os.homedir(), "go", "bin", "gopls");
const shown = (page: Page, sel: string) => page.locator(`${sel} >> visible=true`).first();
const made: string[] = [];

test.afterEach(async ({page}) => {
    for (const name of made.splice(0)) {
        await page.goto("/");
        await page.getByRole("button", {name: /^workspaces/}).click();
        const card = page
            .locator("#home-workspaces div.group")
            .filter({has: page.getByText(name, {exact: true})});
        await expect(card).toHaveCount(1);
        await card.getByTitle(/^Delete workspace/).click();
        await expect(card).toHaveCount(0);
    }
});

async function openWorkspace(page: Page, name: string) {
    made.push(name);
    await page.goto("/");
    await expect(page.locator("#home")).toBeVisible();
    await page.getByRole("button", {name: /^workspaces/}).click();
    await page.getByRole("button", {name: "New workspace"}).click();
    await expect(page.locator("#ws-modal")).toBeVisible();
    await page.getByPlaceholder("e.g. rook-core").fill(name);
    await page.getByPlaceholder("~/go/src/github.com/incantery/rook").fill(REPO);
    await page.getByRole("button", {name: "Create workspace"}).click();
    await expect(shown(page, ".xterm-screen")).toBeVisible({timeout: 15_000});
}

async function runCommand(page: Page, title: string) {
    await page.getByRole("button", {name: /commands/}).click();
    await expect(page.getByPlaceholder("Run a command…")).toBeVisible();
    await page.getByPlaceholder("Run a command…").fill(title);
    await page.keyboard.press("Enter");
}

/** Warm gopls through the host API so the UI drive never races the
 *  workspace load — the host state file carries port + token. */
async function warmup(ws: string) {
    const st = JSON.parse(
        fs.readFileSync(path.join(SANDBOX, "state", "rook", "host.json"), "utf8"),
    ) as {port: number; token: string};
    const deadline = Date.now() + 90_000;
    for (;;) {
        const r = await fetch(`http://127.0.0.1:${st.port}/workspaces/${ws}/lsp/definition`, {
            method: "POST",
            headers: {Authorization: `Bearer ${st.token}`},
            body: JSON.stringify({path: "internal/host/plugins.go", line: 1, col: 9}),
        });
        const res = (await r.json()) as {locations: unknown[]; note?: string};
        if (r.ok && !res.note) return;
        if (Date.now() > deadline) throw new Error(`gopls never warmed: ${res.note}`);
        await new Promise((r) => setTimeout(r, 2000));
    }
}

test("gd jumps across files and gr fills the refs quickfix", async ({page}) => {
    test.setTimeout(180_000);
    test.skip(!fs.existsSync(GOPLS), "no gopls on this machine (~/go/bin/gopls)");

    // the sandbox config is hot-read; the explicit tier may name commands
    // (user layer). Roots include .git so the whole checkout is one instance.
    const confDir = path.join(SANDBOX, "config", "rook");
    fs.mkdirSync(confDir, {recursive: true});
    fs.writeFileSync(
        path.join(confDir, "config"),
        `lsp-gopls = ${GOPLS} serve\nlsp-gopls-filetypes = go\nlsp-gopls-roots = go.mod, .git\n`,
    );

    const ws = `lsp-e2e-${Date.now()}`;
    await openWorkspace(page, ws);
    await warmup(ws);

    // open a Go file whose first lines call into another package. Click the
    // row (its mousedown picks) — Enter can lose a focus race against the
    // freshly spawned terminal's replay gate.
    await runCommand(page, "Open file (read-only)");
    const picker = page.getByPlaceholder("Open file (read-only)…");
    await expect(picker).toBeVisible();
    await picker.fill("internal/host/plugins.go");
    await page.getByText("internal/host/plugins.go", {exact: true}).click();
    const editorPath = page.locator(".editor-path");
    await expect(editorPath).toContainText("internal/host/plugins.go", {timeout: 15_000});
    // vim must be attached before keystrokes mean anything; click into the
    // editor so the keyboard is provably Monaco's, not the terminal's
    await expect(page.locator(".editor-vim")).toContainText(/NORMAL/i, {timeout: 15_000});
    await page.locator(".editor-mount").click();

    // land the cursor on a cross-package symbol with vim search, then gd
    await page.keyboard.type("/CatalogEntry");
    await page.keyboard.press("Enter");
    await page.keyboard.type("gd");
    // the openFile ladder retargets the pane to the definition's file
    await expect(editorPath).toContainText("internal/plugin/plugin.go", {timeout: 20_000});

    // gd landed the cursor ON CatalogEntry's definition — K hovers it
    await page.keyboard.press("Shift+K");
    await expect(page.locator(".monaco-hover:not(.hidden)").first()).toBeVisible({
        timeout: 20_000,
    });
    await page.keyboard.press("Escape");

    // …and gr right here
    await page.keyboard.type("gr");
    const pane = page.locator('.side-pane[data-side="bottom"]');
    await expect(pane).toContainText("References", {timeout: 20_000});
    const rows = page.locator("#quickfix-list [role=option]");
    expect(await rows.count()).toBeGreaterThan(1); // definition + call sites
    await expect(pane).toContainText("plugins.go"); // the caller we came from

    // ⌃O walks the jumplist back across files (the editor kept the
    // keyboard — the refs list opens without stealing it), ⌃I re-jumps
    await page.keyboard.press("Control+o");
    await expect(editorPath).toContainText("internal/host/plugins.go", {timeout: 20_000});
    await page.keyboard.press("Control+i");
    await expect(editorPath).toContainText("internal/plugin/plugin.go", {timeout: 20_000});

    // gd into the stdlib — the definition opens as an external read-only
    // view (absolute path served by the file endpoint's external branch)
    await page.locator(".editor-mount").click();
    await page.keyboard.type("/strings.Fields");
    await page.keyboard.press("Enter");
    await page.keyboard.type("2w"); // land on Fields, not strings
    await page.keyboard.type("gd");
    await expect(editorPath).toContainText("external · read-only", {timeout: 20_000});
    await expect(editorPath).toContainText("strings.go");

    await page.screenshot({path: "bin/e2e/lsp-refs.png", fullPage: true});
});
