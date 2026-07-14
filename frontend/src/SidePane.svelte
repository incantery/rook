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
    <aside class="side-pane side-pane-{side}">
        <header class="side-pane-head">
            <span class="side-pane-title">{title}</span>
            <button class="editor-btn" title="close pane" onclick={onclose}>×</button>
        </header>
        <div class="side-pane-body">
            {@render children()}
        </div>
    </aside>
{/if}
