<!-- The review side-pane tenant: the INDEX into a review. One row per hunk
     with a disposition glyph + the derived gate up top. It's the ranked list;
     selecting a hunk opens the bespoke detail (ReviewItem, a center overlay) —
     NOT the Monaco editor. Review state lives on `app` (reviewRoot/hunks), so
     this list and the detail overlay are two views over one source. Roving
     j/k cursor; a/r/d quick-disposition from the list; Enter/click opens the
     detail. Styled with inline Tailwind (README decision 7). -->
<script lang="ts">
    import {app} from "./state.svelte";
    import type {ReviewGate, RookTask} from "./hostapi";

    let {
        active,
        busy,
        onPrepare,
        onSelect,
        onDispose,
    }: {
        active: boolean;
        busy: boolean;
        onPrepare: () => void;
        onSelect: (id: number) => void;
        onDispose: (id: number, state: string) => void;
    } = $props();

    const GLYPH: Record<string, string> = {
        proposed: "○",
        approved: "✓",
        rejected: "✗",
        deferred: "»",
        pending: "…",
    };
    const TONE: Record<string, string> = {
        proposed: "text-lo",
        approved: "text-grn",
        rejected: "text-red",
        deferred: "text-amber",
        pending: "text-acc",
    };

    let cursor = $state<number | null>(null);
    let listEl: HTMLDivElement | undefined;

    const rows = $derived<RookTask[]>(app.reviewHunks);
    const gate = $derived<ReviewGate | undefined>(app.reviewRoot?.gate);
    const cursorAt = $derived(rows.findIndex((r) => r.id === cursor));

    // keep the cursor pointing at a live row across reloads
    $effect(() => {
        if (rows.length > 0 && !rows.some((r) => r.id === cursor)) cursor = rows[0].id;
    });
    $effect(() => {
        if (active) listEl?.focus();
    });

    function moveTo(i: number): void {
        if (rows.length === 0) return;
        const ni = Math.min(Math.max(i, 0), rows.length - 1);
        cursor = rows[ni].id;
        queueMicrotask(() =>
            listEl?.querySelector('[data-cursor="1"]')?.scrollIntoView({block: "nearest"}),
        );
    }

    function onKey(e: KeyboardEvent): void {
        if (e.metaKey || e.ctrlKey || e.altKey) return;
        switch (e.key) {
            case "j":
            case "ArrowDown":
                moveTo(cursorAt + 1);
                break;
            case "k":
            case "ArrowUp":
                moveTo(cursorAt - 1);
                break;
            case "g":
                moveTo(0);
                break;
            case "G":
                moveTo(rows.length - 1);
                break;
            case "l":
            case "Enter":
                if (cursor != null) onSelect(cursor);
                break;
            case "a":
                if (cursor != null) onDispose(cursor, "approved");
                break;
            case "r":
                if (cursor != null) onDispose(cursor, "rejected");
                break;
            case "d":
                if (cursor != null) onDispose(cursor, "deferred");
                break;
            default:
                return;
        }
        e.preventDefault();
        e.stopPropagation();
    }

    function gateText(g: ReviewGate): string {
        if (g.ready) return `ready for ${g.verb || "next steps"} · ${g.total} hunks`;
        return `${g.blocking} of ${g.total} hunks blocking`;
    }

    function fileOf(t: RookTask): string {
        return t.path ?? t.title ?? "";
    }
</script>

<div class="flex h-full min-h-0 flex-col text-fg">
    <!-- header: the gate + prepare/refresh -->
    <div class="flex shrink-0 items-center gap-2 border-b border-line/15 px-3 py-2">
        {#if gate}
            <span
                class={"flex items-center gap-1.5 font-mono text-[10px] " +
                    (gate.ready ? "text-grn" : "text-lo")}
            >
                <span class={"size-1.5 rounded-full " + (gate.ready ? "bg-grn" : "bg-amber")}></span>
                {gateText(gate)}
            </span>
        {:else}
            <span class="font-mono text-[10px] text-lo">no review yet</span>
        {/if}
        <span class="flex-1"></span>
        <button
            class="cursor-pointer rounded-lg border border-line/15 bg-fg/5 px-2.5 py-1 text-[11px] font-semibold text-fg hover:border-acc disabled:opacity-50"
            disabled={busy}
            aria-label="prepare review"
            title="prepare / re-run the unstaged review (reconciles dispositions)"
            onclick={onPrepare}>{app.reviewRoot ? "↻" : "Prepare"}</button
        >
    </div>

    <!-- the list is the only scroll region -->
    <div
        id="review-hunks"
        class="min-h-0 flex-1 overflow-y-auto py-1 outline-none"
        tabindex="-1"
        role="listbox"
        aria-label="review hunks"
        bind:this={listEl}
        onkeydown={onKey}
    >
        {#each rows as t (t.id)}
            {@const focused = t.id === cursor}
            {@const open = t.id === app.reviewSelectedId}
            <div
                class={"flex cursor-pointer items-center gap-2 px-3 py-1.5 " +
                    (focused ? "bg-acc/15" : "hover:bg-fg/[0.04]") +
                    (open ? " border-l-2 border-acc" : " border-l-2 border-transparent")}
                role="option"
                aria-selected={focused}
                tabindex="-1"
                data-cursor={focused ? "1" : "0"}
                onclick={() => {
                    cursor = t.id;
                    onSelect(t.id);
                }}
                onkeydown={() => {}}
            >
                <span class={"w-3 shrink-0 text-center text-xs " + (TONE[t.state] ?? "text-lo")}
                    >{GLYPH[t.state] ?? "○"}</span
                >
                <div class="min-w-0 flex-1">
                    <div class="flex items-baseline gap-1.5">
                        <span class="min-w-0 flex-1 truncate font-mono text-[11px] text-fg"
                            >{fileOf(t)}</span
                        >
                        {#if t.startLine}
                            <span class="shrink-0 font-mono text-[10px] text-lo">:{t.startLine}</span>
                        {/if}
                    </div>
                    {#if t.detail?.category}
                        <div class="truncate text-[10px] text-lo">{t.detail.category}</div>
                    {/if}
                </div>
                {#if t.detail?.score?.risk}
                    <span
                        class="shrink-0 rounded bg-fg/10 px-1 font-mono text-[9px] text-dim"
                        title="risk">r{t.detail.score.risk}</span
                    >
                {/if}
            </div>
        {/each}

        {#if rows.length === 0}
            <div class="px-3 py-6 text-center text-xs leading-relaxed text-lo">
                No review here yet.<br />Prepare one to review the unstaged changes as hunks.
            </div>
        {/if}
    </div>

    <!-- footer hint -->
    <div
        class="flex shrink-0 items-center gap-2 border-t border-line/15 px-3 py-2 font-mono text-[10px] text-lo"
    >
        <span class="whitespace-nowrap">j/k move · ↵ open</span>
        <span class="flex-1"></span>
        <span class="whitespace-nowrap">a·r·d disposition</span>
    </div>
</div>
