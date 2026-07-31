//! A keystroke, encoded for a pty.
//!
//! This replaces the passthrough that used to live inline in
//! monitorCallback: NSEvent's cooked `characters`, plus four arrows
//! keyed off their keycodes, and nothing else. That was fine while
//! rook's own chrome was the only reader. It stopped being fine the
//! moment real programs started asking real questions — shift+Tab
//! reached Claude Code as 0x19 (macOS's NSBackTabCharacter) instead of
//! `ESC [ Z`, so its mode cycle simply never fired, and every modified
//! arrow arrived stripped of its modifier.
//!
//! Nothing here touches AppKit. The monitor pulls four facts off the
//! event — keycode, modifier flags, the cooked text, the codepoint with
//! modifiers ignored — and everything after that is a pure function of
//! those four plus the terminal's own modes. That is the whole point:
//! key encoding is a table of exact byte sequences, and a table you
//! can't test without a window is a table nobody checks.
//!
//! The tables are ported from ghostty's `src/input/key_encode.zig` and
//! `src/input/function_keys.zig`, which is the oracle rook already
//! trusts for its terminal half — but they are NOT reachable from the
//! `ghostty-vt` module (lib_vt.zig publishes the emulator, not the
//! input side), so they are transcribed rather than imported. The tests
//! at the bottom pin the sequences that transcription has to preserve.
//!
//! Two deliberate divergences from ghostty, both macOS-shaped:
//!
//!   * Option is a compose key, not Alt, for keys that produce text —
//!     the same as ghostty's default `macos-option-as-alt = false`. The
//!     IME gets first refusal on those upstream of here and hands back
//!     composed text. Option IS honoured as Alt on the named keys
//!     (arrows, backspace, tab), where it composes nothing and where
//!     alt+backspace and alt+arrow are load-bearing shell motions.
//!
//!   * For a key that produces text, macOS has already cooked the
//!     control combinations: ctrl+C arrives as 0x03 without our help.
//!     So `ctrlSeq` is a FALLBACK here rather than the primary path,
//!     which keeps every combination that works today working exactly
//!     as it does today.
//!
//! What is not implemented, stated plainly rather than discovered
//! later: the kitty protocol's key-RELEASE events (flag 2) and
//! alternate-key reporting (flag 4). Releases are not a limitation of
//! this file — the event monitor subscribes to NSEventMaskKeyDown
//! alone, so a release never reaches rook at all. See `Kitty` below.

const std = @import("std");

/// The modifiers that change an encoding. Bit order is the xterm
/// parameter order, so `int()` is already the bitmask that goes on the
/// wire once you add one — see `seq`.
pub const Mods = packed struct(u4) {
    shift: bool = false,
    alt: bool = false,
    ctrl: bool = false,
    super: bool = false,

    pub fn int(self: Mods) u4 {
        return @bitCast(self);
    }

    pub fn empty(self: Mods) bool {
        return self.int() == 0;
    }

    /// The modifier parameter as it appears in a sequence: the bitmask
    /// plus one, so "no modifiers" is 1 and not 0. Shared by the xterm
    /// CSI forms and by kitty, which uses the same low four bits.
    pub fn seq(self: Mods) u16 {
        return @as(u16, self.int()) + 1;
    }
};

/// A key rook knows by name. Everything else is `.text`: whatever the
/// keyboard layout produced, which is the layout's business and not
/// ours.
pub const Key = enum {
    text,
    up,
    down,
    left,
    right,
    home,
    end,
    page_up,
    page_down,
    insert,
    delete,
    backspace,
    tab,
    enter,
    escape,
    keypad_enter,
    f1,
    f2,
    f3,
    f4,
    f5,
    f6,
    f7,
    f8,
    f9,
    f10,
    f11,
    f12,
};

/// macOS virtual keycodes (Carbon `Events.h`) for the named keys. The
/// keycode is the right identity here and the character is not: it is
/// what the physical key IS, before a layout or a modifier has had an
/// opinion. Shift+Tab is the case in point — as a character it is
/// 0x19, which encodes nothing anyone wants.
pub fn keyFromKeycode(kc: u16) Key {
    return switch (kc) {
        36 => .enter,
        48 => .tab,
        51 => .backspace,
        53 => .escape,
        76 => .keypad_enter,
        // 114 is Help on an Apple keyboard and Insert on a PC one.
        114 => .insert,
        115 => .home,
        116 => .page_up,
        117 => .delete,
        119 => .end,
        121 => .page_down,
        123 => .left,
        124 => .right,
        125 => .down,
        126 => .up,
        122 => .f1,
        120 => .f2,
        99 => .f3,
        118 => .f4,
        96 => .f5,
        97 => .f6,
        98 => .f7,
        100 => .f8,
        101 => .f9,
        109 => .f10,
        103 => .f11,
        111 => .f12,
        else => .text,
    };
}

/// The kitty keyboard protocol flags, as the program pushed them.
///
/// rook advertises this protocol whether it means to or not: ghostty-vt
/// answers `CSI ? u` and honours `CSI > u` pushes on rook's behalf, so
/// a program that asks is TOLD yes. Before this file, nothing then
/// encoded it — the answer was a promise rook did not keep.
///
/// `report_events` and `report_alternates` are accepted and ignored.
/// Releases cannot be honoured at all (the monitor sees key-down only);
/// alternates are additional detail a program can do without, and the
/// spec's own reading is that a terminal reports what it knows.
pub const Kitty = packed struct(u5) {
    disambiguate: bool = false,
    report_events: bool = false,
    report_alternates: bool = false,
    report_all: bool = false,
    report_associated: bool = false,

    pub fn int(self: Kitty) u5 {
        return @bitCast(self);
    }
};

/// The terminal's own state, which decides between two spellings of
/// the same keystroke. A pty answers this; rook's chrome does not,
/// which is why chrome gets the defaults.
pub const Modes = struct {
    /// DECCKM. Arrows speak SS3 (`ESC O A`) instead of CSI (`ESC [ A`).
    cursor_keys: bool = false,
    kitty: Kitty = .{},
};

pub const Event = struct {
    key: Key = .text,
    mods: Mods = .{},
    /// NSEvent `characters`: what the layout produced, already cooked
    /// by macOS. Control combinations arrive as their C0 byte.
    text: []const u8 = "",
    /// NSEvent `charactersIgnoringModifiers` as a codepoint, or 0.
    /// AppKit still applies shift here, so ctrl+shift+c gives 'C'.
    unshifted: u21 = 0,
};

/// Longest sequence this can produce, with room to spare: the widest
/// real case is a kitty sequence carrying associated text.
pub const max_len = 64;

/// Encode one key press. The result borrows `buf` or points at static
/// data, so copy it if it has to outlive the call.
pub fn encode(buf: []u8, ev: Event, modes: Modes) []const u8 {
    if (modes.kitty.int() != 0) return kitty(buf, ev, modes);
    return legacy(buf, ev, modes);
}

// -- legacy -----------------------------------------------------------

fn legacy(buf: []u8, ev: Event, modes: Modes) []const u8 {
    if (ev.key != .text) return functionKey(buf, ev.key, ev.mods, modes);

    // macOS cooked it already — see the header. This is the path every
    // ordinary keystroke takes, and it is byte-for-byte what rook sent
    // before this file existed.
    if (ev.text.len > 0) return ev.text;

    // Nothing came back from the layout. The only thing left worth
    // sending is a control combination macOS declined to cook, which
    // is where ctrl+<digit> and the punctuation ctrl-seqs live.
    if (ev.mods.ctrl and ev.unshifted != 0) {
        if (ctrlSeq(ev.unshifted, ev.mods)) |c| {
            buf[0] = c;
            return buf[0..1];
        }
        return fmt(buf, "\x1b[{d};{d}u", .{ csiUCode(ev.unshifted), ev.mods.seq() });
    }
    return "";
}

fn functionKey(buf: []u8, key: Key, mods: Mods, modes: Modes) []const u8 {
    return switch (key) {
        // Unreachable in practice; `.text` is handled by the caller.
        .text => "",

        .up => cursorKey(buf, mods, modes.cursor_keys, 'A'),
        .down => cursorKey(buf, mods, modes.cursor_keys, 'B'),
        .right => cursorKey(buf, mods, modes.cursor_keys, 'C'),
        .left => cursorKey(buf, mods, modes.cursor_keys, 'D'),
        .home => cursorKey(buf, mods, modes.cursor_keys, 'H'),
        .end => cursorKey(buf, mods, modes.cursor_keys, 'F'),

        .insert => tildeKey(buf, mods, 2),
        .delete => tildeKey(buf, mods, 3),
        .page_up => tildeKey(buf, mods, 5),
        .page_down => tildeKey(buf, mods, 6),

        // F1/F2/F4 keep their SS3 spelling unmodified and take the
        // CSI 1;<mods> form once anything is held. F3 is the odd one
        // out in xterm and becomes a tilde key.
        .f1 => ss3Key(buf, mods, 'P'),
        .f2 => ss3Key(buf, mods, 'Q'),
        .f3 => if (mods.empty()) "\x1bOR" else tildeKey(buf, mods, 13),
        .f4 => ss3Key(buf, mods, 'S'),
        .f5 => tildeKey(buf, mods, 15),
        .f6 => tildeKey(buf, mods, 17),
        .f7 => tildeKey(buf, mods, 18),
        .f8 => tildeKey(buf, mods, 19),
        .f9 => tildeKey(buf, mods, 20),
        .f10 => tildeKey(buf, mods, 21),
        .f11 => tildeKey(buf, mods, 23),
        .f12 => tildeKey(buf, mods, 24),

        // THE bug this file was opened for. Shift+Tab is `ESC [ Z` and
        // has been since VT-something; macOS calls it 0x19 and rook
        // used to forward that verbatim.
        .tab => if (mods.empty())
            "\t"
        else if (mods.int() == (Mods{ .shift = true }).int())
            "\x1b[Z"
        else if (mods.int() == (Mods{ .alt = true }).int())
            "\x1b\t"
        else
            modifyOtherKey(buf, mods, 9),

        // Every row of ghostty's backspace table collapses to this:
        // ctrl picks 0x08 over 0x7f, alt prefixes an ESC, and nothing
        // else in the table moves. (DECBKM would swap the first pair;
        // rook does not track it, and neither does anything that has
        // asked.)
        .backspace => blk: {
            var n: usize = 0;
            if (mods.alt) {
                buf[n] = 0x1b;
                n += 1;
            }
            buf[n] = if (mods.ctrl) 0x08 else 0x7f;
            break :blk buf[0 .. n + 1];
        },

        .enter, .keypad_enter => if (mods.empty())
            "\r"
        else if (mods.int() == (Mods{ .alt = true }).int())
            "\x1b\r"
        else
            modifyOtherKey(buf, mods, 13),

        .escape => if (mods.empty())
            "\x1b"
        else if (mods.int() == (Mods{ .alt = true }).int())
            "\x1b\x1b"
        else
            modifyOtherKey(buf, mods, 27),
    };
}

/// Arrows, Home and End: SS3 when the application cursor mode is on and
/// nothing is held, CSI otherwise, and the `1;<mods>` form the moment a
/// modifier joins in. The modified form is the same in both modes —
/// DECCKM only ever moved the unmodified spelling.
fn cursorKey(buf: []u8, mods: Mods, app: bool, final: u8) []const u8 {
    if (mods.empty()) return if (app)
        fmt(buf, "\x1bO{c}", .{final})
    else
        fmt(buf, "\x1b[{c}", .{final});
    return fmt(buf, "\x1b[1;{d}{c}", .{ mods.seq(), final });
}

fn tildeKey(buf: []u8, mods: Mods, code: u16) []const u8 {
    if (mods.empty()) return fmt(buf, "\x1b[{d}~", .{code});
    return fmt(buf, "\x1b[{d};{d}~", .{ code, mods.seq() });
}

fn ss3Key(buf: []u8, mods: Mods, final: u8) []const u8 {
    if (mods.empty()) return fmt(buf, "\x1bO{c}", .{final});
    return fmt(buf, "\x1b[1;{d}{c}", .{ mods.seq(), final });
}

/// xterm's `CSI 27;<mods>;<code>~`, which is how tab/enter/escape carry
/// a modifier that has no older spelling. Not gated on modifyOtherKeys
/// here: ghostty's table reaches these rows unconditionally once the
/// shorter forms above have had their turn.
fn modifyOtherKey(buf: []u8, mods: Mods, code: u16) []const u8 {
    return fmt(buf, "\x1b[27;{d};{d}~", .{ mods.seq(), code });
}

/// The C0 byte for ctrl+<char>, or null if there isn't one. Ported from
/// ghostty's ctrlSeq, which took it from kitty. `i`, `m` and `[` are
/// absent on purpose — fixterms routes those through CSI u so a program
/// can tell ctrl+i from Tab.
fn ctrlSeq(cp: u21, mods: Mods) ?u8 {
    if (!mods.ctrl) return null;
    if (cp > 0x7f) return null;

    var m = mods;
    // Alt has no say in whether this is a control sequence; the ESC
    // prefix is a separate decision made by the caller.
    m.alt = false;

    const char: u8 = @intCast(cp);

    // Outside the letters, shift is how you TYPED the character rather
    // than a modifier of it, so it stops counting. `@` is fixterms'
    // named exception.
    if (m.shift and (char < 'A' or char > 'Z') and char != '@') m.shift = false;

    // A shifted letter keeps its shift, which means the check below
    // fails and we fall through to CSI u — that is what lets a program
    // tell ctrl+m from ctrl+shift+m.
    m.ctrl = false;
    if (m.int() != 0) return null;

    return switch (char) {
        ' ' => 0,
        '/' => 31,
        '0' => 48,
        '1' => 49,
        '2' => 0,
        '3' => 27,
        '4' => 28,
        '5' => 29,
        '6' => 30,
        '7' => 31,
        '8' => 127,
        '9' => 57,
        '?' => 127,
        '@' => 0,
        '\\' => 28,
        ']' => 29,
        '^' => 30,
        '_' => 31,
        'a'...'h', 'j'...'l', 'n'...'z' => char - 'a' + 1,
        '~' => 30,
        else => null,
    };
}

/// CSI u and kitty both report the key you pressed, not the glyph shift
/// made of it, so an uppercase letter reports as lowercase with the
/// shift modifier alongside.
fn csiUCode(cp: u21) u21 {
    if (cp >= 'A' and cp <= 'Z') return cp + 32;
    return cp;
}

// -- kitty ------------------------------------------------------------

const KittyEntry = struct { code: u21, final: u8 };

/// The functional-key half of kitty's table
/// (https://sw.kovidgoyal.net/kitty/keyboard-protocol/). Ported from
/// ghostty's `src/input/kitty.zig`, itself ported from foot.
fn kittyEntry(key: Key, unshifted: u21) ?KittyEntry {
    return switch (key) {
        .escape => .{ .code = 27, .final = 'u' },
        .enter => .{ .code = 13, .final = 'u' },
        .tab => .{ .code = 9, .final = 'u' },
        .backspace => .{ .code = 127, .final = 'u' },
        .insert => .{ .code = 2, .final = '~' },
        .delete => .{ .code = 3, .final = '~' },
        .left => .{ .code = 1, .final = 'D' },
        .right => .{ .code = 1, .final = 'C' },
        .up => .{ .code = 1, .final = 'A' },
        .down => .{ .code = 1, .final = 'B' },
        .page_up => .{ .code = 5, .final = '~' },
        .page_down => .{ .code = 6, .final = '~' },
        .home => .{ .code = 1, .final = 'H' },
        .end => .{ .code = 1, .final = 'F' },
        .f1 => .{ .code = 1, .final = 'P' },
        .f2 => .{ .code = 1, .final = 'Q' },
        .f3 => .{ .code = 13, .final = '~' },
        .f4 => .{ .code = 1, .final = 'S' },
        .f5 => .{ .code = 15, .final = '~' },
        .f6 => .{ .code = 17, .final = '~' },
        .f7 => .{ .code = 18, .final = '~' },
        .f8 => .{ .code = 19, .final = '~' },
        .f9 => .{ .code = 20, .final = '~' },
        .f10 => .{ .code = 21, .final = '~' },
        .f11 => .{ .code = 23, .final = '~' },
        .f12 => .{ .code = 24, .final = '~' },
        .keypad_enter => .{ .code = 57414, .final = 'u' },
        .text => if (unshifted != 0)
            .{ .code = csiUCode(unshifted), .final = 'u' }
        else
            null,
    };
}

fn kitty(buf: []u8, ev: Event, modes: Modes) []const u8 {
    const f = modes.kitty;

    const entry = kittyEntry(ev.key, ev.unshifted) orelse return ev.text;

    if (!f.report_all) {
        // The spec carves these three out by name: unmodified Enter,
        // Tab and Backspace keep their legacy bytes so that a shell is
        // still usable after a program dies without popping its flags.
        if (ev.mods.empty()) switch (ev.key) {
            .enter, .keypad_enter => return "\r",
            .tab => return "\t",
            .backspace => return "\x7f",
            else => {},
        };

        // Ordinary typing stays ordinary typing.
        if (ev.mods.empty() and ev.text.len > 0 and !isControlText(ev.text))
            return ev.text;
    }

    if (entry.final != 'u' and entry.final != '~') {
        // The "special" form: arrows, Home/End and F1/F2/F4 keep their
        // CSI final byte and carry modifiers in the 1;<mods> slot.
        if (ev.mods.empty()) return fmt(buf, "\x1b[{c}", .{entry.final});
        return fmt(buf, "\x1b[1;{d}{c}", .{ ev.mods.seq(), entry.final });
    }

    var n: usize = 0;
    n += (fmt(buf[n..], "\x1b[{d}", .{entry.code})).len;

    var emitted_mods = false;
    if (ev.mods.seq() > 1) {
        n += (fmt(buf[n..], ";{d}", .{ev.mods.seq()})).len;
        emitted_mods = true;
    }

    // Associated text (flag 16): the codepoints this key would have
    // typed, so a program can take both the key and the character from
    // one sequence. Control bytes are not text and are skipped.
    if (f.report_associated and !preventsText(ev.mods) and ev.text.len > 0) {
        var count: usize = 0;
        const view = std.unicode.Utf8View.init(ev.text) catch return buf[0..n];
        var it = view.iterator();
        while (it.nextCodepoint()) |cp| {
            if (isControlCp(cp)) continue;
            if (count == 0) {
                if (!emitted_mods) {
                    buf[n] = ';';
                    n += 1;
                }
                buf[n] = ';';
                n += 1;
            } else {
                buf[n] = ':';
                n += 1;
            }
            n += (fmt(buf[n..], "{d}", .{cp})).len;
            count += 1;
        }
    }

    buf[n] = entry.final;
    return buf[0 .. n + 1];
}

fn preventsText(mods: Mods) bool {
    // Option is not Alt for text keys on macOS, so it does not prevent
    // text either — the same divergence as everywhere else in here.
    return mods.ctrl or mods.super;
}

fn isControlCp(cp: u21) bool {
    return cp < 0x20 or cp == 0x7f;
}

fn isControlText(s: []const u8) bool {
    return s.len == 1 and isControlCp(s[0]);
}

/// bufPrint that cannot fail in practice: every format string in this
/// file is bounded well under `max_len`. A caller that shrank the
/// buffer gets an empty sequence rather than a crash on a keystroke.
fn fmt(buf: []u8, comptime f: []const u8, args: anytype) []const u8 {
    return std.fmt.bufPrint(buf, f, args) catch "";
}

// -- tests ------------------------------------------------------------
//
// The oracle is ghostty's tables, transcribed above; these pin the
// transcription. Where a sequence is famous enough to check against a
// second source (shift+Tab, ctrl+arrow, DECCKM) it was also read out of
// xterm's ctlseqs and kitty's protocol page.

const testing = std.testing;

fn expectEncode(expected: []const u8, ev: Event, modes: Modes) !void {
    var buf: [max_len]u8 = undefined;
    try testing.expectEqualStrings(expected, encode(&buf, ev, modes));
}

test "shift+tab is CSI Z, not macOS's 0x19" {
    // The reported bug: Claude Code cycles its mode on ESC[Z and
    // ignores 0x19, which is what NSEvent.characters hands over.
    try expectEncode("\x1b[Z", .{
        .key = .tab,
        .mods = .{ .shift = true },
        .text = "\x19",
    }, .{});
}

test "tab without modifiers is still a tab" {
    try expectEncode("\t", .{ .key = .tab, .text = "\t" }, .{});
}

test "tab with the modifiers that have no older spelling" {
    try expectEncode("\x1b\t", .{ .key = .tab, .mods = .{ .alt = true } }, .{});
    try expectEncode("\x1b[27;5;9~", .{ .key = .tab, .mods = .{ .ctrl = true } }, .{});
    try expectEncode("\x1b[27;6;9~", .{
        .key = .tab,
        .mods = .{ .ctrl = true, .shift = true },
    }, .{});
}

test "arrows follow DECCKM only while unmodified" {
    try expectEncode("\x1b[A", .{ .key = .up }, .{});
    try expectEncode("\x1bOA", .{ .key = .up }, .{ .cursor_keys = true });

    // A modifier collapses both modes onto the one CSI form.
    try expectEncode("\x1b[1;5A", .{ .key = .up, .mods = .{ .ctrl = true } }, .{});
    try expectEncode("\x1b[1;5A", .{
        .key = .up,
        .mods = .{ .ctrl = true },
    }, .{ .cursor_keys = true });
}

test "modifier parameter is the xterm bitmask plus one" {
    try expectEncode("\x1b[1;2D", .{ .key = .left, .mods = .{ .shift = true } }, .{});
    try expectEncode("\x1b[1;3D", .{ .key = .left, .mods = .{ .alt = true } }, .{});
    try expectEncode("\x1b[1;4D", .{
        .key = .left,
        .mods = .{ .shift = true, .alt = true },
    }, .{});
    try expectEncode("\x1b[1;5D", .{ .key = .left, .mods = .{ .ctrl = true } }, .{});
    try expectEncode("\x1b[1;9D", .{ .key = .left, .mods = .{ .super = true } }, .{});
}

test "home and end share the arrow shape" {
    try expectEncode("\x1b[H", .{ .key = .home }, .{});
    try expectEncode("\x1bOF", .{ .key = .end }, .{ .cursor_keys = true });
    try expectEncode("\x1b[1;5H", .{ .key = .home, .mods = .{ .ctrl = true } }, .{});
}

test "the tilde keys" {
    try expectEncode("\x1b[2~", .{ .key = .insert }, .{});
    try expectEncode("\x1b[3~", .{ .key = .delete }, .{});
    try expectEncode("\x1b[5~", .{ .key = .page_up }, .{});
    try expectEncode("\x1b[6~", .{ .key = .page_down }, .{});
    try expectEncode("\x1b[3;5~", .{ .key = .delete, .mods = .{ .ctrl = true } }, .{});
}

test "function keys, including xterm's odd F3" {
    try expectEncode("\x1bOP", .{ .key = .f1 }, .{});
    try expectEncode("\x1bOR", .{ .key = .f3 }, .{});
    try expectEncode("\x1b[15~", .{ .key = .f5 }, .{});
    try expectEncode("\x1b[24~", .{ .key = .f12 }, .{});

    // F3 modified is a tilde key, F1/F2/F4 modified are not.
    try expectEncode("\x1b[13;5~", .{ .key = .f3, .mods = .{ .ctrl = true } }, .{});
    try expectEncode("\x1b[1;5P", .{ .key = .f1, .mods = .{ .ctrl = true } }, .{});
}

test "backspace: ctrl picks the byte, alt prefixes the escape" {
    try expectEncode("\x7f", .{ .key = .backspace }, .{});
    try expectEncode("\x7f", .{ .key = .backspace, .mods = .{ .shift = true } }, .{});
    try expectEncode("\x08", .{ .key = .backspace, .mods = .{ .ctrl = true } }, .{});
    try expectEncode("\x1b\x7f", .{ .key = .backspace, .mods = .{ .alt = true } }, .{});
    try expectEncode("\x1b\x08", .{
        .key = .backspace,
        .mods = .{ .alt = true, .ctrl = true },
    }, .{});
}

test "enter and escape" {
    try expectEncode("\r", .{ .key = .enter }, .{});
    try expectEncode("\x1b\r", .{ .key = .enter, .mods = .{ .alt = true } }, .{});
    try expectEncode("\x1b[27;2;13~", .{ .key = .enter, .mods = .{ .shift = true } }, .{});
    try expectEncode("\x1b", .{ .key = .escape }, .{});
    try expectEncode("\x1b\x1b", .{ .key = .escape, .mods = .{ .alt = true } }, .{});
}

test "text macOS already cooked passes through untouched" {
    // The path every ordinary keystroke takes. ctrl+C is 0x03 before it
    // reaches us and must stay 0x03 — this is the behaviour that was
    // working before the encoder existed and must not move.
    try expectEncode("a", .{ .key = .text, .text = "a", .unshifted = 'a' }, .{});
    try expectEncode("\x03", .{
        .key = .text,
        .mods = .{ .ctrl = true },
        .text = "\x03",
        .unshifted = 'c',
    }, .{});
    try expectEncode("é", .{ .key = .text, .text = "é" }, .{});
}

test "ctrl with no text from the layout falls back to a control sequence" {
    try expectEncode("\x03", .{
        .key = .text,
        .mods = .{ .ctrl = true },
        .unshifted = 'c',
    }, .{});
    // fixterms keeps i/m/[ out of the C0 table so they stay tellable
    // apart from tab/enter/escape.
    try expectEncode("\x1b[105;5u", .{
        .key = .text,
        .mods = .{ .ctrl = true },
        .unshifted = 'i',
    }, .{});
    // A shifted letter is reported lowercase with shift alongside.
    try expectEncode("\x1b[109;6u", .{
        .key = .text,
        .mods = .{ .ctrl = true, .shift = true },
        .unshifted = 'M',
    }, .{});
}

test "kitty: disambiguate leaves plain typing alone" {
    const k: Modes = .{ .kitty = .{ .disambiguate = true } };
    try expectEncode("a", .{ .key = .text, .text = "a", .unshifted = 'a' }, k);
    // The three keys the spec carves out by name.
    try expectEncode("\r", .{ .key = .enter }, k);
    try expectEncode("\t", .{ .key = .tab }, k);
    try expectEncode("\x7f", .{ .key = .backspace }, k);
}

test "kitty: modified keys become CSI u" {
    const k: Modes = .{ .kitty = .{ .disambiguate = true } };
    try expectEncode("\x1b[99;5u", .{
        .key = .text,
        .mods = .{ .ctrl = true },
        .text = "\x03",
        .unshifted = 'c',
    }, k);
    try expectEncode("\x1b[9;2u", .{ .key = .tab, .mods = .{ .shift = true } }, k);
    try expectEncode("\x1b[13;2u", .{ .key = .enter, .mods = .{ .shift = true } }, k);
}

test "kitty: arrows keep their final byte" {
    const k: Modes = .{ .kitty = .{ .disambiguate = true } };
    try expectEncode("\x1b[A", .{ .key = .up }, k);
    try expectEncode("\x1b[1;5A", .{ .key = .up, .mods = .{ .ctrl = true } }, k);
    try expectEncode("\x1b[3;5~", .{ .key = .delete, .mods = .{ .ctrl = true } }, k);
}

test "kitty: report_all sends even the carved-out keys as escapes" {
    const k: Modes = .{ .kitty = .{ .disambiguate = true, .report_all = true } };
    try expectEncode("\x1b[13u", .{ .key = .enter }, k);
    try expectEncode("\x1b[9u", .{ .key = .tab }, k);
    try expectEncode("\x1b[127u", .{ .key = .backspace }, k);
    try expectEncode("\x1b[97u", .{ .key = .text, .text = "a", .unshifted = 'a' }, k);
}

test "kitty: associated text rides along when asked for" {
    const k: Modes = .{ .kitty = .{
        .disambiguate = true,
        .report_all = true,
        .report_associated = true,
    } };
    // No modifiers: the text slot needs both separators.
    try expectEncode("\x1b[97;;97u", .{
        .key = .text,
        .text = "a",
        .unshifted = 'a',
    }, k);
    // With modifiers the first separator is already there.
    try expectEncode("\x1b[97;2;65u", .{
        .key = .text,
        .mods = .{ .shift = true },
        .text = "A",
        .unshifted = 'a',
    }, k);
    // Ctrl prevents text: the byte is a control code, not a character.
    try expectEncode("\x1b[99;5u", .{
        .key = .text,
        .mods = .{ .ctrl = true },
        .text = "\x03",
        .unshifted = 'c',
    }, k);
}

test "keycodes name the keys the character cannot" {
    try testing.expectEqual(Key.tab, keyFromKeycode(48));
    try testing.expectEqual(Key.up, keyFromKeycode(126));
    try testing.expectEqual(Key.f3, keyFromKeycode(99));
    try testing.expectEqual(Key.backspace, keyFromKeycode(51));
    try testing.expectEqual(Key.text, keyFromKeycode(0)); // 'a'
}
