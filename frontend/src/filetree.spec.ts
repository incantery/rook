import {describe, expect, it} from "vitest";
import {
    buildFileTree,
    changeCounts,
    dirPaths,
    fileIcon,
    flattenVisible,
    parentPath,
    pruneToChanged,
    statusMap,
    statusMeta,
    threadCounts,
    type FileNode,
} from "./filetree";
import type {ChangedFile, ThreadInfo} from "./hostapi";

// compact shape for assertions: "name/" for dirs, "name" for files
function shape(nodes: FileNode[]): unknown {
    return nodes.map((n) => (n.dir ? {[`${n.name}/`]: shape(n.children)} : n.name));
}

const chg = (path: string, status: ChangedFile["status"]): ChangedFile => ({path, status});
/** only the fields these helpers read — the rest of ThreadInfo is noise here */
const th = (path: string, state: ThreadInfo["state"]): ThreadInfo =>
    ({path, state}) as unknown as ThreadInfo;

describe("buildFileTree", () => {
    it("nests paths and infers directories", () => {
        const tree = buildFileTree(["src/a.ts", "src/sub/b.ts", "README.md"]);
        // dirs before files at each level
        expect(shape(tree)).toEqual([{"src/": [{"sub/": ["b.ts"]}, "a.ts"]}, "README.md"]);
    });

    it("gives every node its full repo-relative path", () => {
        const [src] = buildFileTree(["src/sub/b.ts"]);
        expect(src.path).toBe("src");
        expect(src.children[0].path).toBe("src/sub");
        expect(src.children[0].children[0].path).toBe("src/sub/b.ts");
    });

    it("merges a directory shared by many files instead of duplicating it", () => {
        const [src] = buildFileTree(["src/a.ts", "src/b.ts", "src/c.ts"]);
        expect(src.children.map((c) => c.name)).toEqual(["a.ts", "b.ts", "c.ts"]);
    });

    it("sorts dirs first, then case-insensitively by name", () => {
        const tree = buildFileTree(["Zebra.ts", "apple.ts", "lib/x.ts"]);
        expect(tree.map((n) => n.name)).toEqual(["lib", "apple.ts", "Zebra.ts"]);
    });

    it("is empty for no paths", () => {
        expect(buildFileTree([])).toEqual([]);
    });
});

describe("threadCounts", () => {
    // The badge is a triage signal, so resolved threads must not keep a file
    // marked forever. This is the whole contract.
    it("counts pending + open per file and ignores resolved", () => {
        const counts = threadCounts([
            th("a.ts", "open"),
            th("a.ts", "pending"),
            th("a.ts", "resolved"),
            th("b.ts", "resolved"),
        ]);
        expect(counts.get("a.ts")).toBe(2);
        expect(counts.has("b.ts")).toBe(false);
    });

    it("is empty for no threads", () => {
        expect(threadCounts([]).size).toBe(0);
    });
});

describe("statusMeta", () => {
    it("gives each git status a letter and a tone", () => {
        expect(statusMeta("added")).toEqual({letter: "A", tone: "grn"});
        expect(statusMeta("modified")).toEqual({letter: "M", tone: "amber"});
        expect(statusMeta("deleted")).toEqual({letter: "D", tone: "red"});
        expect(statusMeta("renamed")).toEqual({letter: "R", tone: "acc"});
        expect(statusMeta("untracked")).toEqual({letter: "U", tone: "grn"});
    });
});

describe("changeCounts", () => {
    it("rolls added/untracked into +, modified/renamed into ~, deleted into −", () => {
        expect(
            changeCounts([
                chg("a", "added"),
                chg("b", "untracked"),
                chg("c", "modified"),
                chg("d", "renamed"),
                chg("e", "deleted"),
            ]),
        ).toEqual({added: 2, modified: 2, deleted: 1});
    });

    it("is all zero for a clean tree", () => {
        expect(changeCounts([])).toEqual({added: 0, modified: 0, deleted: 0});
    });
});

describe("pruneToChanged", () => {
    const tree = buildFileTree(["src/a.ts", "src/sub/b.ts", "src/sub/c.ts", "docs/d.md", "e.md"]);

    it("keeps changed files and the dirs on the way to one", () => {
        const out = pruneToChanged(tree, statusMap([chg("src/sub/b.ts", "modified")]));
        expect(shape(out)).toEqual([{"src/": [{"sub/": ["b.ts"]}]}]);
    });

    it("drops a directory whose every file is unchanged", () => {
        const out = pruneToChanged(tree, statusMap([chg("e.md", "added")]));
        expect(shape(out)).toEqual(["e.md"]);
    });

    it("is empty for a clean tree", () => {
        expect(pruneToChanged(tree, statusMap([]))).toEqual([]);
    });

    // The component flips scope back to "all" without refetching, so the
    // pruned pass must not have eaten the tree it was given.
    it("does not mutate the input tree", () => {
        const before = shape(tree);
        pruneToChanged(tree, statusMap([chg("src/a.ts", "modified")]));
        expect(shape(tree)).toEqual(before);
    });
});

describe("flattenVisible", () => {
    const tree = buildFileTree(["src/sub/b.ts", "src/a.ts", "e.md"]);

    it("renders only top-level rows when nothing is expanded", () => {
        expect(flattenVisible(tree, new Set()).map((r) => r.node.name)).toEqual(["src", "e.md"]);
    });

    it("splices an expanded dir's children in, at depth+1, in render order", () => {
        const rows = flattenVisible(tree, new Set(["src"]));
        expect(rows.map((r) => `${r.depth}:${r.node.name}`)).toEqual([
            "0:src",
            "1:sub",
            "1:a.ts",
            "0:e.md",
        ]);
    });

    it("keeps a collapsed dir's children out even when a descendant is expanded", () => {
        // "src/sub" is expanded but "src" is not — b.ts must not appear
        const rows = flattenVisible(tree, new Set(["src/sub"]));
        expect(rows.map((r) => r.node.name)).toEqual(["src", "e.md"]);
    });

    it("nests to arbitrary depth", () => {
        const rows = flattenVisible(tree, new Set(["src", "src/sub"]));
        expect(rows.map((r) => `${r.depth}:${r.node.name}`)).toEqual([
            "0:src",
            "1:sub",
            "2:b.ts",
            "1:a.ts",
            "0:e.md",
        ]);
    });

    it("is empty for an empty tree", () => {
        expect(flattenVisible([], new Set())).toEqual([]);
    });
});

describe("parentPath", () => {
    it("drops the last segment", () => {
        expect(parentPath("src/sub/b.ts")).toBe("src/sub");
        expect(parentPath("src/a.ts")).toBe("src");
    });

    it("returns empty at the top level — h has nowhere to climb", () => {
        expect(parentPath("e.md")).toBe("");
        expect(parentPath("")).toBe("");
    });
});

describe("dirPaths", () => {
    it("lists every directory, nested ones included", () => {
        const tree = buildFileTree(["src/sub/b.ts", "docs/d.md", "e.md"]);
        expect(dirPaths(tree).sort()).toEqual(["docs", "src", "src/sub"]);
    });

    it("skips files", () => {
        expect(dirPaths(buildFileTree(["a.ts", "b.ts"]))).toEqual([]);
    });
});

describe("fileIcon", () => {
    it("groups by kind rather than by extension", () => {
        expect(fileIcon("main.go")).toBe(fileIcon("App.svelte")); // both code
        expect(fileIcon("config.toml")).toBe(fileIcon("package.json")); // both config
        expect(fileIcon("README.md")).toBe("▤");
    });

    it("knows extensionless build files from prose", () => {
        expect(fileIcon("Makefile")).toBe("▦");
        expect(fileIcon("LICENSE")).toBe("○");
    });

    it("ignores extension case and leading dots", () => {
        expect(fileIcon("Main.GO")).toBe("◆");
        expect(fileIcon(".gitignore")).toBe("○"); // a dotfile has no extension
    });
});
