// Nocturne — rook's own theme, lifted from the Claude Design refinement
// boards ("Rook Refinement" / the Nocturne design system, 2026-07-22).
// Deep indigo grounds with a blurple accent; every hue deliberately muted
// (state dots, diffs and telemetry should read at a glance without glowing).
// Elevation runs LIGHTER as surfaces rise: sunken #12141d → bg #14161f →
// raise #1a1c2e → overlay #1b1e2e, with the violet-gray `line` stock chosen
// so border-line/15 lands on the boards' #232637 hairline.

import type {Theme} from "./palette";

export const NOCTURNE: Theme = {
    name: "Nocturne",
    palette: {
        type: "dark",

        bg: "#14161f",
        sunken: "#12141d", // the boards' status-bar / input-well ground
        raise: "#1a1c2e", // titlebar + side panes
        overlay: "#1b1e2e", // quick-open, palette, modals
        // solid stock; at /15 over bg this yields ≈#242636 — the boards'
        // #232637 internal divider. At /30 it's the modal edge (#2e3150-ish).
        line: "#7d82b8",

        fg: "#e9e9ed",
        editorFg: "#cdd0dd",
        dim: "#8b8fa8",
        lo: "#565a70",

        accent: "#9184d9", // the product blurple (OKLCH hue 289)
        onAccent: "#10121c",
        cursor: "#8f84c9",
        selection: "#393757", // accent at ~30% over bg, pre-mixed

        blue: "#a3c0e8",
        green: "#79b98a",
        yellow: "#d9bd7f",
        red: "#d98a8a",
        magenta: "#b8abee",
        cyan: "#89c2c5",
        orange: "#d9a97f",
        hot: "#e57e7e",

        ansi: [
            "#232637", // 0 black — a surface step, still visible on bg
            "#d98a8a", // 1 red
            "#79b98a", // 2 green
            "#d9bd7f", // 3 yellow
            "#8ea9dd", // 4 blue
            "#b8abee", // 5 magenta
            "#89c2c5", // 6 cyan
            "#cdd0dd", // 7 white
            "#565a70", // 8 bright black
            "#e8a3a3", // 9 bright red
            "#94cca3", // 10 bright green
            "#e8d09a", // 11 bright yellow
            "#a3c0e8", // 12 bright blue
            "#cbc2f5", // 13 bright magenta
            "#a3d5d8", // 14 bright cyan
            "#e9e9ed", // 15 bright white
        ],

        syntax: {
            // lifted two ramp steps above classic comment-gray on purpose —
            // the boards call comments out as readable, not whispered
            comment: "#8d92ad",
            string: "#9ec49a",
            number: "#d4bd85",
            keyword: "#b8abee",
            type: "#d4bd85",
            operator: "#a9adc4",
            tag: "#d98a8a",
            attrName: "#d4bd85",
            attrValue: "#9ec49a",
            function: "#a3c0e8",
            variable: "#cdd0dd",
            constant: "#d4bd85",
            regexp: "#89c2c5",
        },
    },
};
