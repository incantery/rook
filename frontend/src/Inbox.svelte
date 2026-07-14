<!-- The attention inbox (` a): every claude session waiting on you, across
     workspaces, in one overlay — with the drafter's proposed replies once
     rook-agent is running (docs/agent.md). Rows are keyed
     (sessionId, askSeq) so a poll refresh never steals the selection, and
     a snooze dies with its ask. -->
<script lang="ts">
    import type {AttentionItem, HostAPI} from "./hostapi";
    import {ago} from "./util";

    interface Props {
        api: HostAPI;
        dashTab: number;
        onjump: (sessionId: string) => void;
        onclose: () => void;
    }
    let {api, dashTab, onjump, onclose}: Props = $props();

    // Keyed on the transcript session, not the window: a new claude process
    // in the same window is a new identity (askSeq restarts with it).
    const key = (it: AttentionItem) => `${it.agentSession}:${it.askSeq}`;

    let items = $state<AttentionItem[]>([]);
    let selKey = $state<string | null>(null);
    let editingKey = $state<string | null>(null);
    let editText = $state("");
    const snoozed = new Set<string>();
    let listEl: HTMLElement;
    let editEl = $state<HTMLTextAreaElement | null>(null);

    const selIndex = $derived.by(() => {
        const i = items.findIndex((it) => key(it) === selKey);
        return i === -1 ? (items.length ? 0 : -1) : i;
    });
    const selected = $derived(items[selIndex]);

    async function refresh() {
        let fresh: AttentionItem[];
        try {
            fresh = await api.attention();
        } catch (err) {
            console.error("inbox refresh failed", err);
            return;
        }
        items = fresh.filter((it) => !snoozed.has(key(it)));
        // snoozes for asks that no longer exist can be forgotten
        const live = new Set(fresh.map(key));
        for (const k of snoozed) if (!live.has(k)) snoozed.delete(k);
        if (editingKey && !items.some((it) => key(it) === editingKey)) {
            editingKey = null; // the ask moved on under the editor
        }
    }

    $effect(() => {
        void refresh();
        const timer = setInterval(() => void refresh(), 2000);
        return () => clearInterval(timer);
    });

    // Capture-phase so the terminal (and App's keybinding ladder) never see
    // keys while the inbox is up; App also bails on inboxOpen.
    $effect(() => {
        const onKey = (e: KeyboardEvent) => onKeydown(e);
        window.addEventListener("keydown", onKey, {capture: true});
        return () => window.removeEventListener("keydown", onKey, {capture: true});
    });

    // the editor grabs focus when it appears
    $effect(() => {
        if (editEl) {
            editEl.focus();
            editEl.setSelectionRange(editEl.value.length, editEl.value.length);
        }
    });

    function onKeydown(e: KeyboardEvent) {
        // Edit mode: the textarea owns typing; we only intercept its exits.
        if (editingKey) {
            if (e.key === "Escape") {
                e.preventDefault();
                e.stopPropagation();
                editingKey = null;
            } else if (e.key === "Enter" && !e.shiftKey) {
                e.preventDefault();
                e.stopPropagation();
                const it = selected;
                if (it?.draft) void decide(it, "approve", editText.trim());
            }
            return;
        }
        e.preventDefault();
        e.stopPropagation();
        const it = selected;
        switch (e.key) {
            case "Escape":
                onclose();
                break;
            case "ArrowDown":
            case "j": // no filter input here, so bare vim motions work
                move(1);
                break;
            case "ArrowUp":
            case "k":
                move(-1);
                break;
            case "o":
                if (it) jump(it);
                break;
            case "Enter":
                if (!it) break;
                if (it.draft?.action === "draft" || it.draft?.action === "spawn")
                    void decide(it, "approve");
                else jump(it);
                break;
            case "e":
                if (it?.draft?.action === "draft" || it?.draft?.action === "spawn") {
                    editText = it.draft.reply ?? "";
                    editingKey = key(it);
                }
                break;
            case "x":
                if (!it) break;
                if (it.draft) void decide(it, "reject");
                else {
                    snoozed.add(key(it));
                    items = items.filter((o) => o !== it);
                }
                break;
        }
    }

    function move(d: number) {
        if (items.length === 0) return;
        const i = Math.min(Math.max(selIndex + d, 0), items.length - 1);
        selKey = key(items[i]);
        listEl?.querySelector(".sel")?.scrollIntoView({block: "nearest"});
    }

    function jump(it: AttentionItem) {
        onclose();
        onjump(it.rookSession);
    }

    async function decide(it: AttentionItem, action: "approve" | "reject", text?: string) {
        if (!it.draft) return;
        editingKey = null;
        try {
            if (action === "approve") await api.approveDraft(it.draft.id, text);
            else await api.rejectDraft(it.draft.id);
        } catch (err) {
            console.error(`${action} draft failed`, err);
        }
        // approved: claude is working again, the row leaves on its own;
        // rejected: the ask still stands, draft-less — either way, refetch
        await refresh();
    }
</script>

<div
    class="fixed inset-0 z-50 flex items-start justify-center bg-black/55 pt-[12vh]"
    onmousedown={(e) => e.target === e.currentTarget && onclose()}
    role="presentation"
>
    <div
        class="w-150 max-w-[92vw] overflow-hidden rounded-xl border border-line/30 bg-[#151924] shadow-2xl"
    >
        <div class="flex items-center gap-2.5 border-b border-line/15 px-4 py-3">
            <span class="text-sm font-bold text-fg">Attention</span>
            <span class="flex-1"></span>
            <span class="rounded border border-line/15 px-1.5 py-0.5 font-mono text-xs text-lo"
                >esc</span
            >
        </div>
        <div class="max-h-[48vh] overflow-y-auto p-1.5" bind:this={listEl}>
            {#if items.length === 0}
                <div class="p-6 text-center text-sm text-lo">Nobody needs you.</div>
            {/if}
            {#each items as it, i (key(it))}
                {@const draftReady =
                    !it.interactive &&
                    (it.draft?.action === "draft" || it.draft?.action === "spawn") &&
                    editingKey !== key(it)}
                <!-- .sel stays as a JS scroll-into-view hook, not a style -->
                <div
                    class={[
                        "block cursor-pointer rounded-md px-3 py-2 hover:bg-acc/15",
                        i === selIndex && "bg-acc/15",
                    ]}
                    class:sel={i === selIndex}
                    onmousedown={(e) => {
                        e.preventDefault();
                        if (editingKey) return;
                        selKey = key(it);
                        jump(it);
                    }}
                    role="presentation"
                >
                    <div class="flex items-baseline gap-2.5">
                        <!-- "window N" is the host's per-workspace creation index —
                             once windows hold panes it can drift from the strip slot.
                             Accepted: the label orients, the jump (by session id) is
                             what must stay correct. -->
                        <span
                            class="rounded-sm bg-amber/10 px-1.5 py-0.5 font-mono text-xs text-amber"
                            >{it.workspace} · window {dashTab + 1 + it.window}</span
                        >
                        <span class="ml-auto font-mono text-xs text-lo">{ago(it.since)}</span>
                    </div>
                    {#if it.ask}
                        <div class="mt-1.5 truncate text-sm leading-normal text-fg" title={it.ask}>
                            {it.ask.replace(/\n/g, " ")}
                        </div>
                    {/if}
                    <div
                        class={[
                            "mt-1 font-mono text-xs leading-normal",
                            !it.interactive && !it.draft && "hidden",
                            draftReady && "truncate text-grn",
                            (it.interactive || it.draft?.action === "escalate") && "text-amber",
                        ]}
                    >
                        {#if editingKey === key(it) && (it.draft?.action === "draft" || it.draft?.action === "spawn")}
                            <textarea
                                class="box-border w-full resize-y rounded-md border border-acc bg-[#0a0c14]/80 px-2 py-1.5 font-mono text-xs text-fg outline-none"
                                rows="2"
                                spellcheck="false"
                                bind:value={editText}
                                bind:this={editEl}></textarea>
                            <div class="mt-0.5 font-mono text-xs text-lo">
                                ↵ send edited · esc cancel
                            </div>
                        {:else if it.interactive}
                            ⌨ pick an option in the window — ↵ jumps
                        {:else if it.draft?.action === "draft" || it.draft?.action === "spawn"}
                            {@const pct = it.draft.confidence
                                ? ` ${Math.round(it.draft.confidence * 100)}%`
                                : ""}
                            {@const why = it.draft.reason ? `\n${it.draft.reason}` : ""}
                            <span
                                title={`${it.draft.action}${pct} — ↵ approve, e edit, x reject${why}`}
                            >
                                {it.draft.action === "spawn" ? "▶ new session:" : "✎"}
                                {it.draft.reply ?? ""}
                            </span>
                        {:else if it.draft?.action === "escalate"}
                            <!-- the reason is what makes an escalation legible: "yours —
                                 destructive" reads as a judgment, not a shrug -->
                            {it.draft.reason ? `⚑ yours — ${it.draft.reason}` : "⚑ yours to answer"}
                        {/if}
                    </div>
                </div>
            {/each}
        </div>
        <div
            class="flex items-center gap-4 border-t border-line/15 px-4 py-2 font-mono text-xs text-lo"
        >
            <span>↑↓ / j k navigate</span><span>↵ approve / jump</span><span>o open</span>
            <span>e edit</span><span>x dismiss</span>
            <span class="flex-1"></span>
            <span>drafts are suggestions — you send them</span>
        </div>
    </div>
</div>
