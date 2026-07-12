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
    id="spawn-modal"
    class="overlay"
    onmousedown={(e) => e.target === e.currentTarget && onclose()}
    role="presentation"
>
    <div class="pal-panel">
        <div class="ws-modal-title">New agent session</div>
        <div class="ws-form">
            <label>
                <span>Task — becomes <code>claude "…"</code> in a fresh window</span>
                <textarea
                    class="spawn-task"
                    rows="3"
                    spellcheck="false"
                    placeholder="fix the flaky picker test and run the suite"
                    bind:value={task}
                    bind:this={taskEl}></textarea>
            </label>
            <label
                ><span>Workspace</span><input
                    class="spawn-ws"
                    spellcheck="false"
                    bind:value={ws}
                /></label
            >
            <label
                class="spawn-wt"
                title="git worktree off the workspace's repo — parallel sessions stop sharing one checkout"
            >
                <input type="checkbox" bind:checked={worktree} />
                <span>Isolate in a new worktree (branch <code>rook/…</code>)</span>
            </label>
            <div class="key-error" hidden={!error}>{error}</div>
        </div>
        <div class="ws-modal-foot">
            <button class="home-btn spawn-cancel" onclick={onclose}>Cancel</button>
            <button class="home-btn primary spawn-go" onclick={() => void go()}
                >Start session</button
            >
        </div>
    </div>
</div>
