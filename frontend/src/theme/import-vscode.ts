// Import a VS Code / Cursor color theme (JSON) into rook's Palette. This is
// the primary reuse path: a VS Code theme is the one artifact that colors all
// three of rook's surfaces — colors[editor.*/sideBar.*] → chrome, colors
// [terminal.ansi*] → xterm, tokenColors[] → editor syntax.
//
// Fidelity notes (see the design doc, grounded in the research pass):
//  - Themes populate ~110–230 of ~600 keys, so DERIVATION is mandatory; but
//    popular themes DO set the ansi + sideBar/list keys directly (read those).
//  - Syntax is LOSSY: VS Code colors TextMate scopes; rook's Monaco uses
//    Monarch's coarse tokens. We resolve each coarse role from the best-match
//    (longest-prefix) tokenColors rule, falling back to a hue.
//  - semanticTokenColors is IGNORED (Monaco+Monarch has no semantic tokens).
//  - Every real theme uses #RRGGBBAA / #RGBA — all values normalize first.

import {mix, normalizeHex, withAlpha} from "./color";
import type {Palette, Syntax, Theme} from "./palette";

interface TokenColor {
    scope?: string | string[];
    settings?: {foreground?: string; fontStyle?: string};
}
interface VSTheme {
    name?: string;
    type?: string;
    colors?: Record<string, string>;
    tokenColors?: TokenColor[];
}

const ANSI_KEYS = [
    "terminal.ansiBlack",
    "terminal.ansiRed",
    "terminal.ansiGreen",
    "terminal.ansiYellow",
    "terminal.ansiBlue",
    "terminal.ansiMagenta",
    "terminal.ansiCyan",
    "terminal.ansiWhite",
    "terminal.ansiBrightBlack",
    "terminal.ansiBrightRed",
    "terminal.ansiBrightGreen",
    "terminal.ansiBrightYellow",
    "terminal.ansiBrightBlue",
    "terminal.ansiBrightMagenta",
    "terminal.ansiBrightCyan",
    "terminal.ansiBrightWhite",
];

// VS Code's default dark terminal ramp — only used if a theme omits ansi keys
// entirely (popular themes don't; this is the safety net).
const DEFAULT_ANSI = [
    "#000000",
    "#cd3131",
    "#0dbc79",
    "#e5e510",
    "#2472c8",
    "#bc3fbc",
    "#11a8cd",
    "#e5e5e5",
    "#666666",
    "#f14c4c",
    "#23d18b",
    "#f5f543",
    "#3b8eea",
    "#d670d6",
    "#29b8db",
    "#e5e5e5",
];

/** Representative concrete scopes per coarse syntax role — a rule selector
 *  matches when it is a dotted prefix of one of these (longest prefix wins). */
const SYNTAX_TARGETS: Record<keyof Syntax, string[]> = {
    comment: ["comment.line.double-slash", "comment"],
    string: ["string.quoted.double", "string"],
    number: ["constant.numeric.decimal", "constant.numeric"],
    keyword: ["keyword.control.flow", "keyword.control", "keyword"],
    type: ["entity.name.type.class", "support.type", "storage.type"],
    function: ["entity.name.function", "support.function", "meta.function-call"],
    variable: ["variable.other.readwrite", "variable"],
    constant: ["constant.language.boolean", "support.constant", "constant.language"],
    operator: ["keyword.operator"],
    tag: ["entity.name.tag"],
    attrName: ["entity.other.attribute-name"],
    attrValue: ["string.quoted.double", "string"],
    regexp: ["string.regexp"],
};

export function importVSCode(text: string): Theme {
    const raw = JSON.parse(stripTrailingCommas(stripJsonc(text))) as VSTheme;
    const colors = raw.colors ?? {};
    const rules = raw.tokenColors ?? [];

    const c = (key: string): string | undefined => {
        const v = colors[key];
        return v ? normalizeHex(v) : undefined;
    };
    const scope = (role: keyof Syntax): string | undefined =>
        scopeColor(rules, SYNTAX_TARGETS[role]);

    // surfaces + core text (derive what the theme omits)
    const bg = c("editor.background") ?? "#1e1e1e";
    const editorFg = c("editor.foreground") ?? "#d4d4d4";
    const fg = c("foreground") ?? c("sideBar.foreground") ?? editorFg;

    // terminal ANSI: read directly (popular themes set all 16), else default ramp
    const ansi = ANSI_KEYS.map((k, i) => c(k) ?? DEFAULT_ANSI[i]);

    // chrome hues from the vivid (bright) ANSI slots, falling back to normal
    const blue = c("terminal.ansiBrightBlue") ?? ansi[4];
    const green = c("terminal.ansiBrightGreen") ?? ansi[2];
    const yellow = c("terminal.ansiBrightYellow") ?? ansi[3];
    const red = c("terminal.ansiBrightRed") ?? ansi[1];
    const magenta = c("terminal.ansiBrightMagenta") ?? ansi[5];
    const cyan = c("terminal.ansiBrightCyan") ?? ansi[6];
    const orange = mix(red, yellow, 0.5);

    const palette: Palette = {
        type: raw.type === "light" ? "light" : "dark",

        bg,
        raise: c("sideBar.background") ?? c("editorGroupHeader.tabsBackground") ?? bg,
        overlay:
            c("editorWidget.background") ??
            c("editorSuggestWidget.background") ??
            mix(bg, fg, 0.06),
        line:
            c("panel.border") ??
            c("sideBar.border") ??
            c("editorWidget.border") ??
            mix(bg, fg, 0.25),

        fg,
        editorFg,
        dim:
            c("descriptionForeground") ??
            c("editorLineNumber.activeForeground") ??
            mix(editorFg, bg, 0.35),
        lo: c("editorLineNumber.foreground") ?? mix(editorFg, bg, 0.55),

        accent: c("focusBorder") ?? c("textLink.foreground") ?? blue,
        cursor: c("editorCursor.foreground") ?? c("terminalCursor.foreground") ?? editorFg,
        selection: c("editor.selectionBackground") ?? withAlpha(blue, 0.3),

        blue,
        green,
        yellow,
        red,
        magenta,
        cyan,
        orange,
        hot: red,

        ansi,

        syntax: {
            comment: scope("comment") ?? mix(editorFg, bg, 0.4),
            string: scope("string") ?? green,
            number: scope("number") ?? orange,
            keyword: scope("keyword") ?? magenta,
            type: scope("type") ?? yellow,
            function: scope("function") ?? blue,
            variable: scope("variable") ?? editorFg,
            constant: scope("constant") ?? orange,
            operator: scope("operator") ?? cyan,
            tag: scope("tag") ?? red,
            attrName: scope("attrName") ?? yellow,
            attrValue: scope("attrValue") ?? green,
            regexp: scope("regexp") ?? green,
        },
    };

    return {name: raw.name ?? "Imported", palette};
}

// ---- scope matching (lossy: TextMate scopes → coarse role) ----

/** The color a token of one of `targets` would receive: the tokenColors rule
 *  whose selector is the LONGEST dotted-prefix of any target. */
function scopeColor(rules: TokenColor[], targets: string[]): string | undefined {
    let best: {len: number; color: string} | undefined;
    for (const t of targets) {
        for (const r of rules) {
            const fg = r.settings?.foreground;
            if (!fg) continue;
            for (const sel of selectorsOf(r.scope)) {
                if ((t === sel || t.startsWith(`${sel}.`)) && (!best || sel.length > best.len)) {
                    best = {len: sel.length, color: normalizeHex(fg)};
                }
            }
        }
    }
    return best?.color;
}

/** A rule's `scope` is a string (comma-separated) or string[]; each selector
 *  may be a descendant path ("meta.fn entity.name") — take the last segment,
 *  the scope actually being colored. */
function selectorsOf(scope?: string | string[]): string[] {
    if (!scope) return [];
    const list = Array.isArray(scope) ? scope : scope.split(",");
    return list
        .map((s) => s.trim())
        .filter(Boolean)
        .map((s) => s.split(/\s+/).pop() ?? s);
}

// ---- JSONC tolerance (real themes ship with comments + trailing commas) ----

function stripJsonc(text: string): string {
    let out = "";
    let inStr = false;
    let esc = false;
    let inLine = false;
    let inBlock = false;
    for (let i = 0; i < text.length; i++) {
        const ch = text[i];
        const next = text[i + 1];
        if (inLine) {
            if (ch === "\n") {
                inLine = false;
                out += ch;
            }
            continue;
        }
        if (inBlock) {
            if (ch === "*" && next === "/") {
                inBlock = false;
                i++;
            }
            continue;
        }
        if (inStr) {
            out += ch;
            if (esc) esc = false;
            else if (ch === "\\") esc = true;
            else if (ch === '"') inStr = false;
            continue;
        }
        if (ch === '"') {
            inStr = true;
            out += ch;
        } else if (ch === "/" && next === "/") {
            inLine = true;
            i++;
        } else if (ch === "/" && next === "*") {
            inBlock = true;
            i++;
        } else {
            out += ch;
        }
    }
    return out;
}

function stripTrailingCommas(text: string): string {
    return text.replace(/,(\s*[}\]])/g, "$1");
}
