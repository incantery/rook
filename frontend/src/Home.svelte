<!-- Mission control — the app's landing screen: the answer to "what is going
     on across everything right now", and the deck you steer from.

     The unit is the AGENT. It used to be the workspace: a grid of cards with
     agents reduced to chips inside them, which meant the thing you actually
     came here for was countable but never addressable. Now every agent across
     every workspace is one flat, ordered, vim-navigable list — needs-you
     first — and the workspace is a column on the row. Press ↵ for the
     conversation, R for the raw pty: two chromes over one session, the same
     bargain as the editor's (docs/agent.md, amendment 2026-07-15).
     Workspaces and the cross-repo issue queue keep their own tabs; they are
     still how work starts and how trees get cleaned up.

     Data is GET /overview (one call, live rollups); on an old daemon it fails
     open to the bare /workspaces list and renders what it has — minus the
     ids, which costs the verbs and not the rows. The strip carries the
     app-wide status line: subscription usage windows + the raw-inference cost
     picture (zeros render — "$0.00 today" on a fresh start is information,
     not absence).

     Ordering, filtering and cursor motion live in deck.ts, tested there. This
     file is chrome, polling, and keys. -->
<script lang="ts">
    import {onMount, tick} from "svelte";

    import AgentSession from "./AgentSession.svelte";
    import UsageCluster from "./UsageCluster.svelte";
    import {
        counts,
        cycle,
        glyph,
        group,
        inTab,
        isAgentTab,
        match,
        move,
        rows,
        short,
        type DeckRow,
        type Tab,
    } from "./deck";
    import type {HostAPI, IssueInfo, IssuesResult, OverviewItem, StageInfo} from "./hostapi";
    import {app} from "./state.svelte";
    import {ago, tilde} from "./util";

    interface Props {
        api: HostAPI;
        onopen: (name: string) => void;
        /** open the workspace with a fresh first shell — the create flows
         *  (scratch, modal) need one to exist, not a dashboard landing */
        onspawn: (name: string) => void;
        /** start claude on this issue off that workspace — App owns the flow */
        onwork: (workspace: string, issue: IssueInfo) => Promise<void>;
        /** ↵ — open a claude session as a conversation (App owns the ladder) */
        onagent: (session: string) => void;
        /** R — attach the raw pty behind a row */
        onraw: (rookSession: string) => void;
        /** n — new agent, prefilled with the workspace you're looking at.
         *  From here it spawns host-side and joins the list; App owns that. */
        onnew: (workspace: string) => void;
    }
    let {api, onopen, onspawn, onwork, onagent, onraw, onnew}: Props = $props();

    let items = $state<OverviewItem[]>([]);
    let error = $state("");
    let modalOpen = $state(false);
    let modalName = $state("");
    let modalRoot = $state("");
    let nameEl = $state<HTMLInputElement | null>(null);
    let starting = $state(""); // issue key being started (debounce the ▶)

    // ==== the deck ====
    // Tabs, ordering, filtering and cursor motion all live in deck.ts and are
    // tested there; this file is chrome, polling, and keys.
    //
    // The tab, filter, cursor and grouping live on `app` (see
    // state.svelte.ts): Home is an {#if}, so anything held here dies the
    // moment you open a row — which is the one thing you came to do.
    const deck = $derived(app.deck);
    let deckEl = $state<HTMLElement | null>(null);
    let filterEl = $state<HTMLInputElement | null>(null);
    /** `g` pressed once, waiting to see if it's `gg` */
    let gArmed = $state(false);

    const allRows = $derived(rows(items));
    const tally = $derived(counts(allRows));
    const visible = $derived(allRows.filter((r) => inTab(r, deck.tab) && match(r, deck.query)));
    // deckGroups, not groups: the workspace-lineage `groups` below is a
    // different thing entirely, and these two live in one file.
    const deckGroups = $derived(group(visible));
    /** What j/k walk. Grouping REORDERS rows, so the cursor has to index what
     *  is on screen — indexing the flat list while rendering the grouped one
     *  would move the highlight to an unrelated row. One list, both modes. */
    const navRows = $derived(deck.grouped ? deckGroups.flatMap((g) => g.rows) : visible);
    /** Row -> its index in navRows, for the grouped render.
     *
     *  The grouped markup needs each row's position in the flat nav order, and
     *  indexOf per row is quadratic: 200 agents is 40k scans on every keypress
     *  AND every 5s poll. Same object refs flow through group(), so a Map is
     *  exact and O(n). */
    const navIndex = $derived(new Map(navRows.map((r, i) => [r, i])));
    /** The cursor addresses a POSITION, but rows come and go under it on
     *  every 5s poll. Clamping keeps it in range; selection is re-read from
     *  the list each time rather than held, so a vanished row degrades to its
     *  neighbour instead of to a stale object.
     *
     *  Clamped HERE as well as in the effect below: the effect runs after the
     *  render flush, so a bare navRows[cursor] renders one frame of null when
     *  the list shrinks under a bottom cursor — which unmounts the rail and
     *  refetches it a tick later, for nothing. */
    const selected = $derived<DeckRow | null>(
        navRows[Math.min(deck.cursor, navRows.length - 1)] ?? null,
    );

    $effect(() => {
        if (deck.cursor > navRows.length - 1) deck.cursor = Math.max(0, navRows.length - 1);
    });

    /** The session the rail actually renders, a beat behind the cursor.
     *
     *  The rail fetches a 200-record transcript per session it's handed. Wired
     *  straight to `selected`, holding j down a 40-row deck fires ~40 of them
     *  and throws 39 away, with the rail flashing "reading transcript…" the
     *  whole way. Waiting for the cursor to sit still costs nothing when you
     *  step deliberately and everything when you scroll. */
    let railSession = $state<string | null>(null);
    $effect(() => {
        const want = selected?.session ?? null;
        if (want === railSession) return; // already there; don't re-arm
        const t = setTimeout(() => (railSession = want), 150);
        return () => clearTimeout(t);
    });

    // needs-you fallback for old daemons whose /overview is missing: the
    // attention poll knows the same count, just without the rest of the rollup
    const attnCounts = $derived.by(() => {
        const byWs = new Map<string, number>();
        for (const it of app.attention) byWs.set(it.workspace, (byWs.get(it.workspace) ?? 0) + 1);
        return byWs;
    });

    const attnOf = (w: OverviewItem) => w.attention ?? attnCounts.get(w.name) ?? 0;
    const workingOf = (w: OverviewItem) =>
        (w.agents ?? []).filter((a) => a.state === "working").length;

    /** One group per source workspace, its task trees under it — they're
     *  work surfaces for one task, not peers. One level of nesting only:
     *  a tree carved from another tree (▶ work inside one does this) hangs
     *  under the topmost listed ancestor, and a tree whose source is gone
     *  stands on its own (fail open, lineage on the card). */
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
        const byName = new Map(items.map((w) => [w.name, w]));
        const anchorOf = (w: OverviewItem): OverviewItem => {
            const seen = new Set<string>();
            let cur = w;
            while (cur.worktreeOf && byName.has(cur.worktreeOf) && !seen.has(cur.name)) {
                seen.add(cur.name);
                cur = byName.get(cur.worktreeOf)!;
            }
            return cur;
        };
        const gs: Group[] = items
            .filter((w) => anchorOf(w) === w)
            .map((ws) => {
                const trees = items
                    .filter((t) => t !== ws && anchorOf(t) === ws)
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
    /** The strip's headline count.
     *
     *  Max of two sources, and both are load-bearing. The deck's own tally is
     *  the truth when /overview carries agents — it counts the very rows on
     *  screen, so the strip cannot contradict the `needs you` tab, which it
     *  did when this read workspace attention alone. The workspace rollup
     *  survives as the floor because an old daemon sends no agents at all and
     *  the attention poll is then the only thing that knows. */
    const needsYou = $derived(
        Math.max(
            tally.needs_input,
            groups.reduce((n, g) => n + g.attention, 0),
        ),
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

    /** Checklist glyphs: ✓ done, ✗ error, ◉ running-but-needs-you,
     *  ● running, ○ pending. */
    function stageGlyph(s: StageInfo): string {
        if (s.status === "done") return "✓";
        if (s.status === "error") return "✗";
        if (s.status === "running") return s.needsInput ? "◉" : "●";
        return "○";
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
        // overview items are a superset of the registry snapshot — keep the
        // shared lineage store (Titlebar/Picker/Dashboard) fresh from here
        app.workspaces = items;
    }

    export function showError(msg: string): void {
        error = msg;
        setTimeout(() => (error = ""), 6000);
    }

    /** Take real DOM focus.
     *
     *  Not decoration: #terminals is always mounted (visibility is a display
     *  toggle, never {#if}), so xterm's hidden textarea holds focus unless
     *  something takes it. That is why keys pressed on this screen used to
     *  land in the terminal you last had open. The zone follows DOM focus
     *  rather than tracking it, so the fix is to actually hold it. */
    export function focusDeck(): void {
        deckEl?.focus({preventScroll: true});
    }

    onMount(focusDeck);

    function openNormal(r: DeckRow | null): void {
        if (!r) return;
        if (!r.session) {
            showError("no transcript for this session yet — R opens its terminal");
            return;
        }
        onagent(r.session);
    }

    function openRaw(r: DeckRow | null): void {
        if (!r) return;
        if (!r.rookSession) {
            showError("no live terminal for this agent — ↵ opens the conversation");
            return;
        }
        onraw(r.rookSession);
    }

    function cycleTab(delta: number): void {
        deck.tab = cycle(deck.tab, delta);
        deck.cursor = 0;
    }

    /** The deck's keys. Vim where vim has an opinion, mnemonic where it
     *  doesn't.
     *
     *  The g-prefix carries its real vim meanings: `gg` to the top, `gt`/`gT`
     *  across tabs. That costs the design's `g = group by` — grouping is `w`
     *  (by workspace) instead, which is the better mnemonic anyway since rook
     *  groups by workspace and not by "project". It also buys back Tab: an
     *  earlier cut cycled tabs with it, which meant swallowing the one key
     *  every keyboard user expects to move focus, on a screen full of buttons.
     *
     *  A g-prefix followed by anything unbound consumes the g and lets the key
     *  act — tmux's rule, and forgiving in the direction that matters. */
    function onKey(e: KeyboardEvent): void {
        // Spend the pending g on ANY key, before every early return below.
        // Read late and it leaks: arm g, click into the filter, come back, and
        // your next g jumps to the top instead of arming.
        const g = gArmed;
        gArmed = false;

        const tgt = e.target as HTMLElement | null;
        // The filter input owns everything while it has focus — j is a letter
        // there, not a motion. Escape hands the deck back.
        if (tgt instanceof HTMLInputElement || tgt instanceof HTMLTextAreaElement) {
            // Escape LEAVES the filter, it does not undo it — the filter you
            // just typed is the one you want to walk. Clearing is the second
            // press, on the deck. (An earlier cut cleared here, which made a
            // committed filter impossible: every route back to the rows wiped
            // the thing you filtered for.)
            //
            // Not mid-composition, though: with an IME, Escape dismisses the
            // candidate window, and stealing it there would blur the field out
            // from under a half-typed word.
            if (e.key === "Escape" && !e.isComposing) {
                e.preventDefault();
                e.stopPropagation();
                filterEl?.blur();
                focusDeck();
            }
            return;
        }
        // The rail has its own buttons ("older", "terminal ↗", tool expanders)
        // and they live inside #home. Without this, focusing one and pressing
        // Enter opens the conversation full-screen instead of clicking it —
        // preventDefault kills the button's synthesized click.
        if (tgt?.closest("button, [role=button]")) return;
        if (e.metaKey || e.ctrlKey || e.altKey) return; // App's chords and the leader
        if (modalOpen) return;

        const len = navRows.length;
        const step = (d: number) => {
            e.preventDefault();
            deck.cursor = move(deck.cursor, d, len);
        };

        if (g) {
            if (e.key === "g") return step(-len); // gg — top
            if (e.key === "t") {
                e.preventDefault();
                return cycleTab(1);
            }
            if (e.key === "T") {
                e.preventDefault();
                return cycleTab(-1);
            }
            // unbound after g: the g is spent, the key still acts
        }

        switch (e.key) {
            case "j":
            case "ArrowDown":
                return step(1);
            case "k":
            case "ArrowUp":
                return step(-1);
            case "g":
                e.preventDefault();
                gArmed = true;
                return;
            case "G":
                return step(len);
            case "Enter":
                e.preventDefault();
                return openNormal(selected);
            case "R":
                e.preventDefault();
                return openRaw(selected);
            case "n":
                e.preventDefault();
                // appends to this list; never a window. The row under the
                // cursor names the workspace — n usually means "another one
                // like this".
                onnew(selected?.workspace ?? "");
                return;
            case "w":
                e.preventDefault();
                deck.grouped = !deck.grouped;
                return;
            case "/":
                e.preventDefault();
                void tick().then(() => filterEl?.focus());
                return;
            case "Escape":
                e.preventDefault();
                if (deck.query) deck.query = "";
                return;
        }
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

    // Conflicts chip debounce: trees we've already spawned a resolver into
    // this session — the chip goes passive so a second click can't double-
    // spawn. The 60s PR poll clears the conflict flag (and the chip) once
    // the agent lands the merge; on spawn failure the button re-arms.
    let resolving = $state<string[]>([]);

    /** One-click conflict resolution: spawn an agent in the task tree with
     *  the host-built resolve-conflicts prompt (merge base in, keep both
     *  sides' intent, push — never rebase). */
    async function resolveConflicts(name: string): Promise<void> {
        if (resolving.includes(name)) return;
        resolving = [...resolving, name];
        try {
            await api.spawnTask(name, {preset: "resolve-conflicts"});
        } catch (err) {
            showError(String(err));
            resolving = resolving.filter((n) => n !== name);
        }
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
    // One issues fetch per repo-rooted source workspace; the host caches
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
        onspawn(name);
    }

    /** One-off task: auto-named ephemeral workspace, straight into a shell.
     *  The host discards it when its last session exits. */
    export async function scratch(): Promise<void> {
        const taken = new Set(items.map((w) => w.name));
        let n = 1;
        while (taken.has(`scratch-${n}`)) n++;
        const name = `scratch-${n}`;
        await api.createWorkspace(name, "", true);
        onspawn(name);
    }

    export function openModal(): void {
        modalName = "";
        modalRoot = "";
        modalOpen = true;
    }

    /** Close the create modal and take the keyboard back.
     *
     *  Same trap as App's focusBack: the modal's focused input unmounts,
     *  focus falls to <body>, and #home's onkeydown never fires again — the
     *  deck looks fine and answers nothing. (createFromModal is exempt: it
     *  navigates away.) */
    function closeModal(): void {
        modalOpen = false;
        focusDeck();
    }
</script>

{#snippet delBtn(name: string)}
    <button
        class={[
            "cursor-pointer appearance-none border-0 bg-transparent px-1 py-0.5 text-xs",
            forceArmed === name
                ? "text-red"
                : "text-transparent group-hover:text-lo hover:text-red",
        ]}
        title={forceArmed === name
            ? "Delete anyway — discards the task tree (branch survives)"
            : "Delete workspace (kills its shells)"}
        onclick={(e) => {
            e.stopPropagation();
            void del(name);
        }}>{forceArmed === name ? "✕!" : "✕"}</button
    >
{/snippet}

{#snippet wsTags(w: OverviewItem, nested: boolean)}
    {@const burn = app.costs?.live.find((l) => l.workspace === w.name)?.usd ?? 0}
    {#if burn >= 0.01}
        <span
            class="rounded-md bg-dim/12 px-1.5 py-0.5 font-mono text-xs text-dim"
            title="live claude sessions here, priced as API tokens">${burn.toFixed(2)}</span
        >
    {/if}
    {#if w.scratch}
        <span class="rounded-md bg-amber/12 px-1.5 py-0.5 font-mono text-xs text-amber"
            >scratch</span
        >
    {/if}
    {#if w.worktreeOf}
        <!-- nested under its source: the branch is the missing fact.
             floated to the top level (source gone): say the lineage. -->
        <span
            class="rounded-md bg-acc/12 px-1.5 py-0.5 font-mono text-xs text-acc"
            title="task tree of {w.worktreeOf} — a git worktree on branch {w.branch}"
            >{nested ? `⎇ ${w.branch}` : `task tree of ${w.worktreeOf} · ⎇ ${w.branch}`}</span
        >
    {/if}
    {#if w.issueRef}
        <span
            class="rounded-md bg-magenta/12 px-1.5 py-0.5 font-mono text-xs text-magenta"
            title="spawned for {w.issueRef.tracker} issue {w.issueRef.key}">{w.issueRef.key}</span
        >
    {/if}
    {#if w.pr?.state === "merged"}
        <button
            class="cursor-pointer rounded-md border-0 bg-magenta/18 px-1.5 py-0.5 font-mono text-xs text-magenta hover:bg-magenta/32"
            title="PR #{w.pr
                .number} merged — remove the task tree and delete {w.branch} (kills its shells)"
            onclick={(e) => {
                e.stopPropagation();
                void cleanup(w.name);
            }}>⇅ merged — clean up</button
        >
    {:else if w.pr?.state === "open" && w.pr.conflicts}
        {#if resolving.includes(w.name)}
            <span
                class="rounded-md bg-amber/15 px-1.5 py-0.5 font-mono text-xs text-amber"
                title="an agent is resolving PR #{w.pr.number}'s conflicts in this tree"
                >⚠ resolving…</span
            >
        {:else}
            <button
                class="cursor-pointer rounded-md border-0 bg-amber/15 px-1.5 py-0.5 font-mono text-xs text-amber hover:bg-amber/28"
                title="PR #{w.pr
                    .number} has merge conflicts — spawn an agent in this tree to merge the base branch and resolve them"
                onclick={(e) => {
                    e.stopPropagation();
                    void resolveConflicts(w.name);
                }}>⚠ conflicts — resolve</button
            >
        {/if}
    {:else if w.pr?.state === "open"}
        <span class="rounded-md bg-grn/12 px-1.5 py-0.5 font-mono text-xs text-grn" title={w.pr.url}
            >PR #{w.pr.number}</span
        >
    {:else if w.pr?.state === "closed"}
        <span
            class="rounded-md bg-red/12 px-1.5 py-0.5 font-mono text-xs text-red"
            title="PR #{w.pr.number} closed without merging">PR #{w.pr.number} closed</span
        >
    {:else if w.pr?.state === "none" && (w.pr.ahead ?? 0) > 0}
        <span
            class="rounded-md bg-amber/10 px-1.5 py-0.5 font-mono text-xs text-amber"
            title="{w.pr.ahead} commit(s) on {w.branch} with no PR — open one from the tree"
            >no PR yet</span
        >
    {/if}
{/snippet}

{#snippet card(w: OverviewItem, nested: boolean)}
    {@const chips = agentChips(w)}
    {@const line = agentLine(w)}
    <div
        class={[
            "group cursor-pointer rounded-lg border border-l-2 border-line/15 px-4 py-3.5 hover:-translate-y-px hover:border-line/40",
            w.worktreeOf ? "bg-acc/[0.035] [border-left-style:dashed]" : "bg-fg/[0.025]",
            attnOf(w) > 0 ? "border-l-amber" : w.worktreeOf ? "border-l-acc/60" : "border-l-acc",
        ]}
        onclick={() => onopen(w.name)}
        role="presentation"
    >
        <div class="mb-2 flex items-center gap-2">
            <span class="min-w-0 flex-1 truncate text-sm font-bold text-fg">{w.name}</span>
            {@render delBtn(w.name)}
            <span class="whitespace-nowrap font-mono text-xs text-lo"
                >{ago(w.lastUsed || w.created)}</span
            >
        </div>
        <div class="mb-3 truncate font-mono text-xs text-lo">{tilde(w.root || "") || "~"}</div>
        <div class="flex flex-wrap gap-1.5">
            <span
                class={[
                    "rounded-md px-1.5 py-0.5 font-mono text-xs",
                    w.sessions > 0 ? "bg-grn/12 text-grn" : "bg-fg/5 text-dim",
                ]}
            >
                {w.sessions > 0 ? `● ${w.sessions} live` : "idle"}
            </span>
            {#each chips as c (c.cls)}
                <span
                    class={[
                        "rounded-md px-1.5 py-0.5 font-mono text-xs",
                        c.cls === "needs_input"
                            ? "animate-attn-pulse bg-amber/12 text-amber"
                            : c.cls === "working"
                              ? "bg-grn/12 text-grn"
                              : "bg-fg/5 text-lo",
                    ]}>{c.text}</span
                >
            {/each}
            {#if w.git}
                <!-- a task tree's branch already sits on its lineage tag -->
                {#if !w.worktreeOf}
                    <span class="rounded-md bg-acc/12 px-1.5 py-0.5 font-mono text-xs text-acc"
                        >⎇ {w.git.branch}</span
                    >
                {/if}
                {#if w.git.dirty > 0}
                    <span class="rounded-md bg-amber/10 px-1.5 py-0.5 font-mono text-xs text-amber"
                        >● {w.git.dirty} modified</span
                    >
                {/if}
                {#if w.git.ahead > 0 || w.git.behind > 0}
                    <span class="rounded-md bg-fg/5 px-1.5 py-0.5 font-mono text-xs text-dim">
                        {[
                            w.git.ahead > 0 ? `↑${w.git.ahead}` : "",
                            w.git.behind > 0 ? `↓${w.git.behind}` : "",
                        ]
                            .filter(Boolean)
                            .join(" ")}
                    </span>
                {/if}
            {/if}
            {#each fgTools(w) as f (f)}
                <span class="rounded-md bg-fg/5 px-1.5 py-0.5 font-mono text-xs text-dim">{f}</span>
            {/each}
            {@render wsTags(w, nested)}
        </div>
        {#if w.stages?.length}
            <!-- the work item's pipeline at a glance: coding → review stages -->
            <div class="mt-2 flex flex-wrap gap-x-2.5 gap-y-1">
                {#each w.stages as s, si (si)}
                    <span
                        class={[
                            "whitespace-nowrap font-mono text-xs",
                            s.status === "done"
                                ? "text-grn"
                                : s.status === "error"
                                  ? "text-red"
                                  : s.status === "running"
                                    ? s.needsInput
                                        ? "animate-attn-pulse text-amber"
                                        : "animate-[stage-pulse_2.2s_ease-in-out_infinite] text-grn"
                                    : "text-lo",
                        ]}
                        title={s.detail || s.name}>{stageGlyph(s)} {s.name}</span
                    >
                {/each}
            </div>
        {/if}
        {#if line}
            <div class="mt-2 line-clamp-2 text-xs leading-normal text-dim" title={line}>{line}</div>
        {/if}
    </div>
{/snippet}

{#snippet deckRow(r: DeckRow, i: number)}
    {@const on = i === deck.cursor}
    <div
        class={[
            "relative flex h-10.5 shrink-0 cursor-pointer items-center border-b border-line/8 pl-10 pr-4",
            on ? "bg-acc/8" : "hover:bg-fg/[0.03]",
        ]}
        onclick={() => (deck.cursor = i)}
        ondblclick={() => openNormal(r)}
        role="presentation"
    >
        {#if on}
            <span class="absolute inset-y-0 left-0 w-0.75 bg-acc"></span>
            <span class="absolute left-3.5 font-mono text-xs text-acc">›</span>
        {/if}
        <span class="flex w-24 shrink-0 items-center gap-2">
            <span
                class={[
                    "font-mono text-xs",
                    r.state === "needs_input"
                        ? "animate-attn-pulse text-amber"
                        : r.state === "working"
                          ? "text-grn"
                          : "text-lo",
                ]}>{glyph(r.state)} {short(r.state)}</span
            >
        </span>
        <!-- the workspace is a COLUMN now, not the container -->
        <span
            class="w-33 shrink-0 truncate pr-3 font-mono text-xs text-dim"
            title={r.worktreeOf ? `task tree of ${r.worktreeOf} · ⎇ ${r.branch}` : r.workspace}
            >{r.worktreeOf ? "⎇ " : ""}{r.workspace}</span
        >
        <span
            class={["min-w-0 flex-1 truncate pr-3.5 text-sm", on ? "text-fg" : "text-dim"]}
            title={r.ask || r.title}>{r.title}</span
        >
        {#if r.tool}
            <span class="w-20 shrink-0 truncate pr-2 font-mono text-xs text-lo">{r.tool}</span>
        {/if}
        {#if (r.costUsd ?? 0) >= 0.01}
            <span class="w-15 shrink-0 text-right font-mono text-xs text-lo"
                >${r.costUsd!.toFixed(2)}</span
            >
        {/if}
        <span class="w-14 shrink-0 text-right font-mono text-xs text-lo"
            >{r.lastEvent ? ago(r.lastEvent) : ""}</span
        >
        <span class="w-16 shrink-0 truncate text-right font-mono text-xs text-lo"
            >{r.model ?? ""}</span
        >
    </div>
{/snippet}

{#snippet destBtn(id: Tab, label: string, n: number | null, active: boolean)}
    <!-- a DESTINATION: where you are, so an underline tab, not a filter chip -->
    <button
        class={[
            "-mb-px cursor-pointer appearance-none border-x-0 border-b-2 border-t-0 border-solid bg-transparent px-3.5 py-2 text-[0.8125rem]",
            active ? "border-acc font-medium text-fg" : "border-transparent text-dim hover:text-fg",
        ]}
        onclick={() => {
            deck.tab = id;
            deck.cursor = 0;
            focusDeck();
        }}
        >{label}{#if n !== null}
            <span class="ml-1 font-mono text-[0.6875rem] text-lo">{n}</span>{/if}</button
    >
{/snippet}

{#snippet filterBtn(id: Tab, label: string, n: number, tone: string)}
    <!-- a STATUS FILTER over the agent list: a flat chip, not a place -->
    <button
        class={[
            "cursor-pointer whitespace-nowrap rounded-md border-0 px-2.5 py-1 text-xs",
            deck.tab === id
                ? "bg-fg/10 font-medium text-fg"
                : `bg-transparent ${tone} hover:bg-fg/6`,
        ]}
        onclick={() => {
            deck.tab = id;
            deck.cursor = 0;
            focusDeck();
        }}>{label} <span class="font-mono text-[0.6875rem] text-lo">{n}</span></button
    >
{/snippet}

<!-- role=application is the point, not a workaround: it tells assistive tech
     to pass keys through to us, which is what a vim surface needs. The lint
     wants listeners only on natively-interactive elements; this div IS the
     interactive element, and it must hold focus, or keys reach the terminal
     underneath — #terminals is always mounted, so its textarea keeps focus
     unless someone takes it. -->
<!-- svelte-ignore a11y_no_noninteractive_element_interactions -->
<div
    id="home"
    class="flex min-h-0 flex-1 flex-col outline-none"
    tabindex="-1"
    bind:this={deckEl}
    onkeydown={onKey}
    role="application"
    aria-label="Mission control"
>
    <div
        id="home-strip"
        class="flex h-13 shrink-0 items-center gap-2.5 pl-21 pr-5.5"
        style="--wails-draggable: drag"
    >
        <span class="text-sm font-bold text-fg">Rook</span>
        <span class="font-mono text-xs text-lo">mission control</span>
        {#if needsYou > 0}
            <span class="animate-attn-pulse font-mono text-xs text-amber"
                >◉ {needsYou} need{needsYou === 1 ? "s" : ""} you</span
            >
        {:else if liveShells > 0}
            <span class="font-mono text-xs text-grn">● {liveShells} live, none blocked</span>
        {/if}
        <span class="flex-1"></span>
        <!-- telemetry: the one usage cluster; ambient numbers ride the status bar -->
        <UsageCluster />
    </div>
    <!-- destinations vs filters: Agents / Queue / Workspaces are PLACES
         (underline tabs); the four agent states are a filter row below.
         The wrapper keeps the #home-tabs id — the deck.tab model underneath
         is unchanged, only its rendering split in two. -->
    <div id="home-tabs" class="shrink-0">
        <div class="flex items-center border-b border-line/12 px-3">
            {@render destBtn("all", "Agents", null, isAgentTab(deck.tab))}
            {@render destBtn("queue", "Queue", queueRows.length, deck.tab === "queue")}
            {@render destBtn("workspaces", "Workspaces", items.length, deck.tab === "workspaces")}
            <span class="flex-1"></span>
            <div class="flex items-center gap-2 pb-1.5">
                <button
                    class="cursor-pointer rounded-md border border-line/15 bg-transparent px-3 py-1.5 text-xs text-dim hover:bg-fg/8 hover:text-fg"
                    style="--wails-draggable: no-drag"
                    title="One-off shell; discarded when it exits"
                    onclick={() => void scratch()}>scratch shell</button
                >
                <button
                    class="cursor-pointer rounded-md border border-acc/45 bg-acc/8 px-3 py-1.5 text-xs text-acc hover:bg-acc/16"
                    style="--wails-draggable: no-drag"
                    onclick={openModal}>+ New workspace</button
                >
            </div>
        </div>
        {#if isAgentTab(deck.tab)}
            <div class="flex h-9 items-center gap-1.5 px-3">
                {@render filterBtn("all", "All", tally.all, "text-dim")}
                {@render filterBtn("needs_input", "Needs you", tally.needs_input, "text-amber")}
                {@render filterBtn("working", "Working", tally.working, "text-grn")}
                {@render filterBtn("quiet", "Quiet", tally.quiet, "text-lo")}
                <span class="flex-1"></span>
                <button
                    class="cursor-pointer rounded-md border-0 bg-transparent px-2 py-1 font-mono text-xs text-lo hover:bg-fg/8"
                    style="--wails-draggable: no-drag"
                    title="w — group by workspace"
                    onclick={() => {
                        deck.grouped = !deck.grouped;
                        focusDeck();
                    }}>{deck.grouped ? "grouped" : "flat"}</button
                >
                <div
                    class="flex items-center gap-1.5 rounded-md border border-line/15 bg-sunken/60 px-2 py-1"
                    style="--wails-draggable: no-drag"
                >
                    <span class="font-mono text-xs text-acc">/</span>
                    <input
                        bind:this={filterEl}
                        bind:value={deck.query}
                        class="w-48 border-0 bg-transparent font-mono text-xs text-fg outline-none placeholder:text-lo"
                        placeholder="state:needs ws:rook"
                        spellcheck="false"
                    />
                </div>
            </div>
        {/if}
    </div>

    {#if error}
        <div
            id="home-error"
            class="shrink-0 border-b border-red/40 bg-red/8 px-4 py-2 font-mono text-sm text-red"
        >
            {error}
        </div>
    {/if}

    <div class="flex min-h-0 flex-1">
        <div
            class={[
                "flex min-w-0 flex-1 flex-col",
                isAgentTab(deck.tab) && "lg:border-r lg:border-line/12",
            ]}
        >
            {#if isAgentTab(deck.tab)}
                <div
                    class="flex h-7 shrink-0 items-center border-b border-line/12 pl-10 pr-4 font-mono text-[0.625rem] uppercase tracking-wider text-lo"
                >
                    <span class="w-24 shrink-0">state</span>
                    <span class="w-33 shrink-0">workspace</span>
                    <span class="min-w-0 flex-1">task</span>
                    <span class="w-14 shrink-0 text-right">age</span>
                    <span class="w-16 shrink-0 text-right">model</span>
                </div>
                <div id="home-rows" class="flex min-h-0 flex-1 flex-col overflow-y-auto">
                    {#if navRows.length === 0}
                        <div class="p-10 text-center text-sm text-lo">
                            {allRows.length === 0
                                ? "No agents running. Press n to start one."
                                : "Nothing matches this filter."}
                        </div>
                    {:else if deck.grouped}
                        {#each deckGroups as g (g.workspace)}
                            <div
                                class="sticky top-0 z-2 flex items-center gap-2 border-b border-line/12 bg-sunken px-4 py-1.5"
                            >
                                <span class="font-mono text-xs font-semibold text-dim"
                                    >{g.workspace}</span
                                >
                                <span class="font-mono text-xs text-lo">{g.rows.length}</span>
                            </div>
                            {#each g.rows as r (r.key)}
                                {@render deckRow(r, navIndex.get(r) ?? 0)}
                            {/each}
                        {/each}
                    {:else}
                        {#each visible as r, i (r.key)}
                            {@render deckRow(r, i)}
                        {/each}
                    {/if}
                </div>
            {:else if deck.tab === "queue"}
                <div
                    class="mx-auto flex min-h-0 w-full max-w-300 flex-1 flex-col gap-1.5 overflow-y-auto p-4"
                >
                    {#each queueRows as r (r.ws + r.issue.tracker + r.issue.key)}
                        <div
                            class="flex shrink-0 items-center gap-2.5 rounded-lg border border-line/15 bg-fg/[0.02] px-3 py-2 text-sm"
                        >
                            <span class="whitespace-nowrap font-mono text-acc">{r.issue.key}</span>
                            <span
                                class={[
                                    "rounded-md px-1.5 py-px font-mono text-xs",
                                    r.issue.mine ? "bg-grn/12 text-grn" : "bg-fg/5 text-lo",
                                ]}>{r.issue.mine ? "mine" : "open"}</span
                            >
                            <span class="flex-1 truncate text-fg" title={r.issue.title}
                                >{r.issue.title}</span
                            >
                            <span
                                class="whitespace-nowrap rounded-md bg-acc/10 px-1.5 py-px font-mono text-xs text-acc"
                                title="from {r.ws}'s queue">{r.ws}</span
                            >
                            <button
                                class="flex cursor-pointer items-center gap-2 whitespace-nowrap rounded-lg border border-line/15 bg-fg/5 px-3 py-1.5 font-[inherit] text-sm font-semibold text-fg hover:bg-fg/10"
                                title="Start claude on this issue in a fresh task tree of {r.ws}"
                                disabled={starting !== ""}
                                onclick={() => void work(r.ws, r.issue)}
                                >{starting === r.issue.key ? "…" : "▶ work"}</button
                            >
                        </div>
                    {/each}
                    {#each queueErrors as e (e)}
                        <div class="shrink-0 truncate px-3 py-0.5 text-xs text-amber" title={e}>
                            ⚠ {e}
                        </div>
                    {/each}
                    {#if queueRows.length === 0 && queueErrors.length === 0}
                        <div class="p-10 text-center text-sm text-lo">
                            Nothing waiting — every tracked issue is either in flight or closed.
                        </div>
                    {/if}
                </div>
            {:else}
                <div
                    id="home-workspaces"
                    class="mx-auto flex min-h-0 w-full max-w-300 flex-1 flex-col overflow-y-auto px-5 pb-10 pt-3"
                >
                    <!-- scratch/new-workspace actions live on the destinations row -->
                    <div
                        id="home-grid"
                        class="grid shrink-0 grid-cols-[repeat(auto-fill,minmax(270px,1fr))] gap-3"
                    >
                        {#each active as g (g.ws.name)}
                            <div class="flex flex-col gap-2 self-start">
                                {@render card(g.ws, false)}
                                {#if g.trees.length > 0}
                                    <div
                                        class="ml-3 flex flex-col gap-2 border-l border-acc/30 pl-3"
                                    >
                                        {#each g.trees as t (t.name)}
                                            {@render card(t, true)}
                                        {/each}
                                    </div>
                                {/if}
                            </div>
                        {/each}
                        {#if items.length === 0}
                            <div class="col-span-full p-10 text-center text-sm text-lo">
                                No workspaces yet — create one, or grab a scratch shell.
                            </div>
                        {/if}
                    </div>
                    {#if idle.length > 0}
                        <div
                            class="mb-2.5 mt-6 shrink-0 text-xs font-bold uppercase tracking-wider text-lo"
                        >
                            Idle
                        </div>
                        <div id="home-idle" class="flex shrink-0 flex-col gap-1">
                            {#each idle as g (g.ws.name)}
                                {#each [g.ws, ...g.trees] as w, wi (w.name)}
                                    <div
                                        class={[
                                            "group flex cursor-pointer items-center gap-2 rounded-lg border border-line/15 bg-fg/[0.015] px-3 py-1.5 text-sm hover:border-line/40",
                                            wi > 0 && "ml-5.5",
                                        ]}
                                        onclick={() => onopen(w.name)}
                                        role="presentation"
                                    >
                                        <span
                                            class={[
                                                "whitespace-nowrap text-sm",
                                                wi > 0
                                                    ? "font-mono font-medium text-acc"
                                                    : "font-semibold text-fg",
                                            ]}>{w.worktreeOf ? `⎇ ${w.name}` : w.name}</span
                                        >
                                        {@render wsTags(w, wi > 0)}
                                        <span class="truncate font-mono text-xs text-lo"
                                            >{tilde(w.root || "")}</span
                                        >
                                        <span class="flex-1"></span>
                                        <span class="whitespace-nowrap font-mono text-xs text-lo"
                                            >{ago(w.lastUsed || w.created)}</span
                                        >
                                        {@render delBtn(w.name)}
                                    </div>
                                {/each}
                            {/each}
                        </div>
                    {/if}
                </div>
            {/if}
        </div>

        <!-- The detail rail: the selected agent's conversation, live. Hidden
             on narrow windows rather than squeezed — a 200px transcript is
             worse than none, and ↵ opens the same view full-size. -->
        {#if isAgentTab(deck.tab)}
            <div class="hidden w-100 shrink-0 flex-col bg-sunken/40 xl:flex">
                {#if railSession}
                    <!-- no {#key}: AgentSession re-reads on its own when the
                         session prop changes, so keying it only bought a full
                         destroy/recreate (DOM, poll interval, scroll state) per
                         deck.cursor step. -->
                    <div class="relative min-h-0 flex-1">
                        <AgentSession
                            {api}
                            session={railSession}
                            onjump={() => openRaw(selected)}
                        />
                    </div>
                {:else}
                    <div
                        class="flex flex-1 items-center justify-center p-8 text-center text-sm text-lo"
                    >
                        {selected ? "No transcript for this session yet." : "Nothing selected."}
                    </div>
                {/if}
            </div>
        {/if}
    </div>

    <!-- key hints + telemetry live in the global status bar now -->
</div>

{#if modalOpen}
    <div
        id="ws-modal"
        class="fixed inset-0 z-50 flex items-start justify-center bg-black/55 pt-[12vh]"
        onmousedown={(e) => e.target === e.currentTarget && closeModal()}
        onkeydown={(e) => {
            if (e.key === "Enter") void createFromModal();
            else if (e.key === "Escape") {
                e.stopPropagation();
                closeModal();
            }
        }}
        role="presentation"
    >
        <div
            class="w-150 max-w-[92vw] overflow-hidden rounded-xl border border-line/30 bg-overlay shadow-2xl"
        >
            <div class="border-b border-line/15 px-4.5 py-4 text-sm font-bold text-fg">
                New workspace
            </div>
            <div class="flex flex-col gap-4 p-4.5">
                <label
                    ><span class="mb-1.5 block text-xs font-semibold text-dim">Name</span><input
                        class="box-border w-full rounded-lg border border-line/15 bg-sunken/80 px-3 py-2 font-mono text-sm text-fg outline-none focus:border-acc"
                        placeholder="e.g. rook-core"
                        spellcheck="false"
                        bind:value={modalName}
                        bind:this={nameEl}
                    /></label
                >
                <label
                    ><span class="mb-1.5 block text-xs font-semibold text-dim"
                        >Directory (optional — or set it later from inside the workspace: cd
                        anywhere, then ` .)</span
                    ><input
                        class="box-border w-full rounded-lg border border-line/15 bg-sunken/80 px-3 py-2 font-mono text-sm text-fg outline-none focus:border-acc"
                        placeholder="~/go/src/github.com/incantery/rook"
                        spellcheck="false"
                        bind:value={modalRoot}
                    /></label
                >
            </div>
            <div class="flex justify-end gap-2 border-t border-line/15 px-4.5 py-3.5">
                <button
                    class="flex cursor-pointer items-center gap-2 rounded-lg border border-line/15 bg-fg/5 px-3 py-1.5 font-[inherit] text-sm font-semibold text-fg hover:bg-fg/10"
                    onclick={closeModal}>Cancel</button
                >
                <button
                    class="flex cursor-pointer items-center gap-2 rounded-lg border-0 bg-acc px-3 py-1.5 font-[inherit] text-sm font-semibold text-on-acc"
                    onclick={() => void createFromModal()}>Create workspace</button
                >
            </div>
        </div>
    </div>
{/if}
