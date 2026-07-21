// Build a Monaco IStandaloneThemeData from a Palette. Two halves:
//   rules  — syntax colors. Two families, because two tokenizers are live:
//            TextMate SCOPES (highlight/scope.ts) for the vendored grammars,
//            and Monaco's coarse MONARCH names for every other language.
//            Both are matched by the same dotted trie — Monaco splits a token
//            on "." and walks it, longest prefix wins — so the two families
//            coexist in one flat list without colliding. Rule foregrounds are
//            BARE 6-digit hex, no # and no alpha.
//   colors — the editor-subset UI keys (Monaco has no side bar etc.; the
//            CSS-var chrome owns everything outside the editor). These DO take
//            # and may carry alpha.
// The diff tints derive from green/red at the same low alphas the original
// hand-written theme hardcoded.

import type {editor} from "monaco-editor";
import {SCOPE_ROLES, SEMANTIC_ROLES} from "../highlight/scope";
import {mix, noHash, withAlpha} from "./color";
import type {Palette} from "./palette";

export function buildMonacoTheme(p: Palette): editor.IStandaloneThemeData {
    const s = p.syntax;
    const rule = (token: string, color: string) => ({token, foreground: noHash(color)});
    return {
        base: p.type === "light" ? "vs" : "vs-dark",
        inherit: true,
        rules: [
            // TextMate scopes — the vendored grammars (highlight/scope.ts owns
            // the scope→role table, so this list and the tokenizer's own
            // claim set can never drift apart)
            ...SCOPE_ROLES.map(([scope, role]) => rule(scope, s[role])),

            // LSP semantic token types — the layer above the grammar.
            // Standalone Monaco resolves a semantic token by joining
            // [type, ...modifiers] with dots and matching THIS SAME trie
            // (standaloneThemeService.getTokenStyleMetadata), so a type is
            // just another rule key and modifiers refine it for free.
            ...SEMANTIC_ROLES.map(([type, role]) => rule(type, s[role])),

            // Monarch names — every language without a vendored grammar.
            // These are single words with no dots, so they can't shadow a
            // scope rule (and vice versa).
            rule("comment", s.comment),
            rule("string", s.string),
            rule("regexp", s.regexp),
            rule("number", s.number),
            rule("keyword", s.keyword),
            rule("type", s.type),
            rule("function", s.function),
            rule("identifier.function", s.function),
            rule("variable", s.variable),
            rule("constant", s.constant),
            rule("delimiter", s.operator),
            rule("operator", s.operator),
            rule("tag", s.tag),
            rule("attribute.name", s.attrName),
            rule("attribute.value", s.attrValue),
        ],
        colors: {
            // Fully transparent, NOT p.bg: the window is see-through
            // (MacBackdropTransparent) and the body tint is the one layer that
            // paints. Monaco does support alpha here — parseHex takes #RRGGBBAA
            // and the standalone theme service emits it as rgba() into
            // --vscode-editor-background — but it paints that var on BOTH
            // .monaco-editor and .monaco-editor-background (lines-content, the
            // margin covers, the textarea cover), so any partial alpha stacks
            // with itself. Zero is the only value that composes: the pane owns
            // the tint once, Monaco adds nothing.
            "editor.background": "#00000000",
            "editor.foreground": p.editorFg,
            "editorCursor.foreground": p.cursor,
            "editor.selectionBackground": p.selection,
            "editorLineNumber.foreground": p.lo,
            "editorLineNumber.activeForeground": p.dim,
            "editorWidget.background": p.overlay,
            // a subtle border between the widget surface and the line hue —
            // derived so it stays dark (using p.line raw would be far too light)
            "editorWidget.border": mix(p.overlay, p.line, 0.13),
            // The hover is its OWN colour key — it does not inherit
            // editorWidget.background in a standalone theme, so leaving these
            // unset renders the hover transparent and its text ghosts over the
            // code underneath. That matters more now that hover is where a
            // thread previews.
            "editorHoverWidget.background": p.overlay,
            "editorHoverWidget.foreground": p.fg,
            "editorHoverWidget.border": mix(p.overlay, p.line, 0.13),
            "editorHoverWidget.statusBarBackground": mix(p.overlay, p.line, 0.06),
            // diff tints: green/red washes, same alphas the old theme baked in
            "diffEditor.insertedTextBackground": withAlpha(p.green, 34 / 255),
            "diffEditor.removedTextBackground": withAlpha(p.red, 34 / 255),
            "diffEditor.insertedLineBackground": withAlpha(p.green, 18 / 255),
            "diffEditor.removedLineBackground": withAlpha(p.red, 18 / 255),
        },
    };
}
