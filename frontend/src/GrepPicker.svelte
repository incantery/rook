<!-- Live grep (` /) — type a pattern, the host searches the workspace as
     you type (git grep in repos), Enter opens the hit at its line and
     column. The file picker's shell, telescope's behavior. -->
<script lang="ts">
    import type {GrepHit, HostAPI} from "./hostapi";
    import {app} from "./state.svelte";

    interface Props {
        api: HostAPI;
        onopen: (path: string, line: number, col: number) => void;
        onclose: () => void;
    }
    let {api, onopen, onclose}: Props = $props();

    /** one keystroke of quiet before the wire — live, not chatty */
    const DEBOUNCE_MS = 120;
    /** single chars match half the repo — wait for two */
    const MIN_QUERY = 2;

    let query = $state("");
    let sel = $state(0);
    let hits = $state<GrepHit[]>([]);
    let truncated = $state(false);
    let note = $state("");
    let searching = $state(false);
    let inputEl: HTMLInputElement;
    let listEl: HTMLElement;

    // Debounced live search; a stale answer must never paint over a newer
    // one, so each request carries its sequence and late arrivals drop.
    let seq = 0;
    let timer: ReturnType<typeof setTimeout> | undefined;
    $effect(() => {
        const q = query.trim();
        clearTimeout(timer);
        if (q.length < MIN_QUERY) {
            seq++; // orphan any in-flight answer
            hits = [];
            truncated = false;
            note = "";
            searching = false;
            return;
        }
        searching = true;
        const mine = ++seq;
        timer = setTimeout(async () => {
            try {
                const res = await api.grep(app.workspace, q);
                if (mine !== seq) return;
                hits = res.hits;
                truncated = res.truncated ?? false;
                note = res.note ?? "";
                sel = 0;
            } catch (err) {
                if (mine !== seq) return;
                console.error("grep failed", err);
                hits = [];
                note = String(err).includes(" 404 ")
                    ? "grep needs a newer rook-host — relaunch rook"
                    : `search failed: ${err}`;
            }
            searching = false;
        }, DEBOUNCE_MS);
        return () => clearTimeout(timer);
    });

    function pick(hit: GrepHit | undefined) {
        if (!hit) return;
        onclose();
        onopen(hit.path, hit.line, hit.col);
    }

    function onKeydown(e: KeyboardEvent) {
        // vim/fzf motions — bare j/k must keep typing into the pattern
        const down = e.key === "ArrowDown" || (e.ctrlKey && (e.key === "j" || e.key === "n"));
        const up = e.key === "ArrowUp" || (e.ctrlKey && (e.key === "k" || e.key === "p"));
        if (down) {
            e.preventDefault();
            sel = Math.min(sel + 1, hits.length - 1);
        } else if (up) {
            e.preventDefault();
            sel = Math.max(sel - 1, 0);
        } else if (e.key === "Enter") {
            e.preventDefault();
            pick(hits[sel]);
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
        class="w-180 max-w-[92vw] overflow-hidden rounded-xl border border-line/30 bg-overlay shadow-2xl"
    >
        <div class="flex items-center gap-2.5 border-b border-line/15 px-4 py-3">
            <span class="font-mono text-sm text-lo">/</span>
            <input
                class="flex-1 border-0 bg-transparent font-[inherit] text-base text-fg outline-none"
                placeholder="Grep the workspace…"
                spellcheck="false"
                bind:this={inputEl}
                bind:value={query}
                onkeydown={onKeydown}
            />
            <span class="rounded border border-line/15 px-1.5 py-0.5 font-mono text-xs text-lo"
                >esc</span
            >
        </div>
        <div class="max-h-[48vh] overflow-y-auto p-1.5" bind:this={listEl}>
            {#if note}
                <div class="flex items-center px-3 py-2">
                    <span class="text-xs uppercase tracking-wider text-lo">{note}</span>
                </div>
            {:else if query.trim().length < MIN_QUERY}
                <div class="flex items-center px-3 py-2">
                    <span class="text-xs uppercase tracking-wider text-lo"
                        >type to search file contents</span
                    >
                </div>
            {:else if !searching && hits.length === 0}
                <div class="flex items-center px-3 py-2">
                    <span class="text-xs uppercase tracking-wider text-lo">no matches</span>
                </div>
            {/if}
            {#each hits as hit, i (`${hit.path}:${hit.line}:${hit.col}`)}
                <!-- .sel stays as a JS scroll-into-view hook, not a style -->
                <div
                    class={[
                        "flex cursor-pointer items-baseline gap-3 rounded-md px-3 py-1.5 hover:bg-acc/15",
                        i === sel && "bg-acc/15",
                    ]}
                    class:sel={i === sel}
                    onmousedown={(e) => {
                        e.preventDefault();
                        pick(hit);
                    }}
                    role="presentation"
                >
                    <span class="shrink-0 font-mono text-xs text-dim">{hit.path}:{hit.line}</span>
                    <span class="truncate font-mono text-sm text-fg">{hit.text.trim()}</span>
                </div>
            {/each}
        </div>
        <div
            class="flex items-center gap-4 border-t border-line/15 px-4 py-2 font-mono text-xs text-lo"
        >
            <span>↑↓ / ^j ^k navigate</span><span>↵ open at line</span>
            <span class="flex-1"></span>
            <span>
                {#if searching}searching…{:else if hits.length > 0}{hits.length} hit{hits.length ===
                    1
                        ? ""
                        : "s"}{truncated ? " · truncated — narrow the pattern" : ""}{/if}
            </span>
        </div>
    </div>
</div>
