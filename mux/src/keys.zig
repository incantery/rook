//! The prefix table: which key after the prefix does what. Rook ships
//! the verbs and a multiplexer's bindings for them — splits, focus,
//! windows, copy mode, home and back — and nothing that names a
//! program. What floats in a popup, which agent, which picker: the
//! config says, in a [keys] table in the same rook.toml:
//!
//!   [keys]
//!   g = "popup 72x86@124x48 grim"    # a program in a popup, sized
//!   s = "popup rook pick"
//!   "C-o" = "last-space"
//!   x = ""                           # unbound
//!
//! A key is one printable character or `C-<letter>`; a verb is one of
//! `Verb` below, with an argument where it takes one. The rows arrive
//! in the compiled config (config.zig); the Go half has already
//! refused a key or a verb this table would skip.
const std = @import("std");

pub const Verb = enum {
    none,
    split_right,
    split_down,
    focus_left,
    focus_down,
    focus_up,
    focus_right,
    resize_left,
    resize_down,
    resize_up,
    resize_right,
    new_window,
    next_window,
    previous_window,
    /// arg: the window's number, from 1
    select_window,
    last_pane,
    zoom,
    copy_mode,
    kill_pane,
    detach,
    next_unread,
    inspect,
    home,
    last_space,
    sidebar,
    pin,
    pin_global,
    /// arg: the popup payload — `\x1fWxH[@MWxMH]\x1f` then the command,
    /// or the command alone (the form `rook popup` sends)
    popup,

    /// The config's spelling: `split-right`, not `split_right`.
    pub fn parse(word: []const u8) ?Verb {
        var buf: [32]u8 = undefined;
        if (word.len > buf.len) return null;
        for (word, 0..) |ch, i| buf[i] = if (ch == '-') '_' else ch;
        const v = std.meta.stringToEnum(Verb, buf[0..word.len]) orelse return null;
        return if (v == .none) null else v;
    }
};

pub const Binding = struct {
    verb: Verb = .none,
    arg_off: u16 = 0,
    arg_len: u16 = 0,
};

pub const Keys = struct {
    slots: [128]Binding = @splat(.{}),
    arena: [4096]u8 = undefined,
    arena_len: usize = 0,

    pub fn get(self: *const Keys, key: u8) Binding {
        return if (key < self.slots.len) self.slots[key] else .{};
    }

    pub fn arg(self: *const Keys, b: Binding) []const u8 {
        return self.arena[b.arg_off..][0..b.arg_len];
    }

    /// The first key bound to a verb, for help text that names it.
    /// Null when nothing is: the hint is then not shown at all.
    pub fn keyFor(self: *const Keys, verb: Verb) ?u8 {
        for (self.slots, 0..) |b, k| {
            if (b.verb == verb) return @intCast(k);
        }
        return null;
    }

    fn bind(self: *Keys, key: u8, verb: Verb, a: []const u8) void {
        if (key >= self.slots.len) return;
        if (self.arena_len + a.len > self.arena.len) return;
        @memcpy(self.arena[self.arena_len..][0..a.len], a);
        self.slots[key] = .{ .verb = verb, .arg_off = @intCast(self.arena_len), .arg_len = @intCast(a.len) };
        self.arena_len += a.len;
    }

    /// `verb [arg…]` → the slot. An empty string unbinds; a verb the
    /// table does not know leaves the key as it was.
    pub fn set(self: *Keys, key: u8, spec: []const u8) void {
        const s = std.mem.trim(u8, spec, " \t");
        if (s.len == 0) {
            if (key < self.slots.len) self.slots[key] = .{};
            return;
        }
        const sp = std.mem.indexOfAny(u8, s, " \t") orelse s.len;
        const verb = Verb.parse(s[0..sp]) orelse return;
        const rest = std.mem.trim(u8, s[sp..], " \t");
        switch (verb) {
            .popup => {
                if (rest.len == 0) return;
                // a leading WxH[@MWxMH] is the size; the rest is the command
                const w_end = std.mem.indexOfAny(u8, rest, " \t") orelse rest.len;
                if (w_end < rest.len and isSize(rest[0..w_end])) {
                    var buf: [512]u8 = undefined;
                    const cmd = std.mem.trim(u8, rest[w_end..], " \t");
                    const payload = std.fmt.bufPrint(&buf, "\x1f{s}\x1f{s}", .{ rest[0..w_end], cmd }) catch return;
                    self.bind(key, verb, payload);
                } else self.bind(key, verb, rest);
            },
            .select_window => {
                const n = std.fmt.parseInt(u8, rest, 10) catch return;
                if (n == 0) return;
                self.bind(key, verb, rest);
            },
            else => self.bind(key, verb, ""),
        }
    }
};

/// `72x86` or `72x86@124x48`.
fn isSize(word: []const u8) bool {
    var halves = std.mem.splitScalar(u8, word, '@');
    var n: usize = 0;
    while (halves.next()) |h| : (n += 1) {
        if (n > 1) return false;
        const x = std.mem.indexOfScalar(u8, h, 'x') orelse return false;
        _ = std.fmt.parseInt(u16, h[0..x], 10) catch return false;
        _ = std.fmt.parseInt(u16, h[x + 1 ..], 10) catch return false;
    }
    return n > 0;
}

/// A key's config spelling → its byte: one printable character, or
/// `C-<letter>` for the control key.
pub fn parseKey(name: []const u8) ?u8 {
    if (name.len == 1 and name[0] >= 0x20 and name[0] < 0x7f) return name[0];
    if (name.len == 3 and (name[0] == 'C' or name[0] == 'c') and name[1] == '-') {
        const ch = std.ascii.toLower(name[2]);
        if (ch >= 'a' and ch <= 'z') return ch - 'a' + 1;
    }
    if (std.ascii.eqlIgnoreCase(name, "space")) return ' ';
    return null;
}

/// A key's byte → how help text writes it: `C-o`, or the character.
pub fn keyName(key: u8, buf: []u8) []const u8 {
    if (key >= 1 and key <= 26) return std.fmt.bufPrint(buf, "C-{c}", .{key - 1 + 'a'}) catch "C-?";
    if (key == ' ') return "space";
    if (key >= 0x20 and key < 0x7f and buf.len > 0) {
        buf[0] = key;
        return buf[0..1];
    }
    return "?";
}

/// A multiplexer's bindings and rook's own ways around itself.
/// Nothing here names a program.
pub fn defaults() Keys {
    var k: Keys = .{};
    const table = [_]struct { u8, []const u8 }{
        .{ 'v', "split-right" },
        .{ '|', "split-right" },
        .{ '-', "split-down" },
        .{ 'h', "focus-left" },
        .{ 'j', "focus-down" },
        .{ 'k', "focus-up" },
        .{ 'l', "focus-right" },
        .{ 'H', "resize-left" },
        .{ 'J', "resize-down" },
        .{ 'K', "resize-up" },
        .{ 'L', "resize-right" },
        .{ 'c', "new-window" },
        .{ 'n', "next-window" },
        .{ 'p', "previous-window" },
        .{ '1', "select-window 1" },
        .{ '2', "select-window 2" },
        .{ '3', "select-window 3" },
        .{ '4', "select-window 4" },
        .{ '5', "select-window 5" },
        .{ '6', "select-window 6" },
        .{ '7', "select-window 7" },
        .{ '8', "select-window 8" },
        .{ '9', "select-window 9" },
        .{ ';', "last-pane" },
        .{ 'z', "zoom" },
        .{ '[', "copy-mode" },
        .{ 'x', "kill-pane" },
        .{ 'd', "detach" },
        .{ 'u', "next-unread" },
        .{ 'i', "inspect" },
        .{ 'o', "home" },
        .{ 0x0f, "last-space" },
        .{ 'A', "sidebar" },
        .{ 'P', "pin" },
        .{ 'G', "pin-global" },
    };
    for (table) |e| k.set(e[0], e[1]);
    return k;
}

test "defaults carry no program" {
    const k = defaults();
    for (k.slots) |b| try std.testing.expect(b.verb != .popup);
    try std.testing.expectEqual(Verb.home, k.get('o').verb);
    try std.testing.expectEqual(Verb.split_right, k.get('v').verb);
    try std.testing.expectEqual(Verb.last_space, k.get(0x0f).verb);
    try std.testing.expectEqualStrings("3", k.arg(k.get('3')));
}

test "rows bind, rebind, and unbind over the defaults" {
    var k = defaults();
    k.set('g', "popup 72x86@124x48 grim");
    k.set('s', "popup rook pick");
    k.set(0x0f, "home");
    k.set('=', "split-down");
    k.set('t', "zoom");
    k.set('x', "");
    k.set('q', "no-such-verb");
    try std.testing.expectEqual(Verb.popup, k.get('g').verb);
    try std.testing.expectEqualStrings("\x1f72x86@124x48\x1fgrim", k.arg(k.get('g')));
    try std.testing.expectEqualStrings("rook pick", k.arg(k.get('s')));
    try std.testing.expectEqual(Verb.home, k.get(0x0f).verb);
    try std.testing.expectEqual(Verb.split_down, k.get('=').verb);
    try std.testing.expectEqual(Verb.none, k.get('x').verb);
    try std.testing.expectEqual(Verb.none, k.get('q').verb);
    // the first key bound to it, in byte order
    try std.testing.expectEqual(@as(?u8, 't'), k.keyFor(.zoom));
    // x was kill-pane's only key, and it is unbound
    try std.testing.expectEqual(@as(?u8, null), k.keyFor(.kill_pane));
}

test "a popup whose first word is not a size keeps it" {
    var k: Keys = .{};
    k.set('e', "popup 12 monkeys");
    try std.testing.expectEqualStrings("12 monkeys", k.arg(k.get('e')));
    k.set('f', "popup 80x90");
    try std.testing.expectEqualStrings("80x90", k.arg(k.get('f')));
    k.set('b', "select-window 0");
    try std.testing.expectEqual(Verb.none, k.get('b').verb);
}

test "key names" {
    try std.testing.expectEqual(@as(?u8, 0x0f), parseKey("C-o"));
    try std.testing.expectEqual(@as(?u8, 0x0f), parseKey("c-O"));
    try std.testing.expectEqual(@as(?u8, '|'), parseKey("|"));
    try std.testing.expectEqual(@as(?u8, null), parseKey("C-1"));
    var b: [4]u8 = undefined;
    try std.testing.expectEqualStrings("C-o", keyName(0x0f, &b));
    try std.testing.expectEqualStrings("g", keyName('g', &b));
}
