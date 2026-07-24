import {expect, test, hostFetch, type Rook} from "./harness";

// The review pane end-to-end, against a repo the test BUILDS. This used to
// point at the rook checkout and review whatever was uncommitted there, so
// its result depended on the developer's working tree — it asserts a second
// hunk, so it passed with two dirty files and failed with one. Now the dirt
// is part of the fixture and the counts are knowable.
//
// This is the real host either way: prepareReview shells git in the sandbox
// and the gate is the daemon's.

/** three committed files, three unstaged edits — one hunk each, far enough
 *  apart that git can't coalesce them */
async function reviewRepo(rook: Rook): Promise<string> {
    return rook.repo({
        files: {
            "main.go": "package main\n\nfunc main() {\n\tprintln(greet())\n}\n",
            "greet.go": 'package main\n\nfunc greet() string {\n\treturn "hello"\n}\n',
            "README.md": "# fixture\n\nA repo that exists to be reviewed.\n",
        },
        dirty: {
            "main.go": 'package main\n\nfunc main() {\n\tprintln(greet())\n\tprintln("again")\n}\n',
            "greet.go": 'package main\n\nfunc greet() string {\n\treturn "hello, world"\n}\n',
            "README.md": "# fixture\n\nA repo that exists to be reviewed, thoroughly.\n",
        },
    });
}

test("review pane prepares hunks, dispositions, and moves the gate", async ({page, rook}) => {
    test.setTimeout(120_000);
    const root = await reviewRepo(rook);
    // unique per run: workspace delete doesn't drop its rook_tasks, so a fixed
    // name would carry a prior run's review (and its ids) into this one.
    await rook.open({name: `review-e2e-${Date.now()}`, root});

    // open the review quickfix strip (vim's bottom window)
    await rook.runCommand("Toggle review pane");
    const pane = page.locator('.side-pane[data-side="bottom"]');
    await expect(pane).toContainText("Review");
    await expect(pane).toContainText("j/k move"); // the footer hint = our pane mounted

    await page.getByRole("button", {name: "prepare"}).click();

    // hunk rows land in the generic quickfix list (review is its first tenant).
    // THREE, exactly — one per edited file. The old version could only say
    // "more than zero", which is the assertion a borrowed working tree allows.
    const rows = page.locator("#quickfix-list [role=option]");
    await expect(rows.first()).toBeVisible({timeout: 20_000});
    await expect(rows).toHaveCount(3);
    await expect(pane).toContainText("0 reviewed · 3 remaining");

    // clicking a hunk opens the bespoke detail overlay (NOT Monaco): the hunk
    // as a decision object — analysis, its own diff, disposition.
    await rows.first().click();
    const detail = page.getByRole("dialog", {name: "review hunk"});
    await expect(detail).toBeVisible();
    await expect(detail.getByRole("button", {name: /Approve/})).toBeVisible();

    // approve from the overlay (it holds the keyboard); a hunk's ring fills
    // green in the list and the gate moves.
    await page.keyboard.press("a");
    await expect(page.locator('#quickfix-list [data-state="approved"]')).toBeVisible({
        timeout: 10_000,
    });

    // esc closes the hero and hands the keyboard BACK to the strip
    await page.keyboard.press("Escape");
    await expect(detail).toHaveCount(0);

    // :copen — close the list, reopen via the command, keyboard included:
    // j moves the cursor immediately, no click needed
    await rook.runCommand("Quickfix: close");
    await expect(pane).toHaveCount(0);
    await rook.runCommand("Quickfix: open list");
    await expect(pane).toBeVisible();
    await page.keyboard.press("g"); // top
    await page.keyboard.press("j"); // down one
    await expect(rows.nth(1)).toHaveAttribute("data-cursor", "1");

    // the context leader (vim's maplocalleader) lives INSIDE the editor
    // now: ,q works from the strip itself (the editor's bottom window) —
    // a comma in a terminal stays a comma. Once the strip is closed and no
    // editor surface holds the keyboard, re-entry is explicit: the same
    // palette door "Toggle review pane" came through.
    await page.keyboard.press(",");
    await page.keyboard.press("q");
    await expect(pane).toHaveCount(0);
    await rook.runCommand("Quickfix: open list");
    await expect(pane).toBeVisible();

    // ,a — the quick-action modal, from the strip's own keyboard
    await page.keyboard.press(",");
    await page.keyboard.press("a");
    const qa = page.getByRole("dialog", {name: "quick actions"});
    await expect(qa).toBeVisible();
    await page.waitForTimeout(250); // let the fly-in settle for the screenshot
    await page.screenshot({path: "bin/e2e/quick-actions.png", fullPage: true});
    // d defers the current item straight from the modal, which then closes
    await page.keyboard.press("d");
    await expect(qa).toHaveCount(0);
    await expect(page.locator('#quickfix-list [data-state="deferred"]')).toBeVisible({
        timeout: 10_000,
    });

    // closing the modal hands the keyboard to the STRIP (the surface it acted
    // on): g/j work immediately, no click needed
    await page.keyboard.press("g");
    await page.keyboard.press("j");
    await expect(rows.nth(1)).toHaveAttribute("data-cursor", "1");

    // ,a works FROM the strip too (no text inputs there — leaders exempt);
    // reopen: j moves the SELECTION (Approve → Reject), Enter runs it
    await page.keyboard.press(",");
    await page.keyboard.press("a");
    await expect(qa).toBeVisible();
    await page.keyboard.press("j");
    await page.keyboard.press("Enter");
    await expect(qa).toHaveCount(0);
    await expect(page.locator('#quickfix-list [data-state="rejected"]')).toBeVisible({
        timeout: 10_000,
    });

    await page.screenshot({path: "bin/e2e/review-pane.png", fullPage: true});
});

// The convergence: a review hunk jumps to the REAL file (no diff mode — the
// gutter carries the change context), and gt inside the hunk creates a
// thread that LINKS to the leaf: it flips pending, the gate closes, and the
// resolve hands the prior disposition back.
test("review jumps to the file; gt in-hunk links a thread and works the gate", async ({
    page,
    rook,
}) => {
    test.setTimeout(120_000);
    const root = await reviewRepo(rook);
    const ws = `revlink-e2e-${Date.now()}`;
    await rook.open({name: ws, root});

    await rook.runCommand("Toggle review pane");
    await page.getByRole("button", {name: "prepare"}).click();
    const rows = page.locator("#quickfix-list [role=option]");
    await expect(rows.first()).toBeVisible({timeout: 20_000});

    interface Task {
        id: number;
        path?: string;
        state: string;
        currentStart?: number;
        children?: Task[];
    }
    const reviewTree = async (): Promise<Task> => {
        const roots = (await (
            await hostFetch(`/workspaces/${ws}/tasks?workType=review`)
        ).json()) as Task[];
        return roots[0];
    };
    const gateOf = async (id: number) =>
        (await (await hostFetch(`/tasks/${id}/gate`)).json()) as {
            ready: boolean;
            blocking: number;
        };
    const parent = await reviewTree();
    const leaf = parent.children!.find((c) => c.path === "greet.go")!;
    expect(leaf.currentStart).toBeGreaterThan(0); // the blob-backed reanchor seam

    // put the cursor on greet.go's row, then o — the REAL file opens, at the
    // leaf's reanchored line, with the git gutter for context
    const greetRow = rows.filter({hasText: "greet.go"});
    await greetRow.click();
    await page.keyboard.press("Escape"); // the hero opened on click; o is the editor door
    await page.keyboard.press("o");
    await expect(page.locator(".editor-path").first()).toContainText("greet.go", {
        timeout: 20_000,
    });
    await expect(page.locator(".editor-vim").first()).toContainText(/NORMAL/i, {timeout: 15_000});
    await expect(page.locator("#statusbar")).toContainText(`Ln ${leaf.currentStart},`, {
        timeout: 15_000,
    });
    await expect(page.locator(".rook-gutter-mod").first()).toBeVisible({timeout: 15_000});

    // approve the leaf so the pending flip is observable on the gate
    await hostFetch(`/tasks/${leaf.id}/state`, {
        method: "POST",
        body: JSON.stringify({state: "approved"}),
    });
    const before = await gateOf(parent.id);

    // gt inside the hunk (the click that grabs focus also moves the cursor,
    // so re-park it on the reanchored line first). The thread links to the
    // LEAF and blocks the gate.
    await page.locator(".editor-mount").first().click();
    await page.keyboard.type(`${leaf.currentStart}G`);
    await page.keyboard.type("gt");
    await expect(page.locator(".editor-path", {hasText: /^thread #/})).toBeVisible({
        timeout: 20_000,
    });
    await expect
        .poll(async () => (await reviewTree()).children!.find((c) => c.id === leaf.id)!.state, {
            timeout: 15_000,
        })
        .toBe("pending");
    expect((await gateOf(parent.id)).blocking).toBe(before.blocking + 1);

    // say something, keep it, resolve — the prior disposition comes back and
    // the gate reopens
    await page.keyboard.press("i");
    await page.keyboard.type("is hello, world the right greeting");
    await page.keyboard.press("Escape");
    await page.keyboard.type(":w");
    await page.keyboard.press("Enter");
    await page.keyboard.type(":resolve");
    await page.keyboard.press("Enter");
    await expect(page.locator(".editor-path", {hasText: /^thread #/})).toHaveCount(0, {
        timeout: 15_000,
    });
    await expect
        .poll(async () => (await reviewTree()).children!.find((c) => c.id === leaf.id)!.state, {
            timeout: 15_000,
        })
        .toBe("approved");
    expect((await gateOf(parent.id)).blocking).toBe(before.blocking);
});
