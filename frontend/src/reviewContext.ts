// The review work-type as a quickfix context: rows/header/hero are the
// review-owned components, the verbs are QfActions, and the data stays in the
// app store (reviewRoot/reviewHunks). App.svelte builds this once with its
// host-facing dependencies; quickfix.svelte.ts stays generic.

import ReviewGateHeader from "./ReviewGateHeader.svelte";
import ReviewItem from "./ReviewItem.svelte";
import ReviewRow from "./ReviewRow.svelte";
import type {HostAPI} from "./hostapi";
import {qf, type QfContext} from "./quickfix.svelte";
import {app} from "./state.svelte";

export function makeReviewContext(deps: {
    api: HostAPI;
    prepare(): Promise<void>;
    dispose(id: number, state: string): Promise<void>;
    openInEditor(id: number): void;
}): QfContext {
    return {
        id: "review",
        title: "Review",
        ids: () => app.reviewHunks.map((h) => h.id),
        Row: ReviewRow,
        Header: ReviewGateHeader,
        Detail: ReviewItem,
        detailProps: () => ({api: deps.api, workspace: app.workspace}),
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
        hint: "a·r·d disposition · o editor",
        empty: "No review here yet. Prepare one to review the unstaged changes as hunks.",
        prepare: {
            label: () => (app.reviewRoot ? "↻" : "Prepare"),
            run: deps.prepare,
        },
    };
}
