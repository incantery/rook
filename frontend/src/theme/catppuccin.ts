// Catppuccin — the four official flavours (https://catppuccin.com).
//
// NOT hand-authored: these palettes are importVSCode()'s output on the real
// upstream themes, published as @catppuccin/vscode (v3.18.1) and generated
// from that package's themes/{latte,frappe,macchiato,mocha}.json. To refresh,
// run those files back through importVSCode and re-emit — the importer is the
// source of truth, this file is its cache. Values are frozen at import time on
// purpose, so a theme's look can't drift when the importer changes.
//
// This is the reuse thesis working end to end (see the design doc): Catppuccin
// sets 564 of VS Code's ~600 colour keys and all 16 terminal.ansi*, so almost
// nothing here is derived — it's read straight from upstream, including the
// syntax roles resolved from 179 tokenColors rules. The one lossy part is
// syntax: VS Code colours TextMate scopes, rook's Monaco uses Monarch's coarse
// tokens, so each role takes its best-matching scope rule.

import type {Theme} from "./palette";

export const CATPPUCCIN_LATTE: Theme = {
    name: "Catppuccin Latte",
    palette: {
        type: "light",

        // surfaces
        bg: "#eff1f5",
        sunken: "#ccd0da",
        raise: "#e6e9ef",
        overlay: "#e6e9ef",
        line: "#acb0be",

        // text
        fg: "#4c4f69",
        editorFg: "#4c4f69",
        dim: "#6c6f85",
        lo: "#8c8fa1",

        // state
        accent: "#8839ef",
        onAccent: "#dce0e8",
        cursor: "#dc8a78",
        selection: "#7c7f934d",

        // hues
        blue: "#456eff",
        green: "#49af3d",
        yellow: "#eea02d",
        red: "#de293e",
        magenta: "#fe85d8",
        cyan: "#2d9fa8",
        orange: "#e66536",
        hot: "#de293e",

        ansi: [
            "#5c5f77", // 0 black
            "#d20f39", // 1 red
            "#40a02b", // 2 green
            "#df8e1d", // 3 yellow
            "#1e66f5", // 4 blue
            "#ea76cb", // 5 magenta
            "#179299", // 6 cyan
            "#acb0be", // 7 white
            "#6c6f85", // 8 bright black
            "#de293e", // 9 bright red
            "#49af3d", // 10 bright green
            "#eea02d", // 11 bright yellow
            "#456eff", // 12 bright blue
            "#fe85d8", // 13 bright magenta
            "#2d9fa8", // 14 bright cyan
            "#bcc0cc", // 15 bright white
        ],

        syntax: {
            comment: "#7c7f93",
            string: "#40a02b",
            number: "#fe640b",
            keyword: "#8839ef",
            type: "#df8e1d",
            function: "#1e66f5",
            variable: "#4c4f69",
            constant: "#fe640b",
            operator: "#179299",
            tag: "#8839ef",
            attrName: "#df8e1d",
            attrValue: "#40a02b",
            regexp: "#40a02b",
        },
    },
};

export const CATPPUCCIN_FRAPPE: Theme = {
    name: "Catppuccin Frappé",
    palette: {
        type: "dark",

        // surfaces
        bg: "#303446",
        sunken: "#414559",
        raise: "#292c3c",
        overlay: "#292c3c",
        line: "#626880",

        // text
        fg: "#c6d0f5",
        editorFg: "#c6d0f5",
        dim: "#a5adce",
        lo: "#838ba7",

        // state
        accent: "#ca9ee6",
        onAccent: "#232634",
        cursor: "#f2d5cf",
        selection: "#949cbb40",

        // hues
        blue: "#7b9ef0",
        green: "#8ec772",
        yellow: "#d9ba73",
        red: "#e67172",
        magenta: "#f2a4db",
        cyan: "#5abfb5",
        orange: "#e09673",
        hot: "#e67172",

        ansi: [
            "#51576d", // 0 black
            "#e78284", // 1 red
            "#a6d189", // 2 green
            "#e5c890", // 3 yellow
            "#8caaee", // 4 blue
            "#f4b8e4", // 5 magenta
            "#81c8be", // 6 cyan
            "#a5adce", // 7 white
            "#626880", // 8 bright black
            "#e67172", // 9 bright red
            "#8ec772", // 10 bright green
            "#d9ba73", // 11 bright yellow
            "#7b9ef0", // 12 bright blue
            "#f2a4db", // 13 bright magenta
            "#5abfb5", // 14 bright cyan
            "#b5bfe2", // 15 bright white
        ],

        syntax: {
            comment: "#949cbb",
            string: "#a6d189",
            number: "#ef9f76",
            keyword: "#ca9ee6",
            type: "#e5c890",
            function: "#8caaee",
            variable: "#c6d0f5",
            constant: "#ef9f76",
            operator: "#81c8be",
            tag: "#ca9ee6",
            attrName: "#e5c890",
            attrValue: "#a6d189",
            regexp: "#a6d189",
        },
    },
};

export const CATPPUCCIN_MACCHIATO: Theme = {
    name: "Catppuccin Macchiato",
    palette: {
        type: "dark",

        // surfaces
        bg: "#24273a",
        sunken: "#363a4f",
        raise: "#1e2030",
        overlay: "#1e2030",
        line: "#5b6078",

        // text
        fg: "#cad3f5",
        editorFg: "#cad3f5",
        dim: "#a5adcb",
        lo: "#8087a2",

        // state
        accent: "#c6a0f6",
        onAccent: "#181926",
        cursor: "#f4dbd6",
        selection: "#939ab740",

        // hues
        blue: "#78a1f6",
        green: "#8ccf7f",
        yellow: "#e1c682",
        red: "#ec7486",
        magenta: "#f2a9dd",
        cyan: "#63cbc0",
        orange: "#e79d84",
        hot: "#ec7486",

        ansi: [
            "#494d64", // 0 black
            "#ed8796", // 1 red
            "#a6da95", // 2 green
            "#eed49f", // 3 yellow
            "#8aadf4", // 4 blue
            "#f5bde6", // 5 magenta
            "#8bd5ca", // 6 cyan
            "#a5adcb", // 7 white
            "#5b6078", // 8 bright black
            "#ec7486", // 9 bright red
            "#8ccf7f", // 10 bright green
            "#e1c682", // 11 bright yellow
            "#78a1f6", // 12 bright blue
            "#f2a9dd", // 13 bright magenta
            "#63cbc0", // 14 bright cyan
            "#b8c0e0", // 15 bright white
        ],

        syntax: {
            comment: "#939ab7",
            string: "#a6da95",
            number: "#f5a97f",
            keyword: "#c6a0f6",
            type: "#eed49f",
            function: "#8aadf4",
            variable: "#cad3f5",
            constant: "#f5a97f",
            operator: "#8bd5ca",
            tag: "#c6a0f6",
            attrName: "#eed49f",
            attrValue: "#a6da95",
            regexp: "#a6da95",
        },
    },
};

export const CATPPUCCIN_MOCHA: Theme = {
    name: "Catppuccin Mocha",
    palette: {
        type: "dark",

        // surfaces
        bg: "#1e1e2e",
        sunken: "#313244",
        raise: "#181825",
        overlay: "#181825",
        line: "#585b70",

        // text
        fg: "#cdd6f4",
        editorFg: "#cdd6f4",
        dim: "#a6adc8",
        lo: "#7f849c",

        // state
        accent: "#cba6f7",
        onAccent: "#11111b",
        cursor: "#f5e0dc",
        selection: "#9399b240",

        // hues
        blue: "#74a8fc",
        green: "#89d88b",
        yellow: "#ebd391",
        red: "#f37799",
        magenta: "#f2aede",
        cyan: "#6bd7ca",
        orange: "#efa595",
        hot: "#f37799",

        ansi: [
            "#45475a", // 0 black
            "#f38ba8", // 1 red
            "#a6e3a1", // 2 green
            "#f9e2af", // 3 yellow
            "#89b4fa", // 4 blue
            "#f5c2e7", // 5 magenta
            "#94e2d5", // 6 cyan
            "#a6adc8", // 7 white
            "#585b70", // 8 bright black
            "#f37799", // 9 bright red
            "#89d88b", // 10 bright green
            "#ebd391", // 11 bright yellow
            "#74a8fc", // 12 bright blue
            "#f2aede", // 13 bright magenta
            "#6bd7ca", // 14 bright cyan
            "#bac2de", // 15 bright white
        ],

        syntax: {
            comment: "#9399b2",
            string: "#a6e3a1",
            number: "#fab387",
            keyword: "#cba6f7",
            type: "#f9e2af",
            function: "#89b4fa",
            variable: "#cdd6f4",
            constant: "#fab387",
            operator: "#94e2d5",
            tag: "#cba6f7",
            attrName: "#f9e2af",
            attrValue: "#a6e3a1",
            regexp: "#a6e3a1",
        },
    },
};
