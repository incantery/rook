// The e2e harness: one place for the steps every spec repeats, and a git
// fixture builder so a test can own its repo instead of borrowing yours.
//
// Before this, eight specs each carried their own copy of openWorkspace and
// its afterEach. That is survivable for a 150-line feature spec and fatal for
// a workflow, which is mostly composition — so the copies became a fixture.
//
// The fixture repo matters more than it looks. review.spec.ts used to point a
// workspace at the ROOK CHECKOUT and review whatever you happened to have
// uncommitted, which meant its result depended on the developer's working
// tree: it asserted a second hunk, so it passed with two dirty files and
// failed with one. A test that reads your desk cannot assert a count. Build
// the repo, know the answer.

import {test as base, expect, type Locator, type Page} from "@playwright/test";
import {execFile} from "node:child_process";
import * as fs from "node:fs/promises";
import * as os from "node:os";
import * as path from "node:path";
import {promisify} from "node:util";

const exec = promisify(execFile);

/** the rook checkout — the right root for specs that need a big real tree
 *  (grep, LSP, highlighting). Anything that WRITES should build a repo. */
export const REPO = path.resolve(process.cwd(), "..");

/** The first match inside the ACTIVE window — how you address a pane.
 *
 *  This used to be `sel >> visible=true`, and that was the suite's one
 *  recurring flake. rook never unmounts an inactive window's panes; it hides
 *  the whole window with `display:none` (app.css `.window`). Playwright's
 *  visibility filter was caught matching one of those hidden panes anyway —
 *  diagnosed live as `vt[0] 0x0@0,0 display=block inActiveWin=false` sitting
 *  alongside the real `vt[1] 1392x804 inActiveWin=true`. The hidden pane is
 *  OLDER, so it sorts first in DOM order, `.first()` returned it, and every
 *  click on a zero-area element timed out.
 *
 *  That is why this scopes to the window rook ITSELF calls active rather than
 *  trusting :visible — the app's own notion of "shown" is the one that can't
 *  disagree with the app. Two scopes, because a window's furniture is not a
 *  pane: `.window.active` holds the terminals and editors, `[data-win=active]`
 *  holds the per-window chrome (the tree), which is mounted for EVERY window
 *  and hidden for all but one. Chrome outside the window tree entirely (the
 *  adopted vim bar) needs `shownChrome` instead.
 *
 *  BOTH guards are load-bearing and the pair is the whole point. Scope alone
 *  is not enough: a closed side pane is still mounted inside the ACTIVE
 *  window, so `toHaveCount(0)` after closing the tree would never pass.
 *  :visible alone is not enough either — that was the original flake. Scope
 *  first so the stale window can't match at all, then filter by visibility
 *  within the window that is genuinely on screen. */
export const shown = (page: Page, sel: string): Locator =>
    page.locator(`.window.active ${sel}, [data-win="active"] ${sel} >> visible=true`).first();

/** The first visible match ANYWHERE — for chrome that is not a pane, so the
 *  window-scoping above would find nothing. The vim command line is the case:
 *  the editor's node is adopted into the global status bar (vimbar.svelte.ts),
 *  which sits outside every .window. */
export const shownChrome = (page: Page, sel: string): Locator =>
    page.locator(`${sel} >> visible=true`).first();

/** Wait for a boot (or reload) to settle on its landing surface. Boot lands
 *  in a SHELL — opening rook is opening a terminal — so the normal landing
 *  is a pane; mission control is the fail-open one (a failed landing).
 *  The first boot of a fresh sandbox spawns the default workspace's first
 *  shell, hence the generous timeout. */
export async function booted(page: Page): Promise<void> {
    await expect(shown(page, ".vt-screen").or(page.locator("#home"))).toBeVisible({
        timeout: 30_000,
    });
}

/** Summon mission control from wherever boot landed — ` h from a shell,
 *  a no-op when the fail-open path already put us there. */
export async function summonHome(page: Page): Promise<void> {
    await booted(page);
    const home = page.locator("#home");
    if (!(await home.isVisible())) {
        await page.keyboard.press("`");
        await page.keyboard.press("h");
    }
    await expect(home).toBeVisible();
}

/** The old goto("/")-and-wait-for-#home gate, under the new boot: land in
 *  the shell, then summon mission control. */
export async function gotoHome(page: Page): Promise<void> {
    await page.goto("/");
    await summonHome(page);
}

/** A git repo to point a workspace at. `files` land in one baseline commit;
 *  `dirty` is written afterwards and left unstaged, which is what a review
 *  batch diffs. */
export interface RepoSpec {
    files: Record<string, string>;
    dirty?: Record<string, string>;
}

async function writeAll(root: string, files: Record<string, string>): Promise<void> {
    for (const [rel, body] of Object.entries(files)) {
        const full = path.join(root, rel);
        await fs.mkdir(path.dirname(full), {recursive: true});
        await fs.writeFile(full, body);
    }
}

/** the sandbox XDG triple serve.sh builds — its own state, config and data */
export const SANDBOX = path.join(REPO, "bin", "e2e", "xdg");

/** the stand-in coder serve.sh points the sandbox's `coder` at */
export const STUB_CODER = path.join(process.cwd(), "e2e", "stub-coder.sh");

/** Talk to the sandbox daemon directly, for the state a UI cannot show —
 *  what the host DECIDED, as opposed to what happened to appear on screen. */
export async function hostFetch(route: string, init?: RequestInit): Promise<Response> {
    const st = JSON.parse(
        await fs.readFile(path.join(SANDBOX, "state", "rook", "host.json"), "utf8"),
    ) as {port: number; token: string};
    return fetch(`http://127.0.0.1:${st.port}${route}`, {
        ...init,
        headers: {Authorization: `Bearer ${st.token}`},
    });
}

/** Delete workspaces a spec created, and wait for each to actually go.
 *
 *  Exported for the specs not yet on the `rook` fixture: seven of them carried
 *  a byte-identical copy of this, which meant seven copies of the same two
 *  bugs. boot.spec's "No workspaces yet" is the sandbox canary, so a leak here
 *  fails a LATER file and reads as a flake in something innocent.
 *
 *  Both waits are explicit. #home renders before listWorkspaces resolves, so
 *  an immediate count reads 0 for a workspace that is very much there, and a
 *  cleanup that treats that as "nothing to do" leaves the mess it exists to
 *  prevent. And deleting kills the workspace's sessions — a shell cold-started
 *  in a fresh sandbox (oh-my-zsh compiling its plugins) is slow to die, which
 *  the default 5s covered warm and not cold. */
export async function deleteWorkspaces(page: Page, names: string[]): Promise<void> {
    for (const name of names) {
        await gotoHome(page);
        await page.getByRole("button", {name: /^workspaces/i}).click();
        const card = page
            .locator("#home-workspaces div.group")
            .filter({has: page.getByText(name, {exact: true})});
        await expect(card).toHaveCount(1, {timeout: 30_000});
        // RETRY the click rather than wait out one. The workspace list
        // re-renders on its own poll, so a delete can land on a node that is
        // detaching and quietly do nothing — and the only symptom is a card
        // that never goes away, thirty seconds later, in cleanup, failing a
        // test whose body already passed.
        let gone = false;
        for (let attempt = 0; attempt < 3 && !gone; attempt++) {
            await card
                .getByTitle(/^Delete workspace/)
                .click({timeout: 10_000})
                .catch(() => {}); // a detached node: re-resolve and try again
            gone = await card
                .waitFor({state: "detached", timeout: 10_000})
                .then(() => true)
                .catch(() => false);
        }
        await expect(card).toHaveCount(0, {timeout: 30_000});
    }
}

/** Flatten a terminal's rendered text. xterm draws every space as U+00A0 to
 *  hold the column, so a plain match with a space in it never fires.
 *
 *  Renderer-agnostic: the WebGL renderer paints to a canvas, which has no
 *  innerText at all, and exposes __screenText() on its container instead
 *  (term/vt/beamterm.ts). Reading through that here is what lets shellReady —
 *  and everything built on it — drive either side of the renderer seam. */
export const screenText = (term: Locator): Promise<string> =>
    term.evaluate((el) => {
        const probe = (el as HTMLElement & {__screenText?: () => string}).__screenText;
        const text = probe ? probe() : (el as HTMLElement).innerText;
        return text.replace(/\u00a0/g, " ");
    });

/** The text of every VISIBLE terminal pane, joined.
 *
 *  Reach for this instead of `expect(locator).toContainText(...)` against a
 *  .vt-screen or a .window.active that contains one. The renderer paints to a
 *  canvas: Playwright's text matchers see an empty string there and simply
 *  time out, which is how a renderer swap turns into a pile of 26-second
 *  failures that look like hangs. In a split it is also what you want — the
 *  keyboard may be in either half. */
export const paneText = (page: Page): Promise<string> =>
    page.evaluate(() =>
        [...document.querySelectorAll<HTMLElement>(".vt-screen")]
            .filter((el) => el.offsetParent !== null)
            .map((el) => {
                const probe = (el as HTMLElement & {__screenText?: () => string}).__screenText;
                return probe ? probe() : el.innerText;
            })
            .join("\n")
            .replace(/\u00a0/g, " "),
    );

/** Poll paneText until it contains `want`. The terminal-safe replacement for
 *  toContainText on a pane. */
export async function expectPaneText(page: Page, want: string, timeout = 15_000): Promise<void> {
    await expect.poll(() => paneText(page), {timeout}).toContain(want);
}

/** Wait until the shell in `term` is reading input.
 *
 *  A pane is visible long before its shell is usable: the e2e sandbox has its
 *  own XDG triple, so the FIRST run in a fresh sandbox pays oh-my-zsh's plugin
 *  compilation, which takes seconds and prints while it works. Anything typed
 *  meanwhile lands in the pty buffer and runs late — or not in the order you
 *  assumed. That is the whole of the "telescope keys" cold flake: it typed a
 *  cd, slept 800ms, and opened a picker that had not moved.
 *
 *  The probe is arithmetic so the ANSWER differs from the ECHO of the command
 *  — waiting for a literal you just typed matches the typing, not the shell. */
/** Click something inside the window tree, tolerating a window switch.
 *
 *  Never `locator.click()` directly on a pane. `click()` resolves its locator
 *  ONCE and then retries its actionability checks against THAT element — so a
 *  click issued while the workbench is switching workspaces can latch onto the
 *  outgoing window's pane, which then collapses to 0x0 and never becomes
 *  visible again. The symptom is fifteen seconds of "element is not visible"
 *  about a terminal that is, by then, perfectly healthy somewhere else. That
 *  was the suite's deepest flake and it is invisible in the failure message.
 *
 *  `toBeVisible` re-queries the locator on every poll, so waiting on it first
 *  lets the switch finish and the click resolves against what is on screen. */
export async function clickShown(target: Locator): Promise<void> {
    await expect(target).toBeVisible({timeout: 20_000});
    await target.click({timeout: 15_000});
}

export async function shellReady(page: Page, term: Locator): Promise<void> {
    const token = `rdy${Math.floor(Math.random() * 1e6)}`;
    try {
        await clickShown(term);
    } catch (err) {
        // The suite's one recurring flake lands here: the click can't reach a
        // visible .vt-screen. A bare Playwright timeout says nothing about WHY
        // — whether no terminal exists, one exists in a hidden window, or the
        // app sat on mission control — so dump the window/pane state instead
        // of leaving the next person to guess.
        throw new Error(`shellReady: no clickable terminal.\n${await diagnose(page)}\n\n${err}`);
    }
    await page.keyboard.type(`echo ${token}$((6*7))`);
    await page.keyboard.press("Enter");
    await expect.poll(() => screenText(term), {timeout: 60_000}).toContain(`${token}42`);
}

/** What the workbench actually looks like right now — windows, their active
 *  flag, and every .vt-screen with its box and owning window. */
export async function diagnose(page: Page): Promise<string> {
    return page.evaluate(() => {
        const box = (e: Element) => {
            const r = e.getBoundingClientRect();
            return `${Math.round(r.width)}x${Math.round(r.height)}@${Math.round(r.x)},${Math.round(r.y)}`;
        };
        const wins = [...document.querySelectorAll(".window")].map(
            (w, i) =>
                `  win[${i}] class="${w.className}" ` +
                `display=${getComputedStyle(w).display} terms=${w.querySelectorAll(".vt-screen").length}`,
        );
        const screens = [...document.querySelectorAll(".vt-screen")].map((e, i) => {
            const win = e.closest(".window");
            const pane = e.closest(".pane");
            const cs = getComputedStyle(e);
            return (
                `  vt[${i}] ${box(e)} display=${cs.display} visibility=${cs.visibility} ` +
                `opacity=${cs.opacity} inActiveWin=${win ? win.classList.contains("active") : "no-window"} ` +
                `paneClass="${pane?.className ?? "-"}"`
            );
        });
        const home = document.querySelector("#home");
        const homeShown = home ? getComputedStyle(home).display !== "none" : false;
        return [
            `screen: home=${homeShown} windows=${wins.length} vt-screens=${screens.length}`,
            ...wins,
            ...screens,
        ].join("\n");
    });
}

/** Run a command and wait for the shell to finish it, by the same trick. */
export async function shellRun(page: Page, term: Locator, cmd: string): Promise<void> {
    await term.click();
    await page.keyboard.type(cmd);
    await page.keyboard.press("Enter");
    await shellReady(page, term);
}

export class Rook {
    private workspaces: string[] = [];
    private repos: string[] = [];
    private editorOpen = false;

    constructor(private page: Page) {}

    /** Build a throwaway git repo and return its path. Identity and signing
     *  are pinned with -c so the run can't inherit the developer's gitconfig
     *  (a global commit.gpgsign would hang the commit on a passphrase). */
    async repo(spec: RepoSpec): Promise<string> {
        const root = await fs.mkdtemp(path.join(os.tmpdir(), "rook-e2e-"));
        this.repos.push(root);
        const git = (...args: string[]) =>
            exec(
                "git",
                [
                    "-c",
                    "user.name=rook e2e",
                    "-c",
                    "user.email=e2e@rook.invalid",
                    "-c",
                    "commit.gpgsign=false",
                    "-c",
                    "init.defaultBranch=main",
                    ...args,
                ],
                {cwd: root},
            );

        await git("init");
        await writeAll(root, spec.files);
        await git("add", "-A");
        await git("commit", "-m", "baseline");
        if (spec.dirty) await writeAll(root, spec.dirty);
        return root;
    }

    /** Create a workspace and wait for its first shell. Returns the name. */
    async open(opts: {name?: string; root?: string} = {}): Promise<string> {
        const name = opts.name ?? `e2e-${Date.now()}-${this.workspaces.length}`;
        this.workspaces.push(name);
        await gotoHome(this.page);
        await this.page.getByRole("button", {name: /^workspaces/i}).click();
        await this.page.getByRole("button", {name: "New workspace"}).click();
        await expect(this.page.locator("#ws-modal")).toBeVisible();
        await this.page.getByPlaceholder("e.g. rook-core").fill(name);
        await this.page
            .getByPlaceholder("~/go/src/github.com/incantery/rook")
            .fill(opts.root ?? REPO);
        await this.page.getByRole("button", {name: "Create workspace"}).click();
        // Wait for the SWITCH to finish, not just for some terminal to be on
        // screen. Until the new workspace is the one displayed, the previous
        // workspace's window is still .active and its terminal is still the
        // one a selector finds — and a click that resolves against it latches
        // onto a pane that is about to collapse to 0x0. That was the suite's
        // deepest flake; see shellReady.
        await expect(this.page.locator(`[data-workspace="${name}"]`)).toBeVisible({
            timeout: 15_000,
        });
        await expect(this.term()).toBeVisible({timeout: 15_000});
        return name;
    }

    /** Record every byte the frontend sends to a pty. Must be called BEFORE
     *  open(), since it rides an init script; Playwright reinstalls those on
     *  every navigation, so the tap survives a reload.
     *
     *  This exists because asserting on the PROGRAM is not an assertion about
     *  the wire. The first version of the reattach test checked that nvim
     *  showed no error and its buffer was unchanged — and it passed with the
     *  replay gate disabled outright, because nvim silently swallows stale
     *  query answers. The only honest statement of "rook typed nothing" is
     *  read off the socket. */
    async tapPty(): Promise<void> {
        await this.page.addInitScript(() => {
            const w = window as unknown as {__pty: string[]};
            w.__pty = [];
            const send = WebSocket.prototype.send;
            WebSocket.prototype.send = function (this: WebSocket, data: unknown) {
                if (this.url.includes("/attach")) w.__pty.push(String(data));
                return send.call(this, data as string);
            };
        });
    }

    /** Everything sent to a pty since the last drain, oldest first. */
    async drainPty(): Promise<string[]> {
        return this.page.evaluate(() => {
            const w = window as unknown as {__pty?: string[]};
            return w.__pty?.splice(0) ?? [];
        });
    }

    /** Reload the page — a rook relaunch as the user performs it. Boot lands
     *  straight back in the last-used workspace (that IS the boot contract),
     *  and host sessions outlive the UI, so whatever was running is still
     *  running; the attach replays the daemon's ring. */
    async reenter(): Promise<void> {
        await this.page.reload();
        await expect(this.term()).toBeVisible({timeout: 15_000});
        this.editorOpen = false; // a reload drops the editor pane's identity
    }

    /** the visible terminal pane */
    term(): Locator {
        return shown(this.page, ".vt-screen");
    }

    /** Run a palette command by title. The titlebar button rather than the
     *  leader chord: leaders are deliberately dead inside side panes, and the
     *  quickfix strip may hold focus. */
    async runCommand(title: string): Promise<void> {
        await this.page.getByRole("button", {name: /commands/}).click();
        await expect(this.page.getByPlaceholder("Run a command…")).toBeVisible();
        await this.page.getByPlaceholder("Run a command…").fill(title);
        await this.page.keyboard.press("Enter");
    }

    /** Open a file in the editor pane. The FIRST open goes through the
     *  palette; later ones use ⌃P, because the palette's "Open file" did not
     *  reliably re-open with the editor focused — ⌃P is also the honest user
     *  path once a pane exists, and it retargets that pane in place. */
    async openFile(file: string): Promise<void> {
        if (this.editorOpen) {
            await this.page.keyboard.press("Control+p");
        } else {
            await this.runCommand("Open file");
        }
        const picker = this.page.getByPlaceholder("Open file…");
        await expect(picker).toBeVisible({timeout: 10_000});
        await picker.fill(file);
        // let the fuzzy list settle on the typed path before committing
        await this.page.waitForTimeout(400);
        await picker.press("Enter");
        await expect(this.page.locator(".editor-path", {hasText: file})).toHaveCount(1, {
            timeout: 20_000,
        });
        this.editorOpen = true;
    }

    /** Wait for this pane's shell to be reading input before typing at it. */
    async shellReady(): Promise<void> {
        await shellReady(this.page, this.term());
    }

    /** Type an ex command into the focused vim surface (editor or nvim). */
    async ex(cmd: string): Promise<void> {
        await this.page.keyboard.type(cmd);
        await this.page.keyboard.press("Enter");
    }

    /** The visible terminal's rendered text. Delegates to screenText rather
     *  than reading innerText itself: the renderer paints to a canvas, which
     *  has none, and this had its own copy of the read for long enough to
     *  break every spec built on expectScreen the day the DOM renderer left. */
    async screen(): Promise<string> {
        return screenText(this.term());
    }

    /** Wait for the terminal to show something.
     *
     *  Matched against the screen AND a de-wrapped copy. A terminal hard-wraps
     *  at the column, so a long line of program output gets a newline pushed
     *  into the middle of a WORD — `…,"sele` / `cted":["Side by side"]}]}` —
     *  and no regex written against the logical output can match that. Whether
     *  it happens depends on how far along the row the text starts, which
     *  depends on the prompt, which contains the workspace name: a random
     *  string of varying length. Hence a pattern that passed all day and then
     *  didn't. */
    async expectScreen(want: RegExp, timeout = 20_000): Promise<void> {
        await expect
            .poll(
                async () => {
                    const s = await this.screen();
                    // \s* on BOTH sides of the newline, not just the newline:
                    // a terminal row is padded out to the full column width
                    // before it wraps, so the split word is `…"sele` + a run
                    // of spaces + `cted":[…`. Dropping the newline alone left
                    // the padding sitting in the middle of the word.
                    return `${s}\n···de-wrapped···\n${s.replace(/\s*\n\s*/g, "")}`;
                },
                {timeout},
            )
            .toMatch(want);
    }

    /** Delete every workspace this test made, then its repos. Workspaces go
     *  first: the daemon holds sessions with cwds inside the repo. */
    async cleanup(): Promise<void> {
        await deleteWorkspaces(this.page, this.workspaces.splice(0));
        for (const root of this.repos.splice(0)) {
            await fs.rm(root, {recursive: true, force: true});
        }
    }
}

/** `test` with a `rook` fixture. Cleanup runs even when the test fails —
 *  boot.spec's "No workspaces yet" is the sandbox canary, so a leaked
 *  workspace fails a LATER file and reads as a flake. */
export const test = base.extend<{rook: Rook}>({
    rook: async ({page}, use) => {
        const rook = new Rook(page);
        await use(rook);
        await rook.cleanup();
    },
});

export {expect};
