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
    const picker = page.getByPlaceholder("Open file…");
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
/** `gt` — go to the thread under the cursor. It moved off ,t when the context
 *  leader became the door to the thread FINDER; gt lives with gd/gr because it
 *  is the same kind of verb (jump to the thing attached to this line). */
async function goToThread(page: Page, at: string) {
    await page.locator(".editor-mount").first().click();
    await page.keyboard.type(at);
    await page.keyboard.type("gt");
}

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
    await expect.poll(async () => (await threadsOf(ws)).length, {timeout: 15_000}).toBe(1);
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

    await expect.poll(async () => (await threadsOf(ws)).length, {timeout: 15_000}).toBe(2);
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
// question, watch claude answer in its own window, and see nothing until you
// clicked back in. Now a thread BUFFER re-renders itself when the reply lands.
test("an agent's reply arrives without touching the page", async ({page}) => {
    test.setTimeout(120_000);

    const ws = `watch-e2e-${Date.now()}`;
    await openWorkspace(page, ws);
    await openSource(page, "internal/host/spawntask.go");

    await ctxChord(page, "c", "18G");
    await writeComment(page, "comment", "does this leak the goroutine");
    await expect.poll(async () => (await threadsOf(ws)).length, {timeout: 15_000}).toBe(1);
    const [t] = await threadsOf(ws);

    // open the thread as a buffer, then never touch the page again
    await goToThread(page, "18G");
    const threadPane = page.locator(".editor-mount").last();
    await expect(threadPane).toContainText("does this leak the goroutine", {timeout: 15_000});

    // …and now the agent answers, the way rookctl reply does
    const reply = await hostFetch(`/threads/${t.id}/comments`, {
        method: "POST",
        body: JSON.stringify({
            body: "No — the pty owns it and Close stops the copy.",
            author: "agent",
        }),
    });
    expect(reply.status).toBe(204);

    await expect(threadPane).toContainText("No — the pty owns it", {timeout: 15_000});
    await expect(threadPane).toContainText("claude");
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
    await goToThread(page, "18G");
    const threadHead = page.locator(".editor-path", {hasText: new RegExp(`^thread #${t.id} `)});
    await expect(threadHead).toBeVisible({timeout: 15_000});
    // it is a real buffer: rendered markdown, with the anchored source fenced
    const threadPane = page.locator(".editor-mount").last();
    await expect(threadPane).toContainText(`Thread #${t.id}`);
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

// Threads read through the ONE traversal muscle memory rather than a bespoke
// panel: ` t opens the quickfix list, j/k moves, o opens the thread buffer.
test("` t lists threads in the quickfix and `o` opens one", async ({page}) => {
    test.setTimeout(120_000);

    const ws = `qflist-e2e-${Date.now()}`;
    await openWorkspace(page, ws);
    await openSource(page, "internal/host/spawntask.go");

    await ctxChord(page, "c", "18G");
    await writeComment(page, "comment", "first note here");
    await ctxChord(page, "c", "24G");
    await writeComment(page, "comment", "second note here");
    await expect.poll(async () => (await threadsOf(ws)).length, {timeout: 15_000}).toBe(2);

    // ` t — the IDE leader opens the list (,t goes to the thread under the
    // cursor; the two are deliberately the same letter on the two leaders)
    await page.locator(".editor-mount").first().click();
    await page.keyboard.press("`");
    await page.keyboard.press("t");

    const strip = page.locator('.side-pane[data-side="bottom"]');
    await expect(strip).toContainText("Threads", {timeout: 15_000});
    const rows = page.locator("#quickfix-list [role=option]");
    await expect(rows).toHaveCount(2);
    await expect(strip).toContainText("first note here");
    await expect(strip).toContainText("second note here");

    // the strip holds the keyboard: j moves, o opens the thread buffer
    await page.keyboard.press("j");
    await expect(rows.nth(1)).toHaveAttribute("data-cursor", "1");
    await page.keyboard.press("o");
    await expect(page.locator(".editor-path", {hasText: /^thread #/})).toBeVisible({
        timeout: 15_000,
    });

    await page.screenshot({path: "bin/e2e/threads-list.png", fullPage: true});
});

// A thread buffer must NOT grab the keyboard when it re-renders.
//
// reloadThreads() routes every watch-stream event back through loadThread, and
// the stream fans out to every open thread pane — so an unconditional focus
// there meant any thread changing anywhere in the workspace (an agent reply, a
// :w of your own) yanked the caret out of whatever you were typing. The pane
// now focuses only through the wantFocus LATCH, which the open path sets and
// a reload does not.
test("a thread buffer re-rendering does not steal the keyboard", async ({page}) => {
    test.setTimeout(120_000);

    const ws = `focus-e2e-${Date.now()}`;
    await openWorkspace(page, ws);
    await openSource(page, "internal/host/spawntask.go");

    await ctxChord(page, "c", "18G");
    await writeComment(page, "comment", "does this leak the goroutine");
    await expect.poll(async () => (await threadsOf(ws)).length, {timeout: 15_000}).toBe(1);
    const [t] = await threadsOf(ws);

    await goToThread(page, "18G");
    const threadPane = page.locator(".editor-mount").last();
    await expect(threadPane).toContainText("does this leak the goroutine", {timeout: 15_000});

    // deliberately put the keyboard back in the SOURCE, as a user would after
    // reading the thread
    await page.locator(".editor-mount").first().click();
    const focusedPath = () =>
        page.evaluate(
            () =>
                document.activeElement?.closest(".editor-wrap")?.querySelector(".editor-path")
                    ?.textContent ?? null,
        );
    // NB: assert on the "thread #" prefix, not the filename — the thread
    // buffer's own header also contains the path, so toContain("spawntask.go")
    // matches BOTH panes and the assertion catches nothing.
    await expect.poll(focusedPath).not.toMatch(/^thread #/);

    // …now the agent answers. The thread pane must update WITHOUT taking focus.
    const reply = await hostFetch(`/threads/${t.id}/comments`, {
        method: "POST",
        body: JSON.stringify({body: "No — the pty owns it.", author: "agent"}),
    });
    expect(reply.status).toBe(204);
    await expect(threadPane).toContainText("No — the pty owns it", {timeout: 15_000});

    // the load-bearing assertion: the caret never left the source buffer
    const where = await focusedPath();
    expect(where).toContain("spawntask.go");
    expect(where).not.toMatch(/^thread #/);
});

// The gutter said "there is a thread here" and nothing else — you had to open
// it to learn whether anything was happening. These are the two surfaces that
// answer that without leaving the code: an inline row under the anchor, and a
// finder over every thread in the workspace.
test("the inline row says whose move it is, and follows the agent's reply", async ({page}) => {
    test.setTimeout(120_000);
    const ws = `zone-e2e-${Date.now()}`;
    await openWorkspace(page, ws);
    await openSource(page, "internal/host/spawntask.go");

    await ctxChord(page, "c", "18GVj");
    await writeComment(page, "comment", "does this leak the goroutine");
    await expect.poll(async () => (await threadsOf(ws)).length, {timeout: 15_000}).toBe(1);
    const [t] = await threadsOf(ws);

    const zone = page.locator(".thread-zone").first();
    await expect(zone).toBeVisible({timeout: 15_000});
    // written but not submitted: the ball is with the user
    await expect(zone).toContainText("not sent yet", {timeout: 15_000});
    await expect(zone).toContainText("does this leak the goroutine");
    // and the row is laid out, not run together — Monaco writes `display`
    // onto the zone node inline, which once silently reverted this to block
    await expect.poll(() => zone.evaluate((el) => getComputedStyle(el).display)).toBe("flex");

    // submit → the ball moves to the agent
    await page.locator(".editor-head .editor-submit").first().click();
    await expect(zone).toContainText("waiting on agent", {timeout: 20_000});

    // the agent answers → it comes back to you, over the watch stream alone
    const reply = await hostFetch(`/threads/${t.id}/comments`, {
        method: "POST",
        body: JSON.stringify({body: "No — the pty owns it.", author: "agent"}),
    });
    expect(reply.status).toBe(204);
    await expect(zone).toContainText("agent replied", {timeout: 20_000});
    await expect(zone).toContainText("No — the pty owns it");

    // resolved threads get NO row: a finished conversation shouldn't still be
    // occupying a line of the file
    const done = await hostFetch(`/threads/${t.id}/resolve`, {
        method: "POST",
        body: JSON.stringify({by: "user"}),
    });
    expect(done.status).toBe(204);
    await expect(page.locator(".thread-zone")).toHaveCount(0, {timeout: 20_000});

    await page.screenshot({path: "bin/e2e/threads-zone.png", fullPage: true});
});

test("`,t` finds threads across files; `gt` still opens the one under the cursor", async ({
    page,
}) => {
    test.setTimeout(120_000);
    const ws = `tfind-e2e-${Date.now()}`;
    await openWorkspace(page, ws);

    await openSource(page, "internal/host/spawntask.go");
    await ctxChord(page, "c", "18GVj");
    await writeComment(page, "comment", "zebra goroutine question");

    // the second thread lands on ANOTHER file through the host, not the UI:
    // this test is about the finder, and re-opening a source in the same pane
    // is a different mechanism with its own tests
    const made = await hostFetch(`/workspaces/${ws}/threads`, {
        method: "POST",
        body: JSON.stringify({
            path: "internal/host/grep.go",
            startLine: 20,
            endLine: 21,
            body: "walrus cap question",
        }),
    });
    expect(made.status).toBeLessThan(300);
    await expect.poll(async () => (await threadsOf(ws)).length, {timeout: 15_000}).toBe(2);

    // ,t — the finder, grouped by file, both threads present
    await page.locator(".editor-mount").first().click();
    await page.keyboard.press(",");
    await page.keyboard.press("t");
    const find = page.getByPlaceholder("Find a thread…");
    await expect(find).toBeVisible({timeout: 15_000});
    await expect(page.locator("[data-finder-row]")).toHaveCount(2, {timeout: 15_000});
    const list = page.locator("[data-finder-list]");
    // grouped by file — the header carries the path, the row carries the words
    await expect(list).toContainText("internal/host/grep.go");
    await expect(list).toContainText("internal/host/spawntask.go");

    // fuzzy matches what was SAID, not just the path — the whole reason this
    // is a finder and not the quickfix list
    await find.fill("zebra");
    await expect(page.locator("[data-finder-row]")).toHaveCount(1, {timeout: 15_000});
    await expect(list).toContainText("zebra goroutine question");
    await page.screenshot({path: "bin/e2e/threads-finder.png", fullPage: true});

    // Enter opens it as a buffer — the thread, not the file
    await find.press("Enter");
    const threadHeader = page.locator(".editor-path", {hasText: /^thread #/}).first();
    await expect(threadHeader).toBeVisible({timeout: 20_000});
    await expect(page.locator(".editor-mount").last()).toContainText("zebra goroutine question");

    // ---- and gt, the verb ,t used to be, still opens the thread under the
    // cursor. This is the half of the rebind that could silently vanish.
    await page.keyboard.type(":q");
    await page.keyboard.press("Enter");
    await expect(threadHeader).toHaveCount(0, {timeout: 15_000});
    await goToThread(page, "18G");
    await expect(page.locator(".editor-path", {hasText: /^thread #/}).first()).toBeVisible({
        timeout: 20_000,
    });
});
