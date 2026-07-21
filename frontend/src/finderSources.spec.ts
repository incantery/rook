import {describe, expect, it, vi} from "vitest";
import {filesSource, grepSource, type FileItem} from "./finderSources";
import type {HostAPI} from "./hostapi";

/** the two calls the sources make, and nothing else */
function fakeApi(over: Partial<HostAPI>): HostAPI {
    return over as HostAPI;
}

describe("filesSource", () => {
    const src = (files: string[], base?: string, buffers: string[] = []) =>
        filesSource({
            api: fakeApi({
                listFiles: vi.fn().mockResolvedValue({files, base, truncated: false}),
            }),
            workspace: "ws",
            buffers: () => buffers,
            open: () => {},
        });

    it("joins the scope base into the openable path, keeps the display path relative", async () => {
        const res = await src(["a.go", "b.go"], "internal/host").load("");
        expect(res.items).toEqual([
            {path: "a.go", full: "internal/host/a.go", buffer: false},
            {path: "b.go", full: "internal/host/b.go", buffer: false},
        ]);
        expect(res.base).toBe("internal/host");
    });

    it("ranks open buffers ahead of repo files", async () => {
        const s = src(["cmd/rook/main.go", "internal/host/main.go"], undefined, [
            "cmd/rook/main.go",
        ]);
        const items = (await s.load("")).items;
        const out = s.rank!("main", items);
        expect(out[0].item.buffer).toBe(true);
        expect(out[0].item.full).toBe("cmd/rook/main.go");
        // and the buffer must not also appear in the tail
        expect(out.filter((r) => r.item.full === "cmd/rook/main.go")).toHaveLength(1);
    });

    it("dedups a buffer against a SCOPED listing, which is base-relative", async () => {
        // the listing says "a.go"; the buffer says "internal/host/a.go".
        // Comparing display forms would miss it — dedup is on the joined form.
        const s = src(["a.go"], "internal/host", ["internal/host/a.go"]);
        const out = s.rank!("a", (await s.load("")).items);
        expect(out).toHaveLength(1);
        expect(out[0].item.buffer).toBe(true);
    });

    it("groups rows so the list can draw the buffer/repo seam", async () => {
        const s = src(["x.go"]);
        const [item] = (await s.load("")).items;
        expect(s.row(item, []).group).toBe("All files");
        expect(s.row({...item, buffer: true} as FileItem, []).group).toBe("Open buffers");
    });

    it("previews the openable path, not the display path", async () => {
        const s = src(["a.go"], "internal/host");
        const [item] = (await s.load("")).items;
        expect(s.preview(item)).toEqual({path: "internal/host/a.go"});
    });
});

describe("grepSource", () => {
    const hit = {path: "a.go", line: 12, col: 3, text: "  func Foo() {"};
    const src = (over: Record<string, unknown> = {}) =>
        grepSource({
            api: fakeApi({
                grep: vi.fn().mockResolvedValue({hits: [hit], base: "internal", ...over}),
            }),
            workspace: "ws",
            open: () => {},
            quickfix: () => {},
        });

    it("joins base ONCE, at load, so open/preview/quickfix all get usable paths", async () => {
        const s = src();
        const res = await s.load("Foo");
        expect(res.items[0].path).toBe("internal/a.go");
        expect(s.preview(res.items[0])).toEqual({path: "internal/a.go", line: 12, col: 3});
        expect(s.key(res.items[0])).toBe("internal/a.go:12:3");
    });

    it("carries the host's note through instead of rows", async () => {
        const res = await src({note: "bad pattern"}).load("(");
        expect(res.note).toBe("bad pattern");
    });

    it("sends EVERY hit to the quickfix, not just the cursor", () => {
        const quickfix = vi.fn();
        const s = grepSource({
            api: fakeApi({grep: vi.fn()}),
            workspace: "ws",
            open: () => {},
            quickfix,
        });
        const all = [hit, {...hit, line: 20}];
        s.actions.find((a) => a.key === "ctrl+q")!.run(all[0], all, "Foo");
        expect(quickfix).toHaveBeenCalledWith(all, "Foo");
    });

    it("is a no-op on an empty list rather than clobbering the quickfix", () => {
        const quickfix = vi.fn();
        const s = grepSource({
            api: fakeApi({grep: vi.fn()}),
            workspace: "ws",
            open: () => {},
            quickfix,
        });
        s.actions.find((a) => a.key === "ctrl+q")!.run(undefined, [], "Foo");
        expect(quickfix).not.toHaveBeenCalled();
    });
});
