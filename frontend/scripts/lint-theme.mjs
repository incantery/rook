// Fail the lint gate on colour utilities that can't follow the theme.
//
// Tailwind's `white`/`black` are literal colours: they don't move when the
// palette does. On every dark built-in `bg-white/5` looks like a correct
// faint raised surface, so this bug class is invisible right up until someone
// picks Catppuccin Latte or One Light — then borders vanish, card surfaces
// dissolve into their pane, and `text-white` goes white-on-white.
//
// Use the palette instead. `fg`-alpha is the theme-agnostic form of
// white-alpha (`bg-fg/5`, `bg-fg/[0.03]`): fg contrasts with the surface by
// construction in BOTH directions, and it tints toward the theme's own text
// hue rather than a flat grey. Hairlines are `border-line/15` (or /30).
//
// Why a script and not a vitest spec: the spec would need node:fs, and
// src/**/*.spec.ts is typechecked by svelte-check against a DOM-only lib with
// no @types/node. This is a lint, so it runs with the lint.
//
// This exists because greps kept under-reporting the problem. `grep '\[#'`
// cleared the chrome sweep while ~50 white-alpha utilities sat untouched, and
// a follow-up grep for `white/` still missed a bare `text-white`. Enumerate
// the FORMS, and let a machine hold the line.

import {readdirSync, readFileSync} from "node:fs";
import {join} from "node:path";

const ROOT = new URL("../src", import.meta.url).pathname;

/** Literal-colour utilities in any variant (hover:, md:, …), with or without
 *  an /alpha or /[0.02] suffix. */
const BANNED =
    /(?<![\w-])(?:[a-z-]+:)*(?:bg|text|border|ring|divide|from|via|to)-(?:white|black)(?:\/(?:\[[^\]]*\]|\d+))?(?![\w-])/g;

/** Utilities that are genuinely theme-independent, with the reason.
 *  A modal scrim darkens whatever is behind it under EITHER theme — that is
 *  the point of a scrim, so it is not palette-driven. Add to this list only
 *  when the colour must not track the theme; if you are unsure, it must. */
const ALLOWED = new Map([["bg-black/55", "modal scrim — darkens under either theme"]]);

function svelteFiles(dir) {
    const out = [];
    for (const e of readdirSync(dir, {withFileTypes: true})) {
        const p = join(dir, e.name);
        if (e.isDirectory()) out.push(...svelteFiles(p));
        else if (e.name.endsWith(".svelte")) out.push(p);
    }
    return out;
}

const findings = [];
for (const file of svelteFiles(ROOT)) {
    const lines = readFileSync(file, "utf8").split("\n");
    lines.forEach((line, i) => {
        for (const m of line.matchAll(BANNED)) {
            // strip any variant prefixes (hover:, focus:) before the allowlist check
            const bare = m[0].slice(m[0].lastIndexOf(":") + 1);
            if (ALLOWED.has(bare)) continue;
            findings.push(`${file.slice(ROOT.length + 1)}:${i + 1}  ${m[0]}`);
        }
    });
}

if (findings.length > 0) {
    console.error(
        `\nlint-theme: ${findings.length} colour utilit${findings.length === 1 ? "y" : "ies"} cannot follow the theme:\n`,
    );
    for (const f of findings) console.error("  " + f);
    console.error(
        "\n  white/black are literal colours — they look right on every dark theme and" +
            "\n  break on the light ones. Use the palette:" +
            "\n    bg-white/5  → bg-fg/5        (fg contrasts with the surface either way)" +
            "\n    border-white/10 → border-line/15" +
            "\n    text-white  → text-fg" +
            "\n  Genuinely theme-independent? Add it to ALLOWED in scripts/lint-theme.mjs" +
            "\n  with the reason.\n",
    );
    process.exit(1);
}
