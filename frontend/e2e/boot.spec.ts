import {expect, test} from "@playwright/test";
import {gotoHome, shown} from "./harness";

// The smoke test that earns every other e2e test. main.ts renders #fatal
// instead of the app when rook-host is unreachable, so #fatal's absence is
// proof the browser really reached both Go services — config.Service.Get for
// the config below, and hostclient.Service.Info for a live daemon. If this
// passes, the harness is talking to rook and not to a mock.

test("boots into a shell against the real Go services", async ({page}) => {
    await page.goto("/");
    // Boot lands in a terminal — opening rook is opening a terminal, like
    // ghostty or iterm. A fresh sandbox has no live sessions, so this first
    // boot also spawns the default workspace's first shell.
    await expect(shown(page, ".vt-screen")).toBeVisible({timeout: 30_000});
    await expect(page.locator("#fatal")).toHaveCount(0);
    // mission control is summoned, never landed on — home must not mount
    await expect(page.locator("#home")).toHaveCount(0);
});

test("summons mission control with ` h", async ({page}) => {
    await gotoHome(page);
    await expect(page.locator("#home-strip")).toContainText("mission control");
    // The deck lands on agents, so the empty state you see first is theirs.
    await expect(page.locator("#home-rows")).toContainText("No agents running");
    // Also the sandbox check: the daily driver's database has workspaces, so
    // a list holding ONLY the boot-spawned default proves XDG_DATA_HOME
    // really is isolated. A failure means the tests are pointed at your real
    // records — read serve.sh.
    await page.getByRole("button", {name: /^workspaces/i}).click();
    await expect(page.locator("#home-workspaces")).toContainText("main");
    await expect(page.locator("#home-workspaces div.group")).toHaveCount(1);
});
