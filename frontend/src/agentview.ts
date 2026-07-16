/** Pure view logic for the agent session view: transcript records in,
 *  renderable items out. No DOM, no Svelte, no fetching — so it can be
 *  tested against the shapes claude actually writes (agentview.spec.ts).
 *  Same split as term/threadview.ts.
 *
 *  The whole reason this can exist: the host serves whole records with
 *  tool_use ids intact. Pairing a call to its result is a two-line map here
 *  and was structurally impossible through agentmon's event stream. */

import type {TranscriptBlock, TranscriptRecord} from "./hostapi";

/** A tool call, and its result once the result lands. */
export interface ToolCall {
    id: string;
    /** empty when the call itself is older than this window — the result
     *  still gets shown rather than silently dropped */
    name: string;
    input?: unknown;
    result: {content: string; isError: boolean} | null;
    /** ms between the call and its result; null while outstanding, or when
     *  either end is outside the window */
    ms: number | null;
}

/** One renderable line of the conversation. `offset` is the record's byte
 *  offset — the scrollback cursor, and a stable key. */
export type Item =
    | {kind: "prompt"; key: string; ts: string; text: string}
    | {kind: "say"; key: string; ts: string; text: string; model?: string}
    | {kind: "tool"; key: string; ts: string; call: ToolCall}
    | {kind: "turn"; key: string; ts: string; ms: number};

/** True while the call has no result: the agent is waiting on it. An aged
 *  one is the whole "blocked, waiting on a human" signal — an
 *  AskUserQuestion has no long-running variant, so an outstanding one is a
 *  person who hasn't answered. */
export function outstanding(c: ToolCall): boolean {
    return c.result === null;
}

/** Field to show for a tool call, per tool. Everything here is a guess at
 *  what the tool's arguments mean, so it degrades: an unknown tool falls
 *  back to the first short string in its input, then to nothing. Never
 *  throws — input is whatever claude sent. */
const SUMMARY_FIELD: Record<string, string[]> = {
    Bash: ["command"],
    Read: ["file_path"],
    Write: ["file_path"],
    Edit: ["file_path"],
    NotebookEdit: ["notebook_path"],
    Glob: ["pattern"],
    Grep: ["pattern"],
    Task: ["description"],
    WebFetch: ["url"],
    WebSearch: ["query"],
    Skill: ["skill"],
};

export function summarize(name: string, input: unknown): string {
    if (input === null || typeof input !== "object") return "";
    const obj = input as Record<string, unknown>;

    if (name === "AskUserQuestion") {
        const qs = obj.questions;
        const first = Array.isArray(qs)
            ? (qs[0] as Record<string, unknown> | undefined)
            : undefined;
        const q = first?.question;
        return typeof q === "string" ? q : "";
    }
    for (const f of SUMMARY_FIELD[name] ?? []) {
        const v = obj[f];
        if (typeof v === "string" && v !== "") return v;
    }
    // unknown tool: the first short string field is usually the interesting
    // one, and a wrong guess costs a worse label, not a broken render
    for (const v of Object.values(obj)) {
        if (typeof v === "string" && v !== "" && v.length <= 200) return v;
    }
    return "";
}

/** The options of an AskUserQuestion, for rendering the picker rook refuses
 *  to type into. Empty for anything else, or for input that will not fit the
 *  shape. */
export function pickerOptions(input: unknown): {label: string; description?: string}[] {
    if (input === null || typeof input !== "object") return [];
    const qs = (input as Record<string, unknown>).questions;
    if (!Array.isArray(qs) || qs.length === 0) return [];
    const opts = (qs[0] as Record<string, unknown>)?.options;
    if (!Array.isArray(opts)) return [];
    const out: {label: string; description?: string}[] = [];
    for (const o of opts) {
        if (o === null || typeof o !== "object") continue;
        const rec = o as Record<string, unknown>;
        if (typeof rec.label !== "string") continue;
        out.push({
            label: rec.label,
            description: typeof rec.description === "string" ? rec.description : undefined,
        });
    }
    return out;
}

function ms(a: string | undefined, b: string | undefined): number | null {
    if (!a || !b) return null;
    const t0 = Date.parse(a);
    const t1 = Date.parse(b);
    if (Number.isNaN(t0) || Number.isNaN(t1)) return null;
    return t1 - t0;
}

/** Build the renderable conversation from a window of records.
 *
 *  Records arrive oldest-first. A tool_result attaches to the tool_use it
 *  names, wherever that call appeared; a result whose call is older than the
 *  window becomes its own nameless item rather than vanishing, because a
 *  window boundary always splits some pair.
 *
 *  Thinking blocks are dropped: claude writes them with an encrypted
 *  signature and no text, so there is nothing to render. The wire keeps them
 *  so this can change its mind without a host change.
 *
 *  Unknown record and block types are skipped, never thrown on. */
export function build(records: TranscriptRecord[]): Item[] {
    const items: Item[] = [];
    const calls = new Map<string, {call: ToolCall; ts: string}>();

    const push = (it: Item) => items.push(it);

    for (const rec of records) {
        const ts = rec.ts ?? "";

        if (rec.type === "system") {
            if (rec.subtype === "turn_duration") {
                push({kind: "turn", key: `${rec.offset}`, ts, ms: rec.durationMs ?? 0});
            }
            continue;
        }
        if (rec.type !== "user" && rec.type !== "assistant") continue;

        let i = 0;
        for (const b of rec.blocks ?? []) {
            const key = `${rec.offset}:${i++}`;
            switch (b.type) {
                case "text": {
                    if (!b.text) break;
                    if (rec.type === "user") push({kind: "prompt", key, ts, text: b.text});
                    else push({kind: "say", key, ts, text: b.text, model: rec.model});
                    break;
                }
                case "tool_use": {
                    if (!b.id) break;
                    const call: ToolCall = {
                        id: b.id,
                        name: b.name ?? "",
                        input: b.input,
                        result: null,
                        ms: null,
                    };
                    calls.set(b.id, {call, ts});
                    push({kind: "tool", key, ts, call});
                    break;
                }
                case "tool_result": {
                    attachResult(calls, b, ts, key, push);
                    break;
                }
                // thinking: no text to render. anything else: a newer claude
                // than this build knows about, and a gap beats a crash.
            }
        }
    }
    return items;
}

function attachResult(
    calls: Map<string, {call: ToolCall; ts: string}>,
    b: TranscriptBlock,
    ts: string,
    key: string,
    push: (it: Item) => void,
): void {
    const result = {content: b.content ?? "", isError: b.isError === true};
    const found = b.toolUseId ? calls.get(b.toolUseId) : undefined;
    if (found) {
        found.call.result = result;
        found.call.ms = ms(found.ts, ts);
        return;
    }
    // the call is older than this window — show the result anyway
    push({
        kind: "tool",
        key,
        ts,
        call: {id: b.toolUseId ?? key, name: "", input: undefined, result, ms: null},
    });
}
