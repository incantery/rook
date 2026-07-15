// The file explorer's view-model: turn the host's FLAT list of
// forward-slash, repo-relative paths (GET /workspaces/{n}/files) into a
// nested tree the pane can render, and decorate it with what review needs —
// git status, thread counts, and the changed-only scope. Pure and DOM-free,
// so it's unit-tested (filetree.spec.ts) the same way term/threadview.ts is —
// the Svelte component (FileExplorer.svelte) only renders + tracks expansion.

import type {ChangedFile, ThreadInfo} from "./hostapi";

export interface FileNode {
    /** the last path segment — what the row shows */
    name: string;
    /** full forward-slash path from the repo top; opens the editor */
    path: string;
    dir: boolean;
    /** empty for files; dirs-first, then case-insensitive by name */
    children: FileNode[];
}

/** Build the tree. Directories are inferred from the files' path segments —
 *  the host only ever lists files, never bare dirs, so every non-leaf
 *  segment is a directory. Stable order: dirs before files, then by name. */
export function buildFileTree(paths: string[]): FileNode[] {
    const root: FileNode = {name: "", path: "", dir: true, children: []};
    for (const p of paths) {
        const parts = p.split("/").filter(Boolean);
        let cur = root;
        let acc = "";
        for (let i = 0; i < parts.length; i++) {
            const name = parts[i];
            acc = acc ? `${acc}/${name}` : name;
            const isDir = i < parts.length - 1;
            let child = cur.children.find((c) => c.name === name && c.dir === isDir);
            if (!child) {
                child = {name, path: acc, dir: isDir, children: []};
                cur.children.push(child);
            }
            cur = child;
        }
    }
    sortNodes(root.children);
    return root.children;
}

function sortNodes(nodes: FileNode[]): void {
    nodes.sort((a, b) =>
        a.dir !== b.dir
            ? a.dir
                ? -1
                : 1
            : a.name.localeCompare(b.name, undefined, {sensitivity: "base"}),
    );
    for (const n of nodes) {
        if (n.dir) sortNodes(n.children);
    }
}

/** Which files the tree shows: everything, or only what the diff touched. */
export type ExplorerScope = "changed" | "all";

export type GitStatus = ChangedFile["status"];
/** Palette roles the status letter is allowed to take (literal Tailwind
 *  class names live in the component — `text-${tone}` emits nothing). */
export type StatusTone = "grn" | "amber" | "red" | "acc" | "lo";

/** path → status, so a row is an O(1) lookup rather than a scan per node. */
export function statusMap(files: ChangedFile[]): Map<string, GitStatus> {
    return new Map(files.map((f) => [f.path, f.status]));
}

/** path → number of threads still wanting attention (pending + open).
 *
 *  Resolved threads are deliberately NOT counted. The badge is a triage
 *  signal — "this file still owes you something" — and counting resolved
 *  would leave a permanent badge on every file ever reviewed. It also keeps
 *  the badge honest against the panel, whose default filter is Open. */
export function threadCounts(threads: ThreadInfo[]): Map<string, number> {
    const counts = new Map<string, number>();
    for (const t of threads) {
        if (t.state === "resolved") continue;
        counts.set(t.path, (counts.get(t.path) ?? 0) + 1);
    }
    return counts;
}

/** The single letter + tone a changed row carries, VS Code / git style. */
export function statusMeta(status: GitStatus): {letter: string; tone: StatusTone} {
    switch (status) {
        case "added":
            return {letter: "A", tone: "grn"};
        case "untracked":
            return {letter: "U", tone: "grn"}; // new to the tree, same as added
        case "modified":
            return {letter: "M", tone: "amber"};
        case "renamed":
            return {letter: "R", tone: "acc"};
        case "deleted":
            return {letter: "D", tone: "red"};
    }
}

/** Header rollup. Added and untracked both read as "+" (new content either
 *  way); renamed counts as a modification, since the diff has a body. */
export function changeCounts(files: ChangedFile[]): {
    added: number;
    modified: number;
    deleted: number;
} {
    let added = 0;
    let modified = 0;
    let deleted = 0;
    for (const f of files) {
        if (f.status === "added" || f.status === "untracked") added++;
        else if (f.status === "modified" || f.status === "renamed") modified++;
        else deleted++;
    }
    return {added, modified, deleted};
}

/** The "Changed" scope: keep changed files and only the directories on the
 *  way to one. Returns new nodes — the input tree is never mutated, so
 *  flipping scope back to "all" needs no refetch. */
export function pruneToChanged(nodes: FileNode[], statuses: Map<string, GitStatus>): FileNode[] {
    const out: FileNode[] = [];
    for (const n of nodes) {
        if (!n.dir) {
            if (statuses.has(n.path)) out.push(n);
            continue;
        }
        const children = pruneToChanged(n.children, statuses);
        if (children.length > 0) out.push({...n, children});
    }
    return out;
}

/** One rendered row: the node plus the indent its nesting earns it. */
export interface VisibleRow {
    node: FileNode;
    depth: number;
}

/** The tree flattened to exactly the rows on screen, in render order —
 *  children of a collapsed directory are gone, not hidden.
 *
 *  This is what makes the explorer keyboard-navigable: j/k are "next/prev
 *  row", which is a flat-list idea, not a tree one. Deriving the flat list
 *  from the tree (rather than the reverse) keeps ONE source of truth, so the
 *  cursor can never point at a row the tree isn't rendering. */
export function flattenVisible(nodes: FileNode[], expanded: ReadonlySet<string>): VisibleRow[] {
    const out: VisibleRow[] = [];
    const walk = (ns: FileNode[], depth: number): void => {
        for (const node of ns) {
            out.push({node, depth});
            if (node.dir && expanded.has(node.path)) walk(node.children, depth + 1);
        }
    };
    walk(nodes, 0);
    return out;
}

/** The containing directory's path, or "" at the top. `h` climbs with this. */
export function parentPath(path: string): string {
    const i = path.lastIndexOf("/");
    return i === -1 ? "" : path.slice(0, i);
}

/** Every directory path in a tree, for auto-expanding a pruned scope —
 *  a changed-only tree with everything collapsed shows nothing useful. */
export function dirPaths(nodes: FileNode[]): string[] {
    const out: string[] = [];
    const walk = (ns: FileNode[]): void => {
        for (const n of ns) {
            if (!n.dir) continue;
            out.push(n.path);
            walk(n.children);
        }
    };
    walk(nodes);
    return out;
}

const CODE = new Set([
    "go",
    "ts",
    "tsx",
    "mts",
    "cts",
    "js",
    "jsx",
    "mjs",
    "cjs",
    "svelte",
    "rs",
    "py",
    "rb",
    "sh",
    "c",
    "h",
    "cc",
    "cpp",
    "java",
    "kt",
    "swift",
    "css",
    "html",
    "sql",
]);
const CONFIG = new Set(["json", "toml", "yaml", "yml", "ini", "conf", "env", "lock"]);
const DOCS = new Set(["md", "txt", "rst", "adoc"]);
/** Files with no extension that are still config/build, not prose. */
const BUILD = new Set(["Makefile", "Dockerfile", "Justfile", "Taskfile"]);

/** A coarse glyph per file kind. Deliberately geometric unicode, not a Nerd
 *  Font icon: the explorer is chrome (system-ui), and only the terminal and
 *  editor are guaranteed the mono font with the icon range. */
export function fileIcon(name: string): string {
    if (BUILD.has(name)) return "▦";
    const dot = name.lastIndexOf(".");
    const ext = dot > 0 ? name.slice(dot + 1).toLowerCase() : "";
    if (CODE.has(ext)) return "◆";
    if (CONFIG.has(ext)) return "⚙";
    if (DOCS.has(ext)) return "▤";
    return "○";
}
