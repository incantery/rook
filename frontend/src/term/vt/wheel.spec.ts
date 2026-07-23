import {describe, expect, it} from "vitest";
import {WheelGauge} from "./wheel";

describe("WheelGauge", () => {
    it("accumulates small trackpad deltas into whole lines", () => {
        const g = new WheelGauge();
        // 10 events of 4px at 16px cells = 40px = 2 lines total, not 10
        let total = 0;
        for (let i = 0; i < 10; i++) total += g.lines(4, 0, 16);
        expect(total).toBe(2);
    });

    it("a discrete wheel notch is one line", () => {
        const g = new WheelGauge();
        expect(g.lines(16, 0, 16)).toBe(1);
        expect(g.lines(-16, 0, 16)).toBe(-1);
    });

    it("a violent flick converts proportionally", () => {
        const g = new WheelGauge();
        expect(g.lines(160, 0, 16)).toBe(10);
    });

    it("direction reversal drops the leftover", () => {
        const g = new WheelGauge();
        g.lines(12, 0, 16); // 12px banked, no line yet
        expect(g.lines(-16, 0, 16)).toBe(-1); // full notch up, not offset by the bank
    });

    it("line-mode deltas map directly", () => {
        const g = new WheelGauge();
        expect(g.lines(3, 1, 16)).toBe(3);
    });

    it("tiny jitter emits nothing", () => {
        const g = new WheelGauge();
        expect(g.lines(2, 0, 16)).toBe(0);
        expect(g.lines(-2, 0, 16)).toBe(0);
    });
});
