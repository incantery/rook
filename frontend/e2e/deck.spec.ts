import {expect, test} from "@playwright/test";
import {gotoHome} from "./harness";

// The deck's keyboard model, against real rows.
//
// One deliberate deviation from the rest of the suite: `/overview`'s JSON is
// substituted. Everything else is real — the real app, the real Go services,
// the real host daemon (see docs/e2e.md). Rows only exist when live claude
// sessions do, and this suite must not require one. The payload is the ONLY
// fake; the moment it lands, every line below is the shipping code path.
//
// deck.ts covers ordering/filtering/motion as pure functions. What lives here
// is the wiring those tests cannot see: which keys reach the component, that
// the cursor tracks the rendered order, and that state outlives a remount.

const now = Date.now();
const ago = (m: number) => new Date(now - m * 60_000).toISOString();

const OVERVIEW = [
    {
        name: "rook",
        root: "/src/rook",
        created: ago(900),
        lastUsed: ago(2),
        sessions: 2,
        agents: [
            {
                state: "working",
                title: "Rate limiting",
                model: "sonnet",
                lastEvent: ago(4),
                sessionId: "t1",
                rookSession: "p1",
            },
            {
                state: "quiet",
                title: "Flaky auth test",
                model: "sonnet",
                lastEvent: ago(46),
                sessionId: "t2",
                rookSession: "p2",
            },
        ],
    },
    {
        name: "docs",
        root: "/src/docs",
        created: ago(500),
        lastUsed: ago(30),
        sessions: 1,
        agents: [
            {
                state: "needs_input",
                title: "Auth guide rewrite",
                model: "opus",
                lastEvent: ago(24),
                sessionId: "t3",
                rookSession: "p3",
            },
        ],
    },
];

test.beforeEach(async ({page}) => {
    await page.route("**/overview", (r) =>
        r.fulfill({json: OVERVIEW, headers: {"access-control-allow-origin": "*"}}),
    );
    // the rail fetches whatever the cursor lands on; keep it cheap and empty
    await page.route("**/agents/*/transcript*", (r) =>
        r.fulfill({
            json: {sessionId: "t", records: [], more: false},
            headers: {"access-control-allow-origin": "*"},
        }),
    );
    await gotoHome(page);
    await expect(page.locator("#home-rows")).toBeVisible();
});

test("lands needs-you first, whatever order the host sent", async ({page}) => {
    // rook's agents arrive first in the payload; docs' blocked one must lead
    const first = page.locator("#home-rows > div").first();
    await expect(first).toContainText("Auth guide rewrite");
});

test("gt cycles tabs and Tab is left alone for focus", async ({page}) => {
    await page.locator("#home").press("g");
    await page.locator("#home").press("t");
    await expect(page.locator("#home-tabs")).toContainText("Needs you 1");
    await expect(page.locator("#home-rows")).not.toContainText("Rate limiting");

    await page.locator("#home").press("g");
    await page.locator("#home").press("T");
    await expect(page.locator("#home-rows")).toContainText("Rate limiting");
});

test("the row verbs do nothing on a tab with no rows to act on", async ({page}) => {
    // The bug this pins: the cursor used to keep walking the full agent list
    // behind the workspace grid, so ↵ here opened the conversation of a row
    // you never selected and could not see.
    await page.getByRole("button", {name: /^workspaces/i}).click();
    await page.locator("#home").press("Enter");
    await expect(page.locator("#home")).toBeVisible();
    await page.locator("#home").press("R");
    await expect(page.locator("#home")).toBeVisible();
});

test("Escape leaves the filter without undoing it", async ({page}) => {
    await page.locator("#home").press("/");
    await page.getByPlaceholder("state:needs ws:rook").fill("ws:rook");
    await page.getByPlaceholder("state:needs ws:rook").press("Escape");

    // still filtered, and the keyboard is back on the rows
    await expect(page.locator("#home-rows")).not.toContainText("Auth guide rewrite");
    expect(await page.evaluate(() => document.activeElement?.id)).toBe("home");

    // a second Escape, on the deck, is what clears it
    await page.locator("#home").press("Escape");
    await expect(page.locator("#home-rows")).toContainText("Auth guide rewrite");
});

test("the filter and grouping survive a trip to a workspace and back", async ({page}) => {
    // Home is an {#if}, so its state dies on remount unless it lives on `app`.
    // Losing your place every time you open a row breaks the triage loop.
    await page.locator("#home").press("w");
    await page.locator("#home").press("/");
    await page.getByPlaceholder("state:needs ws:rook").fill("ws:rook");
    await page.getByPlaceholder("state:needs ws:rook").press("Escape");

    await page.keyboard.press("`");
    await page.keyboard.press("h");
    await page.keyboard.press("`");
    await page.keyboard.press("h");
    await expect(page.locator("#home")).toBeVisible();

    await expect(page.locator("#home-tabs")).toContainText("grouped");
    expect(await page.getByPlaceholder("state:needs ws:rook").inputValue()).toBe("ws:rook");
});
