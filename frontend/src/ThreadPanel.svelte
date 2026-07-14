<!-- The threads side-pane tenant (mounted inside SidePane, which owns the
     "Threads" title + close button + scroll body). Placement-agnostic: it
     takes the active editor pane's seam + hostapi and lists every thread on
     that file — filterable, one card expanded at a time. Marker clicks and
     ⌘⇧M come UP through the seam; reveal/highlight go DOWN. Drafts live here
     in chrome, so a background refetch never eats them. Styled with inline
     Tailwind utilities (README decision 7). Layer 1: no agent proposed-
     revisions (see spec). -->
<script lang="ts">
    import type {HostAPI, ThreadInfo} from "./hostapi";
    import type {EditorSeam} from "./term/editor";
    import {
        avatar,
        contextKey,
        fileThreads,
        filterThreads,
        openCount,
        pickFromStack,
        relTime,
        resolvedCount,
        snippetOf,
        stateMeta,
        threadStack,
        type Side,
        type StateTone,
        type ThreadFilter,
    } from "./term/threadview";

    let {api, editor}: {api: HostAPI; editor: EditorSeam | null} = $props();

    // Tone → literal class names. Tailwind scans source for literal strings,
    // so this must never be `bg-${tone}` (that emits nothing).
    const TONE_TEXT: Record<StateTone, string> = {
        amber: "text-amber",
        acc: "text-acc",
        grn: "text-grn",
    };
    const TONE_BG: Record<StateTone, string> = {
        amber: "bg-amber",
        acc: "bg-acc",
        grn: "bg-grn",
    };
    const FILTERS: [ThreadFilter, string][] = [
        ["open", "Open"],
        ["resolved", "Resolved"],
        ["all", "All"],
    ];

    let threads = $state<ThreadInfo[]>([]);
    let filter = $state<ThreadFilter>("open");
    let selectedId = $state<number | null>(null); // the one expanded card
    let composer = $state<{startLine: number; endLine: number; side: Side} | null>(null);
    let draft = $state(""); // composer body OR the expanded card's reply
    let err = $state("");
    let busy = $state(false);
    let nowMs = $state(Date.now()); // refreshed on sync; feeds relTime
    let ctxKey = ""; // last-seen file identity; selection/composer reset on change

    // (Re)bind to the active editor whenever the prop changes.
    $effect(() => {
        const seam = editor;
        if (!seam) {
            threads = [];
            selectedId = null;
            composer = null;
            ctxKey = "";
            return;
        }
        sync();
        const offChange = seam.onChange(sync);
        const offMarker = seam.onMarkerClick((line, side, _ids) => selectAt(line, side));
        const offCompose = seam.onCompose((s, e, side) => {
            draft = "";
            err = "";
            selectedId = null;
            composer = {startLine: s, endLine: e, side};
        });
        return () => {
            offChange();
            offMarker();
            offCompose();
        };
    });

    function sync(): void {
        if (!editor) return;
        threads = editor.threads();
        nowMs = Date.now();
        const key = contextKey(editor.context());
        if (key !== ctxKey) {
            // file-nav / workspace switch → drop selection + composer (filter persists)
            ctxKey = key;
            selectedId = null;
            composer = null;
            draft = "";
            err = "";
        }
    }

    // A gutter-marker click expands the matching card and reveals it.
    function selectAt(line: number, side: Side): void {
        const ctx = editor?.context();
        if (!ctx) return;
        const stack = threadStack(threads, ctx.path, side, line);
        const pick = pickFromStack(stack, selectedId ?? undefined);
        if (!pick) return;
        draft = "";
        err = "";
        composer = null;
        selectedId = pick.thread.id;
        editor?.reveal(pick.thread);
    }

    const path = $derived(editor?.context()?.path ?? "");
    const onFile = $derived(fileThreads(threads, path));
    const visible = $derived(filterThreads(onFile, filter));
    const selected = $derived(
        selectedId == null ? null : (threads.find((t) => t.id === selectedId) ?? null),
    );

    function toggle(t: ThreadInfo): void {
        if (selectedId === t.id) {
            collapse();
            return;
        }
        composer = null;
        draft = "";
        err = "";
        selectedId = t.id;
        editor?.reveal(t);
    }

    function headKey(e: KeyboardEvent, t: ThreadInfo): void {
        if (e.key === "Enter" || e.key === " ") {
            e.preventDefault();
            toggle(t);
        }
    }

    function collapse(): void {
        selectedId = null;
        draft = "";
        err = "";
        editor?.clearHighlight();
    }

    function cancelComposer(): void {
        composer = null;
        draft = "";
        err = "";
        editor?.clearHighlight();
    }

    async function run(fn: () => Promise<void>): Promise<void> {
        busy = true;
        err = "";
        try {
            await fn();
            await editor?.refetch(); // resync gutter + this panel's data
        } catch (e) {
            err = String(e);
        } finally {
            busy = false;
        }
    }

    async function submitComposer(): Promise<void> {
        const body = draft.trim();
        const ctx = editor?.context();
        if (!body || !ctx || !composer) return;
        const {startLine, endLine, side} = composer;
        let created: ThreadInfo | null = null;
        await run(async () => {
            created = await api.createThread(ctx.workspace, {
                path: ctx.path,
                startLine,
                endLine,
                side,
                base: side === "original" ? ctx.base : undefined,
                body,
            });
            draft = "";
            composer = null;
        });
        // select AFTER refetch populated `threads`, so `selected` resolves at once
        if (created) {
            selectedId = (created as ThreadInfo).id;
            editor?.reveal(created as ThreadInfo);
        }
    }

    async function reply(): Promise<void> {
        const body = draft.trim();
        if (!body || !selected) return;
        const id = selected.id;
        await run(async () => {
            await api.threadComment(id, body);
            draft = "";
        });
    }

    async function resolve(): Promise<void> {
        if (!selected) return;
        const id = selected.id;
        await run(() => api.threadResolve(id));
    }

    async function reopen(): Promise<void> {
        if (!selected) return;
        const id = selected.id;
        await run(() => api.threadReopen(id));
    }

    // Ask the agent = the real nudge. Workspace-level batch: flips ALL pending
    // threads → open and nudges once (no per-thread submit endpoint exists).
    async function askAgent(): Promise<void> {
        const ctx = editor?.context();
        if (!ctx) return;
        await run(async () => {
            await api.submitThreads(ctx.workspace);
        });
    }

    function keydown(e: KeyboardEvent, submit: () => void): void {
        if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) {
            e.preventDefault();
            submit();
        } else if (e.key === "Escape") {
            if (composer) cancelComposer();
            else collapse();
        }
    }

    function fmtRange(a: number, b: number): string {
        return a === b ? `L${a}` : `L${a}–${b}`;
    }
</script>

{#if !editor}
    <div class="p-4 text-sm opacity-60">focus a review or file pane to see its threads</div>
{:else}
    <div class="flex h-full min-h-0 flex-col text-fg">
        <!-- filters + counts (SidePane's header already says "Threads") -->
        <div class="flex shrink-0 items-center gap-2 border-b border-white/10 px-3 py-2">
            <div class="flex gap-1.5">
                {#each FILTERS as [id, label] (id)}
                    <button
                        class={"cursor-pointer rounded-lg border px-2.5 py-1 text-[11px] font-semibold " +
                            (filter === id
                                ? "border-acc/40 bg-acc/15 text-acc"
                                : "border-white/10 bg-transparent text-lo hover:text-fg")}
                        onclick={() => (filter = id)}>{label}</button
                    >
                {/each}
            </div>
            <span class="flex-1"></span>
            <span class="flex items-center gap-1.5 font-mono text-[10px] text-lo">
                <span class="size-1.5 rounded-full bg-amber"></span>{openCount(onFile)} open
            </span>
        </div>

        <!-- the list is the only scroll region -->
        <div class="flex min-h-0 flex-1 flex-col gap-2 overflow-y-auto px-3 py-2.5">
            {#if composer}
                <div class="rounded-xl border border-acc/40 bg-acc/[0.06] px-3 py-2.5">
                    <div class="mb-2 flex items-center gap-2">
                        <span class="text-[10px] font-bold uppercase tracking-wider text-acc"
                            >New thread</span
                        >
                        <span class="font-mono text-[10px] text-lo"
                            >{fmtRange(composer.startLine, composer.endLine)}{composer.side ===
                            "original"
                                ? " (original)"
                                : ""}</span
                        >
                        <span class="flex-1"></span>
                        <button
                            class="cursor-pointer text-xs text-lo hover:text-dim"
                            aria-label="cancel"
                            onclick={cancelComposer}>✕</button
                        >
                    </div>
                    <textarea
                        class="thread-input"
                        rows="3"
                        placeholder="Ask the agent, or leave a note for this region…"
                        bind:value={draft}
                        onkeydown={(e) => keydown(e, submitComposer)}></textarea>
                    {#if err}<div class="thread-err">{err}</div>{/if}
                    <div class="mt-2 flex items-center gap-2">
                        <button
                            class="cursor-pointer rounded-lg bg-acc px-3 py-1.5 text-xs font-semibold text-[#0b0d14] hover:brightness-110 disabled:opacity-50"
                            disabled={busy}
                            onclick={submitComposer}>Start thread</button
                        >
                        <span class="font-mono text-[10px] text-lo">⌘↵ sends · esc closes</span>
                    </div>
                </div>
            {/if}

            {#each visible as t (t.id)}
                {@const meta = stateMeta(t.state)}
                <div
                    class={"overflow-hidden rounded-xl border transition-colors " +
                        (selectedId === t.id
                            ? "border-acc/45 bg-white/[0.04]"
                            : "border-white/10 bg-white/[0.02]")}
                >
                    <div
                        class="flex cursor-pointer items-center gap-2.5 px-3 py-2.5"
                        role="button"
                        tabindex="0"
                        onclick={() => toggle(t)}
                        onkeydown={(e) => headKey(e, t)}
                    >
                        <span class={"size-2 shrink-0 rounded-full " + TONE_BG[meta.tone]}></span>
                        <div class="min-w-0 flex-1">
                            <div class="flex items-center gap-2">
                                <span
                                    class={"text-[10px] font-bold uppercase tracking-wider " +
                                        TONE_TEXT[meta.tone]}>{meta.label}</span
                                >
                                <span class="font-mono text-[10px] text-lo"
                                    >#{t.id} · {fmtRange(t.currentStart, t.currentEnd)}{t.outdated
                                        ? " · outdated"
                                        : ""}</span
                                >
                            </div>
                            <div class="mt-0.5 truncate font-mono text-[11px] text-dim">
                                {snippetOf(t)}
                            </div>
                        </div>
                        <span class="shrink-0 text-[10px] text-lo">{t.comments.length}</span>
                    </div>

                    {#if selectedId === t.id}
                        <div class="px-3 pb-3 pt-0.5">
                            {#if t.outdated && t.anchorText}
                                <pre class="thread-anchor">{t.anchorText}</pre>
                            {/if}
                            <div class="flex flex-col gap-3 py-2.5">
                                {#each t.comments as c (c.id)}
                                    {@const av = avatar(c.author)}
                                    <div class="flex gap-2.5">
                                        <span
                                            class={"inline-flex size-5 shrink-0 items-center justify-center rounded-md text-[10px] font-bold " +
                                                (av.isAgent
                                                    ? "bg-acc/20 text-acc"
                                                    : "bg-white/10 text-fg")}>{av.initials}</span
                                        >
                                        <div class="min-w-0 flex-1 pt-px">
                                            <div class="mb-0.5 flex items-center gap-2">
                                                <span
                                                    class={"text-xs font-semibold " +
                                                        (av.isAgent ? "text-acc" : "text-fg")}
                                                    >{c.author === "agent" ? "agent" : "you"}</span
                                                >
                                                <span class="font-mono text-[10px] text-lo"
                                                    >{relTime(c.created, nowMs)}</span
                                                >
                                            </div>
                                            <div
                                                class="whitespace-pre-wrap break-words text-[13px] leading-normal text-fg"
                                            >
                                                {c.body}
                                            </div>
                                        </div>
                                    </div>
                                {/each}
                            </div>

                            {#if err}<div class="thread-err">{err}</div>{/if}

                            <div class="mt-2.5 flex gap-2">
                                {#if t.state === "pending"}
                                    <button
                                        class="shrink-0 cursor-pointer rounded-lg border border-acc/35 bg-acc/15 px-3 py-1.5 text-[11px] font-semibold text-acc hover:bg-acc/25 disabled:opacity-50"
                                        disabled={busy}
                                        title="submits pending threads and nudges the agent"
                                        onclick={askAgent}>Ask the agent</button
                                    >
                                {/if}
                                <input
                                    class="thread-input min-w-0 flex-1 resize-none"
                                    placeholder="reply…"
                                    bind:value={draft}
                                    onkeydown={(e) => keydown(e, reply)}
                                />
                                <button
                                    class="shrink-0 cursor-pointer rounded-lg border border-white/10 bg-white/5 px-3 text-[11px] font-semibold text-fg hover:border-acc disabled:opacity-50"
                                    disabled={busy}
                                    onclick={reply}>Send</button
                                >
                            </div>

                            <div
                                class="mt-2.5 flex items-center gap-3.5 border-t border-white/10 pt-2.5"
                            >
                                {#if t.state === "resolved"}
                                    <button
                                        class="cursor-pointer text-[11px] font-semibold text-dim hover:text-fg disabled:opacity-50"
                                        disabled={busy}
                                        onclick={reopen}>↺ Reopen</button
                                    >
                                {:else}
                                    <button
                                        class="cursor-pointer text-[11px] font-semibold text-grn hover:brightness-110 disabled:opacity-50"
                                        disabled={busy}
                                        onclick={resolve}>✓ Resolve thread</button
                                    >
                                {/if}
                                <span class="font-mono text-[10px] text-lo"
                                    >attached to {fmtRange(t.currentStart, t.currentEnd)}</span
                                >
                            </div>
                        </div>
                    {/if}
                </div>
            {/each}

            {#if visible.length === 0 && !composer}
                <div class="px-2.5 py-6 text-center text-xs leading-relaxed text-lo">
                    No threads in this filter.{#if resolvedCount(onFile) > 0 && filter === "open"}<br
                        />{resolvedCount(onFile)} resolved — see the Resolved tab.{/if}
                </div>
            {/if}
        </div>

        <!-- footer hint -->
        <div
            class="flex shrink-0 items-center gap-2.5 border-t border-white/10 px-3.5 py-2 font-mono text-[10px] text-lo"
        >
            <span>click any line to start a thread</span>
            <span class="flex-1"></span>
            <span>agents reply here</span>
        </div>
    </div>
{/if}
