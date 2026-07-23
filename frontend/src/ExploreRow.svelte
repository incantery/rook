<!-- One breadcrumb as a quickfix row — grep's shape: path:line · anchored
     text, a star when the spot was marked. Resolves from the active
     investigation by id (rows never hold copies that could go stale). -->
<script lang="ts">
    import {app} from "./state.svelte";

    let {id}: {id: number; focused: boolean; open: boolean} = $props();

    const b = $derived(app.exploreTask?.children?.find((c) => c.id === id));
</script>

{#if b}
    <span class="w-3 shrink-0 text-center text-[0.6875rem] text-amber"
        >{b.state === "starred" ? "★" : ""}</span
    >
    <span class="shrink-0 truncate font-mono text-[0.6875rem] text-fg"
        >{b.path}<span class="text-lo">:{b.startLine}</span></span
    >
    <span class="min-w-0 flex-1 truncate font-mono text-[0.625rem] text-lo"
        >{b.anchorText ?? ""}</span
    >
{/if}
