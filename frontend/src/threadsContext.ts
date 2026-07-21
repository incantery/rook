// Threads as a quickfix context — the surface that replaced their bespoke
// side panel.
//
// The panel was a web form's cousin: a card list with its own selection, its
// own expand/collapse, and its own idea of what "current" meant. A thread is a
// work item like a review hunk, a grep hit or a reference, so it reads through
// the ONE traversal muscle memory (` t opens the list, j/k moves, o opens it).
// quickfix.svelte.ts said as much from the start — "attention/threads/issues
// are the obvious next tenants".
//
// Rows resolve from app.threads by id; the list never holds copies.

import ThreadRow from "./ThreadRow.svelte";
import {app} from "./state.svelte";
import type {QfContext} from "./quickfix.svelte";
import {STATE_ORDER} from "./term/threadview";

export function makeThreadsContext(deps: {
    /** open the thread as a read-only buffer (the ,t destination) */
    open(id: number): void;
    /** jump the editor to the anchored code */
    source(id: number): void;
    resolve(id: number): Promise<void>;
    reopen(id: number): Promise<void>;
    submit(): Promise<void>;
    flash(msg: string): void;
}): QfContext {
    const byId = (id: number) => app.threads.find((t) => t.id === id);
    return {
        id: "threads",
        get title() {
            const open = app.threads.filter((t) => t.state !== "resolved").length;
            return open > 0 ? `Threads (${open} open)` : "Threads";
        },
        // Most-demanding first, then newest — the same rank the gutter glyph
        // uses, so the list agrees with the margin.
        ids: () =>
            [...app.threads]
                .sort(
                    (a, b) =>
                        STATE_ORDER[a.state] - STATE_ORDER[b.state] ||
                        a.path.localeCompare(b.path) ||
                        a.currentStart - b.currentStart,
                )
                .map((t) => t.id),
        Row: ThreadRow,
        Header: null,
        Detail: null,
        actions: [
            {
                key: "o",
                label: "◇ Open",
                tone: "acc",
                advance: false,
                run: (id) => deps.open(id),
            },
            {
                key: "s",
                label: "↦ Source",
                tone: "acc",
                advance: false,
                run: (id) => deps.source(id),
            },
            {
                key: "x",
                label: "✓ Resolve",
                tone: "grn",
                advance: true,
                run: async (id) => {
                    const t = byId(id);
                    if (!t) return;
                    if (t.state === "resolved") await deps.reopen(id);
                    else await deps.resolve(id);
                },
            },
        ],
        hint: "o open · s source · x resolve",
        empty: "No threads here — ,c leaves a note, ,? asks the agent.",
        // the batch send, in the place every other context puts its verb
        prepare: {
            label: () => {
                const pending = app.threads.filter((t) => t.state === "pending").length;
                return pending > 0 ? `submit ${pending}` : "";
            },
            run: () => deps.submit(),
        },
    };
}
