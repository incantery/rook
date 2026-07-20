<!-- The threads side-pane tenant (mounted inside SidePane, which owns the
     "Threads" title + close button + scroll body). Placement-agnostic: it
     takes the active editor pane's seam + hostapi and lists every thread on
     that file — filterable, one card expanded at a time. Marker clicks and
     ⌘⇧M / ,c / ,? come UP through the seam; reveal/highlight go DOWN. The
     composer's MODE decides what submitting means: a note lands pending for
     the batch, an ask submits that one thread and nudges. Drafts live here
     in chrome, so a background refetch never eats them. Styled with inline
     Tailwind utilities (README decision 7). Layer 1: no agent proposed-
     revisions (see spec). -->
<script lang="ts">
    import type {HostAPI, ThreadInfo} from "./hostapi";
    import type {ComposeMode, EditorSeam} from "./term/editor";
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
    // The expanded card is edged in its own state's tone (the mockup's
    // `border: 1px solid meta.color`), so an open card still says what it is
    // once its collapsed dot + label scroll out of view.
    const TONE_BORDER: Record<StateTone, string> = {
        amber: "border-amber/45",
        acc: "border-acc/45",
        grn: "border-grn/45",
    };
    const FILTERS: [ThreadFilter, string][] = [
        ["open", "Open"],
        ["resolved", "Resolved"],
        ["all", "All"],
    ];

    let threads = $state<ThreadInfo[]>([]);
    let filter = $state<ThreadFilter>("open");
    let selectedId = $state<number | null>(null); // the one expanded card
    let composer = $state<{
        startLine: number;
        endLine: number;
        side: Side;
        mode: ComposeMode;
    } | null>(null);
    let draft = $state(""); // composer body OR the expanded card's reply
    let err = $state("");
    let busy = $state(false);
    let nowMs = $state(Date.now()); // refreshed on sync; feeds relTime
    let ctxKey = ""; // last-seen file identity; selection/composer reset on change
    let composerEl = $state<HTMLTextAreaElement | null>(null);

    // The composer is opened BY A KEYSTROKE (,c / ,? / ⌘⇧M), so it has to take
    // the keyboard with it. Without this the pane slides open and the caret is
    // still in Monaco — the user reaches for the mouse to type a note they
    // asked for with a chord.
    $effect(() => {
        if (composer && composerEl) composerEl.focus();
    });

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
        const offCompose = seam.onCompose((s, e, side, mode) => {
            draft = "";
            err = "";
            selectedId = null;
            composer = {startLine: s, endLine: e, side, mode};
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
        // hand the keyboard back where it came from — ,c is a keyboard verb,
        // and stranding focus in a side pane forces a mouse to get out
        editor?.takeFocus();
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
        const {startLine, endLine, side, mode} = composer;
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
            // ,? asks about THIS thread — a per-thread submit, not the
            // workspace batch, which would also ship every note deliberately
            // left pending.
            if (mode === "ask") await api.submitThread((created as ThreadInfo).id);
            draft = "";
            composer = null;
        });
        // select AFTER refetch populated `threads`, so `selected` resolves at once
        if (created) {
            selectedId = (created as ThreadInfo).id;
            editor?.reveal(created as ThreadInfo);
            // …and give the keyboard back: the note is written, the next thing
            // the user wants is to keep reading code, not to be in a panel.
            editor?.takeFocus();
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
        <div class="flex shrink-0 items-center gap-2 border-b border-line/15 px-3 py-2">
            <div class="flex gap-1.5">
                {#each FILTERS as [id, label] (id)}
                    <button
                        class={"cursor-pointer rounded-lg border px-2.5 py-1 text-[11px] font-semibold " +
                            (filter === id
                                ? "border-acc/40 bg-acc/15 text-acc"
                                : "border-line/15 bg-transparent text-lo hover:text-fg")}
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
                            >{composer.mode === "ask" ? "Ask the agent" : "New thread"}</span
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
                        class="box-border min-h-6.5 w-full resize-y rounded-sm border border-line/15 bg-sunken px-1.5 py-1 font-mono text-xs text-fg focus:border-acc focus:outline-none"
                        rows="3"
                        bind:this={composerEl}
                        placeholder={composer.mode === "ask"
                            ? "What do you want to know about this region?"
                            : "Leave a note for this region…"}
                        bind:value={draft}
                        onkeydown={(e) => keydown(e, submitComposer)}></textarea>
                    {#if err}<div class="text-xs text-red [overflow-wrap:anywhere]">{err}</div>{/if}
                    <div class="mt-2 flex items-center gap-2">
                        <button
                            class="cursor-pointer rounded-lg bg-acc px-3 py-1.5 text-xs font-semibold text-on-acc hover:brightness-110 disabled:opacity-50"
                            disabled={busy}
                            onclick={submitComposer}
                            >{composer.mode === "ask" ? "Ask now" : "Start thread"}</button
                        >
                        <span class="font-mono text-[10px] text-lo"
                            >{composer.mode === "ask"
                                ? "⌘↵ asks · esc closes"
                                : "⌘↵ saves · esc closes"}</span
                        >
                    </div>
                </div>
            {/if}

            {#each visible as t (t.id)}
                {@const meta = stateMeta(t.state)}
                <!-- state as a hook, not a style: the tone lives in a class,
                     but "is this thread still pending" is a fact tests and
                     future chrome should be able to read off the card. -->
                <div
                    data-thread-state={t.state}
                    class={"overflow-hidden rounded-xl border transition-colors " +
                        (selectedId === t.id
                            ? TONE_BORDER[meta.tone] + " bg-fg/[0.06] shadow-lg"
                            : "border-line/15 bg-fg/[0.03]")}
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
                                <pre
                                    class="m-0 overflow-x-auto border-l-2 border-line/30 bg-sunken px-2 py-1 text-xs whitespace-pre text-dim">{t.anchorText}</pre>
                            {/if}
                            <div class="flex flex-col gap-3 py-2.5">
                                {#each t.comments as c (c.id)}
                                    {@const av = avatar(c.author)}
                                    <div class="flex gap-2.5">
                                        <span
                                            class={"inline-flex size-5 shrink-0 items-center justify-center rounded-md text-[10px] font-bold " +
                                                (av.isAgent
                                                    ? "bg-acc/20 text-acc"
                                                    : "bg-fg/10 text-fg")}>{av.initials}</span
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

                            {#if err}<div class="text-xs text-red [overflow-wrap:anywhere]">
                                    {err}
                                </div>{/if}

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
                                    class="box-border min-h-6.5 w-full min-w-0 flex-1 resize-none rounded-sm border border-line/15 bg-sunken px-1.5 py-1 font-mono text-xs text-fg focus:border-acc focus:outline-none"
                                    placeholder="reply…"
                                    bind:value={draft}
                                    onkeydown={(e) => keydown(e, reply)}
                                />
                                <button
                                    class="shrink-0 cursor-pointer rounded-lg border border-line/15 bg-fg/5 px-3 text-[11px] font-semibold text-fg hover:border-acc disabled:opacity-50"
                                    disabled={busy}
                                    onclick={reply}>Send</button
                                >
                            </div>

                            <div
                                class="mt-2.5 flex items-center gap-3.5 border-t border-line/15 pt-2.5"
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
            class="flex shrink-0 items-center gap-2.5 border-t border-line/15 px-3.5 py-2 font-mono text-[10px] text-lo"
        >
            <!-- Name the gesture that actually exists. The mockup's "click any
                 line to start a thread" was aspirational: a bare line click does
                 nothing, and creation is Monaco's rook.comment action
                 (term/editor.ts) — ⌘⇧M on a selection, or its context menu.
                 Both spans stay nowrap: the pane is 352px and a wrapped hint
                 pushes the footer to two lines. -->
            <span class="whitespace-nowrap">⌘⇧M starts a thread</span>
            <span class="flex-1"></span>
            <span class="whitespace-nowrap">agents reply here</span>
        </div>
    </div>
{/if}
