// The location list as a quickfix context — the second tenant, and the first
// list-shaped surface fed by the editor island. Two producers fill it (vim:
// the last one owns the list): gr's references and the grep picker's ⌃Q.
// Rows are grep-shaped hits in the app store (app.refHits); the one verb
// jumps the editor there through the openFile ladder. External hits
// (stdlib/deps) are labeled dead ends until the file surface can serve
// outside-workspace paths.

import RefRow from "./RefRow.svelte";
import type {LspLocation} from "./hostapi";
import type {RefHit} from "./state.svelte";
import {app} from "./state.svelte";
import type {QfContext} from "./quickfix.svelte";

export function toRefHits(locations: LspLocation[]): RefHit[] {
    return locations.map((l, i) => ({
        id: i + 1,
        path: l.path,
        line: l.startLine,
        col: l.startCol,
        text: l.lineText ?? "",
        external: l.external,
    }));
}

export function makeRefsContext(deps: {
    open(path: string, line: number, col: number): void;
    flash(msg: string): void;
}): QfContext {
    return {
        id: "refs",
        get title() {
            return app.refTitle;
        },
        ids: () => app.refHits.map((h) => h.id),
        Row: RefRow,
        Header: null,
        Detail: null,
        actions: [
            {
                key: "o",
                label: "◇ Open",
                tone: "acc",
                advance: false,
                run: (id) => {
                    const h = app.refHits.find((r) => r.id === id);
                    if (!h) return;
                    if (h.external) {
                        deps.flash(`outside the workspace: ${h.path}:${h.line}`);
                        return;
                    }
                    deps.open(h.path, h.line, h.col);
                },
            },
        ],
        hint: "o open",
        empty: "Nothing here — gr on a symbol or ⌃Q in grep fills this list.",
    };
}
