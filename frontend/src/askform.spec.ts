import {describe, expect, it} from "vitest";
import {
    canSend,
    enterPicks,
    formQuestion,
    initialCursor,
    initialPicks,
    shapeAnswer,
    toggle,
} from "./askform";

const opts = [{label: "A"}, {label: "B"}, {label: "C"}];

describe("formQuestion", () => {
    it("treats a question with no options as free text", () => {
        const fq = formQuestion({question: "Name it?"});
        expect(fq.freeText).toBe(true);
        expect(fq.options).toEqual([]);
        // the Other row is the only row, and it IS the question
        expect(fq.otherIdx).toBe(0);
        expect(fq.rowCount).toBe(1);
    });

    it("counts the Other row past the last option", () => {
        const fq = formQuestion({question: "?", options: opts});
        expect(fq.freeText).toBe(false);
        expect(fq.otherIdx).toBe(3);
        expect(fq.rowCount).toBe(4);
    });

    it("only multiSelect:true is multi — absent is single", () => {
        expect(formQuestion({question: "?", options: opts}).multi).toBe(false);
        expect(formQuestion({question: "?", options: opts, multiSelect: true}).multi).toBe(true);
    });
});

describe("recommended", () => {
    it("pre-ticks in multi so Enter alone is a complete answer", () => {
        const fq = formQuestion({
            question: "?",
            multiSelect: true,
            options: [{label: "A"}, {label: "B", recommended: true}, {label: "C"}],
        });
        expect([...initialPicks(fq)]).toEqual([1]);
    });

    it("never pre-picks in single — picking there commits, and nobody chose", () => {
        const fq = formQuestion({
            question: "?",
            options: [{label: "A"}, {label: "B", recommended: true}],
        });
        expect(initialPicks(fq).size).toBe(0);
        // it moves the cursor instead
        expect(initialCursor(fq)).toBe(1);
    });

    it("leaves the cursor at the top when nothing is recommended", () => {
        expect(initialCursor(formQuestion({question: "?", options: opts}))).toBe(0);
    });
});

describe("toggle", () => {
    it("adds and removes without mutating the input", () => {
        const before = new Set([0]);
        const on = toggle(before, 1);
        expect([...on]).toEqual([0, 1]);
        expect([...before]).toEqual([0]);
        expect([...toggle(on, 0)]).toEqual([1]);
    });
});

describe("enterPicks", () => {
    it("takes the cursor row when nothing has been touched — the fast path", () => {
        expect([...enterPicks(new Set(), false, 2)]).toEqual([2]);
    });

    it("sends nothing once the user has toggled — that is 'none of these'", () => {
        expect([...enterPicks(new Set(), true, 2)]).toEqual([]);
    });

    it("respects existing picks over the cursor", () => {
        expect([...enterPicks(new Set([0, 1]), true, 2)]).toEqual([0, 1]);
        // untouched but pre-ticked (a recommendation) still wins
        expect([...enterPicks(new Set([1]), false, 2)]).toEqual([1]);
    });
});

describe("shapeAnswer", () => {
    const fq = formQuestion({question: "Which?", header: "Pick", options: opts});

    it("answers in labels, ordered by row, not by click order", () => {
        expect(shapeAnswer(fq, new Set([2, 0]), "")).toEqual({
            question: "Which?",
            header: "Pick",
            selected: ["A", "C"],
        });
    });

    it("carries trimmed free text and omits it when blank", () => {
        expect(shapeAnswer(fq, new Set([0]), "  my own words  ").other).toBe("my own words");
        expect(shapeAnswer(fq, new Set([0]), "   ")).not.toHaveProperty("other");
    });

    it("omits an absent header", () => {
        const bare = formQuestion({question: "?", options: opts});
        expect(shapeAnswer(bare, new Set([0]), "")).not.toHaveProperty("header");
    });

    it("emits an empty selection rather than inventing one", () => {
        expect(shapeAnswer(fq, new Set(), "").selected).toEqual([]);
    });

    it("drops indexes no option answers to", () => {
        expect(shapeAnswer(fq, new Set([0, 99]), "").selected).toEqual(["A"]);
    });

    it("answers a free-text question with its text alone", () => {
        const ft = formQuestion({question: "Name it?"});
        expect(shapeAnswer(ft, new Set(), "rookctl")).toEqual({
            question: "Name it?",
            selected: [],
            other: "rookctl",
        });
    });
});

describe("canSend", () => {
    it("needs words in a free-text question", () => {
        const ft = formQuestion({question: "Name it?"});
        expect(canSend(ft, new Set(), "  ")).toBe(false);
        expect(canSend(ft, new Set(), "x")).toBe(true);
    });

    it("lets an empty multi through — 'none of these' is an answer", () => {
        const fq = formQuestion({question: "?", multiSelect: true, options: opts});
        expect(canSend(fq, new Set(), "")).toBe(true);
    });

    it("needs a pick or words in a single-select", () => {
        const fq = formQuestion({question: "?", options: opts});
        expect(canSend(fq, new Set(), "")).toBe(false);
        expect(canSend(fq, new Set([1]), "")).toBe(true);
        expect(canSend(fq, new Set(), "words")).toBe(true);
    });
});
