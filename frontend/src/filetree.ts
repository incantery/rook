// The file explorer's view-model: turn the host's FLAT list of
// forward-slash, repo-relative paths (GET /workspaces/{n}/files) into a
// nested tree the pane can render. Pure and DOM-free, so it's unit-tested
// (filetree.spec.ts) the same way term/threadview.ts is — the Svelte
// component (FileExplorer.svelte) only renders + tracks expansion.

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
