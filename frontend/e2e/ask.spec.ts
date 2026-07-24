import {expect, test, REPO} from "./harness";
import * as path from "node:path";

// `rookctl ask` — the RUI question: typed in a rook shell (the way the MCP
// tool runs it), it opens the ask form in a split BESIDE this pane, blocks
// the shell, and the human's decision unblocks it with the answer JSON on
// stdout. The echoed $? is the honest assertion, exactly like the `re`
// takeover spec: it can only print after rookctl unblocked, with the code
// the form reported (0 answered, 1 dismissed).

const ROOKCTL = path.join(REPO, "bin", "e2e", "rookctl");

const ONE_QUESTION = JSON.stringify({
    questions: [
        {
            question: "Ship the release now?",
            header: "Deploy",
            options: [
                {label: "Ship", description: "Tag and publish"},
                {label: "Hold", description: "Wait for the soak"},
            ],
        },
    ],
});

test("an ask opens a split beside the shell; picking answers and unblocks", async ({
    page,
    rook,
}) => {
    const root = await rook.repo({files: {"ask.json": ONE_QUESTION + "\n"}});
    await rook.open({name: `ask-pick-${Date.now()}`, root});
    await rook.shellReady();

    await rook.ex(`${ROOKCTL} ask < ask.json; echo "ask exit=$?"`);

    // the form lands in ITS OWN pane — the shell keeps its window
    const form = page.locator("[data-ask-root]");
    await expect(form).toBeVisible({timeout: 15_000});
    await expect(form).toContainText("Ship the release now?");
    await expect(form).toContainText("Tag and publish");
    // both panes live: the terminal is still on screen next to the form
    await expect(rook.term()).toBeVisible();

    // 1 picks "Ship" — single-select commits immediately, the pane closes,
    // and the blocked rookctl prints the answer and exits 0
    await page.keyboard.press("1");
    await expect(form).toHaveCount(0);
    await rook.expectScreen(/"selected":\["Ship"\]/);
    await rook.expectScreen(/ask exit=0/);
});

test("esc dismisses — the asker sees canceled and exit 1", async ({page, rook}) => {
    const root = await rook.repo({files: {"ask.json": ONE_QUESTION + "\n"}});
    await rook.open({name: `ask-esc-${Date.now()}`, root});
    await rook.shellReady();

    await rook.ex(`${ROOKCTL} ask < ask.json; echo "ask exit=$?"`);
    await expect(page.locator("[data-ask-root]")).toBeVisible({timeout: 15_000});

    await page.keyboard.press("Escape");
    await rook.expectScreen(/"canceled":true/);
    await rook.expectScreen(/ask exit=1/);
});

test("a pending ask survives a reload — the host re-pushes it", async ({page, rook}) => {
    const root = await rook.repo({files: {"ask.json": ONE_QUESTION + "\n"}});
    await rook.open({name: `ask-reload-${Date.now()}`, root});
    await rook.shellReady();

    await rook.ex(`${ROOKCTL} ask < ask.json; echo "ask exit=$?"`);
    await expect(page.locator("[data-ask-root]")).toBeVisible({timeout: 15_000});

    // the rookctl behind the form is still parked in the pty — a reload
    // must bring the question back, not strand it
    await rook.reenter();
    const form = page.locator("[data-ask-root]");
    await expect(form).toBeVisible({timeout: 15_000});
    await expect(form).toContainText("Ship the release now?");

    await form.click(); // reload focus lands on the shell; the form takes it back
    await page.keyboard.press("2");
    await rook.expectScreen(/"selected":\["Hold"\]/);
    await rook.expectScreen(/ask exit=0/);
});

test("Other carries the user's own words", async ({page, rook}) => {
    const root = await rook.repo({files: {"ask.json": ONE_QUESTION + "\n"}});
    await rook.open({name: `ask-other-${Date.now()}`, root});
    await rook.shellReady();

    await rook.ex(`${ROOKCTL} ask < ask.json; echo "ask exit=$?"`);
    const form = page.locator("[data-ask-root]");
    await expect(form).toBeVisible({timeout: 15_000});

    // 3 lands on the Other row and opens its input; the typed words ARE
    // the answer
    await page.keyboard.press("3");
    await page.keyboard.type("ship friday after the demo");
    await page.keyboard.press("Enter");
    await expect(form).toHaveCount(0);
    await rook.expectScreen(/"other":"ship friday after the demo"/);
    await rook.expectScreen(/ask exit=0/);
});
