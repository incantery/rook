<!-- The file explorer: a left side-pane tenant (mounted in SidePane, which
     owns the "Explorer" title + × + scroll body). Turns the host's flat
     file list into a collapsible tree (buildFileTree, filetree.ts); a file
     row opens it in a Monaco editor pane via onopen. Read-only view of the
     workspace — no create/rename/delete yet. Styled with inline Tailwind
     utilities (README decision 7). -->
<script lang="ts">
    import type {HostAPI} from "./hostapi";
    import {buildFileTree, type FileNode} from "./filetree";

    let {
        api,
        workspace,
        onopen,
    }: {api: HostAPI; workspace: string; onopen: (path: string) => void} = $props();

    let tree = $state<FileNode[]>([]);
    let loading = $state(true);
    let error = $state("");
    let truncated = $state(false);
    // directory paths that are expanded; reassigned (not mutated) so $state tracks it
    let expanded = $state<Set<string>>(new Set());

    async function load(ws: string): Promise<void> {
        loading = true;
        error = "";
        try {
            const res = await api.listFiles(ws);
            tree = buildFileTree(res.files);
            truncated = res.truncated ?? false;
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

    function toggle(path: string): void {
        const next = new Set(expanded);
        if (!next.delete(path)) next.add(path);
        expanded = next;
    }
</script>

<div class="flex items-center gap-2 border-b border-line/15 px-2 py-1">
    <span class="min-w-0 flex-1 truncate font-mono text-xs text-dim" title={workspace}
        >{workspace}</span
    >
    <button
        class="flex-none cursor-pointer rounded-sm border border-line/15 bg-transparent px-1.5 py-px font-mono text-xs text-dim hover:border-acc hover:text-fg"
        title="refresh"
        onclick={() => void load(workspace)}>⟳</button
    >
</div>

{#if loading}
    <div class="px-3 py-2 font-mono text-xs text-dim">loading…</div>
{:else if error}
    <div class="px-3 py-2 font-mono text-xs text-red">{error}</div>
{:else if tree.length === 0}
    <div class="px-3 py-2 font-mono text-xs text-dim">no files</div>
{:else}
    {#each tree as node (node.path)}
        {@render row(node, 0)}
    {/each}
    {#if truncated}
        <div class="px-3 py-2 font-mono text-[10px] text-dim opacity-70">
            list truncated — some files hidden
        </div>
    {/if}
{/if}

<!-- one file/dir row; dirs recurse into their children when expanded -->
{#snippet row(node: FileNode, depth: number)}
    {#if node.dir}
        <button
            class="flex w-full appearance-none items-center gap-1 border-0 bg-transparent py-0.5 pr-2 text-left font-mono text-xs text-fg hover:bg-white/5"
            style="padding-left: {depth * 12 + 6}px"
            onclick={() => toggle(node.path)}
        >
            <span class="w-3 flex-none text-dim">{expanded.has(node.path) ? "▾" : "▸"}</span>
            <span class="truncate">{node.name}</span>
        </button>
        {#if expanded.has(node.path)}
            {#each node.children as child (child.path)}
                {@render row(child, depth + 1)}
            {/each}
        {/if}
    {:else}
        <button
            class="flex w-full appearance-none items-center gap-1 border-0 bg-transparent py-0.5 pr-2 text-left font-mono text-xs text-dim hover:bg-white/5 hover:text-fg"
            style="padding-left: {depth * 12 + 6}px"
            onclick={() => onopen(node.path)}
        >
            <span class="w-3 flex-none"></span>
            <span class="truncate">{node.name}</span>
        </button>
    {/if}
{/snippet}
