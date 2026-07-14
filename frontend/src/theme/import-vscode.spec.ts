import {describe, expect, it} from "vitest";
import {importVSCode} from "./import-vscode";

// Inlined VS Code theme exercising the importer: JSONC comments, a trailing
// comma, #RRGGBBAA alpha, terminal ANSI + sideBar/list present, a few
// tokenColors scopes, and terminal.background DELIBERATELY absent. Inline
// (not a fixture file) so no node:fs is needed under svelte-check's tsc.
const MINI = `{
    // a minimal theme
    "name": "Mini Test",
    "type": "dark",
    "colors": {
        "editor.background": "#101418",
        "editor.foreground": "#c8d0da",
        "foreground": "#e0e6ee",
        "editor.selectionBackground": "#2a3a5060",
        "editorCursor.foreground": "#ffcc00",
        "sideBar.background": "#0c1014",
        "editorWidget.background": "#161b22",
        "panel.border": "#30363d",
        "editorLineNumber.foreground": "#4a5560",
        "focusBorder": "#4499ff",
        "terminal.ansiBlack": "#1b1f24",
        "terminal.ansiRed": "#e05561",
        "terminal.ansiGreen": "#8cc265",
        "terminal.ansiYellow": "#d18f52",
        "terminal.ansiBlue": "#4aa5f0",
        "terminal.ansiMagenta": "#c162de",
        "terminal.ansiCyan": "#42b3c2",
        "terminal.ansiWhite": "#d7dae0",
        "terminal.ansiBrightBlack": "#525860",
        "terminal.ansiBrightRed": "#ff616e",
        "terminal.ansiBrightGreen": "#a5e075",
        "terminal.ansiBrightYellow": "#f0a45d",
        "terminal.ansiBrightBlue": "#4dc4ff",
        "terminal.ansiBrightMagenta": "#de73ff",
        "terminal.ansiBrightCyan": "#4cd1e0",
        "terminal.ansiBrightWhite": "#f3f4f5"
    },
    "tokenColors": [
        {"scope": "comment", "settings": {"foreground": "#5c6370"}},
        {"scope": ["string", "string.quoted"], "settings": {"foreground": "#8cc265"}},
        {"scope": "keyword.control", "settings": {"foreground": "#c162de"}},
        {"scope": "entity.name.function", "settings": {"foreground": "#4aa5f0"}},
    ]
}`;

describe("importVSCode", () => {
    const {name, palette: p} = importVSCode(MINI);

    it("parses JSONC (comments + trailing comma) without throwing", () => {
        expect(name).toBe("Mini Test");
        expect(p.type).toBe("dark");
    });

    it("reads core editor colors directly", () => {
        expect(p.bg).toBe("#101418");
        expect(p.editorFg).toBe("#c8d0da");
        expect(p.fg).toBe("#e0e6ee");
        expect(p.accent).toBe("#4499ff"); // focusBorder
    });

    it("reads the 16 ANSI colors directly", () => {
        expect(p.ansi[1]).toBe("#e05561");
        expect(p.ansi[15]).toBe("#f3f4f5");
    });

    it("reads chrome/sidebar keys directly", () => {
        expect(p.raise).toBe("#0c1014"); // sideBar.background
        expect(p.overlay).toBe("#161b22"); // editorWidget.background
        expect(p.line).toBe("#30363d"); // panel.border
        expect(p.lo).toBe("#4a5560"); // editorLineNumber.foreground
    });

    it("preserves alpha in selection", () => {
        expect(p.selection).toBe("#2a3a5060");
    });

    it("maps tokenColors scopes to coarse syntax roles", () => {
        expect(p.syntax.comment).toBe("#5c6370");
        expect(p.syntax.keyword).toBe("#c162de"); // keyword.control → keyword
        expect(p.syntax.function).toBe("#4aa5f0");
        expect(p.syntax.string).toBe("#8cc265");
    });

    it("derives roles the theme omits (no undefineds)", () => {
        expect(p.dim).toMatch(/^#[0-9a-f]{6}$/); // no descriptionForeground → derived
        expect(p.syntax.type).toMatch(/^#[0-9a-f]{6,8}$/); // no type scope → hue
    });
});
