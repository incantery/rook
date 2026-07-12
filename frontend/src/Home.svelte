<!-- Mission control — the app's landing screen (issue #12): the answer to
     "what is going on across everything right now". Task trees group under
     their source workspace, whatever needs the human floats to the top,
     idle workspaces compress to one-line rows, and the issue queues of
     every repo surface here — work waiting to start, cross-workspace.
     Data is GET /overview (one call, live rollups); on an old daemon it
     fails open to the bare /workspaces list and renders what it has.
     The strip carries the app-wide status line: subscription usage windows
     + the raw-inference cost picture (zeros render — "$0.00 today" on a
     fresh start is information, not absence). -->
<script lang="ts">
    import type {HostAPI, IssueInfo, IssuesResult, OverviewItem} from "./hostapi";
    import {shortWindow} from "./hostapi";
    import {app} from "./state.svelte";
    import {ago, tilde} from "./util";

    interface Props {
        api: HostAPI;
        onopen: (name: string) => void;
        /** start claude on this issue off that workspace — App owns the flow */
        onwork: (workspace: string, issue: IssueInfo) => Promise<void>;
    }
    let {api, onopen, onwork}: Props = $props();

    let items = $state<OverviewItem[]>([]);
    let error = $state("");
    let modalOpen = $state(false);
    let modalName = $state("");
    let modalRoot = $state("");
    let nameEl = $state<HTMLInputElement | null>(null);
    let starting = $state(""); // issue key being started (debounce the ▶)

    // needs-you fallback for old daemons whose /overview is missing: the
    // attention poll knows the same count, just without the rest of the rollup
    const attnCounts = $derived.by(() => {
        const counts = new Map<string, number>();
        for (const it of app.attention)
            counts.set(it.workspace, (counts.get(it.workspace) ?? 0) + 1);
        return counts;
    });

    const attnOf = (w: OverviewItem) => w.attention ?? attnCounts.get(w.name) ?? 0;
    const workingOf = (w: OverviewItem) =>
        (w.agents ?? []).filter((a) => a.state === "working").length;

    /** One group per top-level workspace, its task trees under it. A tree
     *  whose source workspace is gone stands on its own. */
    interface Group {
        ws: OverviewItem;
        trees: OverviewItem[];
        attention: number;
        working: number;
        live: number;
        /** a merged PR waits for cleanup somewhere in the group */
        actionable: boolean;
    }

    const groups = $derived.by(() => {
        const names = new Set(items.map((w) => w.name));
        const kids = new Map<string, OverviewItem[]>();
        const tops: OverviewItem[] = [];
        for (const w of items) {
            if (w.worktreeOf && names.has(w.worktreeOf)) {
                const list = kids.get(w.worktreeOf) ?? [];
                list.push(w);
                kids.set(w.worktreeOf, list);
            } else tops.push(w);
        }
        const gs: Group[] = tops.map((ws) => {
            const trees = (kids.get(ws.name) ?? [])
                .slice()
                .sort((a, b) => attnOf(b) - attnOf(a) || b.sessions - a.sessions);
            const all = [ws, ...trees];
            return {
                ws,
                trees,
                attention: all.reduce((n, w) => n + attnOf(w), 0),
                working: all.reduce((n, w) => n + workingOf(w), 0),
                live: all.reduce((n, w) => n + w.sessions, 0),
                actionable: all.some((w) => w.pr?.state === "merged"),
            };
        });
        // attention-first: the human's queue, then live work, then recency
        gs.sort(
            (a, b) =>
                b.attention - a.attention ||
                b.working - a.working ||
                b.live - a.live ||
                Date.parse(b.ws.lastUsed || b.ws.created) -
                    Date.parse(a.ws.lastUsed || a.ws.created),
        );
        return gs;
    });
    const isActive = (g: Group) => g.live > 0 || g.attention > 0 || g.actionable;
    const active = $derived(groups.filter(isActive));
    const idle = $derived(groups.filter((g) => !isActive(g)));
    const liveShells = $derived(groups.reduce((n, g) => n + g.live, 0));
    const needsYou = $derived(groups.reduce((n, g) => n + g.attention, 0));
    const worstUsage = $derived(
        app.usage && app.usage.windows.length
            ? app.usage.windows.reduce((a, b) => (b.pct > a.pct ? b : a))
            : null,
    );

    /** The card's agent-state chips: ◉ needs you leads, then ● working,
     *  then ◌ quiet. Works from the rollup when the host sends one, from
     *  the attention poll when it doesn't. */
    function agentChips(w: OverviewItem): {cls: string; text: string}[] {
        const counts = {needs_input: 0, working: 0, quiet: 0};
        for (const a of w.agents ?? []) counts[a.state]++;
        counts.needs_input = Math.max(counts.needs_input, attnOf(w));
        const out: {cls: string; text: string}[] = [];
        if (counts.needs_input)
            out.push({
                cls: "needs_input",
                text: `◉ ${counts.needs_input} need${counts.needs_input === 1 ? "s" : ""} you`,
            });
        if (counts.working) out.push({cls: "working", text: `● ${counts.working} working`});
        if (counts.quiet) out.push({cls: "quiet", text: `◌ ${counts.quiet} quiet`});
        return out;
    }

    /** The card's one-liner: what the workspace's lead agent is asking —
     *  or, when nobody is blocked, doing. Agents arrive needs_input-first. */
    function agentLine(w: OverviewItem): string {
        const a = w.agents?.[0];
        if (!a) return "";
        return (a.state === "needs_input" ? a.ask || a.title : a.title) ?? "";
    }

    // interactive shells matter (nvim, make, …); bare prompts and the agent
    // chips' own claude don't
    const fgTools = (w: OverviewItem) =>
        (w.fg ?? []).filter((f) => !["zsh", "bash", "fish", "sh", "claude"].includes(f));

    export async function refresh(): Promise<void> {
        try {
            items = await api.overview();
        } catch (err) {
            // old daemon (no /overview yet) or a flaky moment: the bare
            // workspace list still renders — never a broken landing screen
            console.warn("overview unavailable — falling back to /workspaces", err);
            items = await api.listWorkspaces();
        }
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
        const t = setInterval(() => void refresh(), 5000);
        return () => clearInterval(t);
    });

    // ==== the cross-workspace queue: work waiting to start ====
    // One issues fetch per repo-rooted top-level workspace; the host caches
    // ~60s per workspace, so this stays cheap. Rows are deduped (two
    // workspaces on one repo see the same issues) and issues already in
    // flight — some workspace carries their issueRef — drop out.
    let queueRaw = $state<{ws: string; res: IssuesResult}[]>([]);
    const queueSources = $derived(
        items
            .filter((w) => !w.scratch && !w.worktreeOf && w.root)
            .map((w) => w.name)
            .sort()
            .join("\n"),
    );
    $effect(() => {
        const names = queueSources.split("\n").filter(Boolean);
        if (names.length === 0) {
            queueRaw = [];
            return;
        }
        const fetchAll = async () => {
            const results = await Promise.all(
                names.map(async (ws) => {
                    try {
                        return {ws, res: await api.issues(ws)};
                    } catch (err) {
                        console.warn(`issues fetch failed for ${ws}`, err);
                        return null;
                    }
                }),
            );
            queueRaw = results.filter((r) => r !== null);
        };
        void fetchAll();
        const t = setInterval(() => void fetchAll(), 60_000);
        return () => clearInterval(t);
    });
    const queueRows = $derived.by(() => {
        const inflight = new Set(
            items.filter((w) => w.issueRef).map((w) => w.issueRef!.tracker + w.issueRef!.key),
        );
        const seen = new Set<string>();
        const rows: {ws: string; issue: IssueInfo}[] = [];
        for (const {ws, res} of queueRaw)
            for (const issue of res.issues) {
                const k = issue.tracker + issue.key;
                if (inflight.has(k) || seen.has(k)) continue;
                seen.add(k);
                rows.push({ws, issue});
            }
        return rows;
    });
    const queueErrors = $derived(
        queueRaw.flatMap(({ws, res}) => (res.errors ?? []).map((e) => `${ws}: ${e}`)),
    );

    async function work(ws: string, issue: IssueInfo): Promise<void> {
        if (starting) return;
        starting = issue.key;
        try {
            await onwork(ws, issue);
        } finally {
            starting = "";
        }
    }

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
        const taken = new Set(items.map((w) => w.name));
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

{#snippet delBtn(name: string)}
    <button
        class="ws-card-del"
        class:armed={forceArmed === name}
        title={forceArmed === name
            ? "Delete anyway — discards the worktree (branch survives)"
            : "Delete workspace (kills its shells)"}
        onclick={(e) => {
            e.stopPropagation();
            void del(name);
        }}>{forceArmed === name ? "✕!" : "✕"}</button
    >
{/snippet}

{#snippet wsTags(w: OverviewItem)}
    {@const burn = app.costs?.live.find((l) => l.workspace === w.name)?.usd ?? 0}
    {#if burn >= 0.01}
        <span class="ws-tag cost" title="live claude sessions here, priced as API tokens"
            >${burn.toFixed(2)}</span
        >
    {/if}
    {#if w.scratch}
        <span class="ws-tag scratch">scratch</span>
    {/if}
    {#if w.issueRef}
        <span class="ws-tag issue" title="spawned for {w.issueRef.tracker} issue {w.issueRef.key}"
            >{w.issueRef.key}</span
        >
    {/if}
    {#if w.pr?.state === "merged"}
        <button
            class="ws-tag pr-merged"
            title="PR #{w.pr
                .number} merged — remove the worktree and delete {w.branch} (kills its shells)"
            onclick={(e) => {
                e.stopPropagation();
                void cleanup(w.name);
            }}>⇅ merged — clean up</button
        >
    {:else if w.pr?.state === "open"}
        <span class="ws-tag pr-open" title={w.pr.url}>PR #{w.pr.number}</span>
    {:else if w.pr?.state === "closed"}
        <span class="ws-tag pr-closed" title="PR #{w.pr.number} closed without merging"
            >PR #{w.pr.number} closed</span
        >
    {:else if w.pr?.state === "none" && (w.pr.ahead ?? 0) > 0}
        <span
            class="ws-tag pr-none"
            title="{w.pr.ahead} commit(s) on {w.branch} with no PR — open one from the tree"
            >no PR yet</span
        >
    {/if}
{/snippet}

<div id="home">
    <div id="home-strip">
        <span class="brand">Rook</span>
        <span class="brand-sub">mission control</span>
        {#if needsYou > 0}
            <span class="strip-attn">◉ {needsYou} need{needsYou === 1 ? "s" : ""} you</span>
        {:else if liveShells > 0}
            <span class="strip-quiet">● {liveShells} live, none blocked</span>
        {/if}
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
                {#each active as g (g.ws.name)}
                    {@const chips = agentChips(g.ws)}
                    {@const line = agentLine(g.ws)}
                    <div
                        class="ws-card"
                        class:attn={g.attention > 0}
                        onclick={() => onopen(g.ws.name)}
                        role="presentation"
                    >
                        <div class="ws-card-head">
                            <span class="ws-card-name">{g.ws.name}</span>
                            {@render delBtn(g.ws.name)}
                            <span class="ws-card-when">{ago(g.ws.lastUsed || g.ws.created)}</span>
                        </div>
                        <div class="ws-card-root">{tilde(g.ws.root || "") || "~"}</div>
                        <div class="ws-card-tags">
                            <span
                                class="ws-tag"
                                class:live={g.ws.sessions > 0}
                                class:idle={g.ws.sessions === 0}
                            >
                                {g.ws.sessions > 0 ? `● ${g.ws.sessions} live` : "idle"}
                            </span>
                            {#each chips as c (c.cls)}
                                <span class="ws-agent {c.cls}">{c.text}</span>
                            {/each}
                            {#if g.ws.git}
                                <span class="ws-tag git">⎇ {g.ws.git.branch}</span>
                                {#if g.ws.git.dirty > 0}
                                    <span class="ws-tag dirty">● {g.ws.git.dirty} modified</span>
                                {/if}
                                {#if g.ws.git.ahead > 0 || g.ws.git.behind > 0}
                                    <span class="ws-tag">
                                        {[
                                            g.ws.git.ahead > 0 ? `↑${g.ws.git.ahead}` : "",
                                            g.ws.git.behind > 0 ? `↓${g.ws.git.behind}` : "",
                                        ]
                                            .filter(Boolean)
                                            .join(" ")}
                                    </span>
                                {/if}
                            {/if}
                            {#each fgTools(g.ws) as f (f)}
                                <span class="ws-tag fg">{f}</span>
                            {/each}
                            {@render wsTags(g.ws)}
                        </div>
                        {#if line}
                            <div class="ws-agent-line" title={line}>{line}</div>
                        {/if}
                        {#if g.trees.length > 0}
                            <div class="ws-trees">
                                {#each g.trees as t (t.name)}
                                    {@const tChips = agentChips(t)}
                                    {@const tLine = agentLine(t)}
                                    <div
                                        class="ws-tree"
                                        onclick={(e) => {
                                            e.stopPropagation();
                                            onopen(t.name);
                                        }}
                                        role="presentation"
                                    >
                                        <div class="ws-tree-head">
                                            <span class="ws-tree-name">⎇ {t.name}</span>
                                            {#if t.sessions > 0 && tChips.length === 0}
                                                <span class="ws-tag live">● {t.sessions} live</span>
                                            {/if}
                                            {#each tChips as c (c.cls)}
                                                <span class="ws-agent {c.cls}">{c.text}</span>
                                            {/each}
                                            {@render wsTags(t)}
                                            <span class="home-spacer"></span>
                                            {@render delBtn(t.name)}
                                        </div>
                                        {#if tLine}
                                            <div class="ws-tree-line" title={tLine}>{tLine}</div>
                                        {/if}
                                    </div>
                                {/each}
                            </div>
                        {/if}
                    </div>
                {/each}
                {#if items.length === 0}
                    <div class="home-empty">
                        No workspaces yet — create one, or grab a scratch shell.
                    </div>
                {/if}
            </div>
            {#if idle.length > 0}
                <div class="home-sec">Idle</div>
                <div id="home-idle">
                    {#each idle as g (g.ws.name)}
                        {#each [g.ws, ...g.trees] as w (w.name)}
                            <div
                                class="idle-row"
                                class:tree={!!w.worktreeOf}
                                onclick={() => onopen(w.name)}
                                role="presentation"
                            >
                                <span class="idle-name"
                                    >{w.worktreeOf ? `⎇ ${w.name}` : w.name}</span
                                >
                                {@render wsTags(w)}
                                <span class="idle-root">{tilde(w.root || "")}</span>
                                <span class="home-spacer"></span>
                                <span class="ws-card-when">{ago(w.lastUsed || w.created)}</span>
                                {@render delBtn(w.name)}
                            </div>
                        {/each}
                    {/each}
                </div>
            {/if}
            {#if queueRows.length > 0 || queueErrors.length > 0}
                <div class="home-sec">Queue — work waiting to start</div>
                <div id="home-queue">
                    {#each queueRows as r (r.ws + r.issue.tracker + r.issue.key)}
                        <div class="dash-issue">
                            <span class="dash-issue-key">{r.issue.key}</span>
                            <span class="dash-issue-who" class:mine={r.issue.mine}
                                >{r.issue.mine ? "mine" : "open"}</span
                            >
                            <span class="dash-issue-title" title={r.issue.title}
                                >{r.issue.title}</span
                            >
                            <span class="dash-issue-ws" title="from {r.ws}'s queue">{r.ws}</span>
                            <button
                                class="home-btn dash-issue-go"
                                title="Start claude on this issue in a fresh worktree off {r.ws}"
                                disabled={starting !== ""}
                                onclick={() => void work(r.ws, r.issue)}
                                >{starting === r.issue.key ? "…" : "▶ work"}</button
                            >
                        </div>
                    {/each}
                    {#each queueErrors as e (e)}
                        <div class="dash-issue-err" title={e}>⚠ {e}</div>
                    {/each}
                </div>
            {/if}
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
