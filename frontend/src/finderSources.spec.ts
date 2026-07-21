import {describe, expect, it, vi} from "vitest";
import {filesSource, grepSource, threadsSource, type FileItem} from "./finderSources";
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

describe("threadsSource", () => {
    const th = (over: Record<string, unknown> = {}) =>
        ({
            id: 1,
            path: "a.go",
            state: "open",
            comments: [{id: 1, author: "user", body: "is the cap right?", created: ""}],
            currentStart: 12,
            currentEnd: 14,
            ...over,
        }) as never;

    const src = (threads: unknown[], deps: Record<string, unknown> = {}) =>
        threadsSource({
            threads: () => threads as never,
            open: () => {},
            source: () => {},
            quickfix: () => {},
            ...deps,
        } as never);

    it("groups rows by file so a review reads as a walk through files", async () => {
        const s = src([th(), th({id: 2, path: "b.go"})]);
        const items = (await s.load("")).items;
        expect(items.map((t) => s.row(t, []).group)).toEqual(["a.go", "b.go"]);
    });

    it("with no query, sorts by what needs you — failures first", async () => {
        const s = src([
            th({id: 1, path: "z.go"}),
            th({id: 2, path: "a.go", deliverError: "spawn failed"}),
            th({id: 3, path: "m.go", state: "resolved"}),
        ]);
        const out = s.rank!("", (await s.load("")).items);
        expect(out.map((r) => r.item.id)).toEqual([2, 1, 3]);
    });

    it("matches on what was SAID, not just the path", async () => {
        const s = src([
            th({
                id: 1,
                path: "a.go",
                comments: [{id: 1, author: "user", body: "cap", created: ""}],
            }),
            th({
                id: 2,
                path: "b.go",
                comments: [{id: 1, author: "user", body: "auth", created: ""}],
            }),
        ]);
        const out = s.rank!("auth", (await s.load("")).items);
        expect(out[0].item.id).toBe(2);
    });

    it("matches on status, so 'waiting' narrows to the agent's queue", async () => {
        const s = src([
            th({
                id: 1,
                comments: [
                    {id: 1, author: "user", body: "q", created: ""},
                    {id: 2, author: "agent", body: "a", created: ""},
                ],
            }),
            th({id: 2, path: "b.go"}),
        ]);
        const out = s.rank!("waiting", (await s.load("")).items);
        expect(out[0].item.id).toBe(2);
    });

    it("translates highlight positions onto the comment the row renders", async () => {
        // positions index the PROJECTED string (path + status + bodies) but
        // the row shows only the first comment — an untranslated position
        // would accent whatever character happened to sit at that offset
        const s = src([
            th({path: "a.go", comments: [{id: 1, author: "user", body: "zebra", created: ""}]}),
        ]);
        const out = s.rank!("zebra", (await s.load("")).items);
        const row = s.row(out[0].item, out[0].positions);
        const hit = row.segments
            .filter((g) => g.hit)
            .map((g) => g.text)
            .join("");
        expect(hit).toBe("zebra");
    });

    it("drops positions that landed on the path or status, not the comment", async () => {
        const s = src([
            th({
                path: "zzz.go",
                comments: [{id: 1, author: "user", body: "nothing alike", created: ""}],
            }),
        ]);
        const out = s.rank!("zzz", (await s.load("")).items);
        const row = s.row(out[0].item, out[0].positions);
        // the match was entirely in the path, which this row does not render
        expect(row.segments.some((g) => g.hit)).toBe(false);
    });

    it("does not repeat the path in the row — the group header already said it", async () => {
        const s = src([th({path: "a.go"})]);
        const row = s.row((await s.load("")).items[0], []);
        expect(row.segments.map((g) => g.text).join("")).not.toContain("a.go");
        expect(row.group).toBe("a.go");
        expect(row.locator).toBe("12");
    });

    it("previews the anchored line, which is the code the thread argues about", async () => {
        const s = src([th()]);
        const [t] = (await s.load("")).items;
        expect(s.preview(t)).toEqual({path: "a.go", line: 12});
    });
});
