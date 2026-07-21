import {expect, test, type Page} from "@playwright/test";
import * as fs from "node:fs";
import * as path from "node:path";

// Commenting, end-to-end against the real host.
//
// A comment is composed in a BUFFER — a Monaco draft model in a split below
// the source — so what these tests drive is the vim flow: chord, `i`, type,
// Escape, `:w`, and you are back in the code with a mark in the gutter. There
// is no form, so nothing here clicks a button or fills a field; if the buffer
// didn't take the keyboard, every assertion below fails.
//
// ,c leaves a note (the whiteboard: it lands pending and stays there); ,? asks
// about ONE region now. The load-bearing assertion is the negative one: after
// ,? the earlier note is STILL pending. The workspace batch would have swept
// it up, which is why the per-thread submit endpoint exists.

const REPO = path.resolve(process.cwd(), "..");
const SANDBOX = path.join(REPO, "bin", "e2e", "xdg");
const shown = (page: Page, sel: string) => page.locator(`${sel} >> visible=true`).first();
const made: string[] = [];

interface Thread {
    id: number;
    path: string;
    startLine: number;
    endLine: number;
    state: string;
    comments: {body: string; author: string}[];
}

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

/** Talk to the sandbox daemon directly — how the AGENT sees and mutates
 *  threads (rookctl is just an HTTP client). Lets a test assert the real
 *  stored state instead of panel text, and produce an agent reply without
 *  touching the page at all. */
async function hostFetch(route: string, init?: RequestInit): Promise<Response> {
    const st = JSON.parse(
        fs.readFileSync(path.join(SANDBOX, "state", "rook", "host.json"), "utf8"),
    ) as {port: number; token: string};
    return fetch(`http://127.0.0.1:${st.port}${route}`, {
        ...init,
        headers: {Authorization: `Bearer ${st.token}`},
    });
}

const threadsOf = async (ws: string): Promise<Thread[]> =>
    (await (await hostFetch(`/workspaces/${ws}/threads`)).json()) as Thread[];

async function runCommand(page: Page, title: string) {
    await page.getByRole("button", {name: /commands/}).click();
    await expect(page.getByPlaceholder("Run a command…")).toBeVisible();
    await page.getByPlaceholder("Run a command…").fill(title);
    await page.keyboard.press("Enter");
}

async function openSource(page: Page, file: string) {
    await runCommand(page, "Open file (read-only)");
    const picker = page.getByPlaceholder("Open file (read-only)…");
    await expect(picker).toBeVisible();
    await picker.fill(file);
    await picker.press("Enter");
    await expect(page.locator(".editor-path").first()).toContainText(file, {timeout: 20_000});
    // vim must be attached before any keystroke means anything
    await expect(page.locator(".editor-vim").first()).toContainText(/NORMAL/i, {timeout: 15_000});
}

/** The context leader is deliberately dead inside side panes, so every chord
 *  departs from the editor — which is also the honest user path. `at` parks
 *  the cursor first, so comments anchor to different lines and the test proves
 *  compose reads the CURRENT cursor rather than a fixed spot. */
async function ctxChord(page: Page, key: string, at: string) {
    await page.locator(".editor-mount").first().click();
    await page.keyboard.type(at);
    await page.keyboard.press(",");
    await page.keyboard.press(key);
}

const draftHeader = (page: Page, kind: "comment" | "ask") =>
    page.locator(".editor-path", {hasText: new RegExp(`^${kind} ·`)});

/** Write a comment the way a human does. The draft opens in NORMAL mode — the
 *  git-commit contract — so `i` enters insert and `:w` sends. Nothing here
 *  targets an element: the keystrokes go wherever focus actually is. */
async function writeComment(page: Page, kind: "comment" | "ask", body: string) {
    const header = draftHeader(page, kind);
    await expect(header).toBeVisible({timeout: 15_000});
    await page.keyboard.press("i");
    await page.keyboard.type(body);
    await page.keyboard.press("Escape");
    await page.keyboard.type(":w");
    await page.keyboard.press("Enter");
    // :w sends AND closes — the buffer existed to be handed off
    await expect(header).toHaveCount(0, {timeout: 15_000});
}

/** Step 8: focus returns to the source. With the draft split gone the only
 *  editor left is the source buffer, so focus sitting in an .editor-mount is
 *  exactly the claim. This is what makes it feel like vim instead of a form. */
async function expectFocusInSource(page: Page) {
    await expect
        .poll(() => page.evaluate(() => !!document.activeElement?.closest(".editor-mount")))
        .toBe(true);
}

test("a comment is written in a buffer and `:w` sends it", async ({page}) => {
    test.setTimeout(120_000);

    // Point the coder at something inert: ,? actuates a responder, and the
    // default coder is `claude` — without this the suite would spawn the
    // machine's real claude. MERGE rather than overwrite: the sandbox config
    // is one file shared by every spec, so rewriting it wholesale silently
    // disarms another spec's setup (lsp.spec's gopls lines live here too).
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

    const ws = `threads-e2e-${Date.now()}`;
    await openWorkspace(page, ws);
    await openSource(page, "internal/host/spawntask.go");

    // ---- ,c : the whiteboard ----
    // from a real VISUAL-LINE selection, which is how a range comment is
    // actually made: 18G selects the func signature and the two lines under it
    await ctxChord(page, "c", "18GVjj");

    // the draft is a REAL buffer: it has a vim mode line of its own, which is
    // the whole difference from the textarea this replaced
    await expect(draftHeader(page, "comment")).toBeVisible({timeout: 15_000});
    expect(await page.locator(".editor-vim").count()).toBe(2);

    await page.keyboard.press("i");
    await page.keyboard.type("why is this named spawnTask");
    await page.screenshot({path: "bin/e2e/threads-draft.png", fullPage: true});
    await page.keyboard.press("Escape");
    await page.keyboard.type(":w");
    await page.keyboard.press("Enter");
    await expect(draftHeader(page, "comment")).toHaveCount(0, {timeout: 15_000});
    await expectFocusInSource(page);

    // the thread exists on the host, anchored to the whole visual selection —
    // the range came from the editor, not from the header text
    await expect
        .poll(async () => (await threadsOf(ws)).length, {timeout: 15_000})
        .toBe(1);
    const [note] = await threadsOf(ws);
    expect(note.comments[0].body).toBe("why is this named spawnTask");
    expect(note.startLine).toBe(18);
    expect(note.endLine).toBe(20);
    expect(note.state).toBe("pending");

    // …and step 9: a mark in the gutter, not a panel
    await expect(page.locator(".thread-glyph").first()).toBeVisible({timeout: 15_000});

    // ---- ,? : ask about this one, now ----
    await ctxChord(page, "?", "20G");
    await writeComment(page, "ask", "can the 400ms sleep race the shell");
    await expectFocusInSource(page);

    await expect
        .poll(async () => (await threadsOf(ws)).length, {timeout: 15_000})
        .toBe(2);
    const all = await threadsOf(ws);
    const asked = all.find((t) => t.comments[0].body.startsWith("can the 400ms"));
    const noted = all.find((t) => t.comments[0].body.startsWith("why is this"));

    // THE assertion: the asked thread went open, and the earlier note is still
    // pending. Reusing the workspace batch would have shipped both.
    expect(asked?.state).toBe("open");
    expect(noted?.state).toBe("pending");

    // …and the ask anchored where 20G put the CURSOR, not to the visual
    // selection the previous comment consumed. Composing has to leave the
    // editor in NORMAL, or the next motion extends a stale selection and this
    // reads 18 — which is exactly how that bug was found.
    expect(asked?.startLine).toBe(20);
    expect(asked?.endLine).toBe(20);

    // Actuation is proven by that transition: /threads/{id}/submit only
    // returns 200 after h.nudge succeeded, so a responder that failed to spawn
    // would have left this pending. The nudge's exact TEXT is pinned in Go
    // (TestThreadSubmitOneLeavesOthersPending), where the one-line pty
    // constraint can be asserted without window-focus races.

    await page.screenshot({path: "bin/e2e/threads-compose.png", fullPage: true});
});

// :q! must throw the draft away without creating anything — the escape hatch
// for "actually, never mind", and the reason :q refuses while the buffer is
// dirty rather than silently discarding a thought.
test("`:q!` discards a draft without creating a thread", async ({page}) => {
    test.setTimeout(120_000);
    const ws = `discard-e2e-${Date.now()}`;
    await openWorkspace(page, ws);
    await openSource(page, "internal/host/spawntask.go");

    await ctxChord(page, "c", "gg");
    const header = draftHeader(page, "comment");
    await expect(header).toBeVisible({timeout: 15_000});
    await page.keyboard.press("i");
    await page.keyboard.type("half a thought");
    await page.keyboard.press("Escape");

    // :q refuses while dirty — vim's contract, and here it protects a comment
    // the user has typed but not sent
    await page.keyboard.type(":q");
    await page.keyboard.press("Enter");
    await expect(header).toBeVisible();

    await page.keyboard.type(":q!");
    await page.keyboard.press("Enter");
    await expect(header).toHaveCount(0, {timeout: 15_000});
    await expectFocusInSource(page);

    expect(await threadsOf(ws)).toHaveLength(0);
});

// The push channel: the agent replies, and rook says so on its own. Threads
// used to refetch only when an editor pane regained FOCUS, so you could ask a
// question, watch claude answer in its own window, and the panel would still
// show your comment alone until you clicked back in.
test("an agent's reply arrives without refocusing the pane", async ({page}) => {
    test.setTimeout(120_000);

    const ws = `watch-e2e-${Date.now()}`;
    await openWorkspace(page, ws);
    await openSource(page, "internal/host/spawntask.go");

    await ctxChord(page, "c", "gg");
    await writeComment(page, "comment", "does this leak the goroutine");
    await expect.poll(async () => (await threadsOf(ws)).length, {timeout: 15_000}).toBe(1);

    // Open the reading panel and EXPAND the card — a collapsed card renders
    // the anchor snippet and a reply count, not the conversation, so an
    // assertion on the reply text would fail against a panel that had in fact
    // updated. Everything below this line happens without touching the page.
    await runCommand(page, "Toggle thread pane");
    const pane = page.locator('.side-pane[data-side="right"]');
    await expect(pane).toContainText("Threads");
    await pane.locator("[data-thread-state]").first().click();
    await expect(pane).toContainText("does this leak the goroutine");

    const [t] = await threadsOf(ws);
    const reply = await hostFetch(`/threads/${t.id}/comments`, {
        method: "POST",
        body: JSON.stringify({
            body: "No — the pty owns it and Close stops the copy.",
            author: "agent",
        }),
    });
    expect(reply.status).toBe(204);

    await expect(pane).toContainText("No — the pty owns it", {timeout: 15_000});
});

// The reading half: ,t opens the thread as a read-only BUFFER, :reply answers
// through the same draft-buffer model composition uses, and hover previews the
// conversation without displacing a single line of code.
test("`,t` opens a thread buffer; `:reply` answers it; hover previews it", async ({page}) => {
    test.setTimeout(120_000);

    const ws = `threadbuf-e2e-${Date.now()}`;
    await openWorkspace(page, ws);
    await openSource(page, "internal/host/spawntask.go");

    await ctxChord(page, "c", "18GVjj");
    await writeComment(page, "comment", "why is this named spawnTask");
    await expect.poll(async () => (await threadsOf(ws)).length, {timeout: 15_000}).toBe(1);
    const [t] = await threadsOf(ws);

    // ---- hover: the preview, in place ----
    // K routes through the same provider the mouse does, so the keyboard path
    // is the one under test. The thread comes FIRST in the stacked contents.
    await page.locator(".editor-mount").first().click();
    await page.keyboard.type("18G");
    await page.keyboard.press("Shift+K");
    const hover = page.locator(".monaco-hover:not(.hidden)").first();
    await expect(hover).toBeVisible({timeout: 20_000});
    await expect(hover).toContainText("why is this named spawnTask");
    await expect(hover).toContainText(`#${t.id}`);
    // the hover fades in (.monaco-hover.fade-in); let it settle or the shot
    // catches it mid-animation and reads as a transparency bug
    await page.waitForTimeout(300);
    await page.screenshot({path: "bin/e2e/threads-hover.png", fullPage: true});
    await page.keyboard.press("Escape");

    // ---- ,t : the thread as a buffer ----
    await ctxChord(page, "t", "18G");
    const threadHead = page.locator(".editor-path", {hasText: new RegExp(`^thread #${t.id} `)});
    await expect(threadHead).toBeVisible({timeout: 15_000});
    // it is a real buffer: rendered markdown, with the anchored source fenced
    const threadPane = page.locator(".editor-mount").last();
    await expect(threadPane).toContainText(`Thread #${t.id}`);
    await expect(threadPane).toContainText("why is this named spawnTask");
    // conversation-first: no fenced snapshot while the thread is still
    // anchored, so a short split shows the comment rather than the code you
    // are already looking at (the outdated case is pinned in the unit tests)
    await expect(threadPane).not.toContainText("```");

    // ---- :reply : the same draft-buffer model ----
    await page.keyboard.type(":reply");
    await page.keyboard.press("Enter");
    const replyHead = page.locator(".editor-path", {hasText: /^reply to #/});
    await expect(replyHead).toBeVisible({timeout: 15_000});
    await page.keyboard.press("i");
    await page.keyboard.type("because it spawns the coder, not a task");
    await page.keyboard.press("Escape");
    await page.keyboard.type(":w");
    await page.keyboard.press("Enter");
    await expect(replyHead).toHaveCount(0, {timeout: 15_000});

    // the thread buffer re-rendered itself with the new comment
    await expect(threadPane).toContainText("because it spawns the coder", {timeout: 15_000});
    await page.screenshot({path: "bin/e2e/threads-buffer.png", fullPage: true});

    // ---- :resolve acts and closes ----
    await page.keyboard.type(":resolve");
    await page.keyboard.press("Enter");
    await expect(threadHead).toHaveCount(0, {timeout: 15_000});
    await expectFocusInSource(page);
    await expect
        .poll(async () => (await threadsOf(ws))[0].state, {timeout: 15_000})
        .toBe("resolved");
});
