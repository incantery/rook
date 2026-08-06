//! Tree-sitter highlighting.
//!
//! The runtime is vendored C (vendor/tree-sitter); the GRAMMARS are
//! not — they are dylibs found and opened at runtime by grammar.zig,
//! which is the whole point of the strip that removed them. The
//! queries stay embedded (src/queries/*.scm): a query is rook's
//! opinion about which captures are keywords and which are types, and
//! that opinion should not vary with whose parser directory the
//! grammar came out of. A `<lang>.scm` sitting beside the dylib wins
//! when there is one, which is how somebody disagrees with us.
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
const bufferpkg = @import("buffer.zig");
const grammarpkg = @import("grammar.zig");

/// The loader owns this type: a TSLanguage is whatever the dylib
/// handed back, and only one module should be deciding it is valid.
const TSLanguage = grammarpkg.TSLanguage;

// ---- C ABI ----

const TSParser = opaque {};
const TSTree = opaque {};
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
extern fn ts_tree_edit(*TSTree, *const TSInputEdit) void;

const TSPoint = extern struct { row: u32, column: u32 };
const TSInputEdit = extern struct {
    start_byte: u32,
    old_end_byte: u32,
    new_end_byte: u32,
    start_point: TSPoint,
    old_end_point: TSPoint,
    new_end_point: TSPoint,
};
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

const zig_query = @embedFile("queries/zig.scm");
const go_query = @embedFile("queries/go.scm");
const python_query = @embedFile("queries/python.scm");
const ts_query = @embedFile("queries/typescript.scm");
/// The shared patterns plus the JSX-only ones, joined at comptime — a
/// query naming a node its grammar lacks fails to COMPILE, and
/// jsx_element exists only in the tsx grammar.
const tsx_query = ts_query ++ @embedFile("queries/tsx.scm");

/// What a path needs: the grammar to ask the loader for, and the
/// query to read it with.
const Lang = struct {
    /// Tree-sitter's own name for the grammar, which is also the dylib's
    /// basename and the symbol suffix. `tsx` and `typescript` are two
    /// grammars, not one with a flag.
    name: []const u8,
    query_src: []const u8,
};

pub fn langForPath(path: []const u8) ?Lang {
    if (std.mem.endsWith(u8, path, ".zig")) return .{ .name = "zig", .query_src = zig_query };
    if (std.mem.endsWith(u8, path, ".go")) return .{ .name = "go", .query_src = go_query };
    if (std.mem.endsWith(u8, path, ".py") or std.mem.endsWith(u8, path, ".pyi"))
        return .{ .name = "python", .query_src = python_query };
    // .ts gets the typescript grammar for ONE reason: `<T>x` is a type
    // assertion there and a JSX element in tsx, and no single table can
    // be both.
    if (std.mem.endsWith(u8, path, ".ts") or std.mem.endsWith(u8, path, ".mts") or
        std.mem.endsWith(u8, path, ".cts"))
        return .{ .name = "typescript", .query_src = ts_query };
    // Everything else in the family gets TSX — including plain
    // JavaScript. That is not a compromise: tsx parses all of JS plus
    // JSX, and the only thing the ts grammar has over it is the
    // angle-bracket type assertion, which JavaScript does not have. A
    // .js file with JSX in it (every pre-2020 React project) would
    // fail to parse under the ts grammar and reads fine under this one.
    if (std.mem.endsWith(u8, path, ".tsx") or std.mem.endsWith(u8, path, ".js") or
        std.mem.endsWith(u8, path, ".jsx") or std.mem.endsWith(u8, path, ".mjs") or
        std.mem.endsWith(u8, path, ".cjs"))
        return .{ .name = "tsx", .query_src = tsx_query };
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

    /// The shared loader. Not owned — one registry serves every pane,
    /// because a dylib opened per editor would be the same image mapped
    /// as many times as you have splits.
    grammars: *grammarpkg.Registry,
    /// Why this buffer is not highlighted, for `ctl syntax`. "" when it
    /// is, or when the file is not a language rook knows.
    fault: []const u8 = "",

    pub fn create(gpa: Allocator, grammars: *grammarpkg.Registry) !*Highlighter {
        const self = try gpa.create(Highlighter);
        self.* = .{
            .gpa = gpa,
            .parser = ts_parser_new(),
            .cursor = ts_query_cursor_new(),
            .grammars = grammars,
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
    ///
    /// Every way this can fail is RECORDED rather than printed. A file
    /// that is not highlighted looks exactly like a file with nothing
    /// worth highlighting, so the difference has to be askable.
    pub fn setPath(self: *Highlighter, path: ?[]const u8) void {
        if (self.tree) |t| ts_tree_delete(t);
        self.tree = null;
        if (self.query) |q| ts_query_delete(q);
        self.query = null;
        self.fault = "";

        const p = path orelse return;
        const l = langForPath(p) orelse return; // not a language we know
        const lang = self.grammars.get(l.name) orelse {
            self.fault = "no grammar";
            return;
        };
        if (!ts_parser_set_language(self.parser, lang)) {
            // The ABI was checked before this, so a refusal here is the
            // runtime disagreeing for some other reason entirely.
            self.fault = "the runtime refused this grammar";
            return;
        }
        var err_off: u32 = 0;
        var err_type: u32 = 0;
        self.query = ts_query_new(lang, l.query_src.ptr, @intCast(l.query_src.len), &err_off, &err_type);
        if (self.query == null) {
            // The likeliest failure in the whole file, and the one the
            // strip made possible: a query names a node type, and a
            // grammar from somebody else's parser directory is a
            // different VERSION of that grammar, which may have
            // renamed it. Highlighting degrades to plain text and says
            // so rather than taking the editor with it.
            self.fault = "query does not fit this grammar";
        }
    }

    /// Is this buffer actually being highlighted? A query without a
    /// tree is a language that was recognised and never parsed.
    pub fn highlighting(self: *const Highlighter) bool {
        return self.query != null and self.tree != null;
    }

    /// Reparse, reusing the old tree where the document has not moved.
    ///
    /// This is the whole difference between typing feeling free and
    /// typing costing a frame and a half. A full parse of a
    /// twelve-thousand-line Zig file measured 42ms — on EVERY keystroke,
    /// because the fill reparses whenever the buffer's version moves.
    /// Told which bytes changed, tree-sitter reuses every subtree the
    /// edit did not touch and the same parse is sub-millisecond.
    ///
    /// `edits` must be every change since the last successful parse, in
    /// order, or the tree silently describes a document that does not
    /// exist. `full` is the caller saying it cannot promise that.
    pub fn reparse(self: *Highlighter, text: []const u8, edits: []const bufferpkg.Buffer.TreeEdit, full: bool) void {
        if (self.query == null) return;
        var old: ?*const TSTree = null;
        if (!full) {
            if (self.tree) |t| {
                for (edits) |e| {
                    const ie: TSInputEdit = .{
                        .start_byte = e.start,
                        .old_end_byte = e.old_end,
                        .new_end_byte = e.new_end,
                        .start_point = .{ .row = e.start_row, .column = e.start_col },
                        .old_end_point = .{ .row = e.old_end_row, .column = e.old_end_col },
                        .new_end_point = .{ .row = e.new_end_row, .column = e.new_end_col },
                    };
                    ts_tree_edit(t, &ie);
                }
                old = t;
            }
        }
        const new_tree = ts_parser_parse_string(self.parser, old, text.ptr, @intCast(text.len));
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

pub fn attach(ed: *editorpkg.Editor, gpa: Allocator, grammars: *grammarpkg.Registry) void {
    const hl = Highlighter.create(gpa, grammars) catch return;
    ed.hl_ctx = hl;
    ed.hl_reparse = &hookReparse;
    ed.hl_spans = &hookSpans;
    ed.hl_set_path = &hookSetPath;
    ed.hl_destroy = &hookDestroy;
    hl.setPath(ed.buf.path);
}

fn hookReparse(ctx: *anyopaque, text: []const u8, edits: []const bufferpkg.Buffer.TreeEdit, full: bool) void {
    const hl: *Highlighter = @ptrCast(@alignCast(ctx));
    hl.reparse(text, edits, full);
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
