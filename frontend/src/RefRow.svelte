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
    <span class="shrink-0 truncate font-mono text-[0.65625rem] text-dim"
        >{h.path}<span class="text-lo">:{h.line}</span></span
    >
    <!-- the hit's own line stays mono — this one IS code, unlike a comment -->
    <span class="min-w-0 flex-1 truncate font-mono text-[0.65625rem] text-fg">{h.text}</span>
    {#if h.external}
        <span class="shrink-0 text-[0.5625rem] text-lo">external · read-only</span>
    {/if}
{/if}
