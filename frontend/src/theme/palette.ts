// The Palette: rook's single source of color truth. One flat record of
// semantic roles that every surface derives from — chrome (CSS vars),
// xterm, and Monaco. Built-ins are authored here; importers (import-vscode.ts)
// target this shape. See docs/superpowers/specs/2026-07-14-theming-design.md.

export type ThemeType = "dark" | "light";

export interface Syntax {
    comment: string;
    string: string;
    number: string;
    keyword: string;
    type: string;
    function: string;
    variable: string;
    constant: string;
    operator: string;
    tag: string;
    attrName: string;
    attrValue: string;
    regexp: string;
}

export interface Palette {
    type: ThemeType;

    // surfaces
    bg: string; // editor + terminal + window base
    sunken: string; // recessed: input wells, code blocks. NOT always darker
    // than bg — a light theme's well reads as lighter, so
    // this is authored, not derived from bg.
    raise: string; // raised panel: side panes, titlebar
    overlay: string; // floating: palette, widgets, modals
    line: string; // hairlines / borders (solid stock; chrome applies /15)

    // text
    fg: string; // primary UI text (chrome)
    editorFg: string; // editor + terminal body text
    dim: string; // muted UI text, secondary labels
    lo: string; // faint: line numbers, disabled

    // state
    accent: string; // focus ring, active, links
    onAccent: string; // text/icons ON an accent fill (primary buttons) — must
    // contrast with `accent`, so it tracks the accent's
    // lightness, not the theme's type
    cursor: string; // caret
    selection: string; // selection background

    // hues — accents; also feed syntax + ANSI when a source omits them
    blue: string;
    green: string;
    yellow: string;
    red: string;
    magenta: string;
    cyan: string;
    orange: string;
    hot: string;

    // terminal: the 16 ANSI, index 0..15
    // black,red,green,yellow,blue,magenta,cyan,white, then the 8 bright*
    ansi: string[];

    syntax: Syntax;
}

export interface Theme {
    name: string;
    palette: Palette;
}

// Material Ocean — today's look, expressed in the new format. Every value is
// lifted verbatim from the four current sources (app.css @theme + body vars,
// main.ts xterm THEME, term/monaco.ts). Syntax roles that the current Monaco
// theme leaves unset (function/variable/constant/regexp) default to editorFg
// so the emitted rules match today's fall-through-to-default coloring.
export const MATERIAL_OCEAN: Theme = {
    name: "Material Ocean",
    palette: {
        type: "dark",

        bg: "#0f111a",
        // the input wells' bg-[#0a0c14]/80; ThreadPanel drifted to #0b0d14
        // for the same job, and folds in here.
        sunken: "#0a0c14",
        raise: "#ffffff09", // rgba(255,255,255,0.035)
        // the modal/palette shell drifted to #151924 in markup vs #151928 in
        // term/monaco.ts — 4 apart in blue, one role.
        overlay: "#151928",
        line: "#8c96b4", // rgb(140,150,180)

        fg: "#d6deeb",
        editorFg: "#8f93a2",
        dim: "#8f93a2",
        lo: "#5b6273",

        accent: "#82aaff",
        // primary buttons drifted between #10131c and #0b0d14 (ThreadPanel);
        // the majority value wins.
        onAccent: "#10131c",
        cursor: "#ffcc00",
        selection: "#717cb4",

        blue: "#82aaff",
        green: "#c3e88d",
        yellow: "#ffcb6b",
        red: "#ff5370",
        magenta: "#c792ea",
        cyan: "#89ddff",
        orange: "#f78c6c",
        hot: "#f07178",

        ansi: [
            "#546e7a", // 0 black
            "#ff5370", // 1 red
            "#c3e88d", // 2 green
            "#ffcb6b", // 3 yellow
            "#82aaff", // 4 blue
            "#c792ea", // 5 magenta
            "#89ddff", // 6 cyan
            "#eeffff", // 7 white
            "#546e7a", // 8 bright black
            "#ff5370", // 9 bright red
            "#c3e88d", // 10 bright green
            "#ffcb6b", // 11 bright yellow
            "#82aaff", // 12 bright blue
            "#c792ea", // 13 bright magenta
            "#89ddff", // 14 bright cyan
            "#ffffff", // 15 bright white
        ],

        syntax: {
            comment: "#546e7a",
            string: "#c3e88d",
            number: "#f78c6c",
            keyword: "#c792ea",
            type: "#ffcb6b",
            operator: "#89ddff", // Monaco "delimiter"
            tag: "#ff5370",
            attrName: "#ffcb6b",
            attrValue: "#c3e88d",
            // These four were editorFg because MONARCH COULD NOT PRODUCE
            // THEM — a keyword-list tokenizer has no notion of a call site
            // or a constant, so a color here would never have been drawn.
            // TextMate scopes and LSP semantic tokens both name them now,
            // so they take Material Ocean's own published values; leaving
            // them flat would make the whole semantic layer invisible on the
            // default theme. `variable` stays at editorFg deliberately —
            // that IS Material Ocean's answer for a plain identifier, and
            // coloring every variable is noise, not information.
            function: "#82aaff",
            variable: "#8f93a2",
            constant: "#f78c6c",
            regexp: "#89ddff",
        },
    },
};
