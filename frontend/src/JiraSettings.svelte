<!-- Jira connection. URL/email/JQL/projects write to the config file via
     SetConfig; the token goes to the keychain via SetJiraToken. Nothing here
     needs a reload — the host hot-reads config + token on the next refresh. -->
<script lang="ts">
    import {Call} from "@wailsio/runtime";
    import type {Config as ConfigModel} from "../bindings/github.com/incantery/rook/internal/config/models";
    import {app} from "./state.svelte";

    const SVC = "github.com/incantery/rook/internal/config.Service.";

    let {cfg}: {cfg: ConfigModel} = $props();

    // seeded once from cfg into an editable buffer; not $derived on purpose
    // svelte-ignore state_referenced_locally
    let url = $state(cfg.jiraUrl ?? "");
    // svelte-ignore state_referenced_locally
    let email = $state(cfg.jiraEmail ?? "");
    // svelte-ignore state_referenced_locally
    let jql = $state(cfg.jiraJql ?? "");
    // project rows keyed by workspace name; start from config, offer a row per
    // known workspace so mapping is discoverable
    // svelte-ignore state_referenced_locally
    let projects = $state<Record<string, string>>({...cfg.jiraProjects} as Record<string, string>);
    let token = $state("");
    let tokenStatus = $state("checking…");
    let tokenOk = $state(false);
    let error = $state("");
    let saved = $state(false);

    const workspaceNames = $derived(
        [...new Set([...app.workspaces.map((w) => w.name), ...Object.keys(projects)])].sort(),
    );

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

    async function save() {
        error = "";
        saved = false;
        // only send non-empty project rows; omitted rows are deleted by SetConfig
        const proj: Record<string, string> = {};
        for (const [ws, key] of Object.entries(projects)) {
            if (key.trim()) proj[ws] = key.trim();
        }
        try {
            await Call.ByName(SVC + "SetConfig", {
                jiraUrl: url.trim(),
                jiraEmail: email.trim(),
                jiraJql: jql.trim(),
                projects: proj,
            });
            const t = token.trim();
            if (t) {
                await Call.ByName(SVC + "SetJiraToken", t);
                token = "";
                tokenOk = true;
                tokenStatus = "✓ a token is stored in the keychain — saving replaces it";
            }
            saved = true;
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

    <label class="my-2 flex items-center gap-2"
        ><span class="mb-1.5 block text-xs font-semibold text-dim">Base URL</span>
        <input
            type="text"
            class="box-border w-full min-w-0 flex-1 rounded-lg border border-line/15 bg-sunken/80 px-2.5 py-2 font-mono text-sm text-fg outline-none focus:border-acc"
            placeholder="https://org.atlassian.net"
            bind:value={url}
            spellcheck="false"
            autocomplete="off"
        />
    </label>
    <label class="my-2 flex items-center gap-2"
        ><span class="mb-1.5 block text-xs font-semibold text-dim">Email</span>
        <input
            type="text"
            class="box-border w-full min-w-0 flex-1 rounded-lg border border-line/15 bg-sunken/80 px-2.5 py-2 font-mono text-sm text-fg outline-none focus:border-acc"
            placeholder="you@org.com"
            bind:value={email}
            spellcheck="false"
            autocomplete="off"
        />
    </label>
    <label class="my-2 flex items-center gap-2"
        ><span class="mb-1.5 block text-xs font-semibold text-dim">JQL override</span>
        <input
            type="text"
            class="box-border w-full min-w-0 flex-1 rounded-lg border border-line/15 bg-sunken/80 px-2.5 py-2 font-mono text-sm text-fg outline-none focus:border-acc"
            placeholder="(optional)"
            bind:value={jql}
            spellcheck="false"
            autocomplete="off"
        />
    </label>

    <div class={["mt-1.5 mb-3.5", tokenOk ? "text-grn" : "text-dim"]}>{tokenStatus}</div>
    <div class="my-2 flex items-center gap-2">
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
            class="flex cursor-pointer items-center gap-2 rounded-lg border border-line/15 bg-fg/5 px-3 py-1.5 font-[inherit] text-xs font-semibold text-fg hover:bg-fg/10"
            onclick={() => void clearToken()}>Remove</button
        >
    </div>

    <div class="border-b border-line/15 px-4.5 py-3.5 text-sm font-bold text-fg">
        Project mapping
    </div>
    {#each workspaceNames as ws (ws)}
        <label class="my-2 flex items-center gap-2"
            ><span class="mb-1.5 block text-xs font-semibold text-dim">{ws}</span>
            <input
                type="text"
                class="box-border w-full min-w-0 flex-1 rounded-lg border border-line/15 bg-sunken/80 px-2.5 py-2 font-mono text-sm text-fg outline-none focus:border-acc"
                placeholder="PROJECTKEY (blank = off)"
                spellcheck="false"
                autocomplete="off"
                value={projects[ws] ?? ""}
                oninput={(e) =>
                    (projects = {...projects, [ws]: (e.target as HTMLInputElement).value})}
            />
        </label>
    {/each}

    {#if error}<div class="mt-2 text-red">{error}</div>{/if}
    <div class="flex justify-end gap-2 border-t border-line/15 px-4.5 py-3.5">
        <span class="flex-1"></span>
        {#if saved}<span class="ml-2 text-grn">saved ✓</span>{/if}
        <button
            class="flex cursor-pointer items-center gap-2 rounded-lg border-0 bg-acc px-3 py-1.5 font-[inherit] text-xs font-semibold text-on-acc"
            onclick={() => void save()}>Save</button
        >
    </div>
</div>
