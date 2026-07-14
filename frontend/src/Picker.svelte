<!-- Workspace switcher (` s) — tmux choose-session. Lists every registered
     workspace with live window counts; typing filters, and a name that
     matches nothing offers "create workspace" (tmux new-session). Reuses
     the palette's styling. -->
<script lang="ts">
    import {app} from "./state.svelte";

    interface Props {
        /** workspaces with attached windows (the manager's projection) */
        workspaces: {name: string; count: number}[];
        current: string;
        onpick: (name: string, create: boolean) => void;
        onmanager: () => void;
        onclose: () => void;
    }
    let {workspaces, current, onpick, onmanager, onclose}: Props = $props();

    let query = $state("");
    let inputEl: HTMLInputElement;
    let listEl: HTMLElement;

    /** Live workspaces plus every registered one (the host list App polls
     *  into the store) at count 0 — switching to a workspace mustn't
     *  require it to already have a session. Live ones keep their
     *  attachment order; session-less ones follow in registry order. */
    const merged = $derived.by((): {name: string; count: number}[] => {
        const out = workspaces.map((w) => ({...w}));
        for (const w of app.workspaces) {
            if (!out.some((x) => x.name === w.name)) out.push({name: w.name, count: 0});
        }
        return out;
    });

    /** The merged list reordered to mirror the manager's grouping: each
     *  source workspace followed by its task trees (one level — a tree
     *  carved from a tree hangs under the topmost listed ancestor). A tree
     *  whose source isn't listed stays top-level, lineage in its detail. */
    interface LiveWs {
        name: string;
        count: number;
        treeOf: string | null;
        nested: boolean;
    }
    const ordered = $derived.by((): LiveWs[] => {
        const lineage = new Map(app.workspaces.map((w) => [w.name, w.worktreeOf ?? null]));
        const listed = new Set(merged.map((w) => w.name));
        const anchorOf = (name: string): string => {
            const seen = new Set<string>([name]);
            let anchor = name;
            for (let cur = lineage.get(name); cur && !seen.has(cur); cur = lineage.get(cur)) {
                seen.add(cur);
                if (listed.has(cur)) anchor = cur;
            }
            return anchor;
        };
        const anno = merged.map((w) => ({
            ...w,
            treeOf: lineage.get(w.name) ?? null,
            nested: false,
        }));
        const out: LiveWs[] = [];
        for (const w of anno) {
            if (anchorOf(w.name) !== w.name) continue; // listed under its anchor
            out.push(w);
            for (const t of anno) {
                if (t.name !== w.name && anchorOf(t.name) === w.name)
                    out.push({...t, nested: true});
            }
        }
        return out;
    });

    // Empty query means items mirror the ordered list, so the active
    // workspace's index is a valid starting selection.
    // svelte-ignore state_referenced_locally — deliberately the initial value
    let sel = $state(
        Math.max(
            0,
            ordered.findIndex((w) => w.name === current),
        ),
    );

    interface Item {
        label: string;
        detail: string;
        create: boolean;
        nested: boolean;
    }
    const items = $derived.by((): Item[] => {
        const q = query.trim();
        const ql = q.toLowerCase();
        const out: Item[] = ordered
            .filter((w) => !ql || w.name.toLowerCase().includes(ql))
            .map((w) => ({
                label: w.name,
                detail:
                    (w.treeOf ? `⎇ task tree of ${w.treeOf} · ` : "") +
                    (w.count ? `${w.count} window${w.count === 1 ? "" : "s"}` : "no windows") +
                    (w.name === current ? " · current" : ""),
                create: false,
                // a filtered list loses the parent row — flatten it
                nested: w.nested && !q,
            }));
        if (q && !merged.some((w) => w.name.toLowerCase() === ql)) {
            out.push({label: q, detail: "create workspace", create: true, nested: false});
        }
        return out;
    });

    function pick(item: Item | undefined) {
        if (!item) return;
        onclose();
        // create spawns a first shell; switch lands wherever the workspace
        // is (a window, or its dashboard when it has none)
        onpick(item.label, item.create);
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
                placeholder="Switch workspace — or type a new name…"
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
            {#each items as item, i (item.label)}
                <!-- .sel stays as a JS scroll-into-view hook, not a style -->
                <div
                    class={[
                        "flex cursor-pointer items-center gap-3 rounded-md py-2 pr-3 hover:bg-acc/15",
                        i === sel && "bg-acc/15",
                        item.nested ? "pl-6" : "pl-3",
                    ]}
                    class:sel={i === sel}
                    onmousedown={(e) => {
                        e.preventDefault();
                        pick(item);
                    }}
                    role="presentation"
                >
                    <span class="flex-1 text-sm text-fg"
                        >{(item.create ? "＋ " : item.nested ? "└ " : "") + item.label}</span
                    >
                    <span class="text-xs uppercase tracking-wider text-lo">{item.detail}</span>
                </div>
            {/each}
        </div>
        <div
            class="flex items-center gap-4 border-t border-line/15 px-4 py-2 font-mono text-xs text-lo"
        >
            <button
                class="flex cursor-pointer items-center gap-2 rounded-lg border border-line/15 bg-white/5 px-3 py-1.5 font-[inherit] text-xs font-semibold text-fg hover:bg-white/10"
                onclick={() => {
                    onclose();
                    onmanager();
                }}>mission control</button
            >
            <span>↑↓ / ^j ^k navigate</span><span>↵ switch / create</span>
            <span class="flex-1"></span>
            <span>workspace = tmux session</span>
        </div>
    </div>
</div>
