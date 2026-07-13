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
            headers: {Authorization: `Bearer ${this.token}`, ...init?.headers},
        });
        if (!r.ok) throw new Error(`host ${path}: ${r.status} ${await r.text()}`);
        return r;
    }

    async list(): Promise<SessionInfo[]> {
        return (await this.req("/sessions")).json();
    }

    /** cwdFrom: inherit the working directory of that session's shell
     *  (tmux `new-window -c "#{pane_current_path}"`). */
    async create(
        cols: number,
        rows: number,
        cwdFrom?: string,
        workspace?: string,
    ): Promise<SessionInfo> {
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

    /** Mission control's poll: every workspace in one call, live ones
     *  carrying their dashboard rollup (agents, attention, git, fg). 404s
     *  on old daemons — callers fall back to listWorkspaces (fail open). */
    async overview(): Promise<OverviewItem[]> {
        return (await this.req("/overview")).json();
    }

    async createWorkspace(name: string, root = "", scratch = false): Promise<void> {
        await this.req("/workspaces", {
            method: "POST",
            body: JSON.stringify({name, root, scratch}),
        });
    }

    /** New task tree: a git worktree off `from`'s repo (branch
     *  rook/<name> unless the workspace configures a branch-prefix),
     *  registered as a workspace — the isolation rung under parallel
     *  agent sessions. `issue` stamps which tracker issue spawned it
     *  (work-on-issue flow); its title is what the host derives the
     *  workspace name from. */
    async createWorktree(
        from: string,
        issue?: IssueRef & {title?: string},
    ): Promise<WorkspaceInfo> {
        return (
            await this.req("/workspaces", {
                method: "POST",
                body: JSON.stringify({worktreeFrom: from, issue}),
            })
        ).json();
    }

    /** Worktree workspaces 409 when deletion would lose work (dirty tree,
     *  unmerged commits) — force discards the tree; the branch survives
     *  unless prune deletes it too (the merged-PR cleanup path). */
    async deleteWorkspace(name: string, force = false, prune = false): Promise<void> {
        const q = [force ? "force=1" : "", prune ? "prune=1" : ""].filter(Boolean).join("&");
        await this.req(`/workspaces/${encodeURIComponent(name)}${q ? `?${q}` : ""}`, {
            method: "DELETE",
        });
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

    /** Start the coder on a task in a fresh window of the workspace.
     *  Either a literal task or a preset the host expands into its own
     *  prompt (e.g. "resolve-conflicts") — host-built prompts keep every
     *  surface actuating the identical thing. */
    async spawnTask(ws: string, opts: {task?: string; preset?: string}): Promise<SessionInfo> {
        return (
            await this.req(`/workspaces/${encodeURIComponent(ws)}/spawn`, {
                method: "POST",
                body: JSON.stringify(opts),
            })
        ).json();
    }

    /** The review pane's file list. Omit base on the first fetch — the
     *  host picks the default (branch for worktrees, head elsewhere) and
     *  the response's base reports what was actually diffed. */
    async changes(ws: string, base?: string): Promise<ChangesResult> {
        const q = base ? `?base=${encodeURIComponent(base)}` : "";
        return (await this.req(`/workspaces/${encodeURIComponent(ws)}/changes${q}`)).json();
    }

    /** Both full texts of one file's diff — Monaco wants sides, not patches. */
    async fileDiff(ws: string, path: string, base?: string): Promise<DiffResult> {
        const q = new URLSearchParams({path});
        if (base) q.set("base", base);
        return (await this.req(`/workspaces/${encodeURIComponent(ws)}/diff?${q}`)).json();
    }

    /** One file, read-only (the ` e viewer). */
    async readFile(ws: string, path: string): Promise<FileResult> {
        const q = new URLSearchParams({path});
        return (await this.req(`/workspaces/${encodeURIComponent(ws)}/file?${q}`)).json();
    }

    /** The file picker's listing: git's view in repos, a bounded walk
     *  elsewhere. */
    async listFiles(ws: string): Promise<FilesResult> {
        return (await this.req(`/workspaces/${encodeURIComponent(ws)}/files`)).json();
    }

    /** All of a workspace's threads — comments inline, ranges re-anchored
     *  on read (currentStart/currentEnd, outdated). The pane fetches
     *  everything and slices locally; filters exist for cheaper pulls. */
    async threads(ws: string, opts?: {state?: string; path?: string}): Promise<ThreadInfo[]> {
        const q = new URLSearchParams();
        if (opts?.state) q.set("state", opts.state);
        if (opts?.path) q.set("path", opts.path);
        const qs = q.size > 0 ? `?${q}` : "";
        return (await this.req(`/workspaces/${encodeURIComponent(ws)}/threads${qs}`)).json();
    }

    /** Comment on a file range → a pending thread. The host snapshots the
     *  anchored content NOW; base only matters for side=original (which
     *  ref the original text came from). */
    async createThread(
        ws: string,
        req: {
            path: string;
            startLine: number;
            endLine: number;
            side?: "modified" | "original";
            base?: "head" | "branch";
            body: string;
        },
    ): Promise<ThreadInfo> {
        return (
            await this.req(`/workspaces/${encodeURIComponent(ws)}/threads`, {
                method: "POST",
                body: JSON.stringify(req),
            })
        ).json();
    }

    /** The webview IS the user — author is declared, and here always "user". */
    async threadComment(id: number, body: string): Promise<void> {
        await this.req(`/threads/${id}/comments`, {
            method: "POST",
            body: JSON.stringify({body, author: "user"}),
        });
    }

    async threadResolve(id: number): Promise<void> {
        await this.req(`/threads/${id}/resolve`, {
            method: "POST",
            body: JSON.stringify({by: "user"}),
        });
    }

    async threadReopen(id: number): Promise<void> {
        await this.req(`/threads/${id}/reopen`, {
            method: "POST",
            body: JSON.stringify({by: "user"}),
        });
    }

    /** Flip pending→open and nudge the responder — or re-nudge when open
     *  threads still await the agent. 400 = nothing to submit. */
    async submitThreads(ws: string): Promise<ThreadsSubmitResult> {
        return (
            await this.req(`/workspaces/${encodeURIComponent(ws)}/threads/submit`, {
                method: "POST",
                body: "{}",
            })
        ).json();
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

/** One row of GET /workspaces/{ws}/changes — what a review covers. */
export interface ChangedFile {
    path: string;
    status: "modified" | "added" | "deleted" | "renamed" | "untracked";
    /** the pre-rename path, renames only */
    oldPath?: string;
}

/** GET /workspaces/{ws}/changes. base reports what was actually diffed:
 *  branch mode falls open to head (fallback says why) when no merge
 *  base resolves. */
export interface ChangesResult {
    base: "head" | "branch";
    baseRef: string;
    baseName: string;
    fallback?: string;
    files: ChangedFile[];
    truncated?: boolean;
}

/** GET /workspaces/{ws}/diff — both sides, full text. Empty original =
 *  added/untracked; empty modified = deleted; binary withholds both. */
export interface DiffResult {
    path: string;
    base: "head" | "branch";
    baseRef: string;
    baseName: string;
    original: string;
    modified: string;
    binary?: boolean;
    truncated?: boolean;
    fallback?: string;
}

/** GET /workspaces/{ws}/file — the read-only viewer's payload. */
export interface FileResult {
    path: string;
    content: string;
    binary?: boolean;
    truncated?: boolean;
}

/** GET /workspaces/{ws}/files — repo-top-relative paths for the picker. */
export interface FilesResult {
    files: string[];
    truncated?: boolean;
}

/** One utterance in a thread. Author is declared, not authenticated —
 *  every client shares the one localhost token (spec, by design). */
export interface ThreadComment {
    id: number;
    author: "user" | "agent";
    agentSession?: string;
    body: string;
    created: string;
}

/** A file-anchored AI conversation (GET /workspaces/{ws}/threads). The
 *  current* fields are computed on read — the stored anchor mapped onto
 *  today's file; outdated means the anchored lines themselves changed
 *  (render anchorText instead of pointing at live lines). */
export interface ThreadInfo {
    id: number;
    workspace: string;
    path: string;
    startLine: number;
    endLine: number;
    side: "modified" | "original";
    blobSha: string;
    commitSha?: string;
    anchorText: string;
    state: "pending" | "open" | "resolved";
    resolvedBy?: "user" | "agent";
    agentReopens?: number;
    created: string;
    updated: string;
    submitted?: string;
    comments: ThreadComment[];
    currentStart: number;
    currentEnd: number;
    outdated?: boolean;
}

/** POST /workspaces/{ws}/threads/submit — how the nudge landed. */
export interface ThreadsSubmitResult {
    mode: "typed" | "spawned";
    rookSession: string;
    count: number;
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

/** The tracker issue a workspace was spawned for (▶ work / rookctl work). */
export interface IssueRef {
    tracker: "github" | "jira";
    key: string;
}

/** Host-polled PR state for a worktree's branch — the close-the-loop
 *  signal. Absent on the workspace = unknown (gh missing, offline);
 *  state "none" = checked, no PR exists. */
export interface PRInfo {
    state: "none" | "open" | "merged" | "closed";
    number?: number;
    url?: string;
    /** the open PR can't merge as-is (gh reports CONFLICTING) — absent on
     *  hosts/gh versions that don't know, never falsely true (fail open) */
    conflicts?: boolean;
    /** commits only this branch has — work with no PR yet */
    ahead?: number;
    dirty?: number;
    checkedAt: string;
}

export interface WorkspaceInfo {
    name: string;
    root?: string;
    scratch?: boolean;
    /** set = this is a task tree: the source workspace it was carved
     *  from (a git worktree of that workspace's repo) */
    worktreeOf?: string;
    /** the task tree's branch (rook/<name> unless a prefix is configured) */
    branch?: string;
    /** the issue this workspace was spawned for — absent otherwise */
    issueRef?: IssueRef;
    /** PR state of the worktree's branch — absent when unknown */
    pr?: PRInfo;
    created: string;
    lastUsed: string;
    sessions: number;
}

/** One agent's card-sized state inside an overview item. */
export interface OverviewAgent {
    state: "working" | "needs_input" | "quiet";
    title?: string;
    ask?: string;
    tool?: string;
}

/** One row of a work item's checklist: the synthetic coding stage, then
 *  the persisted review stages. needsInput is live agent state decorated
 *  at read time — the stage's window is waiting on the user. */
export interface StageInfo {
    name: string;
    status: "pending" | "running" | "done" | "error";
    needsInput?: boolean;
    detail?: string;
}

/** One workspace row of GET /overview. The rollup fields only exist on
 *  workspaces with live sessions — idle ones are bare list items. */
export interface OverviewItem extends WorkspaceInfo {
    git?: GitInfo;
    /** distinct foreground commands across the workspace's windows */
    fg?: string[];
    /** correlated agent states, needs_input first */
    agents?: OverviewAgent[];
    attention?: number;
    /** staged-workflow checklist (worktrees with a workflow configured);
     *  present even on idle workspaces so errored pipelines stay visible */
    stages?: StageInfo[];
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
