<!-- frontend/src/ThreadPanel.svelte (stub — filled in Task 5) -->
<script lang="ts">
    import type {HostAPI} from "./hostapi";
    import type {EditorSeam} from "./term/editor";
    let {api, editor}: {api: HostAPI; editor: EditorSeam | null} = $props();
    void api;
</script>

<div class="thread-panel-empty">{editor ? "no thread selected" : "focus a review pane"}</div>
