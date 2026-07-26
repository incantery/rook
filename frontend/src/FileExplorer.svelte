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
        flattenVisible,
        parentPath,
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
        dir,
        active,
        onopen,
        onex,
    }: {
        api: HostAPI;
        workspace: string;
        /** the focused shell's cwd — roots the tree there (vim's experience);
         *  undefined = the workspace root */
        dir?: string;
        /** the workbench's focus zone is this pane — take the keyboard */
        active: boolean;
        onopen: (path: string) => void;
        /** `:` — raise the command line. The tree holds the keyboard but has
         *  no Monaco behind it, so vim's vocabulary has to arrive some other
         *  way or it isn't there at all. */
        onex?: () => void;
    } = $props();

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
    // the (workspace, dir) the current listing is for — the load effect's
    // dependencies invalidate whenever the parent rebuilds its tab snapshot
    // (every layout/focus changed()), so refetch only on an actual change
    let loadedKey = "";
    /** the scoped listing's prefix — node paths are relative to it; join to
     *  open, and to look up ws-relative decorations (statuses, threads) */
    let base = $state("");
    const fullOf = (p: string) => (base ? `${base}/${p}` : p);
    // directory paths that are expanded; reassigned (not mutated) so $state tracks it
    let expanded = $state<Set<string>>(new Set());
    // the dir set we last auto-expanded for; guards the seed from re-running
    // on every refetch and stomping a collapse the user just made
    let seeded = "";

    async function load(ws: string): Promise<void> {
        loading = true;
        error = "";
        try {
            // The tree is the only required call. changes/threads are
            // decoration: settle() them so a non-git or thread-less
            // workspace degrades to a plain tree instead of an error.
            const [files, ch, th] = await Promise.all([
                api.listFiles(ws, dir),
                api.changes(ws).catch(() => null),
                api.threads(ws).catch(() => []),
            ]);
            tree = buildFileTree(files.files);
            base = files.base ?? "";
            truncated = files.truncated ?? false;
            changed = ch?.files ?? [];
            threads = threadCounts(th);
            git = await api
                .workspaceStatus(ws)
                .then((s) => s.git ?? null)
                .catch(() => null);
        } catch (err) {
            error = String(err);
            tree = [];
        } finally {
            loading = false;
        }
    }

    // (re)load on mount and whenever the workspace or the scope dir changes
    $effect(() => {
        const key = `${workspace}\0${dir ?? ""}`;
        if (key === loadedKey) return;
        loadedKey = key;
        void load(workspace);
    });

    const statuses = $derived(statusMap(changed));
    const counts = $derived(changeCounts(changed));
    // a scoped (cwd-rooted) tree is exploration — statuses key ws-relative
    // paths so the Changed scope only exists at the workspace root
    const shown = $derived(scope === "changed" && !base ? pruneToChanged(tree, statuses) : tree);
    /** exactly the rows on screen, in order — what j/k walk */
    const rows = $derived(flattenVisible(shown, expanded));

    // The cursor is a PATH, not an index: rows are re-derived on every
    // expand/collapse/refetch, and an index would silently point at a
    // different file after any of them.
    let cursor = $state("");
    let treeEl = $state<HTMLElement | null>(null);
    const cursorAt = $derived(rows.findIndex((r) => r.node.path === cursor));

    // Taking the zone takes the keyboard. Landing with no cursor (or one whose
    // row is gone — a collapse or a scope flip can eat it) starts at the top.
    $effect(() => {
        if (!active) return;
        treeEl?.focus();
        if (rows.length > 0 && !rows.some((r) => r.node.path === cursor))
            cursor = rows[0].node.path;
    });

    function moveTo(i: number): void {
        if (i < 0 || i >= rows.length) return;
        cursor = rows[i].node.path;
        // keep the cursor row on screen; the tree is the scroll container
        queueMicrotask(() =>
            treeEl
                ?.querySelector('[data-cursor="true"]')
                ?.scrollIntoView({block: "nearest", behavior: "instant"}),
        );
    }

    function onTreeKey(e: KeyboardEvent): void {
        if (e.metaKey || e.ctrlKey || e.altKey) return; // chords belong to the workbench
        const row = cursorAt === -1 ? null : rows[cursorAt];
        switch (e.key) {
            case "j":
            case "ArrowDown":
                moveTo(cursorAt + 1);
                break;
            case "k":
            case "ArrowUp":
                moveTo(cursorAt - 1);
                break;
            case "h": {
                // an open directory closes; anything else climbs to its parent
                if (row?.node.dir && expanded.has(row.node.path)) {
                    toggle(row.node.path);
                    break;
                }
                const up = parentPath(row?.node.path ?? "");
                if (up) moveTo(rows.findIndex((r) => r.node.path === up));
                break;
            }
            case "l":
                // a closed directory opens; an open one steps into its first
                // child; a file opens in an editor pane
                if (!row) break;
                if (!row.node.dir) onopen(fullOf(row.node.path));
                else if (!expanded.has(row.node.path)) toggle(row.node.path);
                else moveTo(cursorAt + 1);
                break;
            case "Enter":
                if (!row) break;
                if (row.node.dir) toggle(row.node.path);
                else onopen(fullOf(row.node.path));
                break;
            case "g":
                moveTo(0);
                break;
            case "G":
                moveTo(rows.length - 1);
                break;
            case ":":
                // vim's command line, from a surface vim doesn't know about.
                // Without this the tree is a place where `:` silently does
                // nothing — the one key every vim reflex starts with.
                onex?.();
                break;
            default:
                return; // not ours — let it through
        }
        e.preventDefault();
        e.stopPropagation();
    }

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

    // Reveal (nvim's NvimTreeFindFile, ` f): expand down to the file and put
    // the cursor on it. Deferred through state because the first reveal can
    // race the initial load — the effect applies it once the tree is here.
    let pendingReveal = $state<string | null>(null);
    export function revealPath(path: string): void {
        pendingReveal = path;
    }

    /** Put the keyboard back on the listing. The `active` effect can't do it:
     *  it only fires when the prop CHANGES, and a `:` prompt takes focus
     *  without the zone ever moving off this pane. */
    export function focus(): void {
        treeEl?.focus();
    }
    $effect(() => {
        if (loading || pendingReveal == null) return;
        const full = pendingReveal;
        pendingReveal = null;
        // a scoped tree holds base-relative names; a target outside the
        // scope can't be revealed here (the caller resets the scope first)
        const path = base
            ? full.startsWith(base + "/")
                ? full.slice(base.length + 1)
                : null
            : full;
        if (path == null) return;
        // the Changed scope may not hold this file — widen rather than strand
        if (scope === "changed" && !statuses.has(path)) scope = "all";
        const dirs: string[] = [];
        for (let p = parentPath(path); p; p = parentPath(p)) dirs.push(p);
        expanded = new Set([...expanded, ...dirs]);
        cursor = path;
        queueMicrotask(() =>
            treeEl
                ?.querySelector('[data-cursor="true"]')
                ?.scrollIntoView({block: "center", behavior: "instant"}),
        );
    });
</script>

<div class="flex h-full min-h-0 flex-col">
    <div class="flex shrink-0 items-center gap-2 border-b border-line/15 px-2 py-1">
        <span class="min-w-0 flex-1 truncate font-mono text-xs text-dim" title={workspace}
            >{workspace}</span
        >
        <button
            class="flex-none cursor-pointer rounded-sm border border-line/15 px-1.5 py-px font-mono text-xs text-dim hover:border-acc hover:text-fg"
            title="refresh"
            onclick={() => void load(workspace)}>⟳</button
        >
    </div>

    {#if base}
        <div class="shrink-0 border-b border-line/15 px-2 py-1 font-mono text-[0.625rem] text-acc">
            in {base}
        </div>
    {/if}

    <!-- scope + rollup: only meaningful once we know the diff (and only at
         the workspace root — a scoped tree's statuses key differently) -->
    {#if changed.length > 0 && !base}
        <div class="flex shrink-0 items-center gap-1.5 border-b border-line/15 px-2 py-1.5">
            {#each SCOPES as [id, label] (id)}
                <button
                    class={"cursor-pointer rounded-md border px-2 py-0.5 text-[0.6875rem] font-semibold " +
                        (scope === id
                            ? "border-acc/40 bg-acc/15 text-acc"
                            : "border-line/15 text-lo hover:text-fg")}
                    onclick={() => (scope = id)}>{label}</button
                >
            {/each}
            <span class="flex-1"></span>
            <span class="flex items-center gap-1.5 font-mono text-[0.625rem]">
                {#if counts.added > 0}<span class="text-grn">{counts.added}+</span>{/if}
                {#if counts.modified > 0}<span class="text-amber">{counts.modified}~</span>{/if}
                {#if counts.deleted > 0}<span class="text-red">{counts.deleted}−</span>{/if}
            </span>
        </div>
    {/if}

    <!-- The tree is the only scroll region, and the keyboard target: focus
         lands here (tabindex -1, so only the workbench puts it here), and the
         rows are plain divs. They were <button>s, but a button per row fights
         a roving cursor — every j/k would drag DOM focus with it. -->
    <!-- svelte-ignore a11y_no_noninteractive_element_to_interactive_role -->
    <div
        class="min-h-0 flex-1 overflow-y-auto py-1 outline-none"
        bind:this={treeEl}
        tabindex="-1"
        role="tree"
        aria-label="Files"
        onkeydown={onTreeKey}
    >
        {#if loading}
            <div class="px-3 py-2 font-mono text-xs text-dim">loading…</div>
        {:else if error}
            <div class="px-3 py-2 font-mono text-xs text-red">{error}</div>
        {:else if rows.length === 0}
            <div class="px-3 py-2 font-mono text-xs text-dim">
                {scope === "changed" ? "no changes" : "no files"}
            </div>
        {:else}
            {#each rows as r (r.node.path)}
                {@render row(r.node, r.depth)}
            {/each}
            {#if truncated && scope === "all"}
                <div class="px-3 py-2 font-mono text-[0.625rem] text-dim opacity-70">
                    list truncated — some files hidden
                </div>
            {/if}
        {/if}
    </div>

    {#if git}
        <div
            class="flex shrink-0 items-center gap-2 border-t border-line/15 px-2.5 py-1.5 font-mono text-[0.625rem] text-lo"
        >
            <span class="size-1.5 shrink-0 rounded-full bg-amber"></span>
            <span class="min-w-0 truncate" title={git.branch}>{git.branch}</span>
            <span class="flex-1"></span>
            {#if changed.length > 0}<span class="shrink-0">{changed.length} changed</span>{/if}
        </div>
    {/if}
</div>

<!-- One row, already flattened — flattenVisible did the nesting, so this only
     draws. The cursor reads as a filled row + accent edge while the pane holds
     focus, and fades to a faint outline when it doesn't: it must stay findable
     (you left it there) without competing with the real focus. -->
{#snippet row(node: FileNode, depth: number)}
    {@const status = statuses.get(fullOf(node.path))}
    {@const meta = status ? statusMeta(status) : null}
    {@const count = threads.get(fullOf(node.path)) ?? 0}
    {@const on = cursor === node.path}
    <div
        class={"flex w-full cursor-pointer items-center gap-1 border-l-2 py-0.5 pr-2 text-left font-mono text-xs " +
            (on && active
                ? "border-acc bg-acc/15 text-fg"
                : on
                  ? "border-line/30 bg-fg/5 text-fg"
                  : "border-transparent hover:bg-fg/5 ") +
            (on ? "" : node.dir || status ? "text-fg" : "text-dim")}
        style="padding-left: {depth * 12 + 4}px"
        data-cursor={on}
        role="treeitem"
        aria-selected={on}
        aria-expanded={node.dir ? expanded.has(node.path) : undefined}
        tabindex="-1"
        onclick={() => {
            cursor = node.path;
            if (node.dir) toggle(node.path);
            else onopen(fullOf(node.path));
        }}
        onkeydown={() => {}}
    >
        {#if node.dir}
            <span class="w-3 flex-none text-lo">{expanded.has(node.path) ? "▾" : "▸"}</span>
            <span class="flex-none text-acc/70">▦</span>
            <span class="min-w-0 flex-1 truncate font-semibold">{node.name}</span>
        {:else}
            <span class="w-3 flex-none"></span>
            <span class={"flex-none " + (meta ? TONE_TEXT[meta.tone] : "text-lo")}
                >{fileIcon(node.name)}</span
            >
            <span class="min-w-0 flex-1 truncate">{node.name}</span>
        {/if}
        {#if count > 0}
            <span
                class="inline-flex h-4 min-w-4 flex-none items-center justify-center rounded-md bg-acc/15 px-1 font-mono text-[0.59375rem] font-bold text-acc"
                title="{count} unresolved thread{count === 1 ? '' : 's'}">{count}</span
            >
        {:else if meta}
            <span
                class={"w-3.5 flex-none text-center text-[0.625rem] font-bold " +
                    TONE_TEXT[meta.tone]}>{meta.letter}</span
            >
        {:else}
            <span class="w-3.5 flex-none"></span>
        {/if}
    </div>
{/snippet}
