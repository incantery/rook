import {describe, expect, it} from "vitest";
import {ONE_DARK, ONE_LIGHT} from "./builtins";
import type {Theme} from "./palette";

function assertComplete(t: Theme): void {
    const p = t.palette;
    expect(p.ansi).toHaveLength(16);
    for (const c of p.ansi) expect(c).toMatch(/^#[0-9a-f]{6,8}$/i);
    for (const c of Object.values(p.syntax)) expect(c).toMatch(/^#[0-9a-f]{6,8}$/i);
    for (const [k, v] of Object.entries(p)) {
        if (k === "ansi" || k === "syntax" || k === "type") continue;
        expect(v as string).toMatch(/^#[0-9a-f]{6,8}$/i);
    }
}

describe("built-in themes", () => {
    it("One Dark is complete and dark", () => {
        assertComplete(ONE_DARK);
        expect(ONE_DARK.palette.type).toBe("dark");
    });
    it("One Light is complete and light", () => {
        assertComplete(ONE_LIGHT);
        expect(ONE_LIGHT.palette.type).toBe("light");
    });
});
