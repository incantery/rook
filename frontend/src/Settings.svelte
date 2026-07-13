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

    let {onclose}: {onclose: () => void} = $props();

    type Section = "jira" | "openai" | "appearance";
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
    ];
</script>

<svelte:window onkeydown={onKeydown} />

<div id="settings" class="settings-screen" bind:this={rootEl} tabindex="-1">
    <div class="settings-bar">
        <div class="settings-title">Settings</div>
        <button class="home-btn settings-close" onclick={onclose}>Close (Esc)</button>
    </div>
    <div class="settings-body">
        <nav class="settings-nav">
            {#each nav as n (n.id)}
                <button
                    class="settings-nav-item"
                    class:active={section === n.id}
                    onclick={() => (section = n.id)}>{n.label}</button
                >
            {/each}
        </nav>
        <section class="settings-pane">
            {#if cfg == null}
                <div class="settings-loading">loading…</div>
            {:else if section === "jira"}
                <JiraSettings {cfg} />
            {:else if section === "openai"}
                <OpenAISettings />
            {:else}
                <AppearanceSettings {cfg} />
            {/if}
        </section>
    </div>
</div>
