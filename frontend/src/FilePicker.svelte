<!-- File picker (` e) — the workspace's files (git's view in repos, a
     bounded walk elsewhere), substring-filtered, Enter opens the
     read-only Monaco viewer. Reuses the palette's shell. -->
<script lang="ts">
    import {onMount} from "svelte";
    import type {HostAPI} from "./hostapi";
    import {app} from "./state.svelte";

    interface Props {
        api: HostAPI;
        onopen: (path: string) => void;
        onclose: () => void;
    }
    let {api, onopen, onclose}: Props = $props();

    /** big repos list 10k paths — render only this many matches */
    const RENDER_CAP = 200;

    let query = $state("");
    let sel = $state(0);
    let files = $state<string[]>([]);
    let listTruncated = $state(false);
    let loaded = $state(false);
    let error = $state("");
    let inputEl: HTMLInputElement;
    let listEl: HTMLElement;

    onMount(async () => {
        try {
            const res = await api.listFiles(app.workspace);
            files = res.files;
            listTruncated = res.truncated ?? false;
        } catch (err) {
            console.error("file picker: list failed", err);
            error = String(err).includes(" 404 ")
                ? "this rook-host predates the file viewer — relaunch rook"
                : `couldn't list files: ${err}`;
        }
        loaded = true;
    });

    // Open buffers first, then the rest of the repo — this picker is `:ls`
    // and `:find` in one box, which is what makes the buffer list visible
    // without spending a tab bar on it. Both halves take the same filter, and
    // a buffer never repeats in the tail.
    const items = $derived.by((): string[] => {
        const q = query.trim().toLowerCase();
        const hit = (f: string) => !q || f.toLowerCase().includes(q);
        const open = app.buffers.filter(hit);
        const openSet = new Set(open);
        const out: string[] = [...open];
        for (const f of files) {
            if (!hit(f) || openSet.has(f)) continue;
            out.push(f);
            if (out.length === RENDER_CAP) break;
        }
        return out;
    });
    /** how many leading items are open buffers — the list draws the seam */
    const openCount = $derived(
        app.buffers.filter(
            (f) => !query.trim() || f.toLowerCase().includes(query.trim().toLowerCase()),
        ).length,
    );

    function pick(path: string | undefined) {
        if (!path) return;
        onclose();
        onopen(path);
    }

    function onKeydown(e: KeyboardEvent) {
        // vim/fzf motions — bare j/k must keep typing into the filter
        const down = e.key === "ArrowDown" || (e.ctrlKey && (e.key === "j" || e.key === "n"));
        const up = e.key === "ArrowUp" || (e.ctrlKey && (e.key === "k" || e.key === "p"));
        if (down) {
            e.preventDefault();
            sel = Math.min(sel + 1, items.length - 1);
        } else if (up) {
            e.preventDefault();
            sel = Math.max(sel - 1, 0);
        } else if (e.key === "Enter") {
            e.preventDefault();
            pick(items[sel]);
        } else if (e.key === "Escape") {
            e.preventDefault();
            e.stopPropagation();
            onclose();
        }
    }

    $effect(() => {
        inputEl.focus();
    });
    $effect(() => {
        void sel;
        listEl?.querySelector(".sel")?.scrollIntoView({block: "nearest"});
    });
</script>

<div
    class="fixed inset-0 z-50 flex items-start justify-center bg-black/55 pt-[12vh]"
    onmousedown={(e) => e.target === e.currentTarget && onclose()}
    role="presentation"
>
    <div
        class="w-150 max-w-[92vw] overflow-hidden rounded-xl border border-line/30 bg-overlay shadow-2xl"
    >
        <div class="flex items-center gap-2.5 border-b border-line/15 px-4 py-3">
            <span class="font-mono text-sm text-lo">›</span>
            <input
                class="flex-1 border-0 bg-transparent font-[inherit] text-base text-fg outline-none"
                placeholder="Open file (read-only)…"
                spellcheck="false"
                bind:this={inputEl}
                bind:value={query}
                oninput={() => (sel = 0)}
                onkeydown={onKeydown}
            />
            <span class="rounded border border-line/15 px-1.5 py-0.5 font-mono text-xs text-lo"
                >esc</span
            >
        </div>
        <div class="max-h-[48vh] overflow-y-auto p-1.5" bind:this={listEl}>
            {#if error}
                <div class="flex items-center px-3 py-2">
                    <span class="text-xs uppercase tracking-wider text-lo">{error}</span>
                </div>
            {:else if loaded && items.length === 0}
                <div class="flex items-center px-3 py-2">
                    <span class="text-xs uppercase tracking-wider text-lo">no matching files</span>
                </div>
            {/if}
            {#each items as path, i (path)}
                {#if i === 0 && openCount > 0}
                    <div
                        class="px-3 pb-1 pt-1.5 text-[10px] font-bold uppercase tracking-wider text-lo"
                    >
                        Open buffers
                    </div>
                {/if}
                {#if i === openCount && openCount > 0}
                    <div
                        class="mt-1 border-t border-line/15 px-3 pb-1 pt-2 text-[10px] font-bold uppercase tracking-wider text-lo"
                    >
                        All files
                    </div>
                {/if}
                <!-- .sel stays as a JS scroll-into-view hook, not a style -->
                <div
                    class={[
                        "flex cursor-pointer items-center gap-3 rounded-md px-3 py-2 hover:bg-acc/15",
                        i === sel && "bg-acc/15",
                    ]}
                    class:sel={i === sel}
                    onmousedown={(e) => {
                        e.preventDefault();
                        pick(path);
                    }}
                    role="presentation"
                >
                    <span class={"flex-1 text-sm " + (i < openCount ? "text-fg" : "text-dim")}
                        >{path}</span
                    >
                    {#if i < openCount}
                        <span class="font-mono text-[10px] text-lo">buffer</span>
                    {/if}
                </div>
            {/each}
        </div>
        <div
            class="flex items-center gap-4 border-t border-line/15 px-4 py-2 font-mono text-xs text-lo"
        >
            <span>↑↓ / ^j ^k navigate</span><span>↵ open</span>
            <span class="flex-1"></span>
            <span>
                {files.length} files{listTruncated ? " (list truncated)" : ""}{items.length ===
                RENDER_CAP
                    ? " · keep typing to narrow"
                    : ""}
            </span>
        </div>
    </div>
</div>
