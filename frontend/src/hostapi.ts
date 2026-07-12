// Client for the rook-host daemon. All session traffic flows directly
// between the webview and the host — the app process is only involved in
// discovering the endpoint (see internal/hostclient).

export interface SessionInfo {
    id: string;
    name: string;
    workspace: string;
    cols: number;
    rows: number;
    created: string;
}

export class HostAPI {
    constructor(
        readonly endpoint: string,
        private token: string,
    ) {}

    private async req(path: string, init?: RequestInit): Promise<Response> {
        const r = await fetch(`${this.endpoint}${path}`, {
            ...init,
            headers: {Authorization: `Bearer ${this.token}`, ...(init?.headers ?? {})},
        });
        if (!r.ok) throw new Error(`host ${path}: ${r.status} ${await r.text()}`);
        return r;
    }

    async list(): Promise<SessionInfo[]> {
        return (await this.req("/sessions")).json();
    }

    /** cwdFrom: inherit the working directory of that session's shell
     *  (tmux `new-window -c "#{pane_current_path}"`). */
    async create(cols: number, rows: number, cwdFrom?: string, workspace?: string): Promise<SessionInfo> {
        return (
            await this.req("/sessions", {
                method: "POST",
                body: JSON.stringify({cols, rows, cwdFrom, workspace}),
            })
        ).json();
    }

    async kill(id: string): Promise<void> {
        await this.req(`/sessions/${id}`, {method: "DELETE"});
    }

    /** The shell's live working directory (host resolves via lsof). */
    async sessionCwd(id: string): Promise<string> {
        const r = await this.req(`/sessions/${id}/cwd`);
        return ((await r.json()) as {cwd: string}).cwd;
    }

    async resize(id: string, cols: number, rows: number): Promise<void> {
        await this.req(`/sessions/${id}/resize`, {
            method: "POST",
            body: JSON.stringify({cols, rows}),
        });
    }

    attach(id: string): WebSocket {
        const ws = this.endpoint.replace(/^http/, "ws");
        return new WebSocket(`${ws}/sessions/${id}/attach?token=${this.token}`);
    }

    async listWorkspaces(): Promise<WorkspaceInfo[]> {
        return (await this.req("/workspaces")).json();
    }

    async createWorkspace(name: string, root = "", scratch = false): Promise<void> {
        await this.req("/workspaces", {
            method: "POST",
            body: JSON.stringify({name, root, scratch}),
        });
    }

    /** New git worktree off `from`'s repo (branch rook/<name>), registered
     *  as a workspace — the isolation rung under parallel agent sessions. */
    async createWorktree(from: string): Promise<WorkspaceInfo> {
        return (
            await this.req("/workspaces", {
                method: "POST",
                body: JSON.stringify({worktreeFrom: from}),
            })
        ).json();
    }

    /** Worktree workspaces 409 when deletion would lose work (dirty tree,
     *  unmerged commits) — force discards the tree; the branch survives. */
    async deleteWorkspace(name: string, force = false): Promise<void> {
        await this.req(`/workspaces/${encodeURIComponent(name)}${force ? "?force=1" : ""}`, {method: "DELETE"});
    }

    /** Live workspace status: per-session foreground process + cwd, repo
     *  state. The dashboard's data — and the future agent's context. */
    async workspaceStatus(name: string): Promise<WorkspaceStatus> {
        return (await this.req(`/workspaces/${encodeURIComponent(name)}/status`)).json();
    }

    /** Everyone waiting on the user, cross-workspace — the inbox's feed. */
    async attention(): Promise<AttentionItem[]> {
        return (await this.req("/attention")).json();
    }

    /** The workspace's work queue: GitHub + Jira, mine + unassigned, with
     *  ready-to-spawn task prompts. Host caches ~60s; read, never mirror. */
    async issues(ws: string): Promise<IssuesResult> {
        return (await this.req(`/workspaces/${encodeURIComponent(ws)}/issues`)).json();
    }

    /** Subscription usage windows, cached by the host's cost-weighted prober. */
    async usage(): Promise<UsageSnapshot> {
        return (await this.req("/usage")).json();
    }

    /** Raw-inference cost picture: daily ledger + live burn per workspace. */
    async costs(): Promise<CostsSnapshot> {
        return (await this.req("/costs")).json();
    }

    /** Raw bytes into a session's pty; append "\r" to submit. */
    async sendInput(id: string, data: string): Promise<void> {
        await this.req(`/sessions/${id}/input`, {
            method: "POST",
            body: JSON.stringify({data}),
        });
    }

    /** Send a draft into its window; text (≠ draft) records verdict `edited`. */
    async approveDraft(id: number, text?: string): Promise<void> {
        await this.req(`/drafts/${id}/approve`, {
            method: "POST",
            body: JSON.stringify(text ? {text} : {}),
        });
    }

    async rejectDraft(id: number): Promise<void> {
        await this.req(`/drafts/${id}/reject`, {method: "POST", body: "{}"});
    }
}

/** One "Current …: N% used" line from claude's /usage, host-scraped. */
export interface UsageWindow {
    label: string;
    pct: number;
    resets: string;
}

export interface UsageSnapshot {
    windows: UsageWindow[];
    capturedAt: string;
}

/** Compact usage-window label: session → 5h, week (all models) → wk,
 *  week (Fable) → fable. Unknown labels pass through lowercased. */
export function shortWindow(label: string): string {
    if (label === "session") return "5h";
    if (label.startsWith("week (all")) return "wk";
    return label.replace(/^week \((.+)\)$/i, "$1").toLowerCase();
}

/** GET /costs — what claude usage would cost on API billing. */
export interface CostsSnapshot {
    todayUsd: number;
    weekUsd: number;
    drafterTodayUsd: number;
    /** Live burn by workspace; "" = claude sessions outside rook windows. */
    live: {workspace: string; usd: number}[];
}

/** An open judgment from the drafter on one ask (docs/agent.md). */
export interface DraftInfo {
    id: number;
    askSeq: number;
    /** spawn: approval starts a NEW session on the task instead of typing
     *  into the source window. */
    action: "draft" | "escalate" | "spawn";
    reply?: string;
    /** nano's own why, verbatim — shown on escalations and draft tooltips */
    reason?: string;
    confidence?: number;
}

/** One "a claude session is waiting on you" row from GET /attention. */
export interface AttentionItem {
    workspace: string;
    rookSession: string;
    window: number;
    agentSession: string;
    askSeq: number;
    state: string;
    title?: string;
    ask?: string;
    /** A TUI picker in the window — jump and answer there; nothing can be typed for you. */
    interactive?: boolean;
    since: string;
    draft?: DraftInfo | null;
}

/** One row of the workspace's issue queue (GET /workspaces/{ws}/issues). */
export interface IssueInfo {
    tracker: "github" | "jira";
    key: string;
    title: string;
    state?: string;
    mine: boolean;
    url?: string;
    /** host-built claude prompt — every surface spawns the identical thing */
    task: string;
}

export interface IssuesResult {
    issues: IssueInfo[];
    /** per-tracker failures; a dead Jira must not blank the GitHub rows */
    errors?: string[];
}

export interface WorkspaceInfo {
    name: string;
    root?: string;
    scratch?: boolean;
    /** source workspace this one was carved from (git worktree) */
    worktreeOf?: string;
    /** the worktree's rook/<name> branch */
    branch?: string;
    created: string;
    lastUsed: string;
    sessions: number;
}

export interface GitInfo {
    branch: string;
    dirty: number;
    ahead: number;
    behind: number;
}

/** Transcript-derived state of a claude session (via agentmon). */
export interface AgentStatus {
    sessionId: string;
    cwd: string;
    state: "working" | "needs_input" | "quiet";
    title?: string;
    ask?: string;
    tool?: string;
    model?: string;
    costUsd?: number;
    askSeq: number;
    since: string;
    lastEvent: string;
}

export interface SessionStatus extends SessionInfo {
    fg: string;
    cwd: string;
    agent?: AgentStatus;
}

export interface WorkspaceStatus {
    name: string;
    root?: string;
    scratch?: boolean;
    git?: GitInfo;
    sessions: SessionStatus[];
    attention: number;
}
