import {expect, test, type Page} from "@playwright/test";
import * as fs from "node:fs";
import * as path from "node:path";
import {clickShown, deleteWorkspaces, gotoHome, shown} from "./harness";

// Threads as DOCUMENTS, end-to-end against the real host.
//
// A thread is a buffer you edit: host-rendered history above a scissors
// line, your draft below it. gt is dual — go to the thread under the cursor,
// or create one anchored there — and gd-SHAPED: it navigates the pane you
// are in (no split, no second pane), so the keyboard never moves and ⌃O
// walks back to the code. :w stores the tail silently; :ThreadNote /
// :ThreadAsk crystallize it into history (ask also nudges a responder, then
// walks back). If the buffer didn't take the keyboard, every assertion
// below fails.

const REPO = path.resolve(process.cwd(), "..");
const SANDBOX = path.join(REPO, "bin", "e2e", "xdg");
const made: string[] = [];

const SCISSORS = "-- ✂ --";

/** Monaco renders spaces as NBSP — normalize before ordering assertions. */
const plain = (s: string | null) => (s ?? "").replace(/ /g, " ");

interface Thread {
    id: number;
    path: string;
    startLine: number;
    endLine: number;
    state: string;
    draft?: string;
    comments: {body: string; author: string}[];
}

test.afterEach(async ({page}) => {
    await deleteWorkspaces(page, made.splice(0));
});

async function openWorkspace(page: Page, name: string) {
    made.push(name);
    await gotoHome(page);
    await page.getByRole("button", {name: /^workspaces/i}).click();
    await page.getByRole("button", {name: "New workspace"}).click();
    await expect(page.locator("#ws-modal")).toBeVisible();
    await page.getByPlaceholder("e.g. rook-core").fill(name);
    await page.getByPlaceholder("~/go/src/github.com/incantery/rook").fill(REPO);
    await page.getByRole("button", {name: "Create workspace"}).click();
    // Wait for the SWITCH, not just for a shell: until the new workspace
    // is the one displayed, the PREVIOUS one is still what selectors and
    // pickers see. That is how a finder ended up listing ~/Downloads.
    await expect(page.locator(`[data-workspace="${name}"]`)).toBeVisible({timeout: 15_000});
    await expect(shown(page, ".vt-screen")).toBeVisible({timeout: 15_000});
}

/** Talk to the sandbox daemon directly — how the AGENT sees and mutates
 *  threads (rookctl is just an HTTP client). Lets a test assert the real
 *  stored state instead of pane text, and produce an agent reply without
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

const docOf = async (id: number): Promise<{content: string; draft?: string}> =>
    (await (await hostFetch(`/threads/${id}/doc`)).json()) as {content: string; draft?: string};

async function runCommand(page: Page, title: string) {
    await page.getByRole("button", {name: /commands/}).click();
    await expect(page.getByPlaceholder("Run a command…")).toBeVisible();
    await page.getByPlaceholder("Run a command…").fill(title);
    await page.keyboard.press("Enter");
}

async function openSource(page: Page, file: string) {
    await runCommand(page, "Open file");
    const picker = page.getByPlaceholder("Open file…");
    await expect(picker).toBeVisible();
    await picker.fill(file);
    await picker.press("Enter");
    await expect(page.locator(".editor-path").first()).toContainText(file, {timeout: 20_000});
    // vim must be attached before any keystroke means anything
    await expect(page.locator(".editor-vim").first()).toContainText(/NORMAL/i, {timeout: 15_000});
}

/** gt — go-to-or-create. `at` is a vim motion (optionally a visual
 *  selection) that parks the cursor first, so the anchor comes from where
 *  the cursor actually IS, not a fixed spot. */
async function goToThread(page: Page, at: string) {
    await page.locator(".editor-mount").first().click();
    await page.keyboard.type(at);
    await page.keyboard.type("gt");
}

const threadHead = (page: Page) => page.locator(".editor-path", {hasText: /^thread #/}).first();

/** Point the coder at something inert: :ThreadAsk actuates a responder, and
 *  the default coder is `claude` — without this the suite would spawn the
 *  machine's real claude. MERGE rather than overwrite: the sandbox config is
 *  one file shared by every spec, so rewriting it wholesale silently disarms
 *  another spec's setup (lsp.spec's gopls lines live here too). */
function neuterCoder() {
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
}

// The core loop: gt creates, the tail is a draft, :ThreadAsk crystallizes
// and summons; a scripted agent reply lands ABOVE the scissors and the
// draft zone comes back clean.
test("gt creates a thread; :w keeps the tail; :ThreadAsk sends it", async ({page}) => {
    test.setTimeout(120_000);
    neuterCoder();

    const ws = `threads-e2e-${Date.now()}`;
    await openWorkspace(page, ws);
    await openSource(page, "internal/host/spawntask.go");

    // ---- gt on a bare region CREATES, anchored to the visual selection ----
    await goToThread(page, "18GVjj");
    await expect(threadHead(page)).toBeVisible({timeout: 20_000});
    // gd-shaped: the SAME pane navigated — no split appeared, and typing
    // works immediately because the keyboard never left this editor
    await expect(page.locator(".editor-mount")).toHaveCount(1);
    const threadPane = page.locator(".editor-mount").first();
    await expect(threadPane).toContainText(SCISSORS, {timeout: 15_000});

    await expect.poll(async () => (await threadsOf(ws)).length, {timeout: 15_000}).toBe(1);
    const [t] = await threadsOf(ws);
    expect(t.startLine).toBe(18);
    expect(t.endLine).toBe(20);
    expect(t.comments).toHaveLength(0); // history grows only on note/ask
    expect(t.state).toBe("pending");

    // ---- the tail: cursor already sits below the scissors ----
    await page.keyboard.press("i");
    await page.keyboard.type("why is this named spawnTask");
    await page.keyboard.press("Escape");
    await page.keyboard.type(":w");
    await page.keyboard.press("Enter");
    await page.screenshot({path: "bin/e2e/threads-tail.png", fullPage: true});

    // :w is SILENT — a stored draft, no comment, no agent
    await expect
        .poll(async () => (await docOf(t.id)).draft ?? "", {timeout: 15_000})
        .toContain("why is this named spawnTask");
    expect((await threadsOf(ws))[0].comments).toHaveLength(0);

    // ---- the reload survives: an agent reply grows history ABOVE the
    // scissors while the pane is open, and the tail stays put ----
    const reply = await hostFetch(`/threads/${t.id}/comments`, {
        method: "POST",
        body: JSON.stringify({body: "spawn is the pty half.", author: "agent"}),
    });
    expect(reply.status).toBe(204);
    await expect(threadPane).toContainText("spawn is the pty half.", {timeout: 15_000});
    await expect(threadPane).toContainText("why is this named spawnTask");
    const text = plain(await threadPane.textContent());
    expect(text.indexOf("spawn is the pty half.")).toBeGreaterThan(-1);
    expect(text.indexOf("spawn is the pty half.")).toBeLessThan(text.indexOf(SCISSORS));

    // ---- :ThreadAsk crystallizes the tail and walks BACK to the code ----
    await page.keyboard.type(":ThreadAsk");
    await page.keyboard.press("Enter");
    await expect(threadHead(page)).toHaveCount(0, {timeout: 15_000});
    await expect(page.locator(".editor-path").first()).toContainText("spawntask.go", {
        timeout: 15_000,
    });
    await expect.poll(async () => (await threadsOf(ws))[0].state, {timeout: 15_000}).toBe("open");
    const after = (await threadsOf(ws))[0];
    const last = after.comments[after.comments.length - 1];
    expect(last.author).toBe("user");
    expect(last.body).toBe("why is this named spawnTask");

    // ---- reopen with gt: the question is history now, the draft zone clean ----
    await goToThread(page, "18G");
    await expect(threadHead(page)).toBeVisible({timeout: 20_000});
    const pane2 = page.locator(".editor-mount").first();
    await expect(pane2).toContainText("why is this named spawnTask", {timeout: 15_000});
    const text2 = plain(await pane2.textContent());
    expect(text2.indexOf("why is this named spawnTask")).toBeGreaterThan(-1);
    expect(text2.indexOf("why is this named spawnTask")).toBeLessThan(text2.indexOf(SCISSORS));
    expect((await docOf(t.id)).draft ?? "").toBe("");
    await page.screenshot({path: "bin/e2e/threads-doc.png", fullPage: true});
});

// The SECOND round — the regression that shipped with round one. :ThreadAsk
// walks back to the file, and its own notify fans a reload out to the pane
// CONCURRENTLY: without the staleness guard, the late thread render painted
// over the file (a chimera pane where 18G clamps to the doc's line count and
// gt mints a bogus thread at the clamp). This drives ask → reply → follow-up
// ask → :ThreadNote, with the cursor position asserted at the seam.
test("a conversation: follow-up ask after the reply, :ThreadNote stays put", async ({page}) => {
    test.setTimeout(120_000);
    neuterCoder();
    const ws = `reply2-e2e-${Date.now()}`;
    await openWorkspace(page, ws);
    await openSource(page, "internal/host/spawntask.go");

    // round one: gt create, ask — :w and :ThreadAsk back-to-back (the ask
    // must QUEUE behind the in-flight save, not silently vanish)
    await goToThread(page, "18G");
    await expect(threadHead(page)).toBeVisible({timeout: 20_000});
    await page.keyboard.press("i");
    await page.keyboard.type("round one question");
    await page.keyboard.press("Escape");
    await page.keyboard.type(":w");
    await page.keyboard.press("Enter");
    await page.keyboard.type(":ThreadAsk");
    await page.keyboard.press("Enter");
    await expect(threadHead(page)).toHaveCount(0, {timeout: 15_000});
    await expect
        .poll(async () => (await threadsOf(ws))[0]?.comments.length ?? 0, {timeout: 15_000})
        .toBe(1);
    const [t] = await threadsOf(ws);

    const reply = await hostFetch(`/threads/${t.id}/comments`, {
        method: "POST",
        body: JSON.stringify({body: "the agent's answer.", author: "agent"}),
    });
    expect(reply.status).toBe(204);

    // round two: the walk-back left the keyboard in the FILE — the chimera
    // tripwire is this motion working at all
    await expect(page.locator(".editor-path").first()).toContainText("spawntask.go", {
        timeout: 15_000,
    });
    await page.keyboard.type("18G");
    await expect(page.locator("#statusbar")).toContainText("Ln 18,", {timeout: 10_000});
    await page.keyboard.type("gt");
    await expect(threadHead(page)).toBeVisible({timeout: 20_000});
    await expect(page.locator(".editor-mount").first()).toContainText("the agent's answer.", {
        timeout: 15_000,
    });
    await page.keyboard.press("i");
    await page.keyboard.type("round two follow-up");
    await page.keyboard.press("Escape");
    await page.keyboard.type(":ThreadAsk"); // save-first: no :w needed
    await page.keyboard.press("Enter");
    await expect(threadHead(page)).toHaveCount(0, {timeout: 15_000});
    await expect
        .poll(async () => (await threadsOf(ws))[0]?.comments.length ?? 0, {timeout: 15_000})
        .toBe(3);
    const after = (await threadsOf(ws))[0];
    expect(after.comments[2].body).toBe("round two follow-up");
    expect(after.comments[2].author).toBe("user");
    // ONE thread — the chimera bug's signature was a bogus second one
    expect(await threadsOf(ws)).toHaveLength(1);

    // :ThreadNote from inside the buffer: crystallizes, no nudge, STAYS
    await page.keyboard.type("18G");
    await page.keyboard.type("gt");
    await expect(threadHead(page)).toBeVisible({timeout: 20_000});
    await page.keyboard.press("i");
    await page.keyboard.type("a note for the record");
    await page.keyboard.press("Escape");
    await page.keyboard.type(":ThreadNote");
    await page.keyboard.press("Enter");
    await expect
        .poll(async () => (await threadsOf(ws))[0]?.comments.length ?? 0, {timeout: 15_000})
        .toBe(4);
    expect((await threadsOf(ws))[0].comments[3].body).toBe("a note for the record");
    // the note is history now, above the scissors, and the buffer stayed
    await expect(threadHead(page)).toBeVisible();
    await expect(page.locator(".editor-mount").first()).toContainText("a note for the record");
});

// The abort paths: gt minted a thread, nothing was said — navigating away
// (⌃O, the gd-shaped exit) or :q takes it back. Neither litters.
test("an untouched gt thread deletes itself on the way out", async ({page}) => {
    test.setTimeout(120_000);
    const ws = `abort-e2e-${Date.now()}`;
    await openWorkspace(page, ws);
    await openSource(page, "internal/host/spawntask.go");

    // ⌃O — the buffer walk back abandons the empty thread
    await goToThread(page, "gg");
    await expect(threadHead(page)).toBeVisible({timeout: 20_000});
    await expect.poll(async () => (await threadsOf(ws)).length, {timeout: 15_000}).toBe(1);
    await page.keyboard.press("Control+o");
    await expect(page.locator(".editor-path").first()).toContainText("spawntask.go", {
        timeout: 15_000,
    });
    await expect.poll(async () => (await threadsOf(ws)).length, {timeout: 15_000}).toBe(0);

    // :q — vim's window close, same guarantee
    await goToThread(page, "gg");
    await expect(threadHead(page)).toBeVisible({timeout: 20_000});
    await expect.poll(async () => (await threadsOf(ws)).length, {timeout: 15_000}).toBe(1);
    await page.keyboard.type(":q");
    await page.keyboard.press("Enter");
    await expect(threadHead(page)).toHaveCount(0, {timeout: 15_000});
    await expect.poll(async () => (await threadsOf(ws)).length, {timeout: 15_000}).toBe(0);
});

// History is read-only by CONTRACT, not by region locking: a save whose
// prefix doesn't match a fresh render is refused (409) and the buffer heals
// to the honest state — mangled history reverted, tail carried forward.
test("a tampered history is rejected on save and healed", async ({page}) => {
    test.setTimeout(120_000);
    const ws = `tamper-e2e-${Date.now()}`;
    await openWorkspace(page, ws);

    const mk = await hostFetch(`/workspaces/${ws}/threads`, {
        method: "POST",
        body: JSON.stringify({
            path: "internal/host/spawntask.go",
            startLine: 18,
            endLine: 18,
            body: "the original question",
        }),
    });
    expect(mk.status).toBeLessThan(300);

    await openSource(page, "internal/host/spawntask.go");
    await goToThread(page, "18G");
    const pane = page.locator(".editor-mount").last();
    await expect(pane).toContainText("the original question", {timeout: 15_000});

    // vandalize the history (line 2 sits inside the frontmatter), then :w
    await page.keyboard.type("2Gccvandalism");
    await page.keyboard.press("Escape");
    await page.keyboard.type(":w");
    await page.keyboard.press("Enter");

    // the save was refused and the buffer healed from the host's fresh render
    await expect(pane).not.toContainText("vandalism", {timeout: 15_000});
    await expect(pane).toContainText("the original question");
    const [t] = await threadsOf(ws);
    expect(t.comments).toHaveLength(1); // nothing crystallized, nothing lost
});

// The push channel: the agent replies, and the open buffer says so on its
// own — no refocus, no manual refresh.
test("an agent's reply arrives without touching the page", async ({page}) => {
    test.setTimeout(120_000);

    const ws = `watch-e2e-${Date.now()}`;
    await openWorkspace(page, ws);

    const mk = await hostFetch(`/workspaces/${ws}/threads`, {
        method: "POST",
        body: JSON.stringify({
            path: "internal/host/spawntask.go",
            startLine: 18,
            endLine: 18,
            body: "does this leak the goroutine",
        }),
    });
    expect(mk.status).toBeLessThan(300);
    const [t] = await threadsOf(ws);

    await openSource(page, "internal/host/spawntask.go");
    // open the thread as a buffer (in place), then never touch the page again
    await goToThread(page, "18G");
    const threadPane = page.locator(".editor-mount").first();
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

    // arrival proof, hands off: the reply's author header renders on its own
    await expect(threadPane).toContainText("claude", {timeout: 15_000});
    // the pane is a short split and Monaco only mounts visible lines — the
    // body can sit just past the render boundary, so wheel the tail in for
    // the content assertion (scrolling is not the refetch-on-focus the test
    // exists to rule out)
    await threadPane.hover();
    await page.mouse.wheel(0, 600);
    await expect(threadPane).toContainText("No — the pty owns it", {timeout: 15_000});
});

// A thread buffer must NOT grab the keyboard when it re-renders.
//
// reloadThreads() routes every watch-stream event back through loadThread,
// and the stream fans out to every open thread pane — so an unconditional
// focus there meant any thread changing anywhere in the workspace (an agent
// reply, a :w of your own) yanked the caret out of whatever you were typing.
// With gt navigating in place there's no split to steal from, so the other
// surface in the window is a terminal (` % splits one in beside the editor).
test("a thread buffer re-rendering does not steal the keyboard", async ({page}) => {
    test.setTimeout(120_000);

    const ws = `focus-e2e-${Date.now()}`;
    await openWorkspace(page, ws);

    const mk = await hostFetch(`/workspaces/${ws}/threads`, {
        method: "POST",
        body: JSON.stringify({
            path: "internal/host/spawntask.go",
            startLine: 18,
            endLine: 18,
            body: "does this leak the goroutine",
        }),
    });
    expect(mk.status).toBeLessThan(300);
    const [t] = await threadsOf(ws);

    await openSource(page, "internal/host/spawntask.go");
    await goToThread(page, "18G");
    const threadPane = page.locator(".editor-mount").first();
    await expect(threadPane).toContainText("does this leak the goroutine", {timeout: 15_000});

    // a shell beside the buffer, and the keyboard deliberately in it
    await page.keyboard.press("`");
    await page.keyboard.press("%");
    const term = shown(page, ".vt-screen");
    await expect(term).toBeVisible({timeout: 15_000});
    await clickShown(term);
    const inEditor = () => page.evaluate(() => !!document.activeElement?.closest(".editor-wrap"));
    await expect.poll(inEditor).toBe(false);

    // …now the agent answers. The thread pane must update WITHOUT taking focus.
    const reply = await hostFetch(`/threads/${t.id}/comments`, {
        method: "POST",
        body: JSON.stringify({body: "No — the pty owns it.", author: "agent"}),
    });
    expect(reply.status).toBe(204);
    await expect(threadPane).toContainText("No — the pty owns it", {timeout: 15_000});

    // the load-bearing assertion: the caret never left the shell
    expect(await inEditor()).toBe(false);
});

// The same steal, forced rather than waited for: a thread still LOADING when
// you move the keyboard elsewhere must not yank it back when the load lands.
test("a thread loading after you click away does not yank the caret back", async ({page}) => {
    test.setTimeout(120_000);
    const ws = `latch-e2e-${Date.now()}`;
    await openWorkspace(page, ws);

    const mk = await hostFetch(`/workspaces/${ws}/threads`, {
        method: "POST",
        body: JSON.stringify({
            path: "internal/host/spawntask.go",
            startLine: 18,
            endLine: 18,
            body: "does this leak the goroutine",
        }),
    });
    expect(mk.status).toBeLessThan(300);

    await openSource(page, "internal/host/spawntask.go");
    // a shell beside the buffer — the place the keyboard will move to
    await page.keyboard.press("`");
    await page.keyboard.press("%");
    const term = shown(page, ".vt-screen");
    await expect(term).toBeVisible({timeout: 15_000});

    // Hold the thread fetch open: the gap between "gt typed" and "doc
    // loaded" is a few ms in practice — too narrow to land a click in
    // reliably. Delaying the requests the load waits on makes that window a
    // second wide and the race a certainty.
    const slowThreads = (u: URL) => u.pathname.endsWith("/threads") || u.pathname.endsWith("/doc");
    await page.route(slowThreads, async (route) => {
        await new Promise((r) => setTimeout(r, 1500));
        await route.continue();
    });

    await goToThread(page, "18G");
    await clickShown(term); // mid-load, the keyboard moves to the shell
    await page.unroute(slowThreads);

    const threadPane = page.locator(".editor-mount").first();
    await expect(threadPane).toContainText("does this leak the goroutine", {timeout: 15_000});

    expect(await page.evaluate(() => !!document.activeElement?.closest(".editor-wrap"))).toBe(
        false,
    );
});

// Threads read through the ONE traversal muscle memory rather than a bespoke
// panel: ` t opens the quickfix list, j/k moves, o opens the thread buffer.
test("` t lists threads in the quickfix and `o` opens one", async ({page}) => {
    test.setTimeout(120_000);

    const ws = `qflist-e2e-${Date.now()}`;
    await openWorkspace(page, ws);

    for (const [line, body] of [
        [18, "first note here"],
        [24, "second note here"],
    ] as const) {
        const mk = await hostFetch(`/workspaces/${ws}/threads`, {
            method: "POST",
            body: JSON.stringify({
                path: "internal/host/spawntask.go",
                startLine: line,
                endLine: line,
                body,
            }),
        });
        expect(mk.status).toBeLessThan(300);
    }

    await openSource(page, "internal/host/spawntask.go");

    // ` t — the IDE leader opens the list (gt goes to the thread under the
    // cursor; the leader is for the surfaces you reach without one)
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
    await expect(threadHead(page)).toBeVisible({timeout: 15_000});

    await page.screenshot({path: "bin/e2e/threads-list.png", fullPage: true});
});

// The finder over every thread in the workspace (,t), and gt as the motion.
test("`,t` finds threads across files; `gt` opens the one under the cursor", async ({page}) => {
    test.setTimeout(120_000);
    const ws = `tfind-e2e-${Date.now()}`;
    await openWorkspace(page, ws);

    for (const [file, line, body] of [
        ["internal/host/spawntask.go", 18, "zebra goroutine question"],
        ["internal/host/grep.go", 20, "walrus cap question"],
    ] as const) {
        const mk = await hostFetch(`/workspaces/${ws}/threads`, {
            method: "POST",
            body: JSON.stringify({path: file, startLine: line, endLine: line + 1, body}),
        });
        expect(mk.status).toBeLessThan(300);
    }
    await openSource(page, "internal/host/spawntask.go");

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

    // Enter opens it as a buffer — the thread, not the file, IN this pane
    await find.press("Enter");
    await expect(threadHead(page)).toBeVisible({timeout: 20_000});
    await expect(page.locator(".editor-mount").first()).toContainText("zebra goroutine question");

    // ⌃O walks back out — the gd contract, and the pane is the file again
    await page.keyboard.press("Control+o");
    await expect(threadHead(page)).toHaveCount(0, {timeout: 15_000});
    await expect(page.locator(".editor-path").first()).toContainText("spawntask.go");

    // ---- and gt still opens the thread under the cursor — the go-to half
    await goToThread(page, "18G");
    await expect(threadHead(page)).toBeVisible({timeout: 20_000});
    // hover previews without opening — the glance surface (K keyboard path)
    await page.keyboard.press("Control+o");
    await expect(threadHead(page)).toHaveCount(0, {timeout: 15_000});
    await page.locator(".editor-mount").first().click();
    await page.keyboard.type("18G");
    await page.keyboard.press("Shift+K");
    const hover = page.locator(".monaco-hover:not(.hidden)").first();
    await expect(hover).toBeVisible({timeout: 20_000});
    await expect(hover).toContainText("zebra goroutine question");
});
