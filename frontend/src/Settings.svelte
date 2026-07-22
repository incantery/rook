<!-- The Settings view: full-screen, left nav (Jira / OpenAI / Appearance).
     Every write goes through config.Service — secrets to the keychain, the
     rest surgically into ~/.config/rook/config. Jira edits apply on the next
     host request; appearance edits are boot-cached, so their section reloads
     the page after saving. -->
<script lang="ts">
    import {Service as Config} from "../bindings/github.com/incantery/rook/internal/config";
    import type {Config as ConfigModel} from "../bindings/github.com/incantery/rook/internal/config/models";
    import JiraSettings from "./JiraSettings.svelte";
    import OpenAISettings from "./OpenAISettings.svelte";
    import AppearanceSettings from "./AppearanceSettings.svelte";
    import ExperimentalSettings from "./ExperimentalSettings.svelte";

    let {onclose}: {onclose: () => void} = $props();

    type Section = "jira" | "openai" | "appearance" | "experimental";
    let section = $state<Section>("jira");
    let cfg = $state<ConfigModel | null>(null);
    let rootEl: HTMLDivElement;

    $effect(() => {
        // pull focus off the terminal's hidden xterm input so keystrokes
        // don't leak through; later sections' own inputs take over on click
        rootEl?.focus();
        Config.Get().then(
            (c) => (cfg = c),
            (err) => console.error("settings: config load failed", err),
        );
    });

    function onKeydown(e: KeyboardEvent) {
        if (e.key === "Escape") onclose();
        e.stopPropagation();
    }

    const nav: {id: Section; label: string}[] = [
        {id: "jira", label: "Jira"},
        {id: "openai", label: "OpenAI"},
        {id: "appearance", label: "Appearance"},
        {id: "experimental", label: "Experimental"},
    ];
</script>

<svelte:window onkeydown={onKeydown} />

<div
    id="settings"
    class="fixed inset-0 z-50 flex flex-col bg-bg/98 text-dim outline-none"
    bind:this={rootEl}
    tabindex="-1"
>
    <div class="flex items-center justify-between border-b border-line/15 px-4 py-3">
        <div class="text-base text-fg">Settings</div>
        <button
            class="flex cursor-pointer items-center gap-2 rounded-lg border border-line/15 bg-fg/5 px-3 py-1.5 font-[inherit] text-xs font-semibold text-fg hover:bg-fg/10"
            onclick={onclose}>Close (Esc)</button
        >
    </div>
    <div class="flex min-h-0 flex-1">
        <nav class="flex w-40 flex-col gap-1 border-r border-line/15 px-2 py-3">
            {#each nav as n (n.id)}
                <button
                    class={[
                        "cursor-pointer rounded-md border-0 px-3 py-2 text-left",
                        section === n.id ? "bg-line/20 text-fg" : "bg-transparent text-dim",
                    ]}
                    onclick={() => (section = n.id)}>{n.label}</button
                >
            {/each}
        </nav>
        <section class="flex-1 overflow-y-auto px-6 py-5">
            {#if cfg == null}
                <div class="text-dim">loading…</div>
            {:else if section === "jira"}
                <JiraSettings {cfg} />
            {:else if section === "openai"}
                <OpenAISettings />
            {:else if section === "experimental"}
                <ExperimentalSettings />
            {:else}
                <AppearanceSettings {cfg} />
            {/if}
        </section>
    </div>
</div>
