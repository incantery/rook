import {describe, expect, it} from "vitest";
import {ONE_LIGHT} from "./builtins";
import {cssVars} from "./cssvars";
import {MATERIAL_OCEAN} from "./palette";

describe("cssVars", () => {
    const v = cssVars(MATERIAL_OCEAN.palette);

    it("maps palette roles onto the existing token names", () => {
        expect(v["--color-acc"]).toBe("#82aaff");
        expect(v["--color-amber"]).toBe("#ffcb6b"); // yellow → amber
        expect(v["--color-grn"]).toBe("#c3e88d");
        expect(v["--color-raise"]).toBe("#ffffff09");
    });

    it("derives the 0.14 body hairline from the solid line stock", () => {
        expect(v["--color-line"]).toBe("#8c96b4");
        expect(v["--line"]).toBe("#8c96b424"); // 0.14 * 255 ≈ 36 = 0x24
    });

    it("covers every color var the codebase references", () => {
        for (const name of [
            "--color-acc",
            "--color-amber",
            "--color-bg",
            "--color-dim",
            "--color-fg",
            "--color-grn",
            "--color-hot",
            "--color-line",
            "--color-lo",
            "--color-magenta",
            "--color-on-acc",
            "--color-overlay",
            "--color-raise",
            "--color-red",
            "--color-sunken",
            "--bg",
            "--acc",
            "--dim",
            "--fg",
            "--line",
        ]) {
            expect(v[name]).toMatch(/^#[0-9a-f]{6,8}$/i);
        }
    });

    it("emits the terminal fg/bg/cursor/selection and the 16 ANSI colors", () => {
        const p = MATERIAL_OCEAN.palette;
        expect(v["--term-fg"]).toBe(p.editorFg);
        expect(v["--term-bg"]).toBe(p.bg);
        expect(v["--term-cursor"]).toBe(p.cursor);
        expect(v["--term-selection"]).toBe(p.selection);
        for (let i = 0; i < 16; i++) {
            expect(v[`--term-ansi-${i}`]).toBe(p.ansi[i]);
        }
    });

    // These four are why light themes were broken: the chrome hardcoded them,
    // so --fg flipped dark while the panels stayed dark. They must TRACK the
    // palette, not the theme that happened to be authored first.
    it("tracks the palette for the surfaces chrome used to hardcode", () => {
        const light = cssVars(ONE_LIGHT.palette);
        expect(light["--color-bg"]).toBe("#fafafa");
        expect(light["--color-overlay"]).toBe("#ffffff");
        // a light theme's well is LIGHTER than its base — the whole point of
        // authoring `sunken` instead of deriving darken(bg)
        expect(light["--color-sunken"]).toBe("#ffffff");
        // white text on One Light's saturated blue, not Material Ocean's near-black
        expect(light["--color-on-acc"]).toBe("#ffffff");
        expect(v["--color-on-acc"]).toBe("#10131c");
    });
});
