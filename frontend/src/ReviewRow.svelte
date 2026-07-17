<!-- One review hunk as a quickfix row — CONTENT only; QuickfixPanel owns the
     interactive wrapper, cursor, and keyboard. Wide one-line format for the
     bottom strip (vim's quickfix shape): glyph · path:line · category · risk.
     Resolves its own data from the app store by id, so the generic list never
     holds stale copies. -->
<script lang="ts">
    import {app} from "./state.svelte";

    let {id}: {id: number; focused: boolean; open: boolean} = $props();

    const GLYPH: Record<string, string> = {
        proposed: "○",
        approved: "✓",
        rejected: "✗",
        deferred: "»",
        pending: "…",
    };
    // literal class strings — Tailwind scans source (never `text-${tone}`)
    const TONE: Record<string, string> = {
        proposed: "text-lo",
        approved: "text-grn",
        rejected: "text-red",
        deferred: "text-amber",
        pending: "text-acc",
    };

    const t = $derived(app.reviewHunks.find((h) => h.id === id));
</script>

{#if t}
    <span
        class={"w-3 shrink-0 text-center text-xs transition-colors duration-300 " +
            (TONE[t.state] ?? "text-lo")}>{GLYPH[t.state] ?? "○"}</span
    >
    <span class="shrink-0 truncate font-mono text-[11px] text-fg"
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
