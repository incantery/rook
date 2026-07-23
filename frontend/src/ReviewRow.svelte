<!-- One review hunk as a quickfix row — CONTENT only; QuickfixPanel owns the
     interactive wrapper, cursor, and keyboard. Wide one-line format for the
     bottom strip (vim's quickfix shape): glyph · path:line · category · risk.
     Resolves its own data from the app store by id, so the generic list never
     holds stale copies. -->
<script lang="ts">
    import {app} from "./state.svelte";

    let {id}: {id: number; focused: boolean; open: boolean} = $props();

    // Ring vocabulary (the design's three glances): hollow = pending your
    // eyes, filled = reviewed (the fill color carries the verdict), pulsing
    // accent = triage in flight. Literal class strings — Tailwind scans
    // source (never `border-${tone}`).
    const RING: Record<string, string> = {
        proposed: "border-lo",
        approved: "border-grn bg-grn/25",
        rejected: "border-red bg-red/25",
        deferred: "border-amber bg-amber/25",
        pending: "animate-pulse border-acc",
    };
    /** reviewed rows strike their path and recede — done is quiet */
    const DONE = new Set(["approved", "rejected", "deferred"]);

    const t = $derived(app.reviewHunks.find((h) => h.id === id));
</script>

{#if t}
    <span
        data-state={t.state}
        class={"size-3 shrink-0 rounded-full border-[1.5px] transition-colors duration-300 " +
            (RING[t.state] ?? "border-lo")}
    ></span>
    <span
        class={"shrink-0 truncate font-mono text-[11px] " +
            (DONE.has(t.state) ? "text-lo line-through" : "text-fg")}
        >{t.path ?? t.title ?? ""}{#if t.startLine}<span class="text-lo">:{t.startLine}</span
            >{/if}</span
    >
    <span class="min-w-0 flex-1 truncate text-[10px] text-lo">{t.detail?.category ?? ""}</span>
    {#if t.detail?.score?.risk}
        <span class="shrink-0 rounded bg-fg/10 px-1 font-mono text-[9px] text-dim" title="risk"
            >r{t.detail.score.risk}</span
        >
    {/if}
{/if}
