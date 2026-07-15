<!-- The spawn modal (` n / palette "New agent session"): type a task, get a
     window with claude already working on it. This is the user-invoked rung
     of the spawner ladder (docs/agent.md step 4) — zero LLM; nano earns
     routing and unsolicited proposals later, through the same actuator. -->
<script lang="ts">
    interface Props {
        currentWorkspace: string;
        onspawn: (task: string, workspace: string, worktree: boolean) => Promise<void>;
        onclose: () => void;
    }
    let {currentWorkspace, onspawn, onclose}: Props = $props();

    let task = $state("");
    // svelte-ignore state_referenced_locally — prefill, user edits from here
    let ws = $state(currentWorkspace);
    let worktree = $state(false);
    let error = $state("");
    let taskEl: HTMLTextAreaElement;

    $effect(() => {
        taskEl.focus();
    });

    async function go() {
        const t = task.trim();
        if (!t) {
            taskEl.focus();
            return;
        }
        try {
            await onspawn(t, ws.trim() || currentWorkspace, worktree);
            onclose();
        } catch (err) {
            error = `spawn failed: ${err}`;
        }
    }

    // Window-level, not overlay-level: clicking non-focusable modal chrome
    // moves focus to <body>, and keydown from there never bubbles through
    // the overlay — ESC must work no matter where focus wandered.
    function onKeydown(e: KeyboardEvent) {
        // buttons keep native Enter (a focused Cancel must cancel, not submit)
        if (e.key === "Enter" && !e.shiftKey && !(e.target instanceof HTMLButtonElement)) {
            e.preventDefault();
            void go();
        } else if (e.key === "Escape") onclose();
        e.stopPropagation();
    }
</script>

<svelte:window onkeydown={onKeydown} />

<div
    class="fixed inset-0 z-50 flex items-start justify-center bg-black/55 pt-[12vh]"
    onmousedown={(e) => e.target === e.currentTarget && onclose()}
    role="presentation"
>
    <div
        class="w-150 max-w-[92vw] overflow-hidden rounded-xl border border-line/30 bg-overlay shadow-2xl"
    >
        <div class="border-b border-line/15 px-4.5 py-3.5 text-sm font-bold text-fg">
            New agent session
        </div>
        <div class="flex flex-col gap-4 p-4.5">
            <label>
                <span class="mb-1.5 block text-xs font-semibold text-dim"
                    >Task — becomes <code>claude "…"</code> in a fresh window</span
                >
                <textarea
                    class="box-border w-full resize-y rounded-lg border border-line/15 bg-sunken/80 px-2.5 py-2 font-mono text-sm text-fg outline-none focus:border-acc"
                    rows="3"
                    spellcheck="false"
                    placeholder="fix the flaky picker test and run the suite"
                    bind:value={task}
                    bind:this={taskEl}></textarea>
            </label>
            <label
                ><span class="mb-1.5 block text-xs font-semibold text-dim">Workspace</span><input
                    class="box-border w-full rounded-lg border border-line/15 bg-sunken/80 px-2.5 py-2 font-mono text-sm text-fg outline-none focus:border-acc"
                    spellcheck="false"
                    bind:value={ws}
                /></label
            >
            <label
                class="flex cursor-pointer items-center gap-2"
                title="a git worktree off the workspace's repo — parallel sessions stop sharing one checkout"
            >
                <input type="checkbox" class="m-0 w-auto accent-acc" bind:checked={worktree} />
                <span class="text-xs font-normal text-dim"
                    >Isolate in a task tree of the workspace (branch <code>rook/…</code>)</span
                >
            </label>
            {#if error}
                <div class="font-mono text-xs text-red">{error}</div>
            {/if}
        </div>
        <div class="flex justify-end gap-2 border-t border-line/15 px-4.5 py-3.5">
            <button
                class="flex cursor-pointer items-center gap-2 rounded-lg border border-line/15 bg-fg/5 px-3 py-1.5 font-[inherit] text-xs font-semibold text-fg hover:bg-fg/10"
                onclick={onclose}>Cancel</button
            >
            <button
                class="flex cursor-pointer items-center gap-2 rounded-lg border-0 bg-acc px-3 py-1.5 font-[inherit] text-xs font-semibold text-on-acc"
                onclick={() => void go()}>Start session</button
            >
        </div>
    </div>
</div>
