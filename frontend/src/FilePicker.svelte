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

    const items = $derived.by((): string[] => {
        const q = query.trim().toLowerCase();
        const out: string[] = [];
        for (const f of files) {
            if (q && !f.toLowerCase().includes(q)) continue;
            out.push(f);
            if (out.length === RENDER_CAP) break;
        }
        return out;
    });

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
    id="file-picker"
    class="overlay"
    onmousedown={(e) => e.target === e.currentTarget && onclose()}
    role="presentation"
>
    <div class="pal-panel">
        <div class="pal-inputrow">
            <span class="pal-chevron">›</span>
            <input
                class="pal-input"
                placeholder="Open file (read-only)…"
                spellcheck="false"
                bind:this={inputEl}
                bind:value={query}
                oninput={() => (sel = 0)}
                onkeydown={onKeydown}
            />
            <span class="pal-esc">esc</span>
        </div>
        <div class="pal-list" bind:this={listEl}>
            {#if error}
                <div class="pal-item"><span class="pal-cat">{error}</span></div>
            {:else if loaded && items.length === 0}
                <div class="pal-item"><span class="pal-cat">no matching files</span></div>
            {/if}
            {#each items as path, i (path)}
                <div
                    class="pal-item"
                    class:sel={i === sel}
                    onmousedown={(e) => {
                        e.preventDefault();
                        pick(path);
                    }}
                    role="presentation"
                >
                    <span class="pal-title">{path}</span>
                </div>
            {/each}
        </div>
        <div class="pal-footer">
            <span>↑↓ / ^j ^k navigate</span><span>↵ open</span>
            <span class="pal-spacer"></span>
            <span>
                {files.length} files{listTruncated ? " (list truncated)" : ""}{items.length ===
                RENDER_CAP
                    ? " · keep typing to narrow"
                    : ""}
            </span>
        </div>
    </div>
</div>
