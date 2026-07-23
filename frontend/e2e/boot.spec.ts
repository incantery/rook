import {expect, test} from "@playwright/test";

// The smoke test that earns every other e2e test. main.ts renders #fatal
// instead of the app when rook-host is unreachable, so #fatal's absence is
// proof the browser really reached both Go services — config.Service.Get for
// the config below, and hostclient.Service.Info for a live daemon. If this
// passes, the harness is talking to rook and not to a mock.

test("boots against the real Go services", async ({page}) => {
    await page.goto("/");
    await expect(page.locator("#home")).toBeVisible();
    await expect(page.locator("#fatal")).toHaveCount(0);
});

test("renders mission control", async ({page}) => {
    await page.goto("/");
    await expect(page.locator("#home-strip")).toContainText("mission control");
    // The deck lands on agents, so the empty state you see first is theirs.
    await expect(page.locator("#home-rows")).toContainText("No agents running");
    // Also the sandbox check: the daily driver's database has workspaces, so
    // an empty state here proves XDG_DATA_HOME really is isolated. A failure
    // means the tests are pointed at your real records — read serve.sh. It
    // lives behind the workspaces tab now; the canary is the same one.
    await page.getByRole("button", {name: /^workspaces/i}).click();
    await expect(page.locator("#home-workspaces")).toContainText("No workspaces yet");
});
