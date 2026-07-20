import {expect, test, type Page} from "@playwright/test";
import * as fs from "node:fs";
import * as path from "node:path";

// The two comment verbs, end-to-end against the real host: ,c leaves a note
// (the whiteboard — it lands pending and stays there) and ,? asks about ONE
// region now (it submits that thread alone and actuates a responder).
//
// The distinction is the whole point of the per-thread submit endpoint, so
// the load-bearing assertion is the negative one: after ,? the earlier note
// is STILL pending. Reusing the workspace-level batch would have swept it up.

const REPO = path.resolve(process.cwd(), "..");
const SANDBOX = path.join(REPO, "bin", "e2e", "xdg");
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

/** The context leader is deliberately dead inside side panes, so every chord
 *  departs from the editor — which is also the honest user path. `at` parks
 *  the cursor first, so the two comments anchor to different lines and the
 *  test proves compose reads the CURRENT cursor rather than a fixed spot. */
async function ctxChord(page: Page, key: string, at: string) {
    await page.locator(".editor-mount").click();
    await page.keyboard.type(at);
    await page.keyboard.press(",");
    await page.keyboard.press(key);
}

test("`,c` notes stay pending; `,?` asks about one region", async ({page}) => {
    test.setTimeout(120_000);

    // Point the coder at something inert: ,? actuates a responder, and the
    // default coder is `claude` — so without this the suite would spawn the
    // machine's real claude. (That is why submit had no e2e coverage before.)
    //
    // MERGE rather than overwrite: the sandbox config is one file shared by
    // every spec, so rewriting it wholesale silently disarms another spec's
    // setup — lsp.spec's gopls lines live here too. Config is hot-read, so
    // this needs no restart.
    const confDir = path.join(SANDBOX, "config", "rook");
    const confFile = path.join(confDir, "config");
    fs.mkdirSync(confDir, {recursive: true});
    const prior = fs.existsSync(confFile) ? fs.readFileSync(confFile, "utf8") : "";
    const kept = prior
        .split("\n")
        .filter((l) => !/^\s*coder\s*=/.test(l))
        .join("\n")
        .trimEnd();
    fs.writeFileSync(confFile, `${kept}\ncoder = echo\n`.trimStart());

    await openWorkspace(page, `threads-e2e-${Date.now()}`);

    await runCommand(page, "Open file (read-only)");
    const picker = page.getByPlaceholder("Open file (read-only)…");
    await expect(picker).toBeVisible();
    await picker.fill("internal/host/spawntask.go");
    await picker.press("Enter");
    await expect(page.locator(".editor-path")).toContainText("spawntask.go", {timeout: 20_000});
    // vim must be attached before keystrokes mean anything
    await expect(page.locator(".editor-vim")).toContainText(/NORMAL/i, {timeout: 15_000});

    const pane = page.locator('.side-pane[data-side="right"]');

    // ---- ,c : the whiteboard ----
    // The pane starts closed in file mode; ,c must open it AND land the
    // compose. SidePane only mounts its tenant while visible, so a compose
    // signalled before the mount would reach zero subscribers and vanish.
    await ctxChord(page, "c", "gg");
    await expect(pane).toContainText("Threads");
    await expect(pane).toContainText("New thread");
    const note = pane.getByPlaceholder("Leave a note for this region…");
    await expect(note).toBeVisible();
    await note.fill("why is this named spawnTask");
    await pane.getByRole("button", {name: "Start thread"}).click();

    await expect(pane).toContainText("why is this named spawnTask", {timeout: 15_000});
    await expect(pane).toContainText("Pending");

    // ---- ,? : ask about this one, now ----
    await ctxChord(page, "?", "20G");
    await expect(pane).toContainText("Ask the agent");
    const ask = pane.getByPlaceholder("What do you want to know about this region?");
    await expect(ask).toBeVisible();
    await ask.fill("can the 400ms sleep race the shell");
    await pane.getByRole("button", {name: "Ask now"}).click();

    await expect(pane).toContainText("can the 400ms sleep race the shell", {timeout: 15_000});

    // THE assertion: exactly one thread went Open (the asked one) and exactly
    // one is still Pending (the note). A workspace-level batch submit would
    // have shipped both — that's the bug this endpoint exists to avoid.
    // Matched on the state hook, not the body: a COLLAPSED card renders the
    // anchor snippet, so hasText against the comment text finds nothing.
    await expect(pane.locator('[data-thread-state="pending"]')).toHaveCount(1, {timeout: 15_000});
    await expect(pane.locator('[data-thread-state="open"]')).toHaveCount(1);

    // the editor header agrees: one note still batched, awaiting a submit
    await expect(page.getByRole("button", {name: "submit 1"})).toBeVisible();

    // Actuation is proven by the state transition itself, not by reading the
    // spawned terminal: /threads/{id}/submit only returns 200 after h.nudge
    // succeeded, so a responder that failed to spawn would have left this
    // thread pending and a 500 on the wire. The nudge's exact TEXT is pinned
    // in Go (TestThreadSubmitOneLeavesOthersPending), which is where the
    // one-line pty constraint can be asserted without window-focus races.

    await page.screenshot({path: "bin/e2e/threads-compose.png", fullPage: true});
});
