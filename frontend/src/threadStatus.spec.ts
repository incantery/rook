import {describe, expect, it} from "vitest";
import {glyphClass, statusMeta, threadStatus, STATUS_ORDER} from "./term/threadview";
import type {ThreadInfo} from "./hostapi";

/** the fields threadStatus actually reads, and nothing else */
function th(over: Partial<ThreadInfo> = {}): ThreadInfo {
    return {
        id: 1,
        workspace: "ws",
        path: "a.go",
        startLine: 1,
        endLine: 1,
        side: "modified",
        blobSha: "s",
        anchorText: "x",
        state: "open",
        comments: [{id: 1, author: "user", body: "why?", created: ""}],
        currentStart: 1,
        currentEnd: 1,
        ...over,
    } as ThreadInfo;
}

describe("threadStatus", () => {
    it("splits 'open' into whose move it actually is", () => {
        // This is the whole point: stored state says "open" for both, and
        // they are opposite situations for the reviewer.
        expect(threadStatus(th())).toBe("waiting");
        expect(
            threadStatus(
                th({
                    comments: [
                        {id: 1, author: "user", body: "why?", created: ""},
                        {id: 2, author: "agent", body: "because", created: ""},
                    ],
                }),
            ),
        ).toBe("answered");
    });

    it("reports a failed delivery, which stored state cannot express", () => {
        // an open thread that nobody was ever told about
        expect(threadStatus(th({deliverError: "spawn failed"}))).toBe("failed");
    });

    it("never calls a resolved thread failed — a stale error can't resurrect it", () => {
        expect(threadStatus(th({state: "resolved", deliverError: "spawn failed"}))).toBe(
            "resolved",
        );
    });

    it("ranks a failure above everything: nothing is happening and only you can restart it", () => {
        const order = (["failed", "pending", "answered", "waiting", "resolved"] as const).map(
            (s) => STATUS_ORDER[s],
        );
        expect(order).toEqual([...order].sort((a, b) => a - b));
        expect(STATUS_ORDER.failed).toBeLessThan(STATUS_ORDER.pending);
        // and a thread the agent answered outranks one still waiting —
        // your move beats its move
        expect(STATUS_ORDER.answered).toBeLessThan(STATUS_ORDER.waiting);
    });

    it("gives every status a distinct label and tone", () => {
        const all = ["failed", "pending", "waiting", "answered", "resolved"] as const;
        const labels = all.map((s) => statusMeta(s).label);
        const tones = all.map((s) => statusMeta(s).tone);
        expect(new Set(labels).size).toBe(all.length);
        expect(new Set(tones).size).toBe(all.length);
    });
});

describe("glyphClass", () => {
    it("takes the most-demanding status in the group", () => {
        const group = [th({id: 1}), th({id: 2, deliverError: "nope"})];
        expect(glyphClass(group)).toContain("thread-glyph-failed");
    });

    it("carries the outdated modifier from ANY thread on the line", () => {
        expect(glyphClass([th({id: 1}), th({id: 2, outdated: true})])).toContain(
            "thread-glyph-outdated",
        );
    });

    it("a resolved-only line still gets its own class, not a fallthrough", () => {
        expect(glyphClass([th({state: "resolved"})])).toContain("thread-glyph-resolved");
    });
});
