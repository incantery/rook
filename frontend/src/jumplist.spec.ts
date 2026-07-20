import {describe, expect, it} from "vitest";
import {Jumplist} from "./jumplist";

const loc = (path: string, line = 1) => ({path, line, col: 1});

describe("Jumplist", () => {
    it("back saves the live position so forward returns to it", () => {
        const j = new Jumplist();
        j.push(loc("a.go", 10)); // jumped away from a.go:10
        expect(j.back(loc("b.go", 5))).toEqual(loc("a.go", 10));
        expect(j.forward()).toEqual(loc("b.go", 5));
        expect(j.forward()).toBeNull();
    });

    it("walks a chain of jumps both ways", () => {
        const j = new Jumplist();
        j.push(loc("a.go")); // a → b
        j.push(loc("b.go")); // b → c
        expect(j.back(loc("c.go"))).toEqual(loc("b.go"));
        expect(j.back(loc("b.go"))).toEqual(loc("a.go"));
        expect(j.back(loc("a.go"))).toBeNull(); // oldest
        expect(j.forward()).toEqual(loc("b.go"));
        expect(j.forward()).toEqual(loc("c.go"));
        expect(j.forward()).toBeNull(); // newest
    });

    it("a new jump from mid-history discards the forward tail", () => {
        const j = new Jumplist();
        j.push(loc("a.go"));
        j.push(loc("b.go"));
        j.back(loc("c.go")); // at b
        j.push(loc("b.go")); // new jump from b — c is gone
        expect(j.forward()).toBeNull();
        expect(j.back(loc("d.go"))).toEqual(loc("b.go"));
        expect(j.back(loc("b.go"))).toEqual(loc("a.go"));
    });

    it("back on an empty list is a labeled no-op", () => {
        const j = new Jumplist();
        expect(j.back(loc("a.go"))).toBeNull();
        expect(j.forward()).toBeNull();
    });

    it("standing on the newest entry steps past it, not onto it", () => {
        const j = new Jumplist();
        j.push(loc("a.go"));
        j.push(loc("b.go", 7));
        // live position IS b.go:7 (same-file jump landed there)
        expect(j.back(loc("b.go", 7))).toEqual(loc("a.go"));
    });

    it("consecutive duplicate pushes collapse", () => {
        const j = new Jumplist();
        j.push(loc("a.go", 3));
        j.push(loc("a.go", 3));
        expect(j.back(loc("b.go"))).toEqual(loc("a.go", 3));
        expect(j.back(loc("a.go", 3))).toBeNull();
    });

    it("clear forgets everything", () => {
        const j = new Jumplist();
        j.push(loc("a.go"));
        j.clear();
        expect(j.back(loc("b.go"))).toBeNull();
    });

    it("null current position still walks history", () => {
        const j = new Jumplist();
        j.push(loc("a.go"));
        expect(j.back(null)).toEqual(loc("a.go"));
    });
});
