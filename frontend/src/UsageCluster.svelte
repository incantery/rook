<!-- The usage cluster: the ONE place telemetry unpacks — subscription usage
     windows with bars, the raw-inference cost picture, and the process
     footprint. A quiet "usage ▾" control everywhere it appears (titlebar,
     mission-control strip); ambient numbers live in the status bar instead.

     `onmonitor` is optional: from the app screen the footprint row opens the
     performance pane; on mission control it's informational. -->
<script lang="ts">
    import {footprintOf, footprintTitle, shortBytes} from "./hostapi";
    import {app} from "./state.svelte";

    interface Props {
        /** clicking the footprint row opens the performance pane (app screen) */
        onmonitor?: () => void;
        /** render the #tb-* ids (exactly ONE mounted cluster may — the app
         *  screen stays mounted under Home, so ids must not ride both) */
        ids?: boolean;
    }
    let {onmonitor, ids = false}: Props = $props();

    const worstUsage = $derived(
        app.usage && app.usage.windows.length
            ? app.usage.windows.reduce((a, b) => (b.pct > a.pct ? b : a))
            : null,
    );
    const footprint = $derived(footprintOf(app.runtime?.gauges));

    let open = $state(false);
</script>

<svelte:window
    onkeydown={(e) => {
        if (open && e.key === "Escape") open = false;
    }}
/>

<div class="relative self-center" style="--wails-draggable: no-drag">
    <button
        id={ids ? "tb-usage" : undefined}
        class={[
            "box-border inline-flex h-6 cursor-pointer appearance-none items-center gap-1.5 rounded-md border-0 bg-transparent px-2.5 text-xs hover:bg-fg/8",
            worstUsage && worstUsage.pct >= 90
                ? "text-hot"
                : worstUsage && worstUsage.pct >= 70
                  ? "text-amber"
                  : "text-dim",
        ]}
        title="Usage, costs and footprint"
        onclick={() => (open = !open)}>usage<span class="text-[0.625rem] text-lo">▾</span></button
    >
    {#if open}
        <!-- click-away scrim (transparent) then the cluster panel -->
        <div class="fixed inset-0 z-40" role="presentation" onclick={() => (open = false)}></div>
        <div
            class="absolute right-0 top-8 z-50 flex w-76 flex-col gap-3 rounded-lg border border-line/30 bg-overlay p-3.5 shadow-2xl"
        >
            {#if app.usage && app.usage.windows.length}
                <div class="flex flex-col gap-2">
                    {#each app.usage.windows as w (w.label)}
                        {@const hot = w.pct >= 90}
                        {@const warn = w.pct >= 70 && w.pct < 90}
                        <div class="flex flex-col gap-1">
                            <div class="flex items-baseline justify-between text-xs">
                                <span class="text-dim">{w.label}</span>
                                <span
                                    class={[
                                        "font-mono",
                                        hot ? "text-hot" : warn ? "text-amber" : "text-fg",
                                    ]}>{w.pct}%</span
                                >
                            </div>
                            <div class="h-0.75 overflow-hidden rounded-full bg-fg/10">
                                <div
                                    class={[
                                        "h-full",
                                        hot ? "bg-hot" : warn ? "bg-amber" : "bg-acc",
                                    ]}
                                    style="width: {Math.min(100, w.pct)}%"
                                ></div>
                            </div>
                            <div class="text-[0.6875rem] text-lo">resets {w.resets}</div>
                        </div>
                    {/each}
                </div>
            {:else}
                <div class="text-xs text-lo">no usage data</div>
            {/if}
            {#if app.costs && (app.costs.todayUsd > 0 || app.costs.weekUsd > 0)}
                <div
                    class="border-t border-line/15 pt-2.5 font-mono text-[0.6875rem] text-dim"
                    title="raw-inference value (subscription usage priced at API rates)"
                >
                    ${app.costs.todayUsd.toFixed(2)} today · ${app.costs.weekUsd.toFixed(2)} 7d
                    {#if app.costs.drafterTodayUsd > 0}
                        · drafter ${app.costs.drafterTodayUsd.toFixed(2)}{/if}
                </div>
            {/if}
            {#if footprint && footprint.total > 0}
                {#if onmonitor}
                    <button
                        id={ids ? "tb-footprint" : undefined}
                        class={[
                            "flex cursor-pointer appearance-none items-center justify-between rounded-md border border-line/15 bg-transparent px-2.5 py-1.5 font-mono text-[0.6875rem] hover:bg-fg/8",
                            footprint.orphaned ? "text-amber" : "text-dim",
                        ]}
                        title={footprintTitle(footprint)}
                        onclick={() => {
                            open = false;
                            onmonitor();
                        }}
                        ><span>memory{footprint.orphaned ? " ⚠" : ""}</span><span
                            >{shortBytes(footprint.total)}</span
                        ></button
                    >
                {:else}
                    <div
                        class={[
                            "flex items-center justify-between rounded-md border border-line/15 px-2.5 py-1.5 font-mono text-[0.6875rem]",
                            footprint.orphaned ? "text-amber" : "text-dim",
                        ]}
                        title={footprintTitle(footprint)}
                    >
                        <span>memory{footprint.orphaned ? " ⚠" : ""}</span><span
                            >{shortBytes(footprint.total)}</span
                        >
                    </div>
                {/if}
            {/if}
        </div>
    {/if}
</div>
