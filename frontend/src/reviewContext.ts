// The review work-type as a quickfix context: rows/header/hero are the
// review-owned components, the verbs are QfActions, and the data stays in the
// app store (reviewRoot/reviewHunks). App.svelte builds this once with its
// host-facing dependencies; quickfix.svelte.ts stays generic.

import ReviewGateHeader from "./ReviewGateHeader.svelte";
import ReviewItem from "./ReviewItem.svelte";
import ReviewRow from "./ReviewRow.svelte";
import type {HostAPI, RookTask} from "./hostapi";
import {qf, type QfContext} from "./quickfix.svelte";
import {app} from "./state.svelte";

/** Where a hunk sorts in the list: risk desc, understand as the tiebreak,
 *  unscored sinking to the bottom (the stable sort keeps diff order among
 *  equals). Triage re-sorts the list the instant scores land — the row flip
 *  animation makes that reordering the "it just organized my attention" beat.
 *  risk is untouched by disposition, so the order holds steady while you work
 *  the list top-down; approving the top hunk never reshuffles the rest. */
function riskRank(t: RookTask): number {
    const s = t.detail?.score;
    if (!s || s.risk == null) return -1;
    return s.risk * 100 + (s.understand ?? 0);
}

export function makeReviewContext(deps: {
    api: HostAPI;
    prepare(): Promise<void>;
    dispose(id: number, state: string): Promise<void>;
    openInEditor(id: number): void;
    triage(): Promise<void>;
}): QfContext {
    return {
        id: "review",
        title: "Review",
        ids: () => [...app.reviewHunks].sort((a, b) => riskRank(b) - riskRank(a)).map((h) => h.id),
        Row: ReviewRow,
        Header: ReviewGateHeader,
        Detail: ReviewItem,
        detailProps: () => ({api: deps.api, workspace: app.workspace, onTriage: deps.triage}),
        actions: [
            {
                key: "a",
                label: "✓ Approve",
                tone: "grn",
                advance: true,
                run: (id) => deps.dispose(id, "approved"),
            },
            {
                key: "r",
                label: "✗ Reject",
                tone: "red",
                advance: true,
                run: (id) => deps.dispose(id, "rejected"),
            },
            {
                key: "d",
                label: "» Defer",
                tone: "amber",
                advance: true,
                run: (id) => deps.dispose(id, "deferred"),
            },
            {
                key: "o",
                label: "◇ Editor",
                tone: "acc",
                advance: false,
                run: (id) => {
                    // the editor replaces the hero as the evidence surface —
                    // close the overlay so the diff pane is actually visible
                    qf.detailOpen = false;
                    deps.openInEditor(id);
                },
            },
        ],
        hint: [
            ["a", "approve"],
            ["r", "reject"],
            ["d", "defer"],
            ["o", "editor"],
        ],
        empty: "No review here yet. Prepare one to review the unstaged changes as hunks.",
        prepare: {
            label: () => (app.reviewRoot ? "↻" : "Prepare"),
            run: deps.prepare,
        },
    };
}
