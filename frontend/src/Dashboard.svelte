<!-- The workspace dashboard — window 0 of every workspace. It renders
     exactly what GET /workspaces/{name}/status reports, which is the same
     context the attention router (docs/agent.md) consumes — if the
     dashboard can't show it, the agent can't know it. -->
<script lang="ts">
    import type {AgentStatus, HostAPI, IssueInfo, IssuesResult, WorkspaceStatus} from "./hostapi";
    import {shortWindow} from "./hostapi";
    import {app} from "./state.svelte";
    import {ago, squeeze, tilde} from "./util";

    interface Props {
        api: HostAPI;
        /** jump to the pane holding this host session (mgr.switchToId) */
        onjump: (sessionId: string) => void;
        runCmd: (id: string) => void;
        /** start claude on this issue (worktree by default) — App owns the flow */
        onwork: (issue: IssueInfo) => Promise<void>;
    }
    let {api, onjump, runCmd, onwork}: Props = $props();

    let st = $state<WorkspaceStatus | null>(null);
    let queue = $state<IssuesResult | null>(null);
    let starting = $state(""); // issue key being started (debounce the ▶)

    /** One line of agent state on a window card: what claude is doing,
     *  and — at needs_input — what it's asking. */
    function agentLabel(a: AgentStatus): string {
        const label =
            a.state === "needs_input"
                ? "◉ needs you"
                : a.state === "quiet"
                  ? `◌ quiet${a.tool ? " — " + a.tool : ""}`
                  : `● working${a.tool ? " — " + a.tool : ""}`;
        return label + (a.costUsd ? ` · $${a.costUsd.toFixed(2)}` : "");
    }

    async function refresh() {
        try {
            const fresh = await api.workspaceStatus(app.workspace);
            st = fresh;
        } catch (err) {
            console.error("dashboard refresh failed", err);
        }
    }

    // fg process / cwd / git all drift while you watch — poll cheaply.
    // usage/costs pills read the store (App's slower poll owns them).
    $effect(() => {
        void refresh();
        const t = setInterval(() => void refresh(), 3000);
        return () => clearInterval(t);
    });

    // The issue queue moves at human speed and the host caches ~60s —
    // poll gently, and re-fetch when the workspace changes.
    $effect(() => {
        const ws = app.workspace;
        queue = null;
        const fetchQueue = async () => {
            try {
                queue = await api.issues(ws);
            } catch (err) {
                console.error("issues fetch failed", err);
            }
        };
        void fetchQueue();
        const t = setInterval(() => void fetchQueue(), 60_000);
        return () => clearInterval(t);
    });

    async function work(issue: IssueInfo) {
        if (starting) return;
        starting = issue.key;
        try {
            await onwork(issue);
        } finally {
            starting = "";
        }
    }

    const worstUsage = $derived(
        app.usage && app.usage.windows.length
            ? app.usage.windows.reduce((a, b) => (b.pct > a.pct ? b : a))
            : null,
    );

    // Lineage from the registry snapshot — /status doesn't carry it, and
    // the head must say "task tree of X", not read like a peer workspace.
    const treeOf = $derived(app.workspaceInfo?.worktreeOf ?? null);
</script>

<div class="absolute inset-0 z-10 overflow-y-auto bg-bg/72 backdrop-blur-xl">
    <div class="mx-auto max-w-215 px-6.5 pt-7 pb-15">
        <div class="mb-6 flex items-start gap-3">
            <div class="min-w-0 flex-1">
                {#if treeOf}
                    <div class="mb-1 font-mono text-xs text-acc">⎇ task tree of {treeOf}</div>
                {/if}
                <div class="text-xl font-bold text-fg">{st?.name ?? app.workspace}</div>
                <div class="mt-1.5 font-mono text-xs text-lo">
                    {st?.root ? tilde(st.root) : "no root — cd somewhere, then ` ."}
                </div>
            </div>
            <div class="flex flex-wrap items-center gap-1.5">
                {#if st?.git}
                    <span
                        class="rounded-md bg-acc/10 px-2 py-0.5 font-mono text-xs whitespace-nowrap text-acc"
                        >⎇ {st.git.branch}</span
                    >
                    {#if st.git.dirty > 0}<span
                            class="rounded-md bg-amber/10 px-2 py-0.5 font-mono text-xs whitespace-nowrap text-amber"
                            >● {st.git.dirty} modified</span
                        >
                    {:else}<span
                            class="rounded-md bg-grn/10 px-2 py-0.5 font-mono text-xs whitespace-nowrap text-grn"
                            >✓ clean</span
                        >{/if}
                    {#if st.git.ahead > 0}<span
                            class="rounded-md bg-fg/5 px-2 py-0.5 font-mono text-xs whitespace-nowrap text-dim"
                            >↑{st.git.ahead}</span
                        >{/if}
                    {#if st.git.behind > 0}<span
                            class="rounded-md bg-fg/5 px-2 py-0.5 font-mono text-xs whitespace-nowrap text-dim"
                            >↓{st.git.behind}</span
                        >{/if}
                {/if}
                <!-- the fresh-start pills: usage + cost render even at zero — the
                     dashboard should say "nothing burning", not say nothing -->
                {#if worstUsage}
                    <span
                        class={[
                            "rounded-md px-2 py-0.5 font-mono text-xs whitespace-nowrap",
                            worstUsage.pct >= 90 ? "bg-amber/10 text-amber" : "bg-fg/5 text-dim",
                        ]}>◔ {worstUsage.pct}% {shortWindow(worstUsage.label)}</span
                    >
                {/if}
                {#if app.costs}
                    <span
                        class="rounded-md bg-fg/5 px-2 py-0.5 font-mono text-xs whitespace-nowrap text-dim"
                        >${app.costs.todayUsd.toFixed(2)} today</span
                    >
                {/if}
            </div>
        </div>
        <div class="mb-2.5 text-xs font-bold tracking-widest uppercase text-lo">Windows</div>
        <div class="mb-6.5 grid grid-cols-[repeat(auto-fill,minmax(240px,1fr))] gap-2.5">
            {#each st?.sessions ?? [] as s, i (s.id)}
                {@const draft = app.attention.find(
                    (a) => a.rookSession === s.id && a.draft?.action === "draft",
                )}
                <!-- cards stay one-per-session (each is a distinct shell/agent);
                     the number is the STRIP SLOT of the window holding the pane,
                     falling back to list order until the strip snapshot has it -->
                {@const slot = app.tabs.findIndex((t) => t.sessions.includes(s.id))}
                <div
                    class="cursor-pointer rounded-xl border border-line/15 bg-fg/3 px-3.5 py-3 transition-colors hover:border-line/40"
                    onclick={() => onjump(s.id)}
                    role="presentation"
                >
                    <div class="mb-1.5 flex items-baseline gap-2">
                        <span class="font-mono text-xs text-lo">{(slot === -1 ? i : slot) + 1}</span
                        >
                        <!-- agent sessions get the accent — the attention router's
                             targets, visible at a glance -->
                        <span
                            class={[
                                "font-mono text-sm font-bold",
                                s.fg === "claude" ? "text-grn" : "text-fg",
                            ]}>{s.fg || "?"}</span
                        >
                        <span class="flex-1"></span>
                        <span class="font-mono text-xs whitespace-nowrap text-lo"
                            >{ago(s.created)}</span
                        >
                    </div>
                    <div class="truncate font-mono text-xs text-lo" title={s.cwd}>
                        {squeeze(tilde(s.cwd || "")) || "—"}
                    </div>
                    {#if s.agent}
                        {@const text =
                            s.agent.state === "needs_input"
                                ? s.agent.ask || s.agent.title
                                : s.agent.title}
                        <div class="mt-2 border-t border-line/15 pt-2">
                            <span
                                class={[
                                    "font-mono text-xs",
                                    s.agent.state === "working"
                                        ? "text-grn"
                                        : s.agent.state === "needs_input"
                                          ? "text-amber"
                                          : s.agent.state === "quiet"
                                            ? "text-lo"
                                            : "text-dim",
                                ]}>{agentLabel(s.agent)}</span
                            >
                            {#if text}
                                <div
                                    class="mt-1.5 line-clamp-2 text-xs leading-normal text-dim"
                                    title={text}
                                >
                                    {text}
                                </div>
                            {/if}
                        </div>
                    {/if}
                    {#if draft}
                        <div
                            class="mt-1.5 truncate font-mono text-xs text-grn"
                            title={draft.draft?.reply ?? ""}
                        >
                            ↳ draft ready — ` a
                        </div>
                    {/if}
                </div>
            {/each}
            {#if (st?.sessions ?? []).length === 0}
                <div class="col-span-full p-10 text-center text-sm text-lo">
                    No windows — ` c opens one.
                </div>
            {/if}
        </div>
        {#if queue && (queue.issues.length > 0 || (queue.errors ?? []).length > 0)}
            <div class="mb-2.5 text-xs font-bold tracking-widest uppercase text-lo">Queue</div>
            <div class="mb-5.5 flex flex-col gap-1.5">
                {#each queue.issues as i (i.tracker + i.key)}
                    <div
                        class="flex items-center gap-2.5 rounded-lg border border-line/15 bg-fg/2 px-3 py-1.5 text-sm"
                    >
                        <span class="font-mono whitespace-nowrap text-acc">{i.key}</span>
                        <span
                            class={[
                                "rounded-md px-1.5 py-px font-mono text-xs",
                                i.mine ? "bg-grn/12 text-grn" : "bg-fg/5 text-lo",
                            ]}>{i.mine ? "mine" : "open"}</span
                        >
                        <span class="flex-1 truncate text-fg" title={i.title}>{i.title}</span>
                        {#if i.state && i.state !== "open"}<span
                                class="text-xs whitespace-nowrap text-lo">{i.state}</span
                            >{/if}
                        <button
                            class="flex cursor-pointer items-center gap-1.5 rounded-lg border border-line/15 bg-fg/4 px-3 py-1.5 font-[inherit] text-sm font-semibold whitespace-nowrap text-fg hover:bg-fg/8"
                            title="Start claude on this issue in a fresh task tree"
                            disabled={starting !== ""}
                            onclick={() => void work(i)}
                            >{starting === i.key ? "…" : "▶ work"}</button
                        >
                    </div>
                {/each}
                {#each queue.errors ?? [] as e}
                    <div class="truncate px-3 py-0.5 text-xs text-amber" title={e}>⚠ {e}</div>
                {/each}
            </div>
        {/if}
        <div class="flex flex-wrap gap-2">
            <button
                class="flex cursor-pointer items-center gap-1.5 rounded-lg border border-line/15 bg-fg/4 px-3 py-1.5 font-[inherit] text-sm font-semibold text-fg hover:bg-fg/8"
                onclick={() => runCmd("session.new")}
                ><span class="text-sm leading-none text-acc">+</span> New window</button
            >
            <button
                class="flex cursor-pointer items-center gap-1.5 rounded-lg border border-line/15 bg-fg/4 px-3 py-1.5 font-[inherit] text-sm font-semibold text-fg hover:bg-fg/8"
                onclick={() => runCmd("workspace.set-root")}>Set root to shell's cwd</button
            >
            <button
                class="flex cursor-pointer items-center gap-1.5 rounded-lg border border-line/15 bg-fg/4 px-3 py-1.5 font-[inherit] text-sm font-semibold text-fg hover:bg-fg/8"
                onclick={() => runCmd("workspace.manager")}>Mission control</button
            >
        </div>
    </div>
</div>
