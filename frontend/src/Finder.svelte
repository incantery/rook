<!-- The finder shell: the overlay, the query, the ranked list, the preview,
     and ONE fzf/telescope keymap. Every picker in rook used to carry its own
     copy of this; a source now carries only what makes it that source.

     What lives here and not in a source, deliberately: the debounce and the
     sequence guard (a stale answer must never paint over a newer one — the
     bug is identical in every picker, so it gets solved once), the cursor,
     scroll-follow, and the fact that Escape closes. -->
<script lang="ts" generics="T">
    import FinderPreview from "./FinderPreview.svelte";
    import Kbd from "./Kbd.svelte";
    import type {FinderSource, Ranked} from "./finder";
    import type {HostAPI} from "./hostapi";

    interface Props {
        api: HostAPI;
        source: FinderSource<T>;
        /** the preview reads files from here */
        workspace: string;
        /** prefill (grep's ⌃S seed); selected on focus so typing replaces it */
        seed?: string;
        onclose: () => void;
    }
    let {api, source, workspace, seed = "", onclose}: Props = $props();

    // The source is captured ONCE, for the same reason the seed is: callers
    // build it inline, so its object identity changes on any unrelated App
    // re-render, and an effect keyed on it would re-fetch the whole listing
    // mid-typing. The picker remounts per open, which is what makes
    // capturing correct rather than merely convenient.
    // svelte-ignore state_referenced_locally
    const src = source;

    /** one keystroke of quiet before a live source hits the wire */
    const DEBOUNCE_MS = 120;
    /** big repos rank 10k paths — render only this many */
    const RENDER_CAP = 200;

    // read the seed once at init: the picker remounts per open, so a later
    // seed change belongs to the NEXT open
    // svelte-ignore state_referenced_locally
    let query = $state(seed);
    let sel = $state(0);
    let loaded = $state(false);
    let searching = $state(false);
    let items = $state<T[]>([]);
    let base = $state("");
    let truncated = $state(false);
    let note = $state("");
    let previewOn = $state(true);
    let inputEl: HTMLInputElement;
    let listEl: HTMLElement;

    const minQuery = $derived(src.minQuery ?? 0);
    const short = $derived(query.trim().length < minQuery);

    let seq = 0;
    async function run(q: string, mine: number): Promise<void> {
        try {
            const res = await src.load(q);
            if (mine !== seq) return;
            items = res.items;
            base = res.base ?? "";
            truncated = res.truncated ?? false;
            note = res.note ?? "";
            sel = 0;
        } catch (err) {
            if (mine !== seq) return;
            console.error(`finder ${src.id}: load failed`, err);
            items = [];
            note = String(err).includes(" 404 ")
                ? "this rook-host is older than the finder — relaunch rook"
                : `${err}`;
        }
        loaded = true;
        searching = false;
    }

    // A static source loads once and re-ranks in memory; a live source is
    // re-loaded per keystroke, debounced. The $effect reads `query` only in
    // the live branch, so a static source's list does not refetch on typing.
    $effect(() => {
        if (src.mode === "static") {
            const mine = ++seq;
            void run("", mine);
            return;
        }
        const q = query.trim();
        if (q.length < minQuery) {
            seq++; // orphan anything in flight
            items = [];
            truncated = false;
            note = "";
            searching = false;
            return;
        }
        searching = true;
        const mine = ++seq;
        const t = setTimeout(() => void run(q, mine), DEBOUNCE_MS);
        return () => clearTimeout(t);
    });

    // Live sources arrive host-ranked and carry no highlight positions;
    // static sources rank here, over the WHOLE list before the render cap,
    // so the best match can't be shadowed by 200 mediocre earlier rows.
    const ranked = $derived.by((): Ranked<T>[] =>
        src.mode === "live" || !src.rank
            ? items.slice(0, RENDER_CAP).map((item) => ({item, positions: []}))
            : src.rank(query.trim(), items).slice(0, RENDER_CAP),
    );
    const rows = $derived(ranked.map((r) => src.row(r.item, r.positions)));
    const current = $derived(ranked[sel]?.item);
    const spec = $derived(current === undefined ? null : src.preview(current));

    function act(key: string): boolean {
        const a = src.actions.find((x) => x.key === key);
        if (!a) return false;
        // every verb closes first: the picker is a decision, not a workspace
        onclose();
        a.run(
            current,
            ranked.map((r) => r.item),
            query.trim(),
        );
        return true;
    }

    function onKeydown(e: KeyboardEvent) {
        // vim/fzf motions — bare j/k must keep typing into the query
        const down = e.key === "ArrowDown" || (e.ctrlKey && (e.key === "j" || e.key === "n"));
        const up = e.key === "ArrowUp" || (e.ctrlKey && (e.key === "k" || e.key === "p"));
        if (down) {
            e.preventDefault();
            sel = Math.min(sel + 1, ranked.length - 1);
            return;
        }
        if (up) {
            e.preventDefault();
            sel = Math.max(sel - 1, 0);
            return;
        }
        if (e.key === "Escape") {
            e.preventDefault();
            e.stopPropagation();
            onclose();
            return;
        }
        // telescope's toggle — a narrow window sometimes wants all the rows
        if (e.ctrlKey && e.key === "y") {
            e.preventDefault();
            previewOn = !previewOn;
            return;
        }
        const key = e.key === "Enter" ? "enter" : e.ctrlKey ? `ctrl+${e.key}` : "";
        if (key && act(key)) e.preventDefault();
    }

    $effect(() => {
        inputEl.focus();
        if (seed) inputEl.select();
    });
    $effect(() => {
        void sel;
        listEl?.querySelector(".sel")?.scrollIntoView({block: "nearest"});
    });
</script>

<div
    class="fixed inset-0 z-50 flex items-start justify-center bg-black/55 pt-[10vh]"
    onmousedown={(e) => e.target === e.currentTarget && onclose()}
    role="presentation"
>
    <div
        class="flex w-[68rem] max-w-[94vw] flex-col overflow-hidden rounded-xl border border-line/30 bg-overlay shadow-2xl"
    >
        <div class="flex items-center gap-2.5 border-b border-line/15 px-4 py-3">
            <span class="font-mono text-sm text-lo">{src.sigil}</span>
            <input
                class="flex-1 border-0 bg-transparent font-[inherit] text-base text-fg outline-none"
                placeholder={src.placeholder}
                spellcheck="false"
                bind:this={inputEl}
                bind:value={query}
                oninput={() => (sel = 0)}
                onkeydown={onKeydown}
            />
            <Kbd k="esc" />
        </div>

        <div class="flex h-[52vh] min-h-0">
            <div
                class={[
                    "min-w-0 overflow-y-auto p-1.5",
                    previewOn && spec ? "w-2/5 shrink-0" : "flex-1",
                ]}
                data-finder-list
                bind:this={listEl}
            >
                {#if note}
                    <div class="px-3 py-2 text-xs uppercase tracking-wider text-lo">{note}</div>
                {:else if short}
                    <div class="px-3 py-2 text-xs uppercase tracking-wider text-lo">
                        {src.prompt ?? "type to search"}
                    </div>
                {:else if loaded && !searching && ranked.length === 0}
                    <div class="px-3 py-2 text-xs uppercase tracking-wider text-lo">
                        {src.empty}
                    </div>
                {/if}
                {#each ranked as r, i (src.key(r.item))}
                    {@const row = rows[i]}
                    {#if row.group && row.group !== rows[i - 1]?.group}
                        <div
                            class={[
                                "px-3 pb-1 text-[10px] font-bold uppercase tracking-wider text-lo",
                                i === 0 ? "pt-1.5" : "mt-1 border-t border-line/15 pt-2",
                            ]}
                        >
                            {row.group}
                        </div>
                    {/if}
                    <!-- .sel stays as a JS scroll-into-view hook, not a style -->
                    <div
                        class={[
                            "flex cursor-pointer items-baseline gap-2.5 rounded-md py-1.5 pr-3 pl-2.5 hover:bg-acc/10",
                            // the active row gets the same accent rail the
                            // quickfix uses — one vocabulary for "here"
                            i === sel
                                ? "border-l-2 border-acc bg-acc/15 pl-2"
                                : "border-l-2 border-transparent",
                        ]}
                        class:sel={i === sel}
                        data-finder-row
                        onmousedown={(e) => {
                            e.preventDefault();
                            sel = i;
                            act("enter");
                        }}
                        role="presentation"
                    >
                        {#if row.locator}
                            <span class="shrink-0 font-mono text-xs text-dim">{row.locator}</span>
                        {/if}
                        <span
                            class={[
                                "min-w-0 flex-1 truncate text-sm",
                                row.muted ? "text-dim" : "text-fg",
                                row.locator && "font-mono",
                            ]}
                            >{#each row.segments as seg}{#if seg.hit}<span
                                        class="font-semibold text-acc">{seg.text}</span
                                    >{:else}{seg.text}{/if}{/each}</span
                        >
                        {#if row.detail}
                            <span class="shrink-0 font-mono text-[10px] text-lo">{row.detail}</span>
                        {/if}
                    </div>
                {/each}
            </div>
            {#if previewOn && spec}
                <FinderPreview {api} {workspace} {spec} />
            {/if}
        </div>

        <div
            class="flex items-center gap-3 border-t border-line/15 px-4 py-2 font-mono text-xs text-lo"
        >
            <Kbd k="^j" label="^k move" />
            {#each src.actions as a}
                <Kbd k={a.cap} label={a.label} />
            {/each}
            <Kbd k="^y" label="preview" />
            <span class="flex-1"></span>
            <span>
                {#if base}<span class="text-acc">in {base}</span> ·
                {/if}{#if searching}searching…{:else}{ranked.length}{ranked.length === RENDER_CAP
                        ? "+"
                        : ""}
                    {ranked.length === 1 ? "result" : "results"}{truncated
                        ? " · truncated, narrow it"
                        : ""}{/if}
            </span>
        </div>
    </div>
</div>
