<!-- Workspace switcher (` s) — tmux choose-session. Lists workspaces with
     window counts; typing filters, and a name that matches nothing offers
     "create workspace" (tmux new-session). Reuses the palette's styling. -->
<script lang="ts">
    import {app} from "./state.svelte";

    interface Props {
        workspaces: {name: string; count: number}[];
        current: string;
        onpick: (name: string) => void;
        onmanager: () => void;
        onclose: () => void;
    }
    let {workspaces, current, onpick, onmanager, onclose}: Props = $props();

    let query = $state("");
    let inputEl: HTMLInputElement;
    let listEl: HTMLElement;

    /** Live workspaces reordered to mirror the manager's grouping: each
     *  source workspace followed by its task trees (one level — a tree
     *  carved from a tree hangs under the topmost live ancestor). A tree
     *  whose source has no live windows stays top-level, lineage in its
     *  detail. */
    interface LiveWs {
        name: string;
        count: number;
        treeOf: string | null;
        nested: boolean;
    }
    const ordered = $derived.by((): LiveWs[] => {
        const lineage = new Map(app.workspaces.map((w) => [w.name, w.worktreeOf ?? null]));
        const live = new Set(workspaces.map((w) => w.name));
        const anchorOf = (name: string): string => {
            const seen = new Set<string>([name]);
            let anchor = name;
            for (let cur = lineage.get(name); cur && !seen.has(cur); cur = lineage.get(cur)) {
                seen.add(cur);
                if (live.has(cur)) anchor = cur;
            }
            return anchor;
        };
        const anno = workspaces.map((w) => ({
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
                    `${w.count} window${w.count === 1 ? "" : "s"}` +
                    (w.name === current ? " · current" : ""),
                create: false,
                // a filtered list loses the parent row — flatten it
                nested: w.nested && !q,
            }));
        if (q && !workspaces.some((w) => w.name.toLowerCase() === ql)) {
            out.push({label: q, detail: "create workspace", create: true, nested: false});
        }
        return out;
    });

    function pick(item: Item | undefined) {
        if (!item) return;
        onclose();
        onpick(item.label); // create and switch are the same door
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
    id="ws-picker"
    class="overlay"
    onmousedown={(e) => e.target === e.currentTarget && onclose()}
    role="presentation"
>
    <div class="pal-panel">
        <div class="pal-inputrow">
            <span class="pal-chevron">›</span>
            <input
                class="pal-input"
                placeholder="Switch workspace — or type a new name…"
                spellcheck="false"
                bind:this={inputEl}
                bind:value={query}
                oninput={() => (sel = 0)}
                onkeydown={onKeydown}
            />
            <span class="pal-esc">esc</span>
        </div>
        <div class="pal-list" bind:this={listEl}>
            {#each items as item, i (item.label)}
                <div
                    class="pal-item"
                    class:sel={i === sel}
                    class:nested={item.nested}
                    onmousedown={(e) => {
                        e.preventDefault();
                        pick(item);
                    }}
                    role="presentation"
                >
                    <span class="pal-title"
                        >{(item.create ? "＋ " : item.nested ? "└ " : "") + item.label}</span
                    >
                    <span class="pal-cat">{item.detail}</span>
                </div>
            {/each}
        </div>
        <div class="pal-footer">
            <button
                class="home-btn pal-manager-btn"
                onclick={() => {
                    onclose();
                    onmanager();
                }}>workspace manager</button
            >
            <span>↑↓ / ^j ^k navigate</span><span>↵ switch / create</span>
            <span class="pal-spacer"></span>
            <span>workspace = tmux session</span>
        </div>
    </div>
</div>
