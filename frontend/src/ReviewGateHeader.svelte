<!-- The review context's quickfix header: the gate — a goal, not a status.
     Reads the app store directly (review-owned, like ReviewRow). -->
<script lang="ts">
    import {app} from "./state.svelte";

    const gate = $derived(app.reviewRoot?.gate);

    function gateText(): string {
        if (!gate) return "no review yet";
        if (gate.ready) return `ready for ${gate.verb || "next steps"} · ${gate.total} hunks`;
        return `${gate.blocking} of ${gate.total} hunks blocking`;
    }
</script>

{#if gate}
    <span
        class={"flex items-center gap-1.5 font-mono text-[10px] " +
            (gate.ready ? "text-grn" : "text-lo")}
    >
        <span class={"size-1.5 rounded-full " + (gate.ready ? "bg-grn" : "bg-amber")}></span>
        {gateText()}
    </span>
{:else}
    <span class="font-mono text-[10px] text-lo">no review yet</span>
{/if}
