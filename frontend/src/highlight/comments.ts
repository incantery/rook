// What `gc` needs to know, which the grammar can't tell it.
//
// Monaco reads comment tokens off a language's CONFIGURATION, not its
// tokenizer — so a language registered by TextMate alone (svelte here) has
// none, and editor.action.commentLine silently does nothing. Registering a
// configuration fixes that everywhere except the one place it matters most:
// a .svelte file is three languages in a trenchcoat, and one comment rule
// for the whole file is wrong in two thirds of it. `<!-- -->` inside
// <script> is not a comment, it's broken code — and <script> is where you
// spend your time.
//
// So svelte's rule is chosen per POSITION. The region scan below is
// deliberately textual rather than grammar-driven: svelte's <script> and
// <style> are top-level blocks, which makes "which region is this line in"
// a question about tag lines, and answering it needs no tokenizer state,
// no async grammar load, and nothing to keep in sync with the cursor.

import type * as monacoTypes from "monaco-editor";

type CommentRule = monacoTypes.languages.CommentRule;

export const HTML_COMMENTS: CommentRule = {blockComment: ["<!--", "-->"]};
export const SCRIPT_COMMENTS: CommentRule = {
    lineComment: "//",
    blockComment: ["/*", "*/"],
};
/** CSS has no line comment — Monaco's toggle falls back to the block form,
 *  which is what every CSS editor does. */
export const STYLE_COMMENTS: CommentRule = {blockComment: ["/*", "*/"]};

/** Languages rook registers itself, and the comment rule each starts with.
 *  Monaco's own basic-language contributions bring their own; these are the
 *  ones that would otherwise have nothing.
 *
 *  json takes jsonc's rule, matching VS Code: the .json files a developer
 *  actually edits by hand (tsconfig, .vscode/*) are jsonc, and a `gcc` that
 *  refuses on all of them to protect the strict-JSON case helps nobody. */
export const BASE_COMMENTS: Record<string, CommentRule> = {
    svelte: HTML_COMMENTS,
    json: SCRIPT_COMMENTS,
};

export type SvelteRegion = "script" | "style" | "markup";

/** Which language line `line` (1-based) is really in.
 *
 *  The tag lines themselves are MARKUP: `<script>` is an element, and
 *  commenting it out is an HTML comment. Only the lines between an opening
 *  and its closing tag belong to the embedded language — which also means a
 *  one-line `<script>foo()</script>` reads as markup, the honest answer for
 *  a line that is mostly tags.
 *
 *  Unclosed blocks run to the end of the file, so a script you are still
 *  typing comments like script rather than reverting to markup mid-edit. */
export function svelteRegionAt(text: string, line: number): SvelteRegion {
    const lines = text.split("\n");
    let region: SvelteRegion = "markup";
    let openedAt = 0;
    for (let i = 0; i < lines.length; i++) {
        const n = i + 1;
        const l = lines[i];
        if (region === "markup") {
            // an opening tag only counts if it is not closed on its own line
            if (/<script\b/.test(l) && !/<\/script\s*>/.test(l)) {
                region = "script";
                openedAt = n;
            } else if (/<style\b/.test(l) && !/<\/style\s*>/.test(l)) {
                region = "style";
                openedAt = n;
            }
            if (n === line) return "markup";
            continue;
        }
        const closing = region === "script" ? /<\/script\s*>/ : /<\/style\s*>/;
        if (closing.test(l)) {
            // the closing tag line is markup again
            if (n === line) return "markup";
            region = "markup";
            continue;
        }
        if (n === line) return n > openedAt ? region : "markup";
    }
    return "markup";
}

/** The comment rule for a position: svelte answers by region, everything
 *  else by its base rule (null = leave Monaco's own configuration alone). */
export function commentsAt(lang: string, text: string, line: number): CommentRule | null {
    if (lang !== "svelte") return null;
    switch (svelteRegionAt(text, line)) {
        case "script":
            return SCRIPT_COMMENTS;
        case "style":
            return STYLE_COMMENTS;
        default:
            return HTML_COMMENTS;
    }
}
