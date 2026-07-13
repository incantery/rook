<!-- Jira connection. URL/email/JQL/projects write to the config file via
     SetConfig; the token goes to the keychain via SetJiraToken. Nothing here
     needs a reload — the host hot-reads config + token on the next refresh. -->
<script lang="ts">
    import {Call} from "@wailsio/runtime";
    import type {Config as ConfigModel} from "../bindings/github.com/incantery/rook/internal/config/models";
    import {app} from "./state.svelte";

    const SVC = "github.com/incantery/rook/internal/config.Service.";

    let {cfg}: {cfg: ConfigModel} = $props();

    let url = $state(cfg.jiraUrl ?? "");
    let email = $state(cfg.jiraEmail ?? "");
    let jql = $state(cfg.jiraJql ?? "");
    // project rows keyed by workspace name; start from config, offer a row per
    // known workspace so mapping is discoverable
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
        try {
            await Call.ByName(SVC + "ClearJiraToken");
            tokenOk = false;
            tokenStatus = "no token configured — the Jira queue stays off until one exists";
        } catch (err) {
            error = `clear failed: ${err}`;
        }
    }
</script>

<div class="ws-form">
    <div class="ws-modal-title">Jira connection</div>

    <label class="settings-row"><span>Base URL</span>
        <input type="text" placeholder="https://org.atlassian.net" bind:value={url} spellcheck="false" autocomplete="off" />
    </label>
    <label class="settings-row"><span>Email</span>
        <input type="text" placeholder="you@org.com" bind:value={email} spellcheck="false" autocomplete="off" />
    </label>
    <label class="settings-row"><span>JQL override</span>
        <input type="text" placeholder="(optional)" bind:value={jql} spellcheck="false" autocomplete="off" />
    </label>

    <div class="settings-status" class:ok={tokenOk}>{tokenStatus}</div>
    <div class="settings-row"><span>API token</span>
        <input type="password" placeholder="paste token (underscores welcome)" bind:value={token} spellcheck="false" autocomplete="off" />
        <button class="home-btn" onclick={() => void clearToken()}>Remove</button>
    </div>

    <div class="ws-modal-title">Project mapping</div>
    {#each workspaceNames as ws (ws)}
        <label class="settings-row"><span>{ws}</span>
            <input type="text" placeholder="PROJECTKEY (blank = off)" spellcheck="false" autocomplete="off"
                value={projects[ws] ?? ""}
                oninput={(e) => (projects = {...projects, [ws]: (e.target as HTMLInputElement).value})} />
        </label>
    {/each}

    {#if error}<div class="settings-error">{error}</div>{/if}
    <div class="ws-modal-foot">
        <span class="home-spacer"></span>
        {#if saved}<span class="settings-saved">saved ✓</span>{/if}
        <button class="home-btn primary" onclick={() => void save()}>Save</button>
    </div>
</div>
