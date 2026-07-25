import {expect, test, REPO} from "./harness";
import * as path from "node:path";

// gc end to end. The point is not "does a line get a // in front of it" — it is
// that gc is an OPERATOR and not a binding, so the assertions that matter are
// the ones a lone `gcc` mapping could not pass: a count and a motion (gc2j),
// and the same verb over a visual selection.
//
// These drive a scratch repo through the `re` takeover, which is rook's proven
// EDITABLE open path (editor-outside.spec.ts). The palette's "Open file
// (read-only)" lands a read-only pane, where no operator can be tested at all.
//
// Nothing is written: every test quits with :q!, so the scratch file on disk
// keeps its original bytes.

const RE = path.join(REPO, "bin", "e2e", "re");
const SRC = "package main\n\nfunc main() {}\n";

/** The rendered buffer, in DOCUMENT order. Monaco recycles .view-line nodes and
 *  leaves them in arbitrary DOM order — the visual order lives in each node's
 *  `top`, so reading by DOM index quietly returns the wrong line after a
 *  re-render. Rendered text also uses non-breaking spaces. */
async function lines(page: import("@playwright/test").Page): Promise<string[]> {
    return page.evaluate(() => {
        const els = [...document.querySelectorAll(".editor-mount .view-line")] as HTMLElement[];
        return els
            .sort((a, b) => parseInt(a.style.top || "0") - parseInt(b.style.top || "0"))
            .map((e) => (e.textContent ?? "").replace(/ /g, " "));
    });
}

const lineAt = (page: import("@playwright/test").Page, i: number) =>
    lines(page).then((l) => l[i] ?? null);

/** Open main.go in an editable pane, cursor on line 1. */
async function openGo(page: import("@playwright/test").Page, rook: any, tag: string) {
    const ws = await rook.repo({files: {"main.go": SRC}});
    await rook.open({name: `gc-${tag}-${Date.now()}`, root: ws});
    await rook.shellReady();
    await rook.ex(`${RE} main.go; echo "re exit=$?"`);

    await expect(page.locator(".editor-mount .view-lines").first()).toBeVisible({timeout: 15_000});
    await expect(page.locator(".editor-vim").first()).toContainText(/NORMAL/i, {timeout: 15_000});
    // the pane must be genuinely editable, or every assertion below is vacuous
    await expect(page.locator(".editor-path").first()).not.toContainText("read-only");
    await page.locator(".editor-mount").first().click();
    await page.keyboard.type("gg");
    await expect.poll(() => lineAt(page, 0), {timeout: 15_000}).toBe("package main");
}

test("gcc toggles the current line, and toggles it back", async ({page, rook}) => {
    await openGo(page, rook, "cc");

    await page.keyboard.type("gcc");
    await expect.poll(() => lineAt(page, 0), {timeout: 10_000}).toBe("// package main");

    // toggling is the whole verb — a gc that only ever comments is half of one
    await page.keyboard.type("gcc");
    await expect.poll(() => lineAt(page, 0), {timeout: 10_000}).toBe("package main");

    await rook.ex(":q!");
});

test("gc takes a count and a motion — gc2j comments the range", async ({page, rook}) => {
    await openGo(page, rook, "motion");

    // the test a plain `gcc` binding cannot pass: the operator has to consume
    // 2j as its motion and act over three lines
    await page.keyboard.type("gc2j");
    await expect.poll(() => lineAt(page, 0), {timeout: 10_000}).toBe("// package main");
    expect(await lineAt(page, 2)).toBe("// func main() {}");

    await rook.ex(":q!");
});

test("gc works from visual mode, like d and y", async ({page, rook}) => {
    await openGo(page, rook, "visual");

    // no context was named on the mapping precisely so this works; naming
    // "normal" would have taken visual away
    await page.keyboard.type("V2jgc");
    await expect.poll(() => lineAt(page, 0), {timeout: 10_000}).toBe("// package main");
    expect(await lineAt(page, 2)).toBe("// func main() {}");

    await rook.ex(":q!");
});
