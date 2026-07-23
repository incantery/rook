<!-- The review context's quickfix header: the gate — a goal, not a status.
     Reads the app store directly (review-owned, like ReviewRow). -->
<script lang="ts">
    import {app} from "./state.svelte";

    const gate = $derived(app.reviewRoot?.gate);
    const scored = $derived(app.reviewHunks.filter((h) => h.detail?.summary).length);

    // Progress, not blockage: "2 reviewed · 50 remaining" tells you where you
    // are in the pass; "52 of 52 hunks blocking" told you you were in trouble.
    function gateText(): string {
        if (!gate) return "no review yet";
        if (gate.ready) return `ready for ${gate.verb || "next steps"} · ${gate.total} hunks`;
        return `${gate.total - gate.blocking} reviewed · ${gate.blocking} remaining`;
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
    {#if !gate.ready && gate.total > 0}
        <span class="h-0.75 w-24 overflow-hidden rounded-full bg-fg/10"
            ><span
                class="block h-full bg-acc"
                style="width: {Math.round(((gate.total - gate.blocking) / gate.total) * 100)}%"
            ></span></span
        >
    {/if}
    {#if app.reviewRoot?.scoring}
        <span class="flex items-center gap-1.5 font-mono text-[10px] text-acc">
            <span class="size-1.5 animate-pulse rounded-full bg-acc"></span>
            triaging {scored}/{gate.total}
        </span>
    {/if}
{:else}
    <span class="font-mono text-[10px] text-lo">no review yet</span>
{/if}
