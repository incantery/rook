import {describe, expect, it} from "vitest";

import {build, outstanding, pickerOptions, summarize} from "./agentview";
import type {TranscriptRecord} from "./hostapi";

let off = 0;
const rec = (r: Partial<TranscriptRecord>): TranscriptRecord =>
    ({
        offset: (off += 100),
        type: "assistant",
        ts: "2026-07-15T12:00:00.000Z",
        ...r,
    }) as TranscriptRecord;

const prompt = (text: string, ts?: string) =>
    rec({type: "user", ts, blocks: [{type: "text", text}]});
const say = (text: string, ts?: string) =>
    rec({type: "assistant", ts, blocks: [{type: "text", text}]});
const call = (id: string, name: string, input?: unknown, ts?: string) =>
    rec({type: "assistant", ts, blocks: [{type: "tool_use", id, name, input}]});
const result = (toolUseId: string, content: string, ts?: string, isError?: boolean) =>
    rec({type: "user", ts, blocks: [{type: "tool_result", toolUseId, content, isError}]});

describe("build", () => {
    it("renders a turn: prompt, text, tool call and its result", () => {
        const items = build([
            prompt("run the tests"),
            say("On it."),
            call("t1", "Bash", {command: "go test ./..."}, "2026-07-15T12:00:00.000Z"),
            result("t1", "ok", "2026-07-15T12:00:02.500Z"),
            rec({type: "system", subtype: "turn_duration", durationMs: 4200}),
        ]);

        expect(items.map((i) => i.kind)).toEqual(["prompt", "say", "tool", "turn"]);
        expect(items[0]).toMatchObject({kind: "prompt", text: "run the tests"});
        expect(items[1]).toMatchObject({kind: "say", text: "On it."});

        const tool = items[2];
        if (tool.kind !== "tool") throw new Error("expected a tool item");
        expect(tool.call.name).toBe("Bash");
        expect(tool.call.result).toEqual({content: "ok", isError: false});
        // the gap between a call and its result is how long it took
        expect(tool.call.ms).toBe(2500);
        expect(outstanding(tool.call)).toBe(false);

        expect(items[3]).toMatchObject({kind: "turn", ms: 4200});
    });

    // The signal the whole thing exists for.
    it("leaves a call with no result outstanding", () => {
        const items = build([call("t1", "AskUserQuestion", {questions: [{question: "Which?"}]})]);
        const tool = items[0];
        if (tool.kind !== "tool") throw new Error("expected a tool item");
        expect(outstanding(tool.call)).toBe(true);
        expect(tool.call.ms).toBe(null);
    });

    it("pairs results to their own call, not the nearest one", () => {
        const items = build([
            call("t1", "Read", {file_path: "/a"}),
            call("t2", "Bash", {command: "ls"}),
            result("t2", "a b c"),
        ]);
        const tools = items.filter((i) => i.kind === "tool");
        expect(tools).toHaveLength(2);
        if (tools[0].kind !== "tool" || tools[1].kind !== "tool") throw new Error("kind");
        expect(tools[0].call.name).toBe("Read");
        expect(outstanding(tools[0].call)).toBe(true); // still waiting
        expect(tools[1].call.result?.content).toBe("a b c");
    });

    // A window boundary always splits some pair; the result must not vanish.
    it("shows a result whose call is older than the window", () => {
        const items = build([result("t-old", "output from before")]);
        expect(items).toHaveLength(1);
        const tool = items[0];
        if (tool.kind !== "tool") throw new Error("expected a tool item");
        expect(tool.call.name).toBe("");
        expect(tool.call.result?.content).toBe("output from before");
    });

    it("marks tool errors", () => {
        const items = build([
            call("t1", "Bash", {command: "false"}),
            result("t1", "boom", undefined, true),
        ]);
        const tool = items[0];
        if (tool.kind !== "tool") throw new Error("kind");
        expect(tool.call.result).toEqual({content: "boom", isError: true});
    });

    it("drops thinking: claude writes a signature and no text", () => {
        const items = build([rec({blocks: [{type: "thinking"}, {type: "text", text: "said"}]})]);
        expect(items.map((i) => i.kind)).toEqual(["say"]);
    });

    // Fail open: a newer claude must render as a gap, never a crash.
    it("skips unknown record and block types", () => {
        const items = build([
            rec({type: "bridge-session"}),
            rec({
                type: "assistant",
                blocks: [{type: "future_block"}, {type: "text", text: "kept"}],
            }),
            rec({type: "system", subtype: "away_summary"}),
        ]);
        expect(items.map((i) => i.kind)).toEqual(["say"]);
    });

    it("survives empty and malformed-ish input", () => {
        expect(build([])).toEqual([]);
        expect(build([rec({blocks: []})])).toEqual([]);
        expect(build([rec({})])).toEqual([]);
        expect(build([rec({blocks: [{type: "text", text: ""}]})])).toEqual([]);
        // a tool_use with no id cannot be paired, so it is not a call
        expect(build([rec({blocks: [{type: "tool_use", name: "Bash"}]})])).toEqual([]);
    });

    it("keys items uniquely so a poll cannot reorder them", () => {
        const items = build([
            rec({
                blocks: [
                    {type: "text", text: "a"},
                    {type: "tool_use", id: "t1", name: "Bash"},
                ],
            }),
            say("b"),
        ]);
        const keys = items.map((i) => i.key);
        expect(new Set(keys).size).toBe(keys.length);
    });
});

describe("summarize", () => {
    it("picks the field that means something, per tool", () => {
        expect(summarize("Bash", {command: "go test ./...", description: "x"})).toBe(
            "go test ./...",
        );
        expect(summarize("Read", {file_path: "/a/b.go", offset: 1})).toBe("/a/b.go");
        expect(summarize("Edit", {file_path: "/a/b.go", old_string: "x"})).toBe("/a/b.go");
        expect(summarize("Grep", {pattern: "TODO", path: "/x"})).toBe("TODO");
        expect(summarize("WebFetch", {url: "https://x.dev", prompt: "y"})).toBe("https://x.dev");
    });

    it("shows an AskUserQuestion's question", () => {
        expect(
            summarize("AskUserQuestion", {questions: [{question: "Which framing?", options: []}]}),
        ).toBe("Which framing?");
    });

    it("guesses for an unknown tool, and gives up quietly", () => {
        expect(summarize("SomeNewTool", {thing: "hello"})).toBe("hello");
        expect(summarize("SomeNewTool", {n: 4, ok: true})).toBe("");
        expect(summarize("SomeNewTool", {huge: "x".repeat(500)})).toBe("");
    });

    it("never throws on whatever claude sent", () => {
        expect(summarize("Bash", undefined)).toBe("");
        expect(summarize("Bash", null)).toBe("");
        expect(summarize("Bash", "a string")).toBe("");
        expect(summarize("Bash", 42)).toBe("");
        expect(summarize("Bash", {})).toBe("");
        expect(summarize("AskUserQuestion", {questions: []})).toBe("");
        expect(summarize("AskUserQuestion", {questions: "nope"})).toBe("");
    });
});

describe("pickerOptions", () => {
    it("reads the options rook refuses to type into", () => {
        expect(
            pickerOptions({
                questions: [
                    {
                        question: "Which?",
                        options: [{label: "A", description: "does a"}, {label: "B"}],
                    },
                ],
            }),
        ).toEqual([
            {label: "A", description: "does a"},
            {label: "B", description: undefined},
        ]);
    });

    it("is empty for anything that is not a picker", () => {
        expect(pickerOptions({command: "ls"})).toEqual([]);
        expect(pickerOptions(null)).toEqual([]);
        expect(pickerOptions(undefined)).toEqual([]);
        expect(pickerOptions({questions: [{question: "q"}]})).toEqual([]);
        expect(pickerOptions({questions: [{options: [{noLabel: 1}, "x", null]}]})).toEqual([]);
    });
});
