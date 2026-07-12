<!-- Titlebar: drag region; tab strip is centered bare window numbers,
     straight from the tmux config (status-justify centre). The strip is a
     pure projection of the terminal runtime's state via the store — clicks
     dispatch back into the manager, never touch terminals directly. -->
<script lang="ts">
    import {shortWindow} from "./hostapi";
    import {app} from "./state.svelte";

    interface Props {
        onpicker: () => void;
        ondashboard: () => void;
        oninbox: () => void;
        onactivate: (id: string) => void;
        onnew: () => void;
        onpalette: () => void;
    }
    let {onpicker, ondashboard, oninbox, onactivate, onnew, onpalette}: Props = $props();

    /** the window you're looking at doesn't need to flag you down */
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
</script>

<div id="titlebar">
    <button
        id="ws-label"
        class:tasktree={tree}
        style="--wails-draggable: no-drag"
        title={tree
            ? `Task tree of ${tree.of} — branch ${tree.branch ?? "?"}. Switch workspace (\` s)`
            : "Switch workspace (` s)"}
        onclick={onpicker}
        >{#if tree}<span class="ws-parent">{tree.of}</span><span class="ws-sep">▸</span><span
                class="ws-name">⎇ {app.workspace}</span
            >{:else}<span class="ws-dot"></span><span class="ws-name">{app.workspace}</span
            >{/if}</button
    >
    <div id="tabs">
        <button
            class="tab tab-dash"
            class:active={app.dashVisible}
            style="--wails-draggable: no-drag"
            title="Dashboard (` d)"
            onclick={ondashboard}>{app.dashTab}</button
        >
        {#each app.tabs as tab, i (tab.id)}
            <button
                class="tab"
                class:active={tab.id === app.activeId && !app.dashVisible}
                class:attn={attnIds.has(tab.id) && (tab.id !== app.activeId || app.dashVisible)}
                style="--wails-draggable: no-drag"
                title={tab.name}
                onclick={() => onactivate(tab.id)}>{app.dashTab + 1 + i}</button
            >
        {/each}
        <button
            class="tab tab-new"
            style="--wails-draggable: no-drag"
            title="New window (` c)"
            onclick={onnew}>+</button
        >
    </div>
    <span id="prefix-pill" hidden={!app.prefixArmed}>prefix</span>
    {#if worstUsage}
        <button
            id="usage-chip"
            class:warn={worstUsage.pct >= 70 && worstUsage.pct < 90}
            class:hot={worstUsage.pct >= 90}
            style="--wails-draggable: no-drag"
            title={usageTitle}>{worstUsage.pct}% {shortWindow(worstUsage.label)}</button
        >
    {/if}
    {#if app.attention.length > 0}
        <button
            id="attn-chip"
            style="--wails-draggable: no-drag"
            title="Attention inbox (` a)"
            onclick={oninbox}>◉ {app.attention.length}</button
        >
    {/if}
    <button id="palette-btn" style="--wails-draggable: no-drag" onclick={onpalette}>
        commands <kbd>⌘K</kbd>
    </button>
</div>
