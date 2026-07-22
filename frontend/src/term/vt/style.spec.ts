import {describe, expect, it} from "vitest";
import {Attr} from "./frame";
import type {Span} from "./grid";
import {cssColor, escapeHtml, spanHtml, spanStyle} from "./style";

const COLOR_SET = 0x80000000;
const COLOR_RGB = 0x40000000;
const palette = (n: number) => (COLOR_SET | n) >>> 0;
const rgb = (r: number, g: number, b: number) =>
    (COLOR_SET | COLOR_RGB | (r << 16) | (g << 8) | b) >>> 0;

function span(text: string, over: Partial<Span> = {}): Span {
    return {text, fg: 0, bg: 0, attr: 0, ...over};
}

describe("escapeHtml", () => {
    it("escapes the HTML-significant characters", () => {
        expect(escapeHtml("a<b>&c")).toBe("a&lt;b&gt;&amp;c");
    });
    it("leaves terminal box-drawing and unicode alone", () => {
        expect(escapeHtml("┌─┐ 世界")).toBe("┌─┐ 世界");
    });
});

describe("cssColor", () => {
    it("returns empty for the default color", () => {
        expect(cssColor(0)).toBe("");
    });
    it("maps the 16 ANSI colors to theme variables", () => {
        expect(cssColor(palette(1))).toBe("var(--term-ansi-1)");
        expect(cssColor(palette(15))).toBe("var(--term-ansi-15)");
    });
    it("computes the 256-color cube", () => {
        // index 16 is the cube origin -> black
        expect(cssColor(palette(16))).toBe("#000000");
        // index 231 is the cube max -> white
        expect(cssColor(palette(231))).toBe("#ffffff");
    });
    it("computes the grayscale ramp", () => {
        expect(cssColor(palette(232))).toBe("#080808");
        expect(cssColor(palette(255))).toBe("#eeeeee");
    });
    it("renders truecolor as hex", () => {
        expect(cssColor(rgb(255, 100, 0))).toBe("#ff6400");
    });
});

describe("spanStyle", () => {
    it("emits color, weight, and decoration", () => {
        const s = spanStyle(span("x", {fg: palette(2), attr: Attr.Bold | Attr.Underline}));
        expect(s).toContain("color:var(--term-ansi-2)");
        expect(s).toContain("font-weight:bold");
        expect(s).toContain("text-decoration:underline");
    });
    it("swaps fg/bg under reverse video, defaulting to the base colors", () => {
        const s = spanStyle(span("x", {attr: Attr.Reverse}));
        expect(s).toContain("color:var(--term-bg)");
        expect(s).toContain("background:var(--term-fg)");
    });
    it("is empty for a plain default cell", () => {
        expect(spanStyle(span(" "))).toBe("");
    });
});

describe("spanHtml", () => {
    it("wraps escaped text in a styled span", () => {
        expect(spanHtml(span("a<b", {fg: palette(1)}))).toBe(
            '<span style="color:var(--term-ansi-1)">a&lt;b</span>',
        );
    });
    it("renders a plain cell as a bare span", () => {
        expect(spanHtml(span("hi"))).toBe("<span>hi</span>");
    });
    it("replaces hidden text with spaces of the same width", () => {
        expect(spanHtml(span("secret", {attr: Attr.Hidden}))).toBe("<span>      </span>");
    });
});
