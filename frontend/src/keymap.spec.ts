import {describe, expect, it} from "vitest";
import {buildContextMap, CONTEXT_PREFIX} from "./keymap";

describe("buildContextMap", () => {
    it("starts from the context defaults", () => {
        const m = buildContextMap({});
        for (const [k, v] of CONTEXT_PREFIX) expect(m.get(k)).toBe(v);
    });

    it("overrides and unbinds single-char triggers", () => {
        const m = buildContextMap({"<leader>q": "something.else", "<leader>a": ""});
        expect(m.get("q")).toBe("something.else");
        expect(m.has("a")).toBe(false);
    });

    it("accepts named keys, vim-spelling tolerant", () => {
        const m = buildContextMap({
            "<leader>TAB": "explorer.toggle",
            "<leader>cr": "editor.comment",
            "<leader>Esc": "quickfix.toggle",
        });
        // stored under KeyboardEvent.key values — what dispatch matches on
        expect(m.get("Tab")).toBe("explorer.toggle");
        expect(m.get("Enter")).toBe("editor.comment");
        expect(m.get("Escape")).toBe("quickfix.toggle");
    });

    it("drops what it cannot dispatch yet, keeping the rest", () => {
        const m = buildContextMap({
            gd: "editor.definition", // bare sequence — modal dispatch, later
            "<leader>nosuchkey": "x", // not a named key
            "<leader>o": "explorer.reveal",
        });
        expect(m.get("o")).toBe("explorer.reveal");
        expect(m.has("g")).toBe(false);
    });
});
