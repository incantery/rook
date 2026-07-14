<!-- A workbench side pane (VS Code-style secondary side bar): a generic,
     placement-agnostic slot. It knows a side, a visibility, and a title —
     nothing about its tenant. The thread panel is this slice's only
     tenant; a left pane / more panels drop in without touching it. -->
<script lang="ts">
    import type {Snippet} from "svelte";

    interface Props {
        side: "left" | "right";
        visible: boolean;
        title: string;
        onclose: () => void;
        children: Snippet;
    }

    let {side, visible, title, onclose, children}: Props = $props();
</script>

{#if visible}
    <!-- `side-pane` is kept as a bare JS-hook marker (App's keydown guard
         does closest(".side-pane")), not a style. -->
    <aside
        class={[
            "side-pane flex w-88 min-w-64 flex-col border-line/15 bg-raise",
            side === "left" ? "order-first border-r" : "border-l",
        ]}
    >
        <header class="flex items-center justify-between border-b border-line/15 px-2 py-1">
            <span class="text-xs uppercase tracking-wider opacity-70">{title}</span>
            <button
                class="flex-none cursor-pointer rounded-sm border border-line/15 bg-transparent px-1.5 py-px font-mono text-xs text-dim hover:border-acc hover:text-fg"
                title="close pane"
                onclick={onclose}>×</button
            >
        </header>
        <div class="min-h-0 flex-1 overflow-y-auto">
            {@render children()}
        </div>
    </aside>
{/if}
