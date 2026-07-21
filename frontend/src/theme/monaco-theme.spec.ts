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
    it("carries a scope's font style through to the rule", () => {
        expect(ruleFor("markup.heading")?.fontStyle).toBe("bold");
        expect(ruleFor("markup.heading")?.foreground).toBe("c792ea"); // keyword role
        expect(ruleFor("markup.quote")?.fontStyle).toBe("italic");
    });

    // Monaco merges foreground and fontStyle independently, so a rule with no
    // foreground lets the color fall through the trie to the default. That is
    // what keeps **bold** in a paragraph reading as body text with weight,
    // rather than recoloring emphasis to some syntax hue.
    it("emits no foreground for a style-only rule", () => {
        const bold = ruleFor("markup.bold");
        expect(bold?.fontStyle).toBe("bold");
        expect(bold && "foreground" in bold).toBe(false);
    });

    it("sets the editor-subset UI colors", () => {
        expect(t.colors?.["editor.foreground"]).toBe("#8f93a2");
        expect(t.colors?.["editorCursor.foreground"]).toBe("#ffcc00");
    });
    it("leaves the editor background fully transparent for the body tint", () => {
        expect(t.colors?.["editor.background"]).toBe("#00000000");
    });
    it("derives the diff tints to the old exact values", () => {
        expect(t.colors?.["diffEditor.insertedTextBackground"]).toBe("#c3e88d22");
        expect(t.colors?.["diffEditor.removedLineBackground"]).toBe("#ff537012");
    });
});
