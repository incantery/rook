<!-- A workbench pane slot (VS Code-style secondary side bar / bottom panel):
     a generic, placement-agnostic slot. It knows a side, a visibility, and a
     title — nothing about its tenant. Left/right are the vertical rails
     (explorer, threads); bottom is the vim-quickfix strip. Panes slide in and
     out — chrome motion the webview gives us for free, and a terminal never
     could. -->
<script lang="ts">
    import type {Snippet} from "svelte";
    import {slide} from "svelte/transition";

    interface Props {
        side: "left" | "right" | "bottom";
        visible: boolean;
        title: string;
        onclose: () => void;
        children: Snippet;
    }

    let {side, visible, title, onclose, children}: Props = $props();
</script>

{#if visible}
    <!-- `side-pane` is kept as a bare JS-hook marker (App's keydown guard
         does closest(".side-pane")), not a style. data-side is the same kind
         of hook: App projects DOM focus onto its focus zone and needs to know
         WHICH side took it, without reading a layout class. -->
    <aside
        data-side={side}
        transition:slide={{duration: 160, axis: side === "bottom" ? "y" : "x"}}
        class={[
            "side-pane flex flex-col border-line/15 bg-raise",
            side === "left" && "order-first w-88 min-w-64 border-r",
            side === "right" && "w-88 min-w-64 border-l",
            side === "bottom" && "h-72 w-full shrink-0 border-t",
        ]}
    >
        <header class="flex items-center justify-between border-b border-line/15 px-2 py-1">
            <!-- explicit color, not inherited: this span is the reason body
                 needed one at all, and a pane title is exactly the kind of
                 chrome nobody re-checks after a theme change -->
            <span class="text-xs uppercase tracking-wider text-dim">{title}</span>
            <button
                class="flex-none cursor-pointer rounded-sm border border-line/15 px-1.5 py-px font-mono text-xs text-dim hover:border-acc hover:text-fg"
                title="close pane"
                onclick={onclose}>×</button
            >
        </header>
        <div class="min-h-0 flex-1 overflow-y-auto">
            {@render children()}
        </div>
    </aside>
{/if}
