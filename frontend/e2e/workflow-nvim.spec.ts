import {expect, test} from "./harness";
import * as fs from "node:fs/promises";
import * as path from "node:path";

// Editing a file through nvim running in a rook terminal pane — keystroke →
// xterm → websocket → host → pty → nvim → disk. Every other spec drives the
// EDITOR pane (Monaco); this is the only coverage of the terminal data plane,
// which is where rook's two nvim bugs have lived: the $y mode reports the
// replay gate could not see, and an E21 that is still unexplained.
//
// nvim here runs against the e2e sandbox's XDG triple, so it has no user
// config and no plugins. That is deliberate — a plugin-less nvim is the
// deterministic one, and the thing under test is rook's pty, not nvim's.

async function haveNvim(): Promise<boolean> {
    for (const dir of (process.env.PATH ?? "").split(":")) {
        try {
            await fs.access(path.join(dir, "nvim"));
            return true;
        } catch {
            /* keep looking */
        }
    }
    return false;
}

test.beforeAll(async () => {
    test.skip(!(await haveNvim()), "nvim is not installed");
});

test("nvim in a pane edits a file and writes it to disk", async ({page, rook}) => {
    test.setTimeout(120_000);
    const root = await rook.repo({files: {"notes.txt": "alpha\nbravo\ncharlie\n"}});
    await rook.open({name: `nvim-edit-${Date.now()}`, root});

    await rook.term().click();
    await rook.ex("nvim notes.txt");
    // the file's own text on screen is the ready signal — a prompt-based one
    // would race nvim's alternate-screen switch
    await rook.expectScreen(/alpha/);
    await rook.expectScreen(/charlie/);

    // O opens a line above and enters insert; Esc back to normal; :wq writes
    await page.keyboard.press("g");
    await page.keyboard.press("g");
    await page.keyboard.press("Shift+O");
    await page.keyboard.type("delta");
    await page.keyboard.press("Escape");
    await rook.ex(":wq");

    // the assertion that matters is on DISK, not on screen: it is the only
    // one that proves the keystrokes crossed every layer rather than merely
    // being echoed back into a grid
    await expect
        .poll(() => fs.readFile(path.join(root, "notes.txt"), "utf8"), {timeout: 20_000})
        .toBe("delta\nalpha\nbravo\ncharlie\n");
});

test("reattaching to a pane running nvim types nothing into it", async ({rook}) => {
    test.setTimeout(120_000);
    const original = "alpha\nbravo\ncharlie\n";
    const root = await rook.repo({files: {"notes.txt": original}});
    await rook.tapPty();
    const ws = await rook.open({name: `nvim-reattach-${Date.now()}`, root});

    await rook.term().click();
    await rook.ex("nvim notes.txt");
    await rook.expectScreen(/alpha/);
    await rook.drainPty(); // everything so far was typed on purpose

    // Relaunch rook while nvim is live. The host replays its whole ring, so
    // xterm re-parses every query nvim asked on startup and answers them
    // again — to an nvim that is not asking. AUTO_REPLY exists to swallow
    // those; anything it misses arrives as literal text, and literal text in
    // normal mode is a command.
    await rook.reenter(ws);
    await rook.expectScreen(/alpha/);

    // Focus in/out is the ONLY thing rook may legitimately send here: nvim
    // asked for focus reporting (CSI ?1004h) and the browser really did
    // change focus. Everything else is an answer to a question nobody asked.
    //
    // Assert on the socket, not on nvim. nvim swallows stale query answers
    // without complaint, so a screen-and-buffer assertion here passes even
    // with the gate disabled outright — it did, which is how this got caught.
    const sent = await rook.drainPty();
    expect(sent.filter((f) => !/^\x1b\[[IO]$/.test(f))).toEqual([]);
});
