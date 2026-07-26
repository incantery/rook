<!-- Titlebar: drag region; the tab strip is centered NAMED deck tabs — each
     window shows its number (still the ` <n> chord), its focused pane's name,
     and a state dot for the agents inside it (amber needs-you · green working
     · gray quiet · none when no agent). The strip is a pure projection of the
     terminal runtime's state via the store — clicks dispatch back into the
     manager, never touch terminals directly.

     The chrome carries exactly ONE capsule: the attention pill. Everything
     else is a flat rounded-md control, and telemetry collapses into the one
     "usage ▾" cluster (ambient numbers live in the status bar). -->
<script lang="ts">
    import {app} from "./state.svelte";
    import type {TabInfo} from "./term/manager";
    import UsageCluster from "./UsageCluster.svelte";

    interface Props {
        onpicker: () => void;
        ondashboard: () => void;
        oninbox: () => void;
        onactivate: (id: string) => void;
        onnew: () => void;
        onpalette: () => void;
        /** the footprint row in the usage cluster opens the performance pane */
        onmonitor: () => void;
    }
    let {onpicker, ondashboard, oninbox, onactivate, onnew, onpalette, onmonitor}: Props = $props();

    /** sessions (panes) in this workspace waiting on you — a window's dot
     *  goes amber if ANY of its panes asks; the window you're looking at
     *  doesn't pulse (a visible pane's ask is already on screen) */
    const attnIds = $derived(
        new Set(
            app.attention.filter((i) => i.workspace === app.workspace).map((i) => i.rookSession),
        ),
    );
    /** per-pane agent state from the workspace-status poll — the tab dots'
     *  raw material. Empty on an old host or before the first poll lands,
     *  which fails open to attention-only dots. */
    const agentStates = $derived(
        new Map(
            (app.wsStatus?.sessions ?? []).flatMap((s) =>
                s.agent ? [[s.id, s.agent.state] as const] : [],
            ),
        ),
    );
    /** a tab's dot: worst state across its panes; null = no agent, no dot */
    function tabState(tab: TabInfo): "attn" | "working" | "quiet" | null {
        let st: "working" | "quiet" | null = null;
        for (const id of tab.sessions) {
            if (attnIds.has(id) || agentStates.get(id) === "needs_input") return "attn";
            const a = agentStates.get(id);
            if (a === "working") st = "working";
            else if (a === "quiet" && !st) st = "quiet";
        }
        return st;
    }
    /** the workspace chip's dot: the workspace's overall temperature */
    const wsDot = $derived.by(() => {
        if (attnIds.size > 0) return "bg-amber";
        for (const st of agentStates.values()) if (st === "working") return "bg-grn";
        return "bg-lo";
    });
    // Lineage on the "you are here" chip: inside a task tree the bare name
    // is a lie of omission — say what it was carved from. Fails open to the
    // bare name until the workspaces poll lands (or on an older host).
    const tree = $derived.by(() => {
        const info = app.workspaceInfo;
        return info?.worktreeOf ? {of: info.worktreeOf, branch: info.branch} : null;
    });
</script>

<div
    class="relative flex h-13 shrink-0 items-center justify-end gap-2 border-b border-line/15 bg-raise pl-21 pr-3.5"
    style="--wails-draggable: drag"
>
    <button
        class="absolute left-21 top-1/2 box-border inline-flex h-7 -translate-y-1/2 cursor-pointer items-center gap-2 self-center rounded-md px-2.5 text-[0.78125rem] font-medium text-fg hover:bg-fg/8"
        class:max-w-60={!tree}
        class:max-w-80={tree}
        style="--wails-draggable: no-drag"
        title={tree
            ? `Task tree of ${tree.of} — branch ${tree.branch ?? "?"}. Switch workspace (\` s)`
            : "Switch workspace (` s)"}
        onclick={onpicker}
        >{#if tree && !app.flashMsg}<span class="h-1.5 w-1.5 flex-none rounded-full {wsDot}"
            ></span><span class="truncate opacity-60">{tree.of}</span><span
                class="flex-none opacity-50">▸</span
            ><span class="truncate">⎇ {app.workspace}</span>{:else}<span
                class="h-1.5 w-1.5 flex-none rounded-full {wsDot}"
            ></span><span class="truncate">{app.flashMsg ?? app.workspace}</span>{/if}<span
            class="flex-none text-[0.625rem] text-lo">▾</span
        ></button
    >
    <div class="absolute inset-y-0 left-1/2 flex -translate-x-1/2 items-center gap-1.5">
        <!-- The dashboard is a SURFACE, not a layout, so it no longer takes a
             number: the strip is windows and its digits are ` <n>. A numbered
             dashboard put three species of noun in one list (a singleton
             surface, layouts, and — before buffers — documents), which is why
             the numbers never quite meant anything. -->
        <button
            class={[
                "flex h-7 cursor-pointer items-center rounded-md px-2 text-sm",
                app.dashVisible ? "text-acc" : "text-lo hover:bg-fg/8 hover:text-dim",
            ]}
            style="--wails-draggable: no-drag"
            title="Dashboard (` d)"
            aria-label="Dashboard"
            onclick={ondashboard}>⊞</button
        >
        {#each app.tabs as tab, i (tab.id)}
            {@const active = tab.id === app.activeId && !app.dashVisible}
            {@const st = tabState(tab)}
            {@const pulse = st === "attn" && (tab.id !== app.activeId || app.dashVisible)}
            <button
                class={[
                    "box-border flex h-7 cursor-pointer items-center gap-2 rounded-md border px-2.5 text-xs",
                    active
                        ? "border-acc/45 bg-acc/13 font-medium text-fg"
                        : "border-transparent text-dim hover:bg-fg/8",
                ]}
                style="--wails-draggable: no-drag"
                title={tab.name}
                onclick={() => onactivate(tab.id)}
                ><span class={["font-mono text-[0.6875rem]", active ? "text-acc" : "text-lo"]}
                    >{i + 1}</span
                ><span class={["truncate", active ? "max-w-44" : "max-w-24"]}>{tab.name}</span
                >{#if st}<span
                        class={[
                            "h-1.5 w-1.5 flex-none rounded-full",
                            st === "attn" ? "bg-amber" : st === "working" ? "bg-grn" : "bg-lo",
                            pulse && "animate-attn-pulse",
                        ]}
                    ></span>{/if}</button
            >
        {/each}
        <button
            class="flex h-7 cursor-pointer items-center rounded-md px-2 text-sm text-lo hover:bg-fg/8 hover:text-dim"
            style="--wails-draggable: no-drag"
            title="New window (` c)"
            onclick={onnew}>+</button
        >
    </div>
    {#if app.prefixArmed}
        <span
            class="box-border inline-flex h-6 items-center self-center rounded-md border border-amber/35 bg-amber/12 px-2.5 font-mono text-xs font-semibold text-amber"
            >prefix</span
        >
    {/if}
    {#if app.attention.length > 0}
        <button
            class="box-border inline-flex h-6 cursor-pointer items-center gap-1.5 self-center rounded-full border border-amber/35 bg-amber/12 px-2.5 text-[0.71875rem] font-medium text-amber hover:bg-amber/20"
            style="--wails-draggable: no-drag"
            title="Attention inbox (` a)"
            onclick={oninbox}
            ><span class="h-1.5 w-1.5 flex-none rounded-full bg-amber"></span>{app.attention.length} need{app
                .attention.length === 1
                ? "s"
                : ""} you</button
        >
    {/if}
    <UsageCluster ids {onmonitor} />
    <button
        aria-label="commands"
        class="box-border inline-flex h-6 cursor-pointer items-center self-center rounded-md border border-line/15 px-2 font-mono text-xs text-dim hover:bg-fg/8 hover:text-fg"
        style="--wails-draggable: no-drag"
        title="Command palette (⌘K)"
        onclick={onpalette}>⌘K</button
    >
</div>
