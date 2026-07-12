<!-- The workspace manager — the app's landing screen: workspace cards
     (persistent, VS Code-style), a resume banner when shells are live,
     scratch workspaces for one-off tasks, and a new-workspace modal.
     The strip carries the app-wide status line: subscription usage windows
     + the raw-inference cost picture (zeros render — "$0.00 today" on a
     fresh start is information, not absence). -->
<script lang="ts">
    import type {HostAPI, WorkspaceInfo} from "./hostapi";
    import {shortWindow} from "./hostapi";
    import {app} from "./state.svelte";
    import {ago} from "./util";

    let {api, onopen}: {api: HostAPI; onopen: (name: string) => void} = $props();

    let workspaces = $state<WorkspaceInfo[]>([]);
    let error = $state("");
    let modalOpen = $state(false);
    let modalName = $state("");
    let modalRoot = $state("");
    let nameEl = $state<HTMLInputElement | null>(null);

    const attnCounts = $derived.by(() => {
        const counts = new Map<string, number>();
        for (const it of app.attention)
            counts.set(it.workspace, (counts.get(it.workspace) ?? 0) + 1);
        return counts;
    });
    const liveWs = $derived(workspaces.filter((w) => w.sessions > 0));
    const liveShells = $derived(liveWs.reduce((n, w) => n + w.sessions, 0));
    const worstUsage = $derived(
        app.usage && app.usage.windows.length
            ? app.usage.windows.reduce((a, b) => (b.pct > a.pct ? b : a))
            : null,
    );

    export async function refresh(): Promise<void> {
        workspaces = await api.listWorkspaces();
    }

    export function showError(msg: string): void {
        error = msg;
        setTimeout(() => (error = ""), 6000);
    }

    // Two-step worktree deletion: the host 409s when removal would lose
    // work; the refusal arms this card's ✕ so the NEXT click forces. The
    // arm never survives a click elsewhere.
    let forceArmed = $state("");

    async function del(name: string): Promise<void> {
        const force = forceArmed === name;
        forceArmed = "";
        try {
            await api.deleteWorkspace(name, force);
        } catch (err) {
            showError(String(err));
            if (String(err).includes("force to discard")) forceArmed = name;
            return;
        }
        await refresh();
    }

    /** One-click close-the-loop: the merged nudge carries the merged fact,
     *  so force (squash merges read as "unmerged" to the guard) and prune
     *  the local branch knowingly. Kills the tree's shells like any delete. */
    async function cleanup(name: string): Promise<void> {
        try {
            await api.deleteWorkspace(name, true, true);
        } catch (err) {
            showError(String(err));
            return;
        }
        await refresh();
    }

    $effect(() => {
        void refresh();
        const t = setInterval(() => void refresh(), 15_000);
        return () => clearInterval(t);
    });

    $effect(() => {
        if (modalOpen) nameEl?.focus();
    });

    async function createFromModal() {
        const name = modalName.trim();
        if (!name) {
            nameEl?.focus();
            return;
        }
        await api.createWorkspace(name, modalRoot.trim(), false);
        modalOpen = false;
        onopen(name);
    }

    /** One-off task: auto-named ephemeral workspace, straight into a shell.
     *  The host discards it when its last session exits. */
    export async function scratch(): Promise<void> {
        const taken = new Set(workspaces.map((w) => w.name));
        let n = 1;
        while (taken.has(`scratch-${n}`)) n++;
        const name = `scratch-${n}`;
        await api.createWorkspace(name, "", true);
        onopen(name);
    }

    export function openModal(): void {
        modalName = "";
        modalRoot = "";
        modalOpen = true;
    }
</script>

<div id="home">
    <div id="home-strip">
        <span class="brand">Rook</span>
        <span class="brand-sub">workspace manager</span>
        <span class="home-spacer"></span>
        {#if worstUsage && app.usage}
            <span
                id="home-usage"
                class:warn={worstUsage.pct >= 70 && worstUsage.pct < 90}
                class:hot={worstUsage.pct >= 90}
                title={app.usage.windows
                    .map((w) => `${w.label}: ${w.pct}% — resets ${w.resets}`)
                    .join("\n")}
            >
                {app.usage.windows.map((w) => `${shortWindow(w.label)} ${w.pct}%`).join(" · ")}
            </span>
        {/if}
        {#if app.costs}
            <span
                id="home-costs"
                title="What claude usage would cost on API billing — absorbed by the subscription"
            >
                {[
                    `claude $${app.costs.todayUsd.toFixed(2)} today`,
                    `$${app.costs.weekUsd.toFixed(2)} 7d`,
                    ...(app.costs.drafterTodayUsd > 0
                        ? [`drafter $${app.costs.drafterTodayUsd.toFixed(2)}`]
                        : []),
                ].join(" · ")}
            </span>
        {/if}
    </div>
    <div id="home-scroll">
        <div id="home-inner">
            {#if error}
                <div id="home-error">{error}</div>
            {/if}
            {#if liveWs.length > 0}
                <div class="resume">
                    <div class="resume-text">
                        <div class="resume-kicker">Resume where you left off</div>
                        <div class="resume-body">
                            {liveShells} shell{liveShells === 1 ? "" : "s"} still running across {liveWs.length}
                            workspace{liveWs.length === 1 ? "" : "s"} — most recently {liveWs[0]
                                .name}.
                        </div>
                    </div>
                    <button class="resume-btn" onclick={() => onopen(liveWs[0].name)}
                        >Resume →</button
                    >
                </div>
            {/if}
            <div class="home-head">
                <h2>Workspaces</h2>
                <span class="home-spacer"></span>
                <button
                    class="home-btn"
                    style="--wails-draggable: no-drag"
                    title="One-off shell; discarded when it exits"
                    onclick={() => void scratch()}>scratch shell</button
                >
                <button class="home-btn" style="--wails-draggable: no-drag" onclick={openModal}>
                    <span class="plus">+</span> New workspace</button
                >
            </div>
            <div id="home-grid">
                {#each workspaces as ws (ws.name)}
                    {@const burn = app.costs?.live.find((l) => l.workspace === ws.name)?.usd ?? 0}
                    <div class="ws-card" onclick={() => onopen(ws.name)} role="presentation">
                        <div class="ws-card-head">
                            <span class="ws-card-name">{ws.name}</span>
                            <button
                                class="ws-card-del"
                                class:armed={forceArmed === ws.name}
                                title={forceArmed === ws.name
                                    ? "Delete anyway — discards the worktree (branch survives)"
                                    : "Delete workspace (kills its shells)"}
                                onclick={(e) => {
                                    e.stopPropagation();
                                    void del(ws.name);
                                }}>{forceArmed === ws.name ? "✕!" : "✕"}</button
                            >
                            <span class="ws-card-when">{ago(ws.lastUsed || ws.created)}</span>
                        </div>
                        <div class="ws-card-root">{ws.root || "~"}</div>
                        <div class="ws-card-tags">
                            <span
                                class="ws-tag"
                                class:live={ws.sessions > 0}
                                class:idle={ws.sessions === 0}
                            >
                                {ws.sessions > 0 ? `● ${ws.sessions} live` : "idle"}
                            </span>
                            {#if attnCounts.get(ws.name)}
                                <span class="ws-tag attn"
                                    >◉ {attnCounts.get(ws.name)} needs you</span
                                >
                            {/if}
                            {#if burn >= 0.01}
                                <span
                                    class="ws-tag cost"
                                    title="live claude sessions here, priced as API tokens"
                                    >${burn.toFixed(2)}</span
                                >
                            {/if}
                            {#if ws.scratch}
                                <span class="ws-tag scratch">scratch</span>
                            {/if}
                            {#if ws.worktreeOf}
                                <span
                                    class="ws-tag worktree"
                                    title="git worktree of {ws.worktreeOf}">⎇ {ws.branch}</span
                                >
                            {/if}
                            {#if ws.issueRef}
                                <span
                                    class="ws-tag issue"
                                    title="spawned for {ws.issueRef.tracker} issue {ws.issueRef
                                        .key}">{ws.issueRef.key}</span
                                >
                            {/if}
                            {#if ws.pr?.state === "merged"}
                                <button
                                    class="ws-tag pr-merged"
                                    title="PR #{ws.pr
                                        .number} merged — remove the worktree and delete {ws.branch} (kills its shells)"
                                    onclick={(e) => {
                                        e.stopPropagation();
                                        void cleanup(ws.name);
                                    }}>⇅ merged — clean up</button
                                >
                            {:else if ws.pr?.state === "open"}
                                <span class="ws-tag pr-open" title={ws.pr.url}
                                    >PR #{ws.pr.number}</span
                                >
                            {:else if ws.pr?.state === "closed"}
                                <span
                                    class="ws-tag pr-closed"
                                    title="PR #{ws.pr.number} closed without merging"
                                    >PR #{ws.pr.number} closed</span
                                >
                            {:else if ws.pr?.state === "none" && (ws.pr.ahead ?? 0) > 0}
                                <span
                                    class="ws-tag pr-none"
                                    title="{ws.pr
                                        .ahead} commit(s) on {ws.branch} with no PR — open one from the tree"
                                    >no PR yet</span
                                >
                            {/if}
                        </div>
                    </div>
                {/each}
                {#if workspaces.length === 0}
                    <div class="home-empty">
                        No workspaces yet — create one, or grab a scratch shell.
                    </div>
                {/if}
            </div>
        </div>
    </div>
</div>

{#if modalOpen}
    <div
        id="ws-modal"
        class="overlay"
        onmousedown={(e) => e.target === e.currentTarget && (modalOpen = false)}
        onkeydown={(e) => {
            if (e.key === "Enter") void createFromModal();
            else if (e.key === "Escape") {
                e.stopPropagation();
                modalOpen = false;
            }
        }}
        role="presentation"
    >
        <div class="pal-panel">
            <div class="ws-modal-title">New workspace</div>
            <div class="ws-form">
                <label
                    ><span>Name</span><input
                        placeholder="e.g. rook-core"
                        spellcheck="false"
                        bind:value={modalName}
                        bind:this={nameEl}
                    /></label
                >
                <label
                    ><span
                        >Directory (optional — or set it later from inside the workspace: cd
                        anywhere, then ` .)</span
                    ><input
                        placeholder="~/go/src/github.com/incantery/rook"
                        spellcheck="false"
                        bind:value={modalRoot}
                    /></label
                >
            </div>
            <div class="ws-modal-foot">
                <button class="home-btn" onclick={() => (modalOpen = false)}>Cancel</button>
                <button class="home-btn primary" onclick={() => void createFromModal()}
                    >Create workspace</button
                >
            </div>
        </div>
    </div>
{/if}
