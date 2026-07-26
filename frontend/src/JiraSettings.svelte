<!-- Jira connection. URL/email/JQL/projects are read-only config now (the
     app no longer writes config — edit [jira] and [workspaces.<name>] in
     ~/.config/rook/config.toml; the host hot-reads it on the next refresh).
     The token is NOT config: it lives in the keychain and is still managed
     here, via SetJiraToken/ClearJiraToken. -->
<script lang="ts">
    import {Call} from "@wailsio/runtime";
    import type {Config as ConfigModel} from "../bindings/github.com/incantery/rook/internal/config/models";
    import {app} from "./state.svelte";

    const SVC = "github.com/incantery/rook/internal/config.Service.";

    let {cfg}: {cfg: ConfigModel} = $props();

    // svelte-ignore state_referenced_locally — seeded once; the shell reloads cfg on open
    const projects = (cfg.jiraProjects ?? {}) as Record<string, string>;
    const workspaceNames = $derived(
        [...new Set([...app.workspaces.map((w) => w.name), ...Object.keys(projects)])].sort(),
    );

    let token = $state("");
    let tokenStatus = $state("checking…");
    let tokenOk = $state(false);
    let error = $state("");

    $effect(() => {
        Call.ByName(SVC + "JiraTokenStatus").then(
            (s: string) => {
                tokenStatus =
                    s === "keychain"
                        ? "✓ a token is stored in the keychain — saving replaces it"
                        : s === "file"
                          ? "a token file exists (~/.config/rook/jira-token) — the keychain wins once set"
                          : "no token configured — the Jira queue stays off until one exists";
                tokenOk = !!s;
            },
            () => (tokenStatus = ""),
        );
    });

    async function saveToken() {
        error = "";
        const t = token.trim();
        if (!t) return;
        try {
            await Call.ByName(SVC + "SetJiraToken", t);
            token = "";
            tokenOk = true;
            tokenStatus = "✓ a token is stored in the keychain — saving replaces it";
        } catch (err) {
            error = `save failed: ${err}`;
        }
    }

    async function clearToken() {
        error = "";
        try {
            await Call.ByName(SVC + "ClearJiraToken");
            tokenOk = false;
            tokenStatus = "no token configured — the Jira queue stays off until one exists";
        } catch (err) {
            error = `clear failed: ${err}`;
        }
    }
</script>

<div class="flex flex-col gap-4 p-4.5">
    <div class="border-b border-line/15 px-4.5 py-3.5 text-sm font-bold text-fg">
        Jira connection
    </div>

    <div class="mx-4.5 rounded-lg border border-line/15 bg-sunken/50 px-3 py-2.5 text-xs text-dim">
        The connection is configured in
        <span class="font-mono text-fg">~/.config/rook/config.toml</span> — the
        <span class="font-mono text-fg">[jira]</span> section for url/email/jql, a
        <span class="font-mono text-fg">jira-project</span> key under
        <span class="font-mono text-fg">[workspaces.&lt;name&gt;]</span> to opt a workspace in. The
        host re-reads it on the next refresh. Only the API token is managed here (it lives in the
        keychain, never in the file).
    </div>

    <div class="my-2 flex flex-col gap-2 px-4.5 text-sm">
        <div class="flex items-center gap-2">
            <span class="w-32 text-xs font-semibold text-dim">Base URL</span>
            <span class="font-mono text-fg">{cfg.jiraUrl || "(unset — queue off)"}</span>
        </div>
        <div class="flex items-center gap-2">
            <span class="w-32 text-xs font-semibold text-dim">Email</span>
            <span class="font-mono text-fg">{cfg.jiraEmail || "(unset)"}</span>
        </div>
        <div class="flex items-center gap-2">
            <span class="w-32 text-xs font-semibold text-dim">JQL override</span>
            <span class="font-mono text-fg">{cfg.jiraJql || "(built-in query)"}</span>
        </div>
    </div>

    <div class={["mt-1.5 mb-3.5 px-4.5", tokenOk ? "text-grn" : "text-dim"]}>{tokenStatus}</div>
    <div class="my-2 flex items-center gap-2 px-4.5">
        <span>API token</span>
        <input
            type="password"
            class="box-border w-full min-w-0 flex-1 rounded-lg border border-line/15 bg-sunken/80 px-2.5 py-2 font-mono text-sm text-fg outline-none focus:border-acc"
            placeholder="paste token (underscores welcome)"
            bind:value={token}
            spellcheck="false"
            autocomplete="off"
        />
        <button
            class="flex cursor-pointer items-center gap-2 rounded-lg bg-acc px-3 py-1.5 font-[inherit] text-xs font-semibold text-on-acc"
            disabled={!token.trim()}
            onclick={() => void saveToken()}>Save</button
        >
        <button
            class="flex cursor-pointer items-center gap-2 rounded-lg border border-line/15 bg-fg/5 px-3 py-1.5 font-[inherit] text-xs font-semibold text-fg hover:bg-fg/10"
            onclick={() => void clearToken()}>Remove</button
        >
    </div>

    <div class="border-b border-line/15 px-4.5 py-3.5 text-sm font-bold text-fg">
        Project mapping
    </div>
    <div class="flex flex-col gap-1.5 px-4.5 pb-3">
        {#each workspaceNames as ws (ws)}
            <div class="flex items-center gap-2 text-sm">
                <span class="w-44 font-mono text-fg">{ws}</span>
                <span class="text-dim">{projects[ws] || "(no queue)"}</span>
            </div>
        {/each}
    </div>

    {#if error}<div class="mt-2 px-4.5 text-red">{error}</div>{/if}
</div>
