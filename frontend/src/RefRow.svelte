<!-- One reference hit as a quickfix row — CONTENT only; QuickfixPanel owns
     the wrapper, cursor, and keyboard. grep's shape: path:line · line text.
     Resolves its own data from the app store by id (the quickfix rule: rows
     never hold copies that could go stale). -->
<script lang="ts">
    import {app} from "./state.svelte";

    let {id}: {id: number; focused: boolean; open: boolean} = $props();

    const h = $derived(app.refHits.find((r) => r.id === id));
</script>

{#if h}
    <span class="shrink-0 truncate font-mono text-[11px] text-fg"
        >{h.path}<span class="text-lo">:{h.line}</span></span
    >
    <span class="min-w-0 flex-1 truncate font-mono text-[10px] text-lo">{h.text}</span>
    {#if h.external}
        <span class="shrink-0 text-[9px] text-lo">external · read-only</span>
    {/if}
{/if}
