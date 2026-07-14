import {describe, expect, it} from "vitest";
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
            "--color-dim",
            "--color-fg",
            "--color-grn",
            "--color-hot",
            "--color-line",
            "--color-lo",
            "--color-raise",
            "--color-red",
            "--bg",
            "--acc",
            "--dim",
            "--fg",
            "--line",
        ]) {
            expect(v[name]).toMatch(/^#[0-9a-f]{6,8}$/i);
        }
    });
});
