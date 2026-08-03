//! The workspace registry — read from the environment graph.
//!
//! A workspace is DECLARED: a `workspace` node in environment.json (name
//! and root, usually emitted by the config program — rook-config(5)),
//! not a row registered somewhere. This used to be sqlite (rook.db,
//! owned by rook-host); the host left in the strip and nothing wrote the
//! table since, so the app was linking libsqlite3 to read a registry
//! frozen in July. A registry nobody can write is not a registry.
//!
//! What the db held that the graph deliberately does not:
//! `last_used` recency — ephemeral UI state, to return in-memory (or as
//! a dumb flat file) when a feature needs it; and `worktree_of` children
//! — git already knows a repo's worktrees, so those come back DERIVED
//! from `.git/worktrees/` rather than stored, when worktree management
//! lands. Neither justifies a database the config graph now replaces.
//!
//! Re-parsed on every load: the graph is one small cached file, `env
//! apply` rewrites it, and a palette open should see what config last
//! applied without a restart. Same pattern as plugins.zig — one file,
//! N consumers, none owning another's parse.

const std = @import("std");
const cfgpkg = @import("config.zig");

pub const Entry = struct {
    name: []u8,
    root: []u8,
    /// Parent workspace name for worktree children, empty for top-level.
    /// Nothing sets it today — worktree derivation from git is how it
    /// returns — but the palette's grouping pass renders it, so the
    /// field stays real rather than being re-invented later.
    parent: []u8,
};

pub fn free(gpa: std.mem.Allocator, list: []Entry) void {
    for (list) |e| {
        gpa.free(e.name);
        gpa.free(e.root);
        gpa.free(e.parent);
    }
    gpa.free(list);
}

/// Load the declared workspaces, in graph order — the author's order,
/// which beats a recency shuffle for muscle memory. A missing graph, an
/// unparseable graph, no workspace nodes: all the same answer, an EMPTY
/// list, never a failure — rook must run fine unconfigured.
///
/// A leading `~/` in root expands against $HOME, so a hand-written graph
/// can say what a config program would compute. A later node with the
/// same name replaces the earlier one, matching the SDKs' put rule.
pub fn load(io: std.Io, gpa: std.mem.Allocator) []Entry {
    const data = cfgpkg.envData(io, gpa) orelse return &.{};
    defer gpa.free(data);
    return parse(gpa, data);
}

/// The graph-bytes half of load(), split out so it can be tested without
/// the process-global config directory.
fn parse(gpa: std.mem.Allocator, data: []const u8) []Entry {
    var out: std.ArrayListUnmanaged(Entry) = .empty;
    defer out.deinit(gpa);

    const Wire = struct {
        nodes: []struct {
            kind: []const u8 = "",
            name: []const u8 = "",
            root: []const u8 = "",
        } = &.{},
    };
    const parsed = std.json.parseFromSlice(Wire, gpa, data, .{ .ignore_unknown_fields = true }) catch return &.{};
    defer parsed.deinit();

    for (parsed.value.nodes) |n| {
        if (!std.mem.eql(u8, n.kind, "workspace")) continue;
        if (n.name.len == 0 or n.root.len == 0) continue;
        const root = expandTilde(gpa, n.root) orelse continue;
        const e: Entry = .{
            .name = gpa.dupe(u8, n.name) catch {
                gpa.free(root);
                continue;
            },
            .root = root,
            .parent = gpa.dupe(u8, "") catch {
                gpa.free(root);
                continue;
            },
        };
        // Same name twice: the later declaration wins, in the earlier
        // position — the graph's own replace-by-id rule, kept here for
        // hand-written files the SDKs never saw.
        var replaced = false;
        for (out.items) |*old| {
            if (std.mem.eql(u8, old.name, e.name)) {
                gpa.free(old.name);
                gpa.free(old.root);
                gpa.free(old.parent);
                old.* = e;
                replaced = true;
                break;
            }
        }
        if (!replaced) out.append(gpa, e) catch {
            gpa.free(e.name);
            gpa.free(e.root);
            gpa.free(e.parent);
        };
    }
    return out.toOwnedSlice(gpa) catch &.{};
}

/// `~/x` → `$HOME/x` (and bare `~` → `$HOME`). Anything else is copied
/// as-is. Caller owns the result.
fn expandTilde(gpa: std.mem.Allocator, root: []const u8) ?[]u8 {
    if (root.len > 0 and root[0] == '~' and (root.len == 1 or root[1] == '/')) {
        if (std.c.getenv("HOME")) |home| {
            const h = std.mem.span(home);
            return std.mem.concat(gpa, u8, &.{ h, root[1..] }) catch null;
        }
    }
    return gpa.dupe(u8, root) catch null;
}

// ------------------------------------------------------------------ tests

const testing = std.testing;

test "parse: workspace nodes only, in order, later name wins" {
    const gpa = testing.allocator;

    const list = parse(gpa,
        \\{"rookEnvironment":1,"nodes":[
        \\{"id":"opt","kind":"option","scope":"app","key":"theme","value":"nocturne"},
        \\{"id":"workspace:rook","kind":"workspace","scope":"app","name":"rook","root":"~/src/rook"},
        \\{"id":"workspace:dora","kind":"workspace","scope":"app","name":"dora","root":"/w/dora"},
        \\{"id":"workspace:rook2","kind":"workspace","scope":"app","name":"rook","root":"/moved/rook"},
        \\{"id":"bad","kind":"workspace","scope":"app","name":"","root":"/x"}
        \\]}
    );
    defer free(gpa, list);

    try testing.expectEqual(@as(usize, 2), list.len);
    try testing.expectEqualStrings("rook", list[0].name);
    try testing.expectEqualStrings("/moved/rook", list[0].root); // later wins, earlier position
    try testing.expectEqualStrings("dora", list[1].name);
    try testing.expectEqualStrings("/w/dora", list[1].root);
}

test "parse: garbage and absence are an empty list, not a failure" {
    const gpa = testing.allocator;
    const a = parse(gpa, "not json at all");
    defer free(gpa, a);
    try testing.expectEqual(@as(usize, 0), a.len);
    const b = parse(gpa, "{\"rookEnvironment\":1,\"nodes\":[]}");
    defer free(gpa, b);
    try testing.expectEqual(@as(usize, 0), b.len);
}

test "expandTilde" {
    const gpa = testing.allocator;
    const home = std.mem.span(std.c.getenv("HOME").?);

    const a = expandTilde(gpa, "~/src/rook").?;
    defer gpa.free(a);
    try testing.expect(std.mem.startsWith(u8, a, home));
    try testing.expect(std.mem.endsWith(u8, a, "/src/rook"));

    // `~user` is NOT expansion — only `~/` and bare `~` are.
    const b = expandTilde(gpa, "~other/x").?;
    defer gpa.free(b);
    try testing.expectEqualStrings("~other/x", b);

    const c = expandTilde(gpa, "/abs/path").?;
    defer gpa.free(c);
    try testing.expectEqualStrings("/abs/path", c);
}
