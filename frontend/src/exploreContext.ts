// The active investigation's breadcrumb trail as a quickfix context — the
// third tenant. Rows are the explore root's children (visited code
// anchors, host-durable); `o` jumps the editor there through the openFile
// ladder, `s` stars/unstars the aha spots. The trail fills itself as you
// navigate, so this context is a window onto history, not a work list.

import ExploreRow from "./ExploreRow.svelte";
import {app} from "./state.svelte";
import type {QfContext} from "./quickfix.svelte";

export function makeExploreContext(deps: {
    open(path: string, line: number, col: number): void;
    star(id: number): Promise<void>;
}): QfContext {
    return {
        id: "explore",
        get title() {
            const t = app.exploreTask;
            return t ? `Trail — ${t.title ?? "investigation"}` : "Trail";
        },
        ids: () => app.exploreTask?.children?.map((c) => c.id) ?? [],
        Row: ExploreRow,
        Header: null,
        Detail: null,
        actions: [
            {
                key: "o",
                label: "◇ Open",
                tone: "acc",
                advance: false,
                run: (id) => {
                    const b = app.exploreTask?.children?.find((c) => c.id === id);
                    if (!b?.path) return;
                    deps.open(b.path, b.startLine ?? 1, b.detail?.col ?? 1);
                },
            },
            {
                key: "s",
                label: "★ Star",
                tone: "amber",
                advance: false,
                run: (id) => deps.star(id),
            },
        ],
        hint: "o open · s star",
        empty: "No breadcrumbs yet — navigate while an investigation is open.",
    };
}
