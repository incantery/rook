<!-- The thread conversation, the side pane's first tenant. Placement-
     agnostic (knows nothing about left/right): it takes the active editor
     pane's seam + hostapi and renders one thread at a time. Marker clicks
     and ⌘⇧M come UP through the seam; reveal/highlight go DOWN. Drafts live
     here in chrome, so a background refetch never eats them. -->
<script lang="ts">
    import type {HostAPI, ThreadInfo} from "./hostapi";
    import type {EditorSeam} from "./term/editor";
    import {contextKey, cycleStack, pickFromStack, threadStack, type Side} from "./term/threadview";

    let {api, editor}: {api: HostAPI; editor: EditorSeam | null} = $props();

    type Sel =
        | {mode: "empty"}
        | {mode: "composer"; startLine: number; endLine: number; side: Side}
        | {mode: "thread"; id: number};

    let threads = $state<ThreadInfo[]>([]);
    let sel = $state<Sel>({mode: "empty"});
    let draft = $state(""); // reply / new-comment text — never clobbered by refetch
    let err = $state("");
    let busy = $state(false);
    let ctxKey = ""; // last-seen file identity; selection resets when it changes

    // (Re)bind to the active editor whenever the prop changes.
    $effect(() => {
        const seam = editor;
        if (!seam) {
            threads = [];
            sel = {mode: "empty"};
            ctxKey = "";
            return;
        }
        sync();
        const offChange = seam.onChange(sync);
        const offMarker = seam.onMarkerClick((line, side, _ids) => selectAt(line, side));
        const offCompose = seam.onCompose((s, e, side) => {
            draft = "";
            err = "";
            sel = {mode: "composer", startLine: s, endLine: e, side};
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
        // file-nav / workspace switch → drop the selection
        const key = contextKey(editor.context());
        if (key !== ctxKey) {
            ctxKey = key;
            sel = {mode: "empty"};
            draft = "";
            err = "";
        }
    }

    function selectAt(line: number, side: Side): void {
        const ctx = editor?.context();
        if (!ctx) return;
        const stack = threadStack(threads, ctx.path, side, line);
        const active = sel.mode === "thread" ? sel.id : undefined;
        const pick = pickFromStack(stack, active);
        if (!pick) return;
        draft = "";
        err = "";
        sel = {mode: "thread", id: pick.thread.id};
        editor?.reveal(pick.thread);
    }

    // The active thread (or null) + its N-of-Y position within the line stack.
    let active = $derived.by(() => {
        if (sel.mode !== "thread") return null;
        const t = threads.find((x) => x.id === (sel as {id: number}).id);
        if (!t) return null;
        const line = Math.max(1, t.currentStart);
        const stack = threadStack(threads, t.path, t.side, line);
        const pick = pickFromStack(stack, t.id);
        return {thread: t, stack, index: pick?.index ?? 0, count: pick?.count ?? 1};
    });

    function cycle(dir: 1 | -1): void {
        if (!active) return;
        const id = cycleStack(active.stack, active.thread.id, dir);
        if (id == null) return;
        const t = threads.find((x) => x.id === id);
        sel = {mode: "thread", id};
        draft = "";
        if (t) editor?.reveal(t);
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
        if (!body || !ctx || sel.mode !== "composer") return;
        const {startLine, endLine, side} = sel;
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
        });
        // select AFTER run()'s refetch has populated `threads`, so the
        // `active` derived resolves immediately (no empty-state flash)
        if (created) {
            sel = {mode: "thread", id: (created as ThreadInfo).id};
            editor?.reveal(created as ThreadInfo);
        }
    }

    async function reply(): Promise<void> {
        const body = draft.trim();
        if (!body || !active) return;
        const id = active.thread.id;
        await run(async () => {
            await api.threadComment(id, body);
            draft = "";
        });
    }

    async function resolve(): Promise<void> {
        if (!active) return;
        const id = active.thread.id;
        await run(() => api.threadResolve(id));
    }

    async function reopen(): Promise<void> {
        if (!active) return;
        const id = active.thread.id;
        await run(() => api.threadReopen(id));
    }

    function cancel(): void {
        sel = {mode: "empty"};
        draft = "";
        err = "";
        editor?.clearHighlight();
    }

    function keydown(e: KeyboardEvent, submit: () => void): void {
        if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) {
            e.preventDefault();
            submit();
        } else if (e.key === "Escape") {
            cancel();
        }
    }

    function fmtRange(a: number, b: number): string {
        return a === b ? `L${a}` : `L${a}–${b}`;
    }
</script>

{#if !editor}
    <div class="p-4 text-sm opacity-60">focus a review or file pane to see its threads</div>
{:else if sel.mode === "composer"}
    <div
        class="my-1 mr-3 ml-1 box-border flex max-w-160 flex-col gap-1.5 rounded-md border border-[#252a3d] bg-[#151928] px-2.5 py-2 font-mono text-sm leading-normal text-fg"
    >
        <div class="overflow-hidden text-ellipsis text-xs text-dim">
            new thread on {fmtRange(sel.startLine, sel.endLine)}{sel.side === "original"
                ? " (original side)"
                : ""}
        </div>
        <textarea
            class="box-border min-h-6.5 w-full resize-y rounded-sm border border-[#252a3d] bg-[#0b0d14] px-1.5 py-1 font-mono text-sm text-fg focus:border-acc focus:outline-none"
            rows="3"
            placeholder="start a thread… (⌘⏎ comments · esc cancels)"
            bind:value={draft}
            onkeydown={(e) => keydown(e, submitComposer)}></textarea>
        {#if err}<div class="text-xs text-red [overflow-wrap:anywhere]">{err}</div>{/if}
        <div class="flex items-center gap-1.5">
            <button
                class="flex-none cursor-pointer rounded-sm border border-line/15 bg-transparent px-1.5 py-px font-mono text-xs text-dim hover:border-acc hover:text-fg"
                disabled={busy}
                onclick={submitComposer}
            >
                comment
            </button>
            <button
                class="flex-none cursor-pointer rounded-sm border border-line/15 bg-transparent px-1.5 py-px font-mono text-xs text-dim hover:border-acc hover:text-fg"
                onclick={cancel}>cancel</button
            >
        </div>
    </div>
{:else if active}
    <div
        class="my-1 mr-3 ml-1 box-border flex max-w-160 flex-col gap-1.5 rounded-md border border-[#252a3d] bg-[#151928] px-2.5 py-2 font-mono text-sm leading-normal text-fg"
    >
        <div class="flex items-center gap-1.5">
            <span
                class={[
                    "flex-none rounded-full border border-current px-1.5 text-xs tracking-wider uppercase",
                    active.thread.state === "pending" && "text-amber",
                    active.thread.state === "open" && "text-acc",
                    active.thread.state === "resolved" && "text-grn",
                ]}>{active.thread.state}</span
            >
            <span class="overflow-hidden text-ellipsis text-xs text-dim">
                #{active.thread.id} · {fmtRange(
                    active.thread.currentStart,
                    active.thread.currentEnd,
                )}{active.thread.outdated ? " · outdated" : ""}{active.thread.resolvedBy
                    ? ` · by ${active.thread.resolvedBy}`
                    : ""}
            </span>
            {#if active.count > 1}
                <span class="ml-auto text-xs whitespace-nowrap opacity-80">
                    <button
                        class="flex-none cursor-pointer rounded-sm border border-line/15 bg-transparent px-1.5 py-px font-mono text-xs text-dim hover:border-acc hover:text-fg"
                        title="previous thread here"
                        onclick={() => cycle(-1)}>‹</button
                    >
                    {active.index + 1} of {active.count}
                    <button
                        class="flex-none cursor-pointer rounded-sm border border-line/15 bg-transparent px-1.5 py-px font-mono text-xs text-dim hover:border-acc hover:text-fg"
                        title="next thread here"
                        onclick={() => cycle(1)}>›</button
                    >
                </span>
            {/if}
        </div>
        {#if active.thread.outdated && active.thread.anchorText}
            <pre
                class="m-0 overflow-x-auto border-l-2 border-[#464b66] bg-[#0b0d14] px-2 py-1 text-xs whitespace-pre text-dim">{active
                    .thread.anchorText}</pre>
        {/if}
        {#each active.thread.comments as c (c.id)}
            <div class="flex flex-col gap-0.5">
                <span class={["text-xs", c.author === "user" ? "text-amber" : "text-acc"]}
                    >{c.author}</span
                >
                <div class="whitespace-pre-wrap [overflow-wrap:anywhere]">{c.body}</div>
            </div>
        {/each}
        {#if err}<div class="text-xs text-red [overflow-wrap:anywhere]">{err}</div>{/if}
        <div class="flex flex-col gap-1">
            <textarea
                class="box-border min-h-6.5 w-full resize-y rounded-sm border border-[#252a3d] bg-[#0b0d14] px-1.5 py-1 font-mono text-sm text-fg focus:border-acc focus:outline-none"
                rows="1"
                placeholder="reply… (⌘⏎ sends · esc closes)"
                bind:value={draft}
                onkeydown={(e) => keydown(e, reply)}></textarea>
            <div class="flex items-center gap-1.5">
                <button
                    class="flex-none cursor-pointer rounded-sm border border-line/15 bg-transparent px-1.5 py-px font-mono text-xs text-dim hover:border-acc hover:text-fg"
                    disabled={busy}
                    onclick={reply}>reply</button
                >
                {#if active.thread.state === "resolved"}
                    <button
                        class="flex-none cursor-pointer rounded-sm border border-line/15 bg-transparent px-1.5 py-px font-mono text-xs text-dim hover:border-acc hover:text-fg"
                        disabled={busy}
                        onclick={reopen}>reopen</button
                    >
                {:else}
                    <button
                        class="flex-none cursor-pointer rounded-sm border border-line/15 bg-transparent px-1.5 py-px font-mono text-xs text-dim hover:border-acc hover:text-fg"
                        disabled={busy}
                        onclick={resolve}>resolve</button
                    >
                {/if}
            </div>
        </div>
    </div>
{:else}
    <div class="p-4 text-sm opacity-60">
        select a gutter marker, or select code and ⌘⇧M to comment
    </div>
{/if}
