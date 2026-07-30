//! Tree-sitter highlighting — editor slice two. The runtime and the
//! zig/go grammars are vendored C (vendor/); highlight queries are
//! embedded (src/queries/*.scm, from each grammar's repo).
//!
//! The editor never imports this file — it exposes hook function
//! pointers instead (hl_reparse / hl_spans / hl_set_path /
//! hl_destroy), so `zig test src/editor.zig` stays free of C
//! linkage. macos.zig attaches a Highlighter per editor pane.
//!
//! v1 shape: full reparse per buffer version change (files ≤ 4MB;
//! tree-sitter parses this class of file in single-digit ms), query
//! capture extraction restricted to the VISIBLE byte range per frame.
//! Incremental ts_tree_edit is the upgrade path if reparse ever shows
//! up in frame_fill.

const std = @import("std");
const Allocator = std.mem.Allocator;
const editorpkg = @import("editor.zig");

// ---- C ABI ----

const TSParser = opaque {};
const TSTree = opaque {};
const TSLanguage = opaque {};
const TSQuery = opaque {};
const TSQueryCursor = opaque {};

const TSNode = extern struct {
    context: [4]u32,
    id: ?*const anyopaque,
    tree: ?*const anyopaque,
};

const TSQueryCapture = extern struct {
    node: TSNode,
    index: u32,
};

const TSQueryMatch = extern struct {
    id: u32,
    pattern_index: u16,
    capture_count: u16,
    captures: [*]const TSQueryCapture,
};

extern fn ts_parser_new() *TSParser;
extern fn ts_parser_delete(*TSParser) void;
extern fn ts_parser_set_language(*TSParser, *const TSLanguage) bool;
extern fn ts_parser_parse_string(*TSParser, ?*const TSTree, [*]const u8, u32) ?*TSTree;
extern fn ts_tree_delete(*TSTree) void;
extern fn ts_tree_root_node(*const TSTree) TSNode;
extern fn ts_query_new(*const TSLanguage, [*]const u8, u32, *u32, *u32) ?*TSQuery;
extern fn ts_query_delete(*TSQuery) void;
extern fn ts_query_capture_name_for_id(*const TSQuery, u32, *u32) [*]const u8;
extern fn ts_query_cursor_new() *TSQueryCursor;
extern fn ts_query_cursor_delete(*TSQueryCursor) void;
extern fn ts_query_cursor_exec(*TSQueryCursor, *const TSQuery, TSNode) void;
extern fn ts_query_cursor_set_byte_range(*TSQueryCursor, u32, u32) void;
extern fn ts_query_cursor_next_capture(*TSQueryCursor, *TSQueryMatch, *u32) bool;
extern fn ts_node_start_byte(TSNode) u32;
extern fn ts_node_end_byte(TSNode) u32;

extern fn tree_sitter_zig() *const TSLanguage;
extern fn tree_sitter_go() *const TSLanguage;
extern fn tree_sitter_python() *const TSLanguage;
extern fn tree_sitter_typescript() *const TSLanguage;
extern fn tree_sitter_tsx() *const TSLanguage;

const zig_query = @embedFile("queries/zig.scm");
const go_query = @embedFile("queries/go.scm");
const python_query = @embedFile("queries/python.scm");
const ts_query = @embedFile("queries/typescript.scm");
/// The shared patterns plus the JSX-only ones, joined at comptime — a
/// query naming a node its grammar lacks fails to COMPILE, and
/// jsx_element exists only in the tsx grammar.
const tsx_query = ts_query ++ @embedFile("queries/tsx.scm");

const Lang = struct {
    lang: *const TSLanguage,
    query_src: []const u8,
};

fn langForPath(path: []const u8) ?Lang {
    if (std.mem.endsWith(u8, path, ".zig")) return .{ .lang = tree_sitter_zig(), .query_src = zig_query };
    if (std.mem.endsWith(u8, path, ".go")) return .{ .lang = tree_sitter_go(), .query_src = go_query };
    if (std.mem.endsWith(u8, path, ".py") or std.mem.endsWith(u8, path, ".pyi"))
        return .{ .lang = tree_sitter_python(), .query_src = python_query };
    // .ts gets the typescript grammar for ONE reason: `<T>x` is a type
    // assertion there and a JSX element in tsx, and no single table can
    // be both.
    if (std.mem.endsWith(u8, path, ".ts") or std.mem.endsWith(u8, path, ".mts") or
        std.mem.endsWith(u8, path, ".cts"))
        return .{ .lang = tree_sitter_typescript(), .query_src = ts_query };
    // Everything else in the family gets TSX — including plain
    // JavaScript. That is not a compromise: tsx parses all of JS plus
    // JSX, and the only thing the ts grammar has over it is the
    // angle-bracket type assertion, which JavaScript does not have. A
    // .js file with JSX in it (every pre-2020 React project) would
    // fail to parse under the ts grammar and reads fine under this one.
    if (std.mem.endsWith(u8, path, ".tsx") or std.mem.endsWith(u8, path, ".js") or
        std.mem.endsWith(u8, path, ".jsx") or std.mem.endsWith(u8, path, ".mjs") or
        std.mem.endsWith(u8, path, ".cjs"))
        return .{ .lang = tree_sitter_tsx(), .query_src = tsx_query };
    return null;
}

/// Capture name → editor style bucket. Prefix match, most specific
/// first; null = leave as plain text.
fn styleForCapture(name: []const u8) ?editorpkg.Style {
    const map = [_]struct { p: []const u8, st: editorpkg.Style }{
        .{ .p = "comment", .st = .syn_comment },
        .{ .p = "string", .st = .syn_string },
        .{ .p = "character", .st = .syn_string },
        .{ .p = "number", .st = .syn_number },
        .{ .p = "float", .st = .syn_number },
        .{ .p = "boolean", .st = .syn_number },
        .{ .p = "constant", .st = .syn_number },
        .{ .p = "keyword", .st = .syn_keyword },
        .{ .p = "repeat", .st = .syn_keyword },
        .{ .p = "conditional", .st = .syn_keyword },
        .{ .p = "include", .st = .syn_keyword },
        .{ .p = "attribute", .st = .syn_keyword },
        .{ .p = "label", .st = .syn_keyword },
        .{ .p = "type", .st = .syn_type },
        .{ .p = "function", .st = .syn_func },
        .{ .p = "method", .st = .syn_func },
    };
    for (map) |m| {
        if (std.mem.startsWith(u8, name, m.p)) return m.st;
    }
    return null;
}

pub const Highlighter = struct {
    gpa: Allocator,
    parser: *TSParser,
    tree: ?*TSTree = null,
    query: ?*TSQuery = null,
    cursor: *TSQueryCursor,

    pub fn create(gpa: Allocator) !*Highlighter {
        const self = try gpa.create(Highlighter);
        self.* = .{
            .gpa = gpa,
            .parser = ts_parser_new(),
            .cursor = ts_query_cursor_new(),
        };
        return self;
    }

    pub fn destroy(self: *Highlighter) void {
        if (self.tree) |t| ts_tree_delete(t);
        if (self.query) |q| ts_query_delete(q);
        ts_query_cursor_delete(self.cursor);
        ts_parser_delete(self.parser);
        self.gpa.destroy(self);
    }

    /// Pick (or clear) the language from the file path.
    pub fn setPath(self: *Highlighter, path: ?[]const u8) void {
        if (self.tree) |t| ts_tree_delete(t);
        self.tree = null;
        if (self.query) |q| ts_query_delete(q);
        self.query = null;

        const l = langForPath(path orelse return) orelse return;
        if (!ts_parser_set_language(self.parser, l.lang)) return;
        var err_off: u32 = 0;
        var err_type: u32 = 0;
        self.query = ts_query_new(l.lang, l.query_src.ptr, @intCast(l.query_src.len), &err_off, &err_type);
        if (self.query == null) {
            std.debug.print("rook syntax: query failed at byte {d} (type {d})\n", .{ err_off, err_type });
        }
    }

    pub fn reparse(self: *Highlighter, text: []const u8) void {
        if (self.query == null) return;
        // Full reparse: without ts_tree_edit bookkeeping the old tree
        // must NOT be passed as a hint.
        const new_tree = ts_parser_parse_string(self.parser, null, text.ptr, @intCast(text.len));
        if (self.tree) |t| ts_tree_delete(t);
        self.tree = new_tree;
    }

    /// Append highlight spans intersecting [start, end) byte range.
    /// Later captures override earlier ones (the caller applies in
    /// order) — nvim's convention.
    pub fn spans(self: *Highlighter, start: u32, end: u32, out: *std.ArrayListUnmanaged(editorpkg.HlSpan), gpa: Allocator) void {
        const tree = self.tree orelse return;
        const query = self.query orelse return;
        ts_query_cursor_exec(self.cursor, query, ts_tree_root_node(tree));
        ts_query_cursor_set_byte_range(self.cursor, start, end);
        var match: TSQueryMatch = undefined;
        var cap_i: u32 = 0;
        while (ts_query_cursor_next_capture(self.cursor, &match, &cap_i)) {
            const cap = match.captures[cap_i];
            var name_len: u32 = 0;
            const name_ptr = ts_query_capture_name_for_id(query, cap.index, &name_len);
            const st = styleForCapture(name_ptr[0..name_len]) orelse continue;
            out.append(gpa, .{
                .start = ts_node_start_byte(cap.node),
                .end = ts_node_end_byte(cap.node),
                .st = st,
            }) catch return;
        }
    }
};

// The editor-facing hooks (function-pointer seam; see editor.zig).

pub fn attach(ed: *editorpkg.Editor, gpa: Allocator) void {
    const hl = Highlighter.create(gpa) catch return;
    ed.hl_ctx = hl;
    ed.hl_reparse = &hookReparse;
    ed.hl_spans = &hookSpans;
    ed.hl_set_path = &hookSetPath;
    ed.hl_destroy = &hookDestroy;
    hl.setPath(ed.buf.path);
}

fn hookReparse(ctx: *anyopaque, text: []const u8) void {
    const hl: *Highlighter = @ptrCast(@alignCast(ctx));
    hl.reparse(text);
}

fn hookSpans(ctx: *anyopaque, start: u32, end: u32, out: *std.ArrayListUnmanaged(editorpkg.HlSpan), gpa: Allocator) void {
    const hl: *Highlighter = @ptrCast(@alignCast(ctx));
    hl.spans(start, end, out, gpa);
}

fn hookSetPath(ctx: *anyopaque, path: ?[]const u8) void {
    const hl: *Highlighter = @ptrCast(@alignCast(ctx));
    hl.setPath(path);
}

fn hookDestroy(ctx: *anyopaque) void {
    const hl: *Highlighter = @ptrCast(@alignCast(ctx));
    hl.destroy();
}
