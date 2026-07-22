<!-- Titlebar: drag region; tab strip is centered bare window numbers,
     straight from the tmux config (status-justify centre). The strip is a
     pure projection of the terminal runtime's state via the store — clicks
     dispatch back into the manager, never touch terminals directly. -->
<script lang="ts">
    import {footprintOf, footprintTitle, shortBytes, shortWindow} from "./hostapi";
    import {app} from "./state.svelte";

    interface Props {
        onpicker: () => void;
        ondashboard: () => void;
        oninbox: () => void;
        onactivate: (id: string) => void;
        onnew: () => void;
        onpalette: () => void;
        /** the footprint chip opens the performance pane */
        onmonitor: () => void;
    }
    let {onpicker, ondashboard, oninbox, onactivate, onnew, onpalette, onmonitor}: Props = $props();

    /** sessions (panes) in this workspace waiting on you — a window
     *  pulses if ANY of its panes asks; the window you're looking at
     *  doesn't flag you down (a visible pane's ask is already on screen) */
    const attnIds = $derived(
        new Set(
            app.attention.filter((i) => i.workspace === app.workspace).map((i) => i.rookSession),
        ),
    );
    // Lineage on the "you are here" chip: inside a task tree the bare name
    // is a lie of omission — say what it was carved from. Fails open to the
    // bare name until the workspaces poll lands (or on an older host).
    const tree = $derived.by(() => {
        const info = app.workspaceInfo;
        return info?.worktreeOf ? {of: info.worktreeOf, branch: info.branch} : null;
    });
    const worstUsage = $derived(
        app.usage && app.usage.windows.length
            ? app.usage.windows.reduce((a, b) => (b.pct > a.pct ? b : a))
            : null,
    );
    const usageTitle = $derived.by(() => {
        if (!app.usage) return "";
        let t = app.usage.windows
            .map((w) => `${w.label}: ${w.pct}% — resets ${w.resets}`)
            .join("\n");
        if (app.costs && (app.costs.todayUsd > 0 || app.costs.weekUsd > 0)) {
            t += `\nraw-inference value: $${app.costs.todayUsd.toFixed(2)} today · $${app.costs.weekUsd.toFixed(2)} 7d`;
        }
        return t;
    });

    const footprint = $derived(footprintOf(app.runtime?.gauges));
</script>

<div
    class="relative flex h-13 shrink-0 items-center justify-end gap-2 border-b border-line/15 bg-raise pl-21 pr-3.5"
    style="--wails-draggable: drag"
>
    <button
        class="absolute left-21 top-1/2 box-border inline-flex h-6 -translate-y-1/2 cursor-pointer appearance-none items-center gap-2 self-center rounded-full border border-acc/30 bg-acc/10 px-3 font-mono text-xs font-semibold text-acc hover:border-acc/50 hover:bg-acc/20"
        class:max-w-60={!tree}
        class:max-w-80={tree}
        style="--wails-draggable: no-drag"
        title={tree
            ? `Task tree of ${tree.of} — branch ${tree.branch ?? "?"}. Switch workspace (\` s)`
            : "Switch workspace (` s)"}
        onclick={onpicker}
        >{#if tree && !app.flashMsg}<span class="truncate opacity-60">{tree.of}</span><span
                class="flex-none opacity-50">▸</span
            ><span class="truncate">⎇ {app.workspace}</span>{:else}<span
                class="h-1.5 w-1.5 flex-none rounded-full bg-current"
            ></span><span class="truncate">{app.flashMsg ?? app.workspace}</span>{/if}</button
    >
    <div class="absolute inset-y-0 left-1/2 flex -translate-x-1/2 items-stretch">
        <!-- The dashboard is a SURFACE, not a layout, so it no longer takes a
             number: the strip is windows and its digits are ` <n>. A numbered
             dashboard put three species of noun in one list (a singleton
             surface, layouts, and — before buffers — documents), which is why
             the numbers never quite meant anything. -->
        <button
            class={[
                "mr-1 flex cursor-pointer appearance-none items-center border-0 bg-transparent px-2 text-sm",
                app.dashVisible ? "text-acc" : "text-lo hover:text-dim",
            ]}
            style="--wails-draggable: no-drag"
            title="Dashboard (` d)"
            aria-label="Dashboard"
            onclick={ondashboard}>⊞</button
        >
        {#each app.tabs as tab, i (tab.id)}
            {@const active = tab.id === app.activeId && !app.dashVisible}
            {@const attn =
                tab.sessions.some((id) => attnIds.has(id)) &&
                (tab.id !== app.activeId || app.dashVisible)}
            <button
                class={[
                    "flex cursor-pointer appearance-none items-center border-0 bg-transparent px-3 font-mono text-sm",
                    active
                        ? "font-bold text-fg"
                        : attn
                          ? "animate-attn-pulse text-amber"
                          : "text-lo hover:text-dim",
                ]}
                style="--wails-draggable: no-drag"
                title={tab.name}
                onclick={() => onactivate(tab.id)}>{i + 1}</button
            >
        {/each}
        <button
            class="flex cursor-pointer appearance-none items-center border-0 bg-transparent px-3 font-mono text-sm text-lo hover:text-dim"
            style="--wails-draggable: no-drag"
            title="New window (` c)"
            onclick={onnew}>+</button
        >
    </div>
    {#if app.prefixArmed}
        <span
            class="box-border inline-flex h-6 items-center self-center rounded-full border border-amber/35 bg-amber/12 px-2.5 font-mono text-xs font-semibold text-amber"
            >prefix</span
        >
    {/if}
    {#if worstUsage}
        {@const warn = worstUsage.pct >= 70 && worstUsage.pct < 90}
        {@const hot = worstUsage.pct >= 90}
        <button
            class={[
                "box-border inline-flex h-6 cursor-default appearance-none items-center self-center rounded-full border px-2.5 font-mono text-xs font-semibold",
                hot
                    ? "border-hot/35 bg-hot/12 text-hot"
                    : warn
                      ? "border-amber/35 bg-amber/12 text-amber"
                      : "border-dim/30 bg-dim/10 text-dim",
            ]}
            style="--wails-draggable: no-drag"
            title={usageTitle}>{worstUsage.pct}% {shortWindow(worstUsage.label)}</button
        >
    {/if}
    {#if footprint && footprint.total > 0}
        <button
            id="tb-footprint"
            class={[
                "box-border inline-flex h-6 cursor-pointer appearance-none items-center self-center rounded-full border px-2.5 font-mono text-xs font-semibold",
                footprint.orphaned
                    ? "border-amber/35 bg-amber/12 text-amber hover:bg-amber/20"
                    : "border-dim/30 bg-dim/10 text-dim hover:bg-dim/20",
            ]}
            style="--wails-draggable: no-drag"
            title={footprintTitle(footprint)}
            onclick={onmonitor}
            >{footprint.orphaned ? "⚠ " : ""}{shortBytes(footprint.total)}</button
        >
    {/if}
    {#if app.attention.length > 0}
        <button
            class="box-border inline-flex h-6 cursor-pointer appearance-none items-center self-center rounded-full border border-amber/35 bg-amber/12 px-2.5 font-mono text-xs font-semibold text-amber"
            style="--wails-draggable: no-drag"
            title="Attention inbox (` a)"
            onclick={oninbox}>◉ {app.attention.length}</button
        >
    {/if}
    <button
        class="box-border inline-flex h-6 cursor-pointer appearance-none items-center gap-2 self-center rounded-md border border-line/15 bg-fg/5 pl-2.5 pr-2 text-xs text-dim hover:bg-fg/10 hover:text-fg"
        style="--wails-draggable: no-drag"
        onclick={onpalette}
    >
        commands <kbd class="rounded border border-line/15 px-1.5 py-px font-mono text-xs text-lo"
            >⌘K</kbd
        >
    </button>
</div>
