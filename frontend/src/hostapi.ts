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

    async deleteWorkspace(name: string): Promise<void> {
        await this.req(`/workspaces/${encodeURIComponent(name)}`, {method: "DELETE"});
    }
}

export interface WorkspaceInfo {
    name: string;
    root?: string;
    scratch?: boolean;
    created: string;
    lastUsed: string;
    sessions: number;
}
