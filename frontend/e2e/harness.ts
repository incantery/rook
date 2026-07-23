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

/** the first VISIBLE match: rook keeps inactive windows mounted (terminals
 *  are never unmounted, only hidden), so a bare selector matches panes you
 *  cannot see. */
export const shown = (page: Page, sel: string): Locator =>
    page.locator(`${sel} >> visible=true`).first();

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
        await page.goto("/");
        await page.getByRole("button", {name: /^workspaces/i}).click();
        const card = page
            .locator("#home-workspaces div.group")
            .filter({has: page.getByText(name, {exact: true})});
        await expect(card).toHaveCount(1, {timeout: 30_000});
        await card.getByTitle(/^Delete workspace/).click();
        await expect(card).toHaveCount(0, {timeout: 30_000});
    }
}

/** Flatten a terminal's rendered text. xterm draws every space as U+00A0 to
 *  hold the column, so a plain match with a space in it never fires. */
export const screenText = (term: Locator): Promise<string> =>
    term.evaluate((el) => (el as HTMLElement).innerText.replace(/ /g, " "));

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
export async function shellReady(page: Page, term: Locator): Promise<void> {
    const token = `rdy${Math.floor(Math.random() * 1e6)}`;
    await term.click();
    await page.keyboard.type(`echo ${token}$((6*7))`);
    await page.keyboard.press("Enter");
    await expect.poll(() => screenText(term), {timeout: 60_000}).toContain(`${token}42`);
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
        await this.page.goto("/");
        await expect(this.page.locator("#home")).toBeVisible();
        await this.page.getByRole("button", {name: /^workspaces/i}).click();
        await this.page.getByRole("button", {name: "New workspace"}).click();
        await expect(this.page.locator("#ws-modal")).toBeVisible();
        await this.page.getByPlaceholder("e.g. rook-core").fill(name);
        await this.page
            .getByPlaceholder("~/go/src/github.com/incantery/rook")
            .fill(opts.root ?? REPO);
        await this.page.getByRole("button", {name: "Create workspace"}).click();
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

    /** Reload the page and walk back into a workspace — a rook relaunch as
     *  the user performs it. Host sessions outlive the UI, so whatever was
     *  running is still running; the attach replays the daemon's ring. */
    async reenter(name: string): Promise<void> {
        await this.page.reload();
        await this.page.getByRole("button", {name: /^workspaces/i}).click();
        await this.page
            .locator("#home-workspaces div.group")
            .filter({has: this.page.getByText(name, {exact: true})})
            .first()
            .click();
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
            await this.runCommand("Open file (read-only)");
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

    /** The visible terminal's rendered text, with Monaco/xterm's hard spaces
     *  flattened — xterm renders every space as U+00A0 to hold the column,
     *  so a plain toContainText with a space in it never matches. */
    async screen(): Promise<string> {
        return this.term().evaluate((el) => (el as HTMLElement).innerText.replace(/ /g, " "));
    }

    /** Wait for the terminal to show something. */
    async expectScreen(want: RegExp, timeout = 20_000): Promise<void> {
        await expect.poll(() => this.screen(), {timeout}).toMatch(want);
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
