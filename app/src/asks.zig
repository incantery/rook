//! The asks loop — Claude asks a question, a human answers, the asker
//! unblocks. §2's flagship loop, and the one the app exists for.
//!
//! rook polls `GET /asks` (the session-less queue) rather than receiving
//! a msgAsk over a wire-v3 session socket: the app owns its ptys
//! in-process, registers no sessions, and never attaches one. Answers go
//! back through the unchanged `POST /asks/{id}/answer`, so everything
//! downstream — the blocked rookctl, the MCP drain, the relay's remote
//! copy — is untouched by how the question arrived.
//!
//! The questions payload is deliberately opaque to the host, so this
//! file owns the shape. Fixed buffers throughout: the render path reads
//! this under draw_lock and must never touch an allocator.

const std = @import("std");
const hostc = @import("hostc.zig");

pub const max_options = 8;
pub const max_questions = 4;

/// The wire, exactly as `rookctl ask` documents it. Every field past
/// `question` is optional — including `options` itself, which absent
/// means a free-text question rather than an error.
const WireOption = struct {
    label: []const u8 = "",
    description: []const u8 = "",
    recommended: bool = false,
};
const WireQuestion = struct {
    question: []const u8 = "",
    header: []const u8 = "",
    multiSelect: bool = false,
    options: []const WireOption = &.{},
};
const WireAsk = struct {
    id: []const u8 = "",
    questions: []const WireQuestion = &.{},
};

fn Text(comptime n: usize) type {
    return struct {
        buf: [n]u8 = @splat(0),
        len: u8 = 0,
        const Self = @This();
        pub fn set(self: *Self, s: []const u8) void {
            const k = @min(n, s.len);
            @memcpy(self.buf[0..k], s[0..k]);
            self.len = @intCast(k);
        }
        pub fn get(self: *const Self) []const u8 {
            return self.buf[0..self.len];
        }
    };
}

pub const Option = struct {
    label: Text(56) = .{},
    desc: Text(120) = .{},
    /// The asker's suggestion: pre-ticked in multi, under the cursor in
    /// single, so Enter alone is a complete answer.
    recommended: bool = false,
};

pub const Question = struct {
    text: Text(200) = .{},
    header: Text(20) = .{},
    multi: bool = false,
    options: [max_options]Option = @splat(.{}),
    n: usize = 0,
    /// No options at all — the text box IS the question.
    free_text: bool = false,
};

pub const Ask = struct {
    id: Text(24) = .{},
    questions: [max_questions]Question = @splat(.{}),
    n: usize = 0,
};

/// Build an Ask from a questions array — the payload's inner shape,
/// shared by the poller and ctl's `ask` verb so the form is exercised
/// through the same parse either way.
pub fn fromQuestions(id: []const u8, qs: []const WireQuestion) ?Ask {
    var a: Ask = .{};
    a.id.set(id);
    for (qs) |wq| {
        if (a.n >= max_questions) break;
        var q: Question = .{};
        q.text.set(wq.question);
        q.header.set(wq.header);
        q.multi = wq.multiSelect;
        for (wq.options) |wo| {
            if (q.n >= max_options) break;
            var o: Option = .{};
            o.label.set(wo.label);
            o.desc.set(wo.description);
            o.recommended = wo.recommended;
            q.options[q.n] = o;
            q.n += 1;
        }
        q.free_text = q.n == 0;
        a.questions[a.n] = q;
        a.n += 1;
    }
    if (a.n == 0) return null;
    return a;
}

/// Parse a `{"questions":[…]}` (or a bare `[…]`) payload. ctl's `ask`
/// verb uses this to put a question on screen without a host, the same
/// way `paste <text>` drives the paste path without a pasteboard.
pub fn parsePayload(gpa: std.mem.Allocator, id: []const u8, body: []const u8) ?Ask {
    const Outer = struct { questions: []const WireQuestion = &.{} };
    if (std.json.parseFromSlice(Outer, gpa, body, .{ .ignore_unknown_fields = true })) |p| {
        defer p.deinit();
        if (p.value.questions.len > 0) return fromQuestions(id, p.value.questions);
    } else |_| {}
    const p = std.json.parseFromSlice([]const WireQuestion, gpa, body, .{ .ignore_unknown_fields = true }) catch return null;
    defer p.deinit();
    return fromQuestions(id, p.value);
}

/// Parse the queue. Returns the OLDEST pending ask, or null — one
/// question on screen at a time, because a form that stacks is a form
/// nobody finishes.
pub fn poll(gpa: std.mem.Allocator, io: std.Io) ?Ask {
    const info = hostc.readInfo(gpa, io) orelse return null;
    var resp = hostc.get(gpa, &info, "/asks", 512 * 1024) orelse return null;
    defer resp.deinit(gpa);
    if (resp.status != 200) return null;

    const parsed = std.json.parseFromSlice([]WireAsk, gpa, resp.body, .{ .ignore_unknown_fields = true }) catch return null;
    defer parsed.deinit();
    if (parsed.value.len == 0) return null;

    const w = parsed.value[0];
    return fromQuestions(w.id, w.questions);
}

/// POST an answer (or a dismissal). Blocking; background thread only.
pub fn answer(gpa: std.mem.Allocator, io: std.Io, id: []const u8, body: []const u8) bool {
    const info = hostc.readInfo(gpa, io) orelse return false;
    var path_buf: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/asks/{s}/answer", .{id}) catch return false;
    var resp = hostc.post(gpa, &info, path, body, 8 * 1024) orelse return false;
    defer resp.deinit(gpa);
    // 204 is the documented success; anything 2xx is fine by us.
    return resp.status >= 200 and resp.status < 300;
}

/// JSON-escape into a writer. Only the characters JSON requires — an
/// ask's labels are human text and a stray quote or backslash in one
/// would otherwise produce a body the host rejects, losing the answer
/// and leaving the asker blocked forever.
pub fn writeJsonString(w: *std.Io.Writer, s: []const u8) void {
    w.writeByte('"') catch return;
    for (s) |c| {
        switch (c) {
            '"' => _ = w.write("\\\"") catch return,
            '\\' => _ = w.write("\\\\") catch return,
            '\n' => _ = w.write("\\n") catch return,
            '\r' => _ = w.write("\\r") catch return,
            '\t' => _ = w.write("\\t") catch return,
            else => if (c < 0x20) {
                w.print("\\u{x:0>4}", .{c}) catch return;
            } else w.writeByte(c) catch return,
        }
    }
    w.writeByte('"') catch return;
}

// ----------------------------------------------------------------- tests

test "writeJsonString escapes what JSON requires" {
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    writeJsonString(&w, "a\"b\\c\nd\te");
    try std.testing.expectEqualStrings("\"a\\\"b\\\\c\\nd\\te\"", buf[0..w.end]);
}

test "writeJsonString escapes control characters" {
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    writeJsonString(&w, "a\x01b");
    try std.testing.expectEqualStrings("\"a\\u0001b\"", buf[0..w.end]);
}

test "Text truncates rather than overflowing" {
    var t: Text(4) = .{};
    t.set("abcdefgh");
    try std.testing.expectEqualStrings("abcd", t.get());
}
