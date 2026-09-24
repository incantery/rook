//! Classes: names anyone can put on a workspace or a pane, for the
//! stylesheet to match (docs/style.md, "Classes"). Rook gives them no
//! meaning. A detector that decides a workspace is in trouble — an
//! error on the screen, a loop that will not stop — says so with
//! `rook class api +error --ttl 5m`, or a program flags its own pane
//! with OSC 1337 SetUserVar=rook_class; a rule with `class = "error"`
//! decides what that looks like.
//!
//! A set is small and bounded, and a class may carry a deadline, past
//! which it is gone as if it had been taken off.
const std = @import("std");

pub const max = 16;
pub const max_name = 31;

pub const Class = struct {
    name: [max_name]u8 = undefined,
    len: u8 = 0,
    /// wall-clock ms it lapses at; 0 is never
    until_ms: i64 = 0,

    pub fn slice(self: *const Class) []const u8 {
        return self.name[0..self.len];
    }
};

pub const Set = struct {
    items: [max]Class = undefined,
    n: usize = 0,

    pub fn slice(self: *const Set) []const Class {
        return self.items[0..self.n];
    }

    fn find(self: *const Set, name: []const u8) ?usize {
        for (self.items[0..self.n], 0..) |c, i| {
            if (std.mem.eql(u8, c.slice(), name)) return i;
        }
        return null;
    }

    pub fn has(self: *const Set, name: []const u8) bool {
        return self.find(name) != null;
    }

    /// Put one on (again: a new deadline). False when there is no room
    /// or the name is not one.
    pub fn add(self: *Set, name: []const u8, until_ms: i64) bool {
        if (!valid(name)) return false;
        if (self.find(name)) |i| {
            self.items[i].until_ms = until_ms;
            return true;
        }
        if (self.n == max) return false;
        var c: Class = .{ .len = @intCast(name.len), .until_ms = until_ms };
        @memcpy(c.name[0..name.len], name);
        self.items[self.n] = c;
        self.n += 1;
        return true;
    }

    pub fn remove(self: *Set, name: []const u8) bool {
        const i = self.find(name) orelse return false;
        self.items[i] = self.items[self.n - 1];
        self.n -= 1;
        return true;
    }

    /// `+a -b c` — a bare name is `+` — and `-*` takes them all off.
    /// A `+` carries `ttl_ms` when it is not 0, and `ttl=30s` among the
    /// words sets it for the ones after (how a program in a pane gives
    /// its own flag a deadline). True when anything changed;
    /// `error.NotAName` for a word that cannot be a class.
    pub fn apply(self: *Set, ops: []const u8, ttl_in: i64, now_ms: i64) !bool {
        var changed = false;
        var ttl_ms = ttl_in;
        var it = std.mem.tokenizeAny(u8, ops, " \t\r\n,");
        while (it.next()) |w| {
            if (std.mem.startsWith(u8, w, "ttl=")) {
                ttl_ms = parseTtl(w[4..]) orelse return error.NotAName;
                continue;
            }
            if (std.mem.eql(u8, w, "-*")) {
                changed = changed or self.n > 0;
                self.n = 0;
                continue;
            }
            if (w[0] == '-') {
                if (self.remove(w[1..])) changed = true;
                continue;
            }
            const name = if (w[0] == '+') w[1..] else w;
            if (!valid(name)) return error.NotAName;
            const until: i64 = if (ttl_ms > 0) now_ms + ttl_ms else 0;
            const had = self.find(name);
            if (!self.add(name, until)) return error.Full;
            if (had == null) changed = true;
        }
        return changed;
    }

    /// Drop what has lapsed. True when anything did.
    pub fn expire(self: *Set, now_ms: i64) bool {
        var changed = false;
        var i: usize = 0;
        while (i < self.n) {
            const u = self.items[i].until_ms;
            if (u != 0 and u <= now_ms) {
                self.items[i] = self.items[self.n - 1];
                self.n -= 1;
                changed = true;
            } else i += 1;
        }
        return changed;
    }

    /// The soonest deadline, 0 when none.
    pub fn next(self: *const Set) i64 {
        var soon: i64 = 0;
        for (self.slice()) |c| {
            if (c.until_ms != 0 and (soon == 0 or c.until_ms < soon)) soon = c.until_ms;
        }
        return soon;
    }
};

/// Letters, digits, `-`, `_`, `.`, `:`, and not too long: a class is a
/// word a rule can say.
pub fn valid(name: []const u8) bool {
    if (name.len == 0 or name.len > max_name) return false;
    for (name) |ch| {
        if (!(std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.' or ch == ':')) return false;
    }
    return true;
}

/// A duration as a person writes it: `30s`, `5m`, `2h`, `1500ms`, or
/// bare seconds. Milliseconds; null when it is not one.
pub fn parseTtl(s: []const u8) ?i64 {
    if (s.len == 0) return null;
    var end: usize = 0;
    while (end < s.len and std.ascii.isDigit(s[end])) end += 1;
    const n = std.fmt.parseInt(i64, s[0..end], 10) catch return null;
    const unit = s[end..];
    const mul: i64 = if (unit.len == 0 or std.mem.eql(u8, unit, "s"))
        1000
    else if (std.mem.eql(u8, unit, "ms"))
        1
    else if (std.mem.eql(u8, unit, "m"))
        60_000
    else if (std.mem.eql(u8, unit, "h"))
        3_600_000
    else
        return null;
    return n * mul;
}

// ---- in-pane: OSC 1337 SetUserVar=rook_class=<base64 ops>

/// Finds `ESC ] 1337 ; SetUserVar = rook_class = <base64> (BEL | ESC \)`
/// in a pane's output, across reads: ghostty parses the sequence and
/// drops it, so the pane's reader looks for this one itself. The ops
/// are what `apply` reads, base64-encoded as the convention has it
/// (WezTerm, iTerm2).
pub const Scanner = struct {
    /// the start of a sequence the last read cut off
    tail: [320]u8 = undefined,
    tail_len: usize = 0,

    const prefix = "\x1b]1337;SetUserVar=rook_class=";

    /// Call `found(ctx, ops)` for each whole sequence in `bytes`.
    pub fn scan(self: *Scanner, bytes: []const u8, ctx: anytype, comptime found: fn (@TypeOf(ctx), []const u8) void) void {
        var data = bytes;
        if (self.tail_len > 0) {
            // finish the one the last read started, from its own tail
            // plus as much of this read as it can use
            const need = @min(data.len, self.tail.len - self.tail_len);
            var joined: [640]u8 = undefined;
            @memcpy(joined[0..self.tail_len], self.tail[0..self.tail_len]);
            @memcpy(joined[self.tail_len..][0..need], data[0..need]);
            const j = joined[0 .. self.tail_len + need];
            const had = self.tail_len;
            self.tail_len = 0;
            switch (one(j, 0)) {
                .done => |d| {
                    found(ctx, d.ops);
                    data = data[d.end - had ..];
                },
                .partial => {
                    if (j.len < self.tail.len) {
                        @memcpy(self.tail[0..j.len], j);
                        self.tail_len = j.len;
                    }
                    return;
                },
                .no => {},
            }
        }
        var i: usize = 0;
        while (std.mem.indexOfScalarPos(u8, data, i, 0x1b)) |esc| {
            switch (one(data, esc)) {
                .done => |d| {
                    found(ctx, d.ops);
                    i = d.end;
                },
                .partial => {
                    const rest = data[esc..];
                    if (rest.len <= self.tail.len) {
                        @memcpy(self.tail[0..rest.len], rest);
                        self.tail_len = rest.len;
                    }
                    return;
                },
                .no => i = esc + 1,
            }
        }
    }

    const One = union(enum) { no, partial, done: struct { ops: []const u8, end: usize } };

    fn one(data: []const u8, at: usize) One {
        const rest = data[at..];
        const n = @min(rest.len, prefix.len);
        if (!std.mem.eql(u8, rest[0..n], prefix[0..n])) return .no;
        if (rest.len < prefix.len) return .partial;
        const body = rest[prefix.len..];
        var k: usize = 0;
        while (k < body.len) : (k += 1) {
            if (body[k] == 0x07) return .{ .done = .{ .ops = body[0..k], .end = at + prefix.len + k + 1 } };
            if (body[k] == 0x1b) {
                if (k + 1 >= body.len) return .partial;
                if (body[k + 1] == '\\') return .{ .done = .{ .ops = body[0..k], .end = at + prefix.len + k + 2 } };
                return .no;
            }
            if (k > 256) return .no;
        }
        return .partial;
    }
};

/// The ops a SetUserVar carries, decoded: base64 as the convention has
/// it, or the plain words when a hand typed them.
pub fn decodeOps(raw: []const u8, buf: []u8) []const u8 {
    const dec = std.base64.standard.Decoder;
    const n = dec.calcSizeForSlice(raw) catch return raw;
    if (n > buf.len) return raw;
    dec.decode(buf[0..n], raw) catch return raw;
    return buf[0..n];
}

test "apply: add, remove, bare names, clear, ttl" {
    var s: Set = .{};
    try std.testing.expect(try s.apply("+error loop", 0, 1000));
    try std.testing.expect(s.has("error") and s.has("loop"));
    try std.testing.expect(!try s.apply("+error", 0, 1000)); // already on
    try std.testing.expect(try s.apply("-loop", 0, 1000));
    try std.testing.expect(!s.has("loop"));
    try std.testing.expect(try s.apply("+hot", 5000, 1000));
    try std.testing.expectEqual(@as(i64, 6000), s.next());
    try std.testing.expect(!s.expire(5999));
    try std.testing.expect(s.expire(6000));
    try std.testing.expect(!s.has("hot") and s.has("error"));
    try std.testing.expect(try s.apply("-*", 0, 0));
    try std.testing.expectEqual(@as(usize, 0), s.n);
    try std.testing.expectError(error.NotAName, s.apply("+no/slashes", 0, 0));
    // a deadline said among the words, for the ones after it
    try std.testing.expect(try s.apply("+a ttl=2s +b", 0, 100));
    try std.testing.expectEqual(@as(i64, 0), s.items[0].until_ms);
    try std.testing.expectEqual(@as(i64, 2100), s.next());
}

test "ttl" {
    try std.testing.expectEqual(@as(?i64, 30_000), parseTtl("30s"));
    try std.testing.expectEqual(@as(?i64, 300_000), parseTtl("5m"));
    try std.testing.expectEqual(@as(?i64, 7_200_000), parseTtl("2h"));
    try std.testing.expectEqual(@as(?i64, 1500), parseTtl("1500ms"));
    try std.testing.expectEqual(@as(?i64, 10_000), parseTtl("10"));
    try std.testing.expectEqual(@as(?i64, null), parseTtl("soon"));
}

const Collect = struct {
    got: [4][64]u8 = undefined,
    lens: [4]usize = @splat(0),
    n: usize = 0,
    fn found(self: *Collect, ops: []const u8) void {
        @memcpy(self.got[self.n][0..ops.len], ops);
        self.lens[self.n] = ops.len;
        self.n += 1;
    }
    fn at(self: *const Collect, i: usize) []const u8 {
        return self.got[i][0..self.lens[i]];
    }
};

test "the scanner finds the sequence, whole or cut across reads" {
    var sc: Scanner = .{};
    var c: Collect = .{};
    sc.scan("hello\x1b[31mred\x1b]1337;SetUserVar=rook_class=K2Vycm9y\x07after\x1b]1337;SetUserVar=other=eA==\x07", &c, Collect.found);
    try std.testing.expectEqual(@as(usize, 1), c.n);
    try std.testing.expectEqualStrings("K2Vycm9y", c.at(0));
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("+error", decodeOps(c.at(0), &buf));
    // cut inside the prefix, then inside the value, ST-terminated
    var c2: Collect = .{};
    var sc2: Scanner = .{};
    sc2.scan("x\x1b]1337;SetUs", &c2, Collect.found);
    try std.testing.expectEqual(@as(usize, 0), c2.n);
    sc2.scan("erVar=rook_class=LWxv", &c2, Collect.found);
    try std.testing.expectEqual(@as(usize, 0), c2.n);
    sc2.scan("b3A=\x1b\\tail", &c2, Collect.found);
    try std.testing.expectEqual(@as(usize, 1), c2.n);
    try std.testing.expectEqualStrings("-loop", decodeOps(c2.at(0), &buf));
    // an ESC that is not ours is not held on to
    var c3: Collect = .{};
    var sc3: Scanner = .{};
    sc3.scan("\x1b]0;title\x07", &c3, Collect.found);
    try std.testing.expectEqual(@as(usize, 0), sc3.tail_len);
}
