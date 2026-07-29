//! A small backtracking regex engine, in vim's "magic" syntax.
//!
//! It exists because `/` and `:s` over literal strings are a floor, not
//! a feature: `^func`, `\<name\>` and `s/foo(\(.*\))/bar(\1)/` are what
//! people actually reach for, and a half-regex that treats `.` as a dot
//! is worse than either extreme.
//!
//! Syntax (vim magic, the default): `.` `*` `^` `$` `[abc]` `[^a-z]`
//! are special unescaped; `\(` `\)` `\|` `\+` `\?` `\=` `\{n,m}` `\<`
//! `\>` and the class shorthands `\d \D \w \W \s \S \a \l \u` are
//! special escaped. Everything else after a `\` is that literal
//! character.
//!
//! Compiled to instructions and run by BACKTRACKING, not by a Thompson
//! simulation, because captures are the point — `\1` in a replacement
//! is most of why a regex beats a substring search. The catastrophic
//! cases that costs are held off two ways: a repeat of a SINGLE-WIDTH
//! atom is one instruction with an internal greedy loop (so `.*` over a
//! long line costs no stack at all), and every match runs on a step
//! budget that fails closed.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Error = error{ BadPattern, OutOfMemory };

/// The most a single match attempt may execute before it gives up. A
/// pattern that needs more than this is one nobody typed on purpose.
const step_budget: u32 = 200_000;
/// Recursion is bounded too: single-width repeats are iterative, so
/// this only counts group repetitions and alternation.
const depth_budget: u16 = 2000;

const Bits = [32]u8;

fn bitSet(b: *Bits, c: u8) void {
    b[c >> 3] |= @as(u8, 1) << @intCast(c & 7);
}
fn bitHas(b: *const Bits, c: u8) bool {
    return b[c >> 3] & (@as(u8, 1) << @intCast(c & 7)) != 0;
}

/// A single-width atom — the ones a repeat can run as a loop.
const Simple = union(enum) {
    char: u8,
    any,
    class: u16,
};

const Inst = union(enum) {
    char: u8,
    any,
    class: u16,
    /// `x*`, `x\+`, `x\{2,5}` where x is single-width.
    rep: struct { what: Simple, min: u32, max: u32 },
    split: struct { x: u32, y: u32 },
    jmp: u32,
    save: u8,
    bol,
    eol,
    word_start,
    word_end,
    match,
};

pub const Span = struct { a: usize, b: usize };

pub const Match = struct {
    start: usize,
    end: usize,
    /// Group n's span, or null if it did not participate. Index 0 is
    /// the whole match, so `\0` and `&` are the same thing.
    groups: [10]?Span,
};

pub const Regex = struct {
    prog: []Inst,
    classes: []Bits,
    icase: bool,
    /// `^` at the start of every branch — nothing before column zero
    /// can match, which lets a search skip straight to the answer.
    anchored: bool,

    pub fn deinit(self: *Regex, gpa: Allocator) void {
        gpa.free(self.prog);
        gpa.free(self.classes);
        self.* = undefined;
    }

    pub fn compile(gpa: Allocator, pattern: []const u8, icase: bool) Error!Regex {
        var p: Parser = .{
            .gpa = gpa,
            .src = pattern,
            .prog = .empty,
            .classes = .empty,
        };
        errdefer {
            p.prog.deinit(gpa);
            p.classes.deinit(gpa);
        }
        try p.prog.append(gpa, .{ .save = 0 });
        try p.alts(0);
        if (p.i != pattern.len) return error.BadPattern; // a stray `\)`
        try p.prog.append(gpa, .{ .save = 1 });
        try p.prog.append(gpa, .match);
        return .{
            .prog = try p.prog.toOwnedSlice(gpa),
            .classes = try p.classes.toOwnedSlice(gpa),
            .icase = icase,
            .anchored = pattern.len > 0 and pattern[0] == '^' and
                std.mem.indexOf(u8, pattern, "\\|") == null,
        };
    }

    /// Leftmost match at or after `from`.
    pub fn search(self: *const Regex, s: []const u8, from: usize) ?Match {
        if (from > s.len) return null;
        var at = from;
        while (at <= s.len) : (at += 1) {
            if (self.matchAt(s, at)) |m| return m;
            if (self.anchored and at > 0) return null;
            if (self.anchored and at == 0 and from == 0) return null;
        }
        return null;
    }

    /// Rightmost match that STARTS before `before`. Used by `?` and `N`,
    /// where "the previous one" means the previous start, not the
    /// previous end.
    pub fn searchBack(self: *const Regex, s: []const u8, before: usize) ?Match {
        const lim = @min(before, s.len + 1);
        var at = lim;
        while (at > 0) {
            at -= 1;
            if (self.matchAt(s, at)) |m| return m;
        }
        return null;
    }

    pub fn matchAt(self: *const Regex, s: []const u8, at: usize) ?Match {
        var vm: Vm = .{ .re = self, .s = s, .steps = 0 };
        vm.caps = @splat(null);
        if (!vm.run(0, at, 0)) return null;
        var m: Match = .{ .start = at, .end = at, .groups = @splat(null) };
        for (0..10) |g| {
            const a = vm.caps[g * 2] orelse continue;
            const b = vm.caps[g * 2 + 1] orelse continue;
            m.groups[g] = .{ .a = a, .b = b };
        }
        const whole = m.groups[0] orelse return null;
        m.start = whole.a;
        m.end = whole.b;
        return m;
    }
};

// ------------------------------------------------------------------ matching

const Vm = struct {
    re: *const Regex,
    s: []const u8,
    caps: [20]?usize = @splat(null),
    steps: u32,

    fn eq(self: *const Vm, a: u8, b: u8) bool {
        if (a == b) return true;
        return self.re.icase and std.ascii.toLower(a) == std.ascii.toLower(b);
    }

    fn inClass(self: *const Vm, idx: u16, c: u8) bool {
        const set = &self.re.classes[idx];
        if (bitHas(set, c)) return true;
        if (!self.re.icase) return false;
        const other = if (std.ascii.isUpper(c)) std.ascii.toLower(c) else std.ascii.toUpper(c);
        return other != c and bitHas(set, other);
    }

    fn simpleAt(self: *const Vm, what: Simple, sp: usize) bool {
        if (sp >= self.s.len) return false;
        return switch (what) {
            .char => |c| self.eq(c, self.s[sp]),
            .any => true,
            .class => |ci| self.inClass(ci, self.s[sp]),
        };
    }

    fn isWord(c: u8) bool {
        return c == '_' or std.ascii.isAlphanumeric(c);
    }

    fn run(self: *Vm, pc0: usize, sp0: usize, depth: u16) bool {
        var pc = pc0;
        var sp = sp0;
        if (depth > depth_budget) return false;
        while (true) {
            self.steps += 1;
            if (self.steps > step_budget) return false;
            switch (self.re.prog[pc]) {
                .match => return true,
                .char => |c| {
                    if (sp >= self.s.len or !self.eq(c, self.s[sp])) return false;
                    sp += 1;
                    pc += 1;
                },
                .any => {
                    // `.` does not match a newline, same as vim — a
                    // pattern is a LINE pattern here.
                    if (sp >= self.s.len or self.s[sp] == '\n') return false;
                    sp += 1;
                    pc += 1;
                },
                .class => |ci| {
                    if (sp >= self.s.len or !self.inClass(ci, self.s[sp])) return false;
                    sp += 1;
                    pc += 1;
                },
                .bol => {
                    if (sp != 0 and self.s[sp - 1] != '\n') return false;
                    pc += 1;
                },
                .eol => {
                    if (sp != self.s.len and self.s[sp] != '\n') return false;
                    pc += 1;
                },
                .word_start => {
                    if (sp >= self.s.len or !isWord(self.s[sp])) return false;
                    if (sp > 0 and isWord(self.s[sp - 1])) return false;
                    pc += 1;
                },
                .word_end => {
                    if (sp == 0 or !isWord(self.s[sp - 1])) return false;
                    if (sp < self.s.len and isWord(self.s[sp])) return false;
                    pc += 1;
                },
                .save => |n| {
                    const was = self.caps[n];
                    self.caps[n] = sp;
                    if (self.run(pc + 1, sp, depth + 1)) return true;
                    self.caps[n] = was;
                    return false;
                },
                .jmp => |x| pc = x,
                .split => |b| {
                    if (self.run(b.x, sp, depth + 1)) return true;
                    pc = b.y;
                },
                .rep => |r| {
                    // Greedy, and iterative: `.*` on a long line costs
                    // one frame, not one per character.
                    var n: u32 = 0;
                    while (n < r.max and self.simpleAt(r.what, sp + n)) : (n += 1) {
                        if (r.what == .any and self.s[sp + n] == '\n') break;
                    }
                    while (true) {
                        if (n < r.min) return false;
                        self.steps += 1;
                        if (self.steps > step_budget) return false;
                        if (self.run(pc + 1, sp + n, depth + 1)) return true;
                        if (n == 0) return false;
                        n -= 1;
                    }
                },
            }
        }
    }
};

// ------------------------------------------------------------------ parsing

const Parser = struct {
    gpa: Allocator,
    src: []const u8,
    i: usize = 0,
    prog: std.ArrayListUnmanaged(Inst),
    classes: std.ArrayListUnmanaged(Bits),
    ngroup: u8 = 0,
    /// Where the body currently being copied started, so appendBody can
    /// relocate its absolute jump targets.
    body_base: u32 = 0,

    fn at(self: *const Parser) ?u8 {
        return if (self.i < self.src.len) self.src[self.i] else null;
    }

    /// True when the cursor sits on the two-byte escape `\x`.
    fn esc(self: *const Parser, x: u8) bool {
        return self.i + 1 < self.src.len and self.src[self.i] == '\\' and self.src[self.i + 1] == x;
    }

    fn emit(self: *Parser, in: Inst) Error!u32 {
        const at_pc: u32 = @intCast(self.prog.items.len);
        try self.prog.append(self.gpa, in);
        return at_pc;
    }

    /// `a\|b\|c` — a chain of splits, each falling through to the next.
    fn alts(self: *Parser, depth: u8) Error!void {
        if (depth > 32) return error.BadPattern;
        var jmps: std.ArrayListUnmanaged(u32) = .empty;
        defer jmps.deinit(self.gpa);
        while (true) {
            const split_pc = try self.emit(.{ .split = .{ .x = 0, .y = 0 } });
            try self.seq(depth);
            if (self.esc('|')) {
                self.i += 2;
                try jmps.append(self.gpa, try self.emit(.{ .jmp = 0 }));
                self.prog.items[split_pc] = .{ .split = .{
                    .x = split_pc + 1,
                    .y = @intCast(self.prog.items.len),
                } };
                continue;
            }
            // Last branch: the split was unnecessary, so it becomes a
            // no-op jump onto the branch it guarded.
            self.prog.items[split_pc] = .{ .jmp = split_pc + 1 };
            break;
        }
        const end: u32 = @intCast(self.prog.items.len);
        for (jmps.items) |j| self.prog.items[j] = .{ .jmp = end };
    }

    fn seq(self: *Parser, depth: u8) Error!void {
        while (self.i < self.src.len) {
            if (self.esc('|') or self.esc(')')) return;
            try self.piece(depth);
        }
    }

    fn piece(self: *Parser, depth: u8) Error!void {
        const start: u32 = @intCast(self.prog.items.len);
        const simple = try self.atom(depth);
        var min: u32 = 1;
        var max: u32 = 1;
        if (self.at() == '*') {
            self.i += 1;
            min = 0;
            max = std.math.maxInt(u32);
        } else if (self.esc('+')) {
            self.i += 2;
            min = 1;
            max = std.math.maxInt(u32);
        } else if (self.esc('?') or self.esc('=')) {
            self.i += 2;
            min = 0;
            max = 1;
        } else if (self.esc('{')) {
            self.i += 2;
            try self.counted(&min, &max);
        } else return;

        if (simple) |what| {
            // One instruction with an internal loop. This is the case
            // that keeps `.*` off the stack.
            self.prog.shrinkRetainingCapacity(start);
            _ = try self.emit(.{ .rep = .{ .what = what, .min = min, .max = max } });
            return;
        }
        // A group repeat has to backtrack properly, so it keeps the
        // split/jmp shape. Bounded counts are unrolled by copying.
        try self.wrapRepeat(start, min, max);
    }

    /// Wrap the instructions from `start` onward in a repeat. The body
    /// is COPIED for a bounded count, which is why the count is capped:
    /// `\{1,1000}` on a group would be a thousand copies of it.
    fn wrapRepeat(self: *Parser, start: u32, min: u32, max: u32) Error!void {
        const body = try self.gpa.dupe(Inst, self.prog.items[start..]);
        defer self.gpa.free(body);
        self.prog.shrinkRetainingCapacity(start);

        if (max != std.math.maxInt(u32) and max > 32) return error.BadPattern;
        const fixed = @min(min, 32);
        for (0..fixed) |_| try self.appendBody(body);

        if (max == std.math.maxInt(u32)) {
            // L: split L+1, END; <body>; jmp L; END:
            const l: u32 = @intCast(self.prog.items.len);
            _ = try self.emit(.{ .split = .{ .x = 0, .y = 0 } });
            try self.appendBody(body);
            _ = try self.emit(.{ .jmp = l });
            const end: u32 = @intCast(self.prog.items.len);
            self.prog.items[l] = .{ .split = .{ .x = l + 1, .y = end } };
            return;
        }
        // The optional tail: one guarded copy per remaining repetition.
        var opts: std.ArrayListUnmanaged(u32) = .empty;
        defer opts.deinit(self.gpa);
        for (fixed..max) |_| {
            try opts.append(self.gpa, try self.emit(.{ .split = .{ .x = 0, .y = 0 } }));
            try self.appendBody(body);
        }
        const end: u32 = @intCast(self.prog.items.len);
        for (opts.items) |o| self.prog.items[o] = .{ .split = .{ .x = o + 1, .y = end } };
    }

    /// Copy a body, relocating its internal jump targets to the new
    /// position. Every target inside a body is an absolute pc.
    fn appendBody(self: *Parser, body: []const Inst) Error!void {
        const base: u32 = @intCast(self.prog.items.len);
        // The body was captured starting at some old base; the offset
        // between old and new is what every target has to move by.
        const old_base = self.body_base;
        for (body) |in| {
            const moved: Inst = switch (in) {
                .split => |b| .{ .split = .{
                    .x = b.x - old_base + base,
                    .y = b.y - old_base + base,
                } },
                .jmp => |x| .{ .jmp = x - old_base + base },
                else => in,
            };
            try self.prog.append(self.gpa, moved);
        }
    }

    fn counted(self: *Parser, min: *u32, max: *u32) Error!void {
        var lo: u32 = 0;
        var saw_lo = false;
        while (self.at()) |c| : (self.i += 1) {
            if (c < '0' or c > '9') break;
            lo = lo *| 10 +| (c - '0');
            saw_lo = true;
        }
        var hi: u32 = lo;
        if (self.at() == ',') {
            self.i += 1;
            var h: u32 = 0;
            var saw_hi = false;
            while (self.at()) |c| : (self.i += 1) {
                if (c < '0' or c > '9') break;
                h = h *| 10 +| (c - '0');
                saw_hi = true;
            }
            hi = if (saw_hi) h else std.math.maxInt(u32);
        }
        // Vim closes this with `}` or `\}`; take either.
        if (self.esc('}')) self.i += 2 else if (self.at() == '}') self.i += 1 else return error.BadPattern;
        if (!saw_lo) lo = 0;
        if (hi < lo) return error.BadPattern;
        min.* = lo;
        max.* = hi;
    }

    /// Emit one atom. Returns its single-width form when it has one, so
    /// `piece` can turn a repeat of it into a loop.
    fn atom(self: *Parser, depth: u8) Error!?Simple {
        const c = self.at() orelse return error.BadPattern;
        if (c == '^' and self.i == 0) {
            self.i += 1;
            _ = try self.emit(.bol);
            return null;
        }
        if (c == '$' and self.i + 1 == self.src.len) {
            self.i += 1;
            _ = try self.emit(.eol);
            return null;
        }
        if (c == '.') {
            self.i += 1;
            _ = try self.emit(.any);
            return .any;
        }
        if (c == '[') return try self.bracket();
        if (c == '*') return error.BadPattern; // nothing to repeat
        if (c == '\\') {
            const n = if (self.i + 1 < self.src.len) self.src[self.i + 1] else return error.BadPattern;
            switch (n) {
                '(' => {
                    self.i += 2;
                    self.ngroup += 1;
                    if (self.ngroup > 9) return error.BadPattern;
                    const g = self.ngroup;
                    const start: u32 = @intCast(self.prog.items.len);
                    self.body_base = start;
                    _ = try self.emit(.{ .save = g * 2 });
                    try self.alts(depth + 1);
                    if (!self.esc(')')) return error.BadPattern;
                    self.i += 2;
                    _ = try self.emit(.{ .save = g * 2 + 1 });
                    self.body_base = start;
                    return null;
                },
                '<' => {
                    self.i += 2;
                    _ = try self.emit(.word_start);
                    return null;
                },
                '>' => {
                    self.i += 2;
                    _ = try self.emit(.word_end);
                    return null;
                },
                'd', 'D', 'w', 'W', 's', 'S', 'a', 'l', 'u' => {
                    self.i += 2;
                    const idx = try self.shorthand(n);
                    _ = try self.emit(.{ .class = idx });
                    return .{ .class = idx };
                },
                else => {
                    self.i += 2;
                    _ = try self.emit(.{ .char = n });
                    return .{ .char = n };
                },
            }
        }
        self.i += 1;
        _ = try self.emit(.{ .char = c });
        return .{ .char = c };
    }

    fn shorthand(self: *Parser, n: u8) Error!u16 {
        var set: Bits = @splat(0);
        var c: usize = 0;
        while (c < 256) : (c += 1) {
            const b: u8 = @intCast(c);
            const in = switch (std.ascii.toLower(n)) {
                'd' => std.ascii.isDigit(b),
                'w' => b == '_' or std.ascii.isAlphanumeric(b),
                's' => b == ' ' or b == '\t',
                'a' => std.ascii.isAlphabetic(b),
                'l' => std.ascii.isLower(b),
                'u' => std.ascii.isUpper(b),
                else => false,
            };
            // The uppercase forms are the complements, except \a \l \u
            // which vim does not give one.
            const want = if (n == 'D' or n == 'W' or n == 'S') !in else in;
            if (want) bitSet(&set, b);
        }
        try self.classes.append(self.gpa, set);
        return @intCast(self.classes.items.len - 1);
    }

    fn bracket(self: *Parser) Error!?Simple {
        self.i += 1; // [
        var neg = false;
        if (self.at() == '^') {
            neg = true;
            self.i += 1;
        }
        var set: Bits = @splat(0);
        var first = true;
        while (true) {
            const c = self.at() orelse return error.BadPattern;
            if (c == ']' and !first) break;
            first = false;
            self.i += 1;
            var lo = c;
            if (lo == '\\') {
                lo = self.at() orelse return error.BadPattern;
                self.i += 1;
            }
            if (self.at() == '-' and self.i + 1 < self.src.len and self.src[self.i + 1] != ']') {
                self.i += 1;
                var hi = self.at() orelse return error.BadPattern;
                self.i += 1;
                if (hi == '\\') {
                    hi = self.at() orelse return error.BadPattern;
                    self.i += 1;
                }
                if (hi < lo) return error.BadPattern;
                var k: usize = lo;
                while (k <= hi) : (k += 1) bitSet(&set, @intCast(k));
                continue;
            }
            bitSet(&set, lo);
        }
        if (self.at() != ']') return error.BadPattern;
        self.i += 1;
        if (neg) {
            for (&set) |*b| b.* = ~b.*;
            // A negated class never matches a newline; a pattern here
            // is a line pattern.
            set['\n' >> 3] &= ~(@as(u8, 1) << ('\n' & 7));
        }
        try self.classes.append(self.gpa, set);
        const idx: u16 = @intCast(self.classes.items.len - 1);
        _ = try self.emit(.{ .class = idx });
        return .{ .class = idx };
    }
};

// ------------------------------------------------------------- replacement

/// Expand a `:s` replacement against a match: `&` and `\0` are the whole
/// match, `\1`-`\9` are groups, `\&` and `\\` are literals, and `\r` is
/// a newline (vim's, and the reason `:s` can split a line).
pub fn expand(
    out: *std.ArrayListUnmanaged(u8),
    gpa: Allocator,
    rep: []const u8,
    hay: []const u8,
    m: Match,
) Allocator.Error!void {
    var i: usize = 0;
    while (i < rep.len) : (i += 1) {
        const c = rep[i];
        if (c == '&') {
            try out.appendSlice(gpa, hay[m.start..m.end]);
            continue;
        }
        if (c != '\\' or i + 1 >= rep.len) {
            try out.append(gpa, c);
            continue;
        }
        i += 1;
        const n = rep[i];
        switch (n) {
            '0'...'9' => {
                if (m.groups[n - '0']) |g| try out.appendSlice(gpa, hay[g.a..g.b]);
            },
            'r', 'n' => try out.append(gpa, '\n'),
            't' => try out.append(gpa, '\t'),
            else => try out.append(gpa, n),
        }
    }
}

// ------------------------------------------------------------------- tests

const testing = std.testing;

fn find(gpa: Allocator, pat: []const u8, s: []const u8) !?Match {
    var re = try Regex.compile(gpa, pat, false);
    defer re.deinit(gpa);
    return re.search(s, 0);
}

fn expectFind(pat: []const u8, s: []const u8, want: []const u8) !void {
    const gpa = testing.allocator;
    const m = (try find(gpa, pat, s)) orelse {
        std.debug.print("pattern {s} found nothing in {s}\n", .{ pat, s });
        return error.NoMatch;
    };
    try testing.expectEqualStrings(want, s[m.start..m.end]);
}

fn expectNone(pat: []const u8, s: []const u8) !void {
    const gpa = testing.allocator;
    try testing.expect((try find(gpa, pat, s)) == null);
}

test "literals and dot" {
    try expectFind("bar", "foo bar baz", "bar");
    try expectFind("b.r", "foo bar", "bar");
    try expectNone("b.r", "foo bxxr");
}

test "star is greedy" {
    try expectFind("a*", "aaab", "aaa");
    try expectFind("ab*c", "abbbc", "abbbc");
    try expectFind("ab*c", "ac", "ac");
    try expectFind("<.*>", "x <a> and <b> y", "<a> and <b>");
}

test "anchors" {
    try expectFind("^foo", "foo bar", "foo");
    try expectNone("^bar", "foo bar");
    try expectFind("bar$", "foo bar", "bar");
    try expectNone("foo$", "foo bar");
}

test "character classes" {
    try expectFind("[abc]*", "cabx", "cab");
    try expectFind("[^ ]*", "hello world", "hello");
    try expectFind("[0-9][0-9]*", "abc 123 def", "123");
    try expectFind("[a-z-]*", "a-b c", "a-b");
}

test "class shorthands" {
    try expectFind("\\d\\+", "abc 4711 z", "4711");
    try expectFind("\\w\\+", "  foo_bar1 ", "foo_bar1");
    try expectFind("\\s\\+", "a   b", "   ");
    try expectFind("\\u\\l*", "xx Hello", "Hello");
    try expectFind("\\D\\+", "12abc34", "abc");
}

test "word boundaries" {
    try expectFind("\\<bar\\>", "foobar bar baz", "bar");
    try expectNone("\\<bar\\>", "foobar barbaz");
    try expectFind("\\<b", "a b", "b");
}

test "alternation" {
    try expectFind("foo\\|bar", "xx bar", "bar");
    try expectFind("foo\\|bar", "xx foo bar", "foo");
    try expectFind("a\\|b\\|c", "zzc", "c");
    try expectNone("foo\\|bar", "xx baz");
}

test "groups and plus and optional" {
    try expectFind("\\(ab\\)\\+", "xababy", "abab");
    try expectFind("colou\\?r", "the color", "color");
    try expectFind("colou\\?r", "the colour", "colour");
    try expectFind("\\(foo\\|bar\\)baz", "xbarbaz", "barbaz");
}

test "counted repeats" {
    try expectFind("a\\{3}", "aaaa", "aaa");
    try expectFind("a\\{2,3}", "aaaa", "aaa");
    try expectFind("a\\{,2}b", "aaab", "aab");
    try expectFind("\\(ab\\)\\{2}", "ababab", "abab");
    try expectNone("a\\{4}", "aaa");
}

test "escapes make specials literal" {
    try expectFind("a\\.c", "abc a.c", "a.c");
    try expectFind("\\[x\\]", "y [x]", "[x]");
    try expectFind("a\\*", "aa a*", "a*");
}

test "captures" {
    const gpa = testing.allocator;
    var re = try Regex.compile(gpa, "\\(\\w\\+\\)(\\(.*\\))", false);
    defer re.deinit(gpa);
    const s = "call foo(a, b) end";
    const m = re.search(s, 0).?;
    try testing.expectEqualStrings("foo(a, b)", s[m.start..m.end]);
    try testing.expectEqualStrings("foo", s[m.groups[1].?.a..m.groups[1].?.b]);
    try testing.expectEqualStrings("a, b", s[m.groups[2].?.a..m.groups[2].?.b]);
}

test "ignore case" {
    const gpa = testing.allocator;
    var re = try Regex.compile(gpa, "[a-z]oo", true);
    defer re.deinit(gpa);
    const s = "xx FOO";
    const m = re.search(s, 0).?;
    try testing.expectEqualStrings("FOO", s[m.start..m.end]);
}

test "search from an offset, and backward" {
    const gpa = testing.allocator;
    var re = try Regex.compile(gpa, "foo", false);
    defer re.deinit(gpa);
    const s = "foo bar foo baz foo";
    try testing.expectEqual(@as(usize, 0), re.search(s, 0).?.start);
    try testing.expectEqual(@as(usize, 8), re.search(s, 1).?.start);
    try testing.expectEqual(@as(usize, 8), re.searchBack(s, 16).?.start);
    try testing.expectEqual(@as(usize, 0), re.searchBack(s, 8).?.start);
    try testing.expect(re.searchBack(s, 0) == null);
}

test "dot does not cross a newline" {
    try expectFind(".*", "ab\ncd", "ab");
    try expectFind("[^x]*", "ab\ncd", "ab");
}

test "a bad pattern is an error, not a crash" {
    const gpa = testing.allocator;
    try testing.expectError(error.BadPattern, Regex.compile(gpa, "\\(unclosed", false));
    try testing.expectError(error.BadPattern, Regex.compile(gpa, "*leading", false));
    try testing.expectError(error.BadPattern, Regex.compile(gpa, "closed\\)", false));
    try testing.expectError(error.BadPattern, Regex.compile(gpa, "a\\{3,1}", false));
}

test "a pathological pattern fails closed instead of hanging" {
    const gpa = testing.allocator;
    var re = try Regex.compile(gpa, "\\(a\\+\\)\\+b", false);
    defer re.deinit(gpa);
    // No `b` anywhere, and 2^29 ways to split thirty a's into groups.
    // The budget is what makes this return at all.
    try testing.expect(re.search("a" ** 30, 0) == null);
}

test "replacement expansion" {
    const gpa = testing.allocator;
    var re = try Regex.compile(gpa, "\\(\\w\\+\\)=\\(\\w\\+\\)", false);
    defer re.deinit(gpa);
    const s = "key=value";
    const m = re.search(s, 0).?;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(gpa);
    try expand(&out, gpa, "\\2 is \\1 [&]", s, m);
    try testing.expectEqualStrings("value is key [key=value]", out.items);
}

test "replacement escapes" {
    const gpa = testing.allocator;
    var re = try Regex.compile(gpa, "x", false);
    defer re.deinit(gpa);
    const m = re.search("x", 0).?;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(gpa);
    try expand(&out, gpa, "a\\&b\\\\c\\rd", "x", m);
    try testing.expectEqualStrings("a&b\\c\nd", out.items);
}
