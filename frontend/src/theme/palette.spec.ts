import {describe, expect, it} from "vitest";
import {MATERIAL_OCEAN, type Palette} from "./palette";

// every role must be a non-empty string, ansi must be 16 long, syntax full
function assertComplete(p: Palette): void {
    for (const [k, v] of Object.entries(p)) {
        if (k === "ansi") {
            expect(p.ansi).toHaveLength(16);
            for (const c of p.ansi) expect(c).toMatch(/^#[0-9a-f]{6,8}$/i);
        } else if (k === "syntax") {
            for (const c of Object.values(p.syntax)) expect(c).toMatch(/^#[0-9a-f]{6,8}$/i);
        } else if (k !== "type") {
            expect(typeof v).toBe("string");
            expect(v as string).toMatch(/^#[0-9a-f]{6,8}$/i);
        }
    }
}

describe("MATERIAL_OCEAN", () => {
    it("is complete", () => {
        assertComplete(MATERIAL_OCEAN.palette);
    });
    it("preserves today's key values", () => {
        const p = MATERIAL_OCEAN.palette;
        expect(p.bg).toBe("#0f111a");
        expect(p.accent).toBe("#82aaff");
        expect(p.cursor).toBe("#ffcc00");
        expect(p.ansi[4]).toBe("#82aaff");
        expect(p.syntax.keyword).toBe("#c792ea");
        expect(p.type).toBe("dark");
    });
});
