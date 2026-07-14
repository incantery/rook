import {describe, expect, it} from "vitest";
import {buildFileTree, type FileNode} from "./filetree";

// compact shape for assertions: "name/" for dirs, "name" for files
function shape(nodes: FileNode[]): unknown {
    return nodes.map((n) => (n.dir ? {[`${n.name}/`]: shape(n.children)} : n.name));
}

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
