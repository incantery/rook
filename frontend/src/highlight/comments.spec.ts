import {describe, expect, it} from "vitest";
import {commentsAt, svelteRegionAt} from "./comments";

// A .svelte file is three languages, and `gc` has to pick the right one per
// POSITION. Getting this wrong is not a cosmetic miss: `<!-- -->` inside
// <script> is broken code, in the region you edit most.

const FILE = [
    /* 1 */ '<script lang="ts">',
    /* 2 */ "    let n = 1;",
    /* 3 */ "    const f = () => n;",
    /* 4 */ "</script>",
    /* 5 */ "",
    /* 6 */ '<div class="x">',
    /* 7 */ "    {n}",
    /* 8 */ "</div>",
    /* 9 */ "",
    /* 10 */ "<style>",
    /* 11 */ "    .x { color: red; }",
    /* 12 */ "</style>",
].join("\n");

const region = (line: number) => svelteRegionAt(FILE, line);

describe("svelteRegionAt", () => {
    it("reads the body of <script> as script", () => {
        expect(region(2)).toBe("script");
        expect(region(3)).toBe("script");
    });

    it("reads the body of <style> as style", () => {
        expect(region(11)).toBe("style");
    });

    it("reads markup as markup", () => {
        expect(region(6)).toBe("markup");
        expect(region(7)).toBe("markup");
        expect(region(9)).toBe("markup");
    });

    // The tags are elements. Commenting the <script> line itself is an HTML
    // comment, not a JS one — this is the boundary people actually hit.
    it("treats the tag lines themselves as markup", () => {
        expect(region(1)).toBe("markup");
        expect(region(4)).toBe("markup");
        expect(region(10)).toBe("markup");
        expect(region(12)).toBe("markup");
    });

    it("handles a script closed on its own line as markup throughout", () => {
        const one = "<div>a</div>\n<script>f()</script>\n<p>b</p>";
        expect(svelteRegionAt(one, 1)).toBe("markup");
        expect(svelteRegionAt(one, 2)).toBe("markup");
        expect(svelteRegionAt(one, 3)).toBe("markup");
    });

    // Half-typed files are the common case while editing — a script whose
    // closing tag isn't there yet must not silently revert to markup.
    it("runs an unclosed block to the end of the file", () => {
        const open = "<script>\n    let n = 1;\n    let m = 2;";
        expect(svelteRegionAt(open, 2)).toBe("script");
        expect(svelteRegionAt(open, 3)).toBe("script");
    });

    it('handles <script context="module"> and attributes', () => {
        const mod = '<script context="module" lang="ts">\n  export const x = 1;\n</script>';
        expect(svelteRegionAt(mod, 2)).toBe("script");
    });

    it("survives a line past the end", () => {
        expect(region(99)).toBe("markup");
    });
});

describe("commentsAt", () => {
    it("gives svelte's script region a line comment", () => {
        expect(commentsAt("svelte", FILE, 2)?.lineComment).toBe("//");
    });

    it("gives svelte's style region the CSS block form and no line comment", () => {
        const r = commentsAt("svelte", FILE, 11);
        expect(r?.lineComment).toBeUndefined();
        expect(r?.blockComment).toEqual(["/*", "*/"]);
    });

    it("gives svelte's markup an HTML comment", () => {
        expect(commentsAt("svelte", FILE, 7)?.blockComment).toEqual(["<!--", "-->"]);
    });

    // Everything else already has a configuration from its own contribution;
    // null means "don't touch what Monaco already knows".
    it("declines to answer for other languages", () => {
        expect(commentsAt("typescript", "const a = 1;", 1)).toBeNull();
        expect(commentsAt("go", "package main", 1)).toBeNull();
    });
});
