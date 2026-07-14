import {describe, expect, it} from "vitest";
import {buildMonacoTheme} from "./monaco-theme";
import {MATERIAL_OCEAN} from "./palette";

describe("buildMonacoTheme", () => {
    const t = buildMonacoTheme(MATERIAL_OCEAN.palette);
    const ruleFor = (token: string) => t.rules.find((r) => r.token === token);

    it("uses the dark base for a dark palette", () => {
        expect(t.base).toBe("vs-dark");
    });
    it("emits rule foregrounds as bare 6-digit hex (no #, no alpha)", () => {
        expect(ruleFor("keyword")?.foreground).toBe("c792ea");
        expect(ruleFor("delimiter")?.foreground).toBe("89ddff"); // operator role
    });
    it("sets the editor-subset UI colors", () => {
        expect(t.colors?.["editor.background"]).toBe("#0f111a");
        expect(t.colors?.["editor.foreground"]).toBe("#8f93a2");
        expect(t.colors?.["editorCursor.foreground"]).toBe("#ffcc00");
    });
    it("derives the diff tints to the old exact values", () => {
        expect(t.colors?.["diffEditor.insertedTextBackground"]).toBe("#c3e88d22");
        expect(t.colors?.["diffEditor.removedLineBackground"]).toBe("#ff537012");
    });
});
