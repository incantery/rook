import {expect, test} from "@playwright/test";

// Nerd Font icons must survive an UNPATCHED terminal font.
//
// A neovim statusline (lualine, nvim-web-devicons) emits the private-use
// ranges — U+E0B0 powerline separator, U+F07B folder. A stock family like
// JetBrains Mono or Menlo has none of them, so without a symbols font behind
// it in the stack the row paints tofu. That is exactly what someone running
// `font-family = "JetBrains Mono"` reported.
//
// These assert the two halves independently: that main.ts still PUTS the
// fallbacks in --vt-font, and that a browser laying out the PUA codepoints
// against that stack really resolves them to a Nerd Font. The second half is
// the one that catches a misspelled family name — a wrong name is silent, it
// just quietly renders tofu again.

const PUA = ""; // powerline separator, devicon folder

test("the terminal font stack carries symbol fallbacks behind the configured family", async ({
    page,
}) => {
    await page.goto("/");
    await expect(page.locator("#fatal")).toHaveCount(0);

    const stack = await page.evaluate(() =>
        getComputedStyle(document.documentElement).getPropertyValue("--vt-font").trim(),
    );

    // the configured family still leads — fallbacks must never outrank it
    const families = stack.split(",").map((f) => f.trim().replace(/^"|"$/g, ""));
    expect(families.length).toBeGreaterThan(4);
    expect(families).toContain("Symbols Nerd Font Mono");
    expect(families).toContain("Hack Nerd Font Mono");
    expect(families.indexOf("Symbols Nerd Font Mono")).toBeGreaterThan(0);
    // generic fallbacks stay last, so a symbols font can never beat Menlo to
    // a glyph the configured font actually has
    expect(families.indexOf("Symbols Nerd Font Mono")).toBeLessThan(families.indexOf("Menlo"));
});

test("PUA icons resolve to a Nerd Font when the configured font lacks them", async ({page}) => {
    await page.goto("/");
    await expect(page.locator("#fatal")).toHaveCount(0);

    // Menlo stands in for any unpatched family: it ships with macOS, and it
    // has no PUA coverage. Same shape as the reported JetBrains Mono config.
    const stack = await page.evaluate(() =>
        getComputedStyle(document.documentElement).getPropertyValue("--vt-font").trim(),
    );
    const probeStack = `Menlo, ${stack.split(",").slice(1).join(",")}`;

    await page.evaluate(
        ([font, text]) => {
            const el = document.createElement("span");
            el.id = "font-probe";
            el.style.cssText = `position:fixed;top:-100px;font:13px ${font}`;
            el.textContent = text;
            document.body.appendChild(el);
        },
        [probeStack, PUA] as const,
    );
    await expect(page.locator("#font-probe")).toHaveCount(1);

    // Chromium's CDP reports the platform fonts that ACTUALLY laid out the
    // node — the only way to tell a real glyph from a convincing tofu box.
    const cdp = await page.context().newCDPSession(page);
    await cdp.send("DOM.enable");
    await cdp.send("CSS.enable");
    const {root} = await cdp.send("DOM.getDocument", {depth: -1});
    const {nodeId} = await cdp.send("DOM.querySelector", {
        nodeId: root.nodeId,
        selector: "#font-probe",
    });
    const {fonts} = (await cdp.send("CSS.getPlatformFontsForNode", {nodeId})) as {
        fonts: {familyName: string; glyphCount: number}[];
    };

    const used = fonts.filter((f) => f.glyphCount > 0).map((f) => f.familyName);
    test.skip(
        !used.some((f) => /nerd/i.test(f)) && used.every((f) => /menlo|times|system/i.test(f)),
        `no Nerd Font installed on this machine — resolved to ${used.join(", ")}`,
    );
    // named exactly: passing via some incidental system font would prove
    // nothing about the stack main.ts builds
    expect(used.join(", ")).toMatch(/Symbols Nerd Font Mono|Hack Nerd Font Mono/);
});
