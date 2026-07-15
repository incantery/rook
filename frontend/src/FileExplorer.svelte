<!-- The file explorer: a left side-pane tenant (mounted in SidePane, which
     owns the "Explorer" title + × and a scrolling body). Turns the host's
     flat file list into a collapsible tree (buildFileTree, filetree.ts) and
     decorates it for review: git status letters, per-file thread counts, and
     a Changed/All scope. A file row opens it in a Monaco editor pane via
     onopen. Read-only view — no create/rename/delete yet. Styled with inline
     Tailwind utilities (README decision 7).

     Three fetches back this: files (the tree), changes (status + counts),
     threads (badges). Only `files` is load-bearing — a workspace with no git
     (a scratch dir) still lists fine; it just loses the scope pills and the
     branch footer rather than erroring. -->
<script lang="ts">
    import type {ChangedFile, GitInfo, HostAPI} from "./hostapi";
    import {
        buildFileTree,
        changeCounts,
        dirPaths,
        fileIcon,
        pruneToChanged,
        statusMap,
        statusMeta,
        threadCounts,
        type ExplorerScope,
        type FileNode,
        type StatusTone,
    } from "./filetree";

    let {
        api,
        workspace,
        onopen,
    }: {api: HostAPI; workspace: string; onopen: (path: string) => void} = $props();

    // Tone → literal class names. Tailwind scans source for literal strings,
    // so this must never be `text-${tone}` (that emits nothing).
    const TONE_TEXT: Record<StatusTone, string> = {
        grn: "text-grn",
        amber: "text-amber",
        red: "text-red",
        acc: "text-acc",
        lo: "text-lo",
    };
    const SCOPES: [ExplorerScope, string][] = [
        ["changed", "Changed"],
        ["all", "All files"],
    ];

    let tree = $state<FileNode[]>([]);
    let loading = $state(true);
    let error = $state("");
    let truncated = $state(false);
    let changed = $state<ChangedFile[]>([]);
    let git = $state<GitInfo | null>(null);
    let threads = $state<Map<string, number>>(new Map());
    let scope = $state<ExplorerScope>("all");
    // directory paths that are expanded; reassigned (not mutated) so $state tracks it
    let expanded = $state<Set<string>>(new Set());
    // the dir set we last auto-expanded for; guards the seed from re-running
    // on every refetch and stomping a collapse the user just made
    let seeded = "";
    // first load per workspace picks the scope; later loads must not re-pick
    let scopedFor = "";

    async function load(ws: string): Promise<void> {
        loading = true;
        error = "";
        try {
            // The tree is the only required call. changes/threads are
            // decoration: settle() them so a non-git or thread-less
            // workspace degrades to a plain tree instead of an error.
            const [files, ch, th] = await Promise.all([
                api.listFiles(ws),
                api.changes(ws).catch(() => null),
                api.threads(ws).catch(() => []),
            ]);
            tree = buildFileTree(files.files);
            truncated = files.truncated ?? false;
            changed = ch?.files ?? [];
            threads = threadCounts(th);
            git = await api
                .workspaceStatus(ws)
                .then((s) => s.git ?? null)
                .catch(() => null);
            // Default to Changed when there IS a diff to review — rook is a
            // review tool first — but never strand the pane on an empty list
            // for a clean tree. Decided once per workspace so a refetch that
            // lands on zero changes can't yank the scope out from under you.
            if (scopedFor !== ws) {
                scopedFor = ws;
                scope = changed.length > 0 ? "changed" : "all";
            }
        } catch (err) {
            error = String(err);
            tree = [];
        } finally {
            loading = false;
        }
    }

    // (re)load on mount and whenever the workspace changes
    $effect(() => {
        void load(workspace);
    });

    const statuses = $derived(statusMap(changed));
    const counts = $derived(changeCounts(changed));
    const shown = $derived(scope === "changed" ? pruneToChanged(tree, statuses) : tree);

    // A changed-only tree collapsed to its roots shows nothing useful, so
    // open its dirs — but only when the dir set itself changes, so a refetch
    // never re-expands what the user just collapsed.
    $effect(() => {
        if (scope !== "changed") return;
        const dirs = dirPaths(shown);
        const key = dirs.join("\n");
        if (key === seeded) return;
        seeded = key;
        expanded = new Set([...expanded, ...dirs]);
    });

    function toggle(path: string): void {
        const next = new Set(expanded);
        if (!next.delete(path)) next.add(path);
        expanded = next;
    }
</script>

<div class="flex h-full min-h-0 flex-col">
    <div class="flex shrink-0 items-center gap-2 border-b border-line/15 px-2 py-1">
        <span class="min-w-0 flex-1 truncate font-mono text-xs text-dim" title={workspace}
            >{workspace}</span
        >
        <button
            class="flex-none cursor-pointer rounded-sm border border-line/15 bg-transparent px-1.5 py-px font-mono text-xs text-dim hover:border-acc hover:text-fg"
            title="refresh"
            onclick={() => void load(workspace)}>⟳</button
        >
    </div>

    <!-- scope + rollup: only meaningful once we know the diff -->
    {#if changed.length > 0}
        <div class="flex shrink-0 items-center gap-1.5 border-b border-line/15 px-2 py-1.5">
            {#each SCOPES as [id, label] (id)}
                <button
                    class={"cursor-pointer rounded-md border px-2 py-0.5 text-[11px] font-semibold " +
                        (scope === id
                            ? "border-acc/40 bg-acc/15 text-acc"
                            : "border-line/15 bg-transparent text-lo hover:text-fg")}
                    onclick={() => (scope = id)}>{label}</button
                >
            {/each}
            <span class="flex-1"></span>
            <span class="flex items-center gap-1.5 font-mono text-[10px]">
                {#if counts.added > 0}<span class="text-grn">{counts.added}+</span>{/if}
                {#if counts.modified > 0}<span class="text-amber">{counts.modified}~</span>{/if}
                {#if counts.deleted > 0}<span class="text-red">{counts.deleted}−</span>{/if}
            </span>
        </div>
    {/if}

    <!-- the tree is the only scroll region -->
    <div class="min-h-0 flex-1 overflow-y-auto py-1">
        {#if loading}
            <div class="px-3 py-2 font-mono text-xs text-dim">loading…</div>
        {:else if error}
            <div class="px-3 py-2 font-mono text-xs text-red">{error}</div>
        {:else if shown.length === 0}
            <div class="px-3 py-2 font-mono text-xs text-dim">
                {scope === "changed" ? "no changes" : "no files"}
            </div>
        {:else}
            {#each shown as node (node.path)}
                {@render row(node, 0)}
            {/each}
            {#if truncated && scope === "all"}
                <div class="px-3 py-2 font-mono text-[10px] text-dim opacity-70">
                    list truncated — some files hidden
                </div>
            {/if}
        {/if}
    </div>

    {#if git}
        <div
            class="flex shrink-0 items-center gap-2 border-t border-line/15 px-2.5 py-1.5 font-mono text-[10px] text-lo"
        >
            <span class="size-1.5 shrink-0 rounded-full bg-amber"></span>
            <span class="min-w-0 truncate" title={git.branch}>{git.branch}</span>
            <span class="flex-1"></span>
            {#if changed.length > 0}<span class="shrink-0">{changed.length} changed</span>{/if}
        </div>
    {/if}
</div>

<!-- one file/dir row; dirs recurse into their children when expanded -->
{#snippet row(node: FileNode, depth: number)}
    {@const status = statuses.get(node.path)}
    {@const meta = status ? statusMeta(status) : null}
    {@const count = threads.get(node.path) ?? 0}
    {#if node.dir}
        <button
            class="flex w-full appearance-none items-center gap-1 border-0 bg-transparent py-0.5 pr-2 text-left font-mono text-xs text-fg hover:bg-fg/5"
            style="padding-left: {depth * 12 + 6}px"
            onclick={() => toggle(node.path)}
        >
            <span class="w-3 flex-none text-lo">{expanded.has(node.path) ? "▾" : "▸"}</span>
            <span class="flex-none text-acc/70">▦</span>
            <span class="truncate font-semibold">{node.name}</span>
        </button>
        {#if expanded.has(node.path)}
            {#each node.children as child (child.path)}
                {@render row(child, depth + 1)}
            {/each}
        {/if}
    {:else}
        <button
            class={"flex w-full appearance-none items-center gap-1 border-0 bg-transparent py-0.5 pr-2 text-left font-mono text-xs hover:bg-fg/5 hover:text-fg " +
                (status ? "text-fg" : "text-dim")}
            style="padding-left: {depth * 12 + 6}px"
            onclick={() => onopen(node.path)}
        >
            <span class="w-3 flex-none"></span>
            <span class={"flex-none " + (meta ? TONE_TEXT[meta.tone] : "text-lo")}
                >{fileIcon(node.name)}</span
            >
            <span class="min-w-0 flex-1 truncate">{node.name}</span>
            {#if count > 0}
                <span
                    class="inline-flex h-4 min-w-4 flex-none items-center justify-center rounded-md bg-acc/15 px-1 font-mono text-[9.5px] font-bold text-acc"
                    title="{count} unresolved thread{count === 1 ? '' : 's'}">{count}</span
                >
            {:else if meta}
                <span
                    class={"w-3.5 flex-none text-center text-[10px] font-bold " +
                        TONE_TEXT[meta.tone]}>{meta.letter}</span
                >
            {:else}
                <span class="w-3.5 flex-none"></span>
            {/if}
        </button>
    {/if}
{/snippet}
