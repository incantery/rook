import {expect, hostFetch, STUB_CODER, test, type Rook} from "./harness";

// Delivering a thread to the agent — the claim half of rook's orchestration.
//
// `nudge` picks its target from h.claims, which claude's SessionStart hook
// populates and its SessionEnd hook clears. When both fire, rook types the
// prompt into the window holding the live agent. The question these tests
// exist to answer is what happens when only the FIRST one fires.
//
// The coder is a stub (e2e/stub-coder.sh) wired in through the sandbox's
// `coder` config. It is faithful about exactly one thing — the claim
// lifecycle — because that is the part rook reasons about.

/** the host session backing this workspace's only pane */
async function sessionOf(ws: string): Promise<string> {
    const list = (await (await hostFetch("/sessions")).json()) as {id: string; workspace: string}[];
    const mine = list.filter((s) => s.workspace === ws);
    expect(mine).toHaveLength(1);
    return mine[0].id;
}

async function makeThread(ws: string, body: string): Promise<void> {
    const r = await hostFetch(`/workspaces/${ws}/threads`, {
        method: "POST",
        body: JSON.stringify({path: "main.go", startLine: 3, endLine: 3, body}),
    });
    expect(r.ok).toBe(true);
}

const submit = async (ws: string) =>
    (await (await hostFetch(`/workspaces/${ws}/threads/submit`, {method: "POST"})).json()) as {
        mode: string;
        rookSession: string;
    };

async function repo(rook: Rook): Promise<string> {
    return rook.repo({
        files: {"main.go": "package main\n\nfunc main() {\n\tprintln(1)\n}\n"},
    });
}

test("a submitted thread is typed at the claimed agent", async ({rook}) => {
    test.setTimeout(120_000);
    const root = await repo(rook);
    const ws = await rook.open({name: `agent-live-${Date.now()}`, root});
    const sid = await sessionOf(ws);

    // the user starts the coder themselves, as they would
    await rook.shellReady();
    await rook.ex(`${STUB_CODER} 'look at this'`);
    // READY prints after the claim lands, so this is "the window is claimed"
    await rook.expectScreen(/STUB CODER READY/);

    await makeThread(ws, "is this off by one?");
    const res = await submit(ws);

    // typed at the live agent, in THIS window — not spawned somewhere new
    expect(res.mode).toBe("typed");
    expect(res.rookSession).toBe(sid);
    // and it really arrived at the PROCESS, not just the pty: the stub
    // echoes each line it reads. Matching the prompt text too would be
    // matching the tty's own echo — and it wraps across rows anyway.
    await rook.expectScreen(/STUB GOT:/);
});

test("a thread is not typed at a window whose agent died without unclaiming", async ({
    page,
    rook,
}) => {
    test.setTimeout(120_000);
    const root = await repo(rook);
    const ws = await rook.open({name: `agent-stale-${Date.now()}`, root});
    const sid = await sessionOf(ws);

    // Same start, except this coder will not run its SessionEnd hook — the
    // ^C / crash / kill -9 case, where claude is gone, the shell is alive,
    // and the claim rook holds now points at a window running something else.
    await rook.shellReady();
    await rook.ex(`ROOK_STUB_NO_UNCLAIM=1 ${STUB_CODER} 'look at this'`);
    await rook.expectScreen(/STUB CODER READY/);

    await rook.term().click();
    await page.keyboard.press("Control+c");
    await rook.shellReady(); // back at a prompt, claim never released

    // …and the user does what anyone does with a free pane
    await rook.ex("nvim main.go");
    await rook.expectScreen(/func main/);

    await makeThread(ws, "is this off by one?");
    const res = await submit(ws);

    // The load-bearing assertion. Typing a prompt here does not reach an
    // agent — it reaches nvim, as keystrokes, in normal mode. rook must
    // notice the window is no longer a coder and spawn a responder instead.
    expect(res.rookSession).not.toBe(sid);
    expect(res.mode).toBe("spawned");
});
