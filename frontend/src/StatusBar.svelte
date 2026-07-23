<!-- The status bar: one global, context-sensitive strip at the bottom of the
     viewport (the design's "ambient numbers live here"). Three zones:

       left    where you are — git on the app screen, host link on home
       center  what's happening — review progress > the vim command line
               (the focused editor's monaco-vim node, adopted via
               vimbar.svelte.ts) > agent working > asks
       right   ambient telemetry — costs, worst usage window, orphan alert

     Pure projection of the app store; owns nothing but a 30s clock for the
     "working · Nm" readout. Chrome is mono 11px on the sunken surface, so the
     bar reads as instrument panel, not content. -->
<script lang="ts">
    import {isAgentTab} from "./deck";
    import {footprintOf, footprintTitle, shortBytes, shortWindow} from "./hostapi";
    import {app} from "./state.svelte";
    import {vimbar} from "./term/vimbar.svelte";

    // the vim slot: a plain container the focused editor's monaco-vim node is
    // adopted into. bind:this hands it over; a terminal taking focus clears it
    // (an editor's mode indicator must not outlive the editor's keyboard).
    let vimSlot = $state<HTMLElement | null>(null);
    $effect(() => {
        vimbar.mountSlot(vimSlot);
    });
    $effect(() => {
        if (app.focusedSessionId) vimbar.publish(null);
    });

    // a coarse clock: the duration readout only speaks in minutes
    let now = $state(Date.now());
    $effect(() => {
        const t = setInterval(() => (now = Date.now()), 30_000);
        return () => clearInterval(t);
    });

    const git = $derived(app.wsStatus?.git);
    /** the longest-running working agent anchors the center readout */
    const working = $derived.by(() => {
        const w = (app.wsStatus?.sessions ?? [])
            .flatMap((s) => (s.agent ? [s.agent] : []))
            .filter((a) => a.state === "working");
        if (!w.length) return null;
        const starts = w
            .map((a) => Date.parse(a.since))
            .filter((t) => !Number.isNaN(t) && t > 0)
            .sort((a, b) => a - b);
        return {count: w.length, since: starts[0]};
    });
    function dur(t?: number): string {
        if (!t) return "";
        const m = Math.max(0, Math.floor((now - t) / 60_000));
        return m >= 60 ? ` · ${Math.floor(m / 60)}h ${m % 60}m` : ` · ${m}m`;
    }

    const gate = $derived(app.reviewRoot?.gate);
    /** review owns the center zone while the review surface owns the viewport */
    const reviewCenter = $derived(app.mode === "review" && gate ? gate : null);

    const worstUsage = $derived(
        app.usage && app.usage.windows.length
            ? app.usage.windows.reduce((a, b) => (b.pct > a.pct ? b : a))
            : null,
    );
    const footprint = $derived(footprintOf(app.runtime?.gauges));
</script>

<div
    id="statusbar"
    class="flex h-7 shrink-0 items-center gap-5 border-t border-line/15 bg-sunken px-3.5 font-mono text-[11px] text-dim"
>
    {#if app.screen === "home"}
        <span class={["flex items-center gap-1.5", app.runtime ? "text-grn" : "text-lo"]}
            ><span class="text-[8px]">●</span>rook-host</span
        >
        <span class="flex items-center gap-4 text-lo">
            {#if isAgentTab(app.deck.tab)}
                <span><span class="text-dim">j/k</span> row</span>
                <span><span class="text-dim">↵</span> conversation</span>
                <span><span class="text-dim">R</span> raw</span>
                <span><span class="text-dim">w</span> group</span>
                <span><span class="text-dim">/</span> filter</span>
            {/if}
            <span><span class="text-dim">n</span> new agent</span>
            <span><span class="text-dim">gt</span> tab</span>
        </span>
    {:else}
        <span class="flex items-center gap-1.5">
            {#if git}
                <span>⎇ {git.branch}{git.dirty > 0 ? "*" : ""}</span>
                {#if git.dirty > 0}<span class="text-lo">· {git.dirty} changed</span>{/if}
            {:else}
                <span>⎇ {app.workspaceInfo?.branch ?? app.workspace}</span>
            {/if}
        </span>
    {/if}
    <span class="flex flex-1 items-center justify-center gap-2.5 text-center">
        {#if reviewCenter}
            <span class="text-amber"
                >review · {reviewCenter.total - reviewCenter.blocking} reviewed · {reviewCenter.blocking}
                remaining</span
            >
            <span class="h-0.75 w-24 overflow-hidden rounded-full bg-fg/10"
                ><span
                    class="block h-full bg-acc"
                    style="width: {reviewCenter.total > 0
                        ? Math.round(
                              ((reviewCenter.total - reviewCenter.blocking) / reviewCenter.total) *
                                  100,
                          )
                        : 0}%"
                ></span></span
            >
        {:else if app.screen === "app" && vimbar.active}
            <span bind:this={vimSlot} class="flex min-w-0 flex-1 items-center"></span>
        {:else if app.screen === "app" && working}
            <span class="text-grn"
                >agent working{working.count > 1 ? ` ×${working.count}` : ""}{dur(
                    working.since,
                )}</span
            >
        {:else if app.screen === "home" && app.attention.length > 0}
            <span class="text-amber"
                >{app.attention.length} need{app.attention.length === 1 ? "s" : ""} you</span
            >
        {/if}
    </span>
    {#if vimbar.active && vimbar.pos}
        <span class="text-lo">Ln {vimbar.pos.ln}, Col {vimbar.pos.col}</span>
    {/if}
    {#if footprint && footprint.total > 0}
        <span
            id="sb-footprint"
            class={footprint.orphaned ? "text-amber" : "text-lo"}
            title={footprintTitle(footprint)}
            >{footprint.orphaned ? "⚠ " : ""}{shortBytes(footprint.total)}</span
        >
    {/if}
    {#if app.costs && (app.costs.todayUsd > 0 || app.costs.weekUsd > 0)}
        <span
            class="text-lo"
            title="What claude usage would cost on API billing — absorbed by the subscription"
            >claude ${app.costs.todayUsd.toFixed(2)} today{app.screen === "home"
                ? ` · $${app.costs.weekUsd.toFixed(2)} 7d`
                : ""}</span
        >
    {/if}
    {#if worstUsage}
        <span
            class={worstUsage.pct >= 90
                ? "text-hot"
                : worstUsage.pct >= 70
                  ? "text-amber"
                  : "text-lo"}
            title={app.usage?.windows
                .map((w) => `${w.label}: ${w.pct}% — resets ${w.resets}`)
                .join("\n")}>{worstUsage.pct}% {shortWindow(worstUsage.label)}</span
        >
    {/if}
</div>
