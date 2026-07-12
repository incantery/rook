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
        onjump: (index: number) => void;
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

<div id="dashboard">
    <div id="dash-inner">
        <div class="dash-head">
            <div class="dash-head-text">
                {#if treeOf}
                    <div class="dash-lineage">⎇ task tree of {treeOf}</div>
                {/if}
                <div class="dash-name">{st?.name ?? app.workspace}</div>
                <div class="dash-root">
                    {st?.root ? tilde(st.root) : "no root — cd somewhere, then ` ."}
                </div>
            </div>
            <div class="dash-pills">
                {#if st?.git}
                    <span class="dash-pill branch">⎇ {st.git.branch}</span>
                    {#if st.git.dirty > 0}<span class="dash-pill dirty"
                            >● {st.git.dirty} modified</span
                        >
                    {:else}<span class="dash-pill clean">✓ clean</span>{/if}
                    {#if st.git.ahead > 0}<span class="dash-pill sync">↑{st.git.ahead}</span>{/if}
                    {#if st.git.behind > 0}<span class="dash-pill sync">↓{st.git.behind}</span>{/if}
                {/if}
                <!-- the fresh-start pills: usage + cost render even at zero — the
                     dashboard should say "nothing burning", not say nothing -->
                {#if worstUsage}
                    <span class="dash-pill" class:dirty={worstUsage.pct >= 90}
                        >◔ {worstUsage.pct}% {shortWindow(worstUsage.label)}</span
                    >
                {/if}
                {#if app.costs}
                    <span class="dash-pill">${app.costs.todayUsd.toFixed(2)} today</span>
                {/if}
            </div>
        </div>
        <div class="dash-sec">Windows</div>
        <div id="dash-grid">
            {#each st?.sessions ?? [] as s, i (s.id)}
                {@const draft = app.attention.find(
                    (a) => a.rookSession === s.id && a.draft?.action === "draft",
                )}
                <div class="dash-card" onclick={() => onjump(i)} role="presentation">
                    <div class="dash-card-top">
                        <span class="dash-num">{app.dashTab + 1 + i}</span>
                        <!-- agent sessions get the accent — the attention router's
                             targets, visible at a glance -->
                        <span class="dash-fg" class:agent={s.fg === "claude"}>{s.fg || "?"}</span>
                        <span class="dash-spacer"></span>
                        <span class="dash-when">{ago(s.created)}</span>
                    </div>
                    <div class="dash-cwd" title={s.cwd}>{squeeze(tilde(s.cwd || "")) || "—"}</div>
                    {#if s.agent}
                        {@const text =
                            s.agent.state === "needs_input"
                                ? s.agent.ask || s.agent.title
                                : s.agent.title}
                        <div class="dash-agent {s.agent.state}">
                            <span class="dash-agent-chip">{agentLabel(s.agent)}</span>
                            {#if text}
                                <div class="dash-agent-text" title={text}>{text}</div>
                            {/if}
                        </div>
                    {/if}
                    {#if draft}
                        <div class="dash-draft" title={draft.draft?.reply ?? ""}>
                            ↳ draft ready — ` a
                        </div>
                    {/if}
                </div>
            {/each}
            {#if (st?.sessions ?? []).length === 0}
                <div class="home-empty">No windows — ` c opens one.</div>
            {/if}
        </div>
        {#if queue && (queue.issues.length > 0 || (queue.errors ?? []).length > 0)}
            <div class="dash-sec">Queue</div>
            <div id="dash-queue">
                {#each queue.issues as i (i.tracker + i.key)}
                    <div class="dash-issue">
                        <span class="dash-issue-key">{i.key}</span>
                        <span class="dash-issue-who" class:mine={i.mine}
                            >{i.mine ? "mine" : "open"}</span
                        >
                        <span class="dash-issue-title" title={i.title}>{i.title}</span>
                        {#if i.state && i.state !== "open"}<span class="dash-issue-state"
                                >{i.state}</span
                            >{/if}
                        <button
                            class="home-btn dash-issue-go"
                            title="Start claude on this issue in a fresh task tree"
                            disabled={starting !== ""}
                            onclick={() => void work(i)}
                            >{starting === i.key ? "…" : "▶ work"}</button
                        >
                    </div>
                {/each}
                {#each queue.errors ?? [] as e}
                    <div class="dash-issue-err" title={e}>⚠ {e}</div>
                {/each}
            </div>
        {/if}
        <div class="dash-actions">
            <button class="home-btn" onclick={() => runCmd("session.new")}
                ><span class="plus">+</span> New window</button
            >
            <button class="home-btn" onclick={() => runCmd("workspace.set-root")}
                >Set root to shell's cwd</button
            >
            <button class="home-btn" onclick={() => runCmd("workspace.manager")}
                >Workspace manager</button
            >
        </div>
    </div>
</div>
