// Extra built-in themes beyond Material Ocean (palette.ts). Authored as full
// Palette literals — the values match the well-known Atom One Dark / One Light
// palettes, the same data importVSCode would produce from their upstream JSON.
// One Light exercises the type:"light" path (Monaco base "vs", light chrome).

import type {Theme} from "./palette";

export const ONE_DARK: Theme = {
    name: "One Dark",
    palette: {
        type: "dark",

        bg: "#282c34",
        sunken: "#21252b",
        raise: "#21252b",
        overlay: "#2c313a",
        line: "#3e4451",

        fg: "#abb2bf",
        editorFg: "#abb2bf",
        dim: "#828997",
        lo: "#495162",

        accent: "#61afef",
        onAccent: "#282c34", // #61afef is a light blue — dark text on it
        cursor: "#528bff",
        selection: "#3e4451",

        blue: "#61afef",
        green: "#98c379",
        yellow: "#e5c07b",
        red: "#e06c75",
        magenta: "#c678dd",
        cyan: "#56b6c2",
        orange: "#d19a66",
        hot: "#e06c75",

        ansi: [
            "#282c34", // black
            "#e06c75", // red
            "#98c379", // green
            "#e5c07b", // yellow
            "#61afef", // blue
            "#c678dd", // magenta
            "#56b6c2", // cyan
            "#abb2bf", // white
            "#5c6370", // bright black
            "#e06c75", // bright red
            "#98c379", // bright green
            "#e5c07b", // bright yellow
            "#61afef", // bright blue
            "#c678dd", // bright magenta
            "#56b6c2", // bright cyan
            "#ffffff", // bright white
        ],

        syntax: {
            comment: "#5c6370",
            string: "#98c379",
            number: "#d19a66",
            keyword: "#c678dd",
            type: "#e5c07b",
            function: "#61afef",
            variable: "#e06c75",
            constant: "#d19a66",
            operator: "#56b6c2",
            tag: "#e06c75",
            attrName: "#d19a66",
            attrValue: "#98c379",
            regexp: "#98c379",
        },
    },
};

export const ONE_LIGHT: Theme = {
    name: "One Light",
    palette: {
        type: "light",

        bg: "#fafafa",
        // the light-theme case the `sunken` role exists for: a well here is
        // LIGHTER than the base, so no darken(bg) derivation would work.
        sunken: "#ffffff",
        raise: "#eaeaeb",
        overlay: "#ffffff",
        line: "#c8c8c9",

        fg: "#383a42",
        editorFg: "#383a42",
        dim: "#a0a1a7",
        lo: "#9d9d9f",

        accent: "#4078f2",
        onAccent: "#ffffff", // #4078f2 is a saturated blue — white text on it
        cursor: "#526fff",
        selection: "#d4d4d5",

        blue: "#4078f2",
        green: "#50a14f",
        yellow: "#c18401",
        red: "#e45649",
        magenta: "#a626a4",
        cyan: "#0184bc",
        orange: "#986801",
        hot: "#e45649",

        ansi: [
            "#383a42", // black
            "#e45649", // red
            "#50a14f", // green
            "#c18401", // yellow
            "#4078f2", // blue
            "#a626a4", // magenta
            "#0184bc", // cyan
            "#fafafa", // white
            "#a0a1a7", // bright black
            "#e45649", // bright red
            "#50a14f", // bright green
            "#c18401", // bright yellow
            "#4078f2", // bright blue
            "#a626a4", // bright magenta
            "#0184bc", // bright cyan
            "#ffffff", // bright white
        ],

        syntax: {
            comment: "#a0a1a7",
            string: "#50a14f",
            number: "#986801",
            keyword: "#a626a4",
            type: "#c18401",
            function: "#4078f2",
            variable: "#e45649",
            constant: "#986801",
            operator: "#0184bc",
            tag: "#e45649",
            attrName: "#986801",
            attrValue: "#50a14f",
            regexp: "#50a14f",
        },
    },
};
