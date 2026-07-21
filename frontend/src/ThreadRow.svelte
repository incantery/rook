<!-- One thread as a quickfix row — CONTENT only; QuickfixPanel owns the
     wrapper, cursor and keyboard. Same shape as a grep hit (path:line · text)
     so the list reads consistently whatever produced it. Resolves its own data
     from the app store by id (the quickfix rule: rows never hold copies that
     could go stale). -->
<script lang="ts">
    import {app} from "./state.svelte";
    import {snippetOf, stateMeta, type StateTone} from "./term/threadview";

    let {id}: {id: number; focused: boolean; open: boolean} = $props();

    const t = $derived(app.threads.find((x) => x.id === id));
    // Tone → literal class names; Tailwind scans source for literal strings,
    // so this can never be `text-${tone}`.
    const TONE: Record<StateTone, string> = {
        amber: "text-amber",
        acc: "text-acc",
        grn: "text-grn",
    };
</script>

{#if t}
    {@const meta = stateMeta(t.state)}
    <span class={"shrink-0 " + TONE[meta.tone]}>●</span>
    <span class="shrink-0 truncate font-mono text-[11px] text-fg"
        >{t.path}<span class="text-lo">:{t.currentStart}</span></span
    >
    <span class="min-w-0 flex-1 truncate font-mono text-[10px] text-lo"
        >{t.comments[0]?.body ?? snippetOf(t)}</span
    >
    {#if t.outdated}
        <span class="shrink-0 text-[9px] text-lo">outdated</span>
    {/if}
    {#if t.comments.length > 1}
        <span class="shrink-0 text-[9px] text-lo">{t.comments.length}</span>
    {/if}
{/if}
