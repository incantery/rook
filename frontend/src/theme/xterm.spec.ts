import {describe, expect, it} from "vitest";
import {MATERIAL_OCEAN} from "./palette";
import {buildXtermTheme} from "./xterm";

describe("buildXtermTheme", () => {
    const t = buildXtermTheme(MATERIAL_OCEAN.palette);
    it("keeps the terminal background transparent", () => {
        expect(t.background).toBe("#00000000");
    });
    it("maps foreground/cursor/selection and the 16 ANSI ramp", () => {
        expect(t.foreground).toBe("#8f93a2");
        expect(t.cursor).toBe("#ffcc00");
        expect(t.selectionBackground).toBe("#717cb4");
        expect(t.blue).toBe("#82aaff"); // ansi[4]
        expect(t.brightWhite).toBe("#ffffff"); // ansi[15]
    });
});
