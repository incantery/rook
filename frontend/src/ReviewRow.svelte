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
    // threads linked to THIS leaf (gt inside its hunk while the review was
    // open); open ones are why the ring pulses pending
    const linked = $derived(app.threads.filter((th) => th.rookTaskId === id));
    const openLinked = $derived(linked.filter((th) => th.state !== "resolved").length);
</script>

{#if t}
    <span
        data-state={t.state}
        class={"size-3 shrink-0 rounded-full border-[1.5px] transition-colors duration-300 " +
            (RING[t.state] ?? "border-lo")}
    ></span>
    <span
        class={"shrink-0 truncate font-mono text-[0.6875rem] " +
            (DONE.has(t.state) ? "text-lo line-through" : "text-fg")}
        >{t.path ?? t.title ?? ""}{#if t.startLine}<span class="text-lo">:{t.startLine}</span
            >{/if}</span
    >
    <span class="min-w-0 flex-1 truncate text-[0.625rem] text-lo">{t.detail?.category ?? ""}</span>
    {#if linked.length > 0}
        <span
            class={"shrink-0 rounded px-1 font-mono text-[0.5625rem] " +
                (openLinked > 0 ? "bg-acc/15 text-acc" : "bg-fg/10 text-lo")}
            title={openLinked > 0
                ? `${openLinked} open thread${openLinked === 1 ? "" : "s"}`
                : "threads resolved"}>⊙ {linked.length}</span
        >
    {/if}
    {#if t.detail?.score?.risk}
        <span
            class="shrink-0 rounded bg-fg/10 px-1 font-mono text-[0.5625rem] text-dim"
            title="risk">r{t.detail.score.risk}</span
        >
    {/if}
{/if}
