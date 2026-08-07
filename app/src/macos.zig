//! AppKit + Metal shell for rook. Pure Zig via zig-objc — no Swift, no nib.
//! The window owns a CAMetalLayer; a CVDisplayLink drives rendering off the
//! main thread (ghostty's renderer-thread shape). The frame is a SCENE:
//! a binary split tree of panes (pty → ghostty-vt → RenderState each),
//! drawn as N grid regions + separator rects from one pipeline.
//!
//! Threading: draw_lock serializes every scene reader/mutator — display
//! link, input kick, key monitor, resize observer, ctl socket. Lock
//! order is always draw_lock → session mutex, and the reader thread
//! never holds its session mutex when it takes draw_lock (via kick).

const std = @import("std");
const objc = @import("objc");
const vt = @import("ghostty-vt");
const sessionpkg = @import("session.zig");
const ptypkg = @import("pty.zig");
const renderpkg = @import("render.zig");
const panespkg = @import("panes.zig");
const monitorpkg = @import("monitor.zig");
const procmon = @import("procmon.zig");
const diskscan = @import("diskscan.zig");
const editorpkg = @import("editor.zig");
const fuzzy = @import("fuzzy.zig");
const workspacespkg = @import("workspaces.zig");
const registrypkg = @import("registry.zig");
const pastepkg = @import("paste.zig");
const themepkg = @import("theme.zig");
const cfgpkg = @import("config.zig");
const filelistpkg = @import("filelist.zig");
const searchpkg = @import("search.zig");
const lsppkg = @import("lsp.zig");
const plugpkg = @import("plugins.zig");
const envpkg = @import("envapply.zig");
const lspmgrpkg = @import("lspmgr.zig");
const grammarpkg = @import("grammar.zig");
const langpkg = @import("language.zig");
const syntaxpkg = @import("syntax.zig");
const docspkg = @import("docs.zig");
const bufferpkg = @import("buffer.zig");
const uipkg = @import("ui.zig");
const stats = @import("stats.zig");
const keyenc = @import("keyenc.zig");

extern "c" fn CACurrentMediaTime() f64;
/// AppKit's system alert sound — the audible half of the bell.
extern "c" fn NSBeep() void;

const NSPoint = extern struct { x: f64, y: f64 };
const NSSize = extern struct { width: f64, height: f64 };
const NSRect = extern struct { origin: NSPoint, size: NSSize };
const MTLClearColor = extern struct { r: f64, g: f64, b: f64, a: f64 };

extern "c" fn MTLCreateSystemDefaultDevice() objc.c.id;
extern "c" fn proc_pidinfo(pid: c_int, flavor: c_int, arg: u64, buffer: *anyopaque, buffersize: c_int) c_int;
const PROC_PIDVNODEPATHINFO: c_int = 9;
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
extern "c" fn getcwd(buf: [*]u8, size: usize) ?[*:0]const u8;
/// Needed because paneCwd reads the KERNEL's path (already resolved) while
/// an asker sends whatever its shell thinks its cwd is. On macOS /tmp is a
/// symlink to /private/tmp, so those two disagree for any path under it and
/// a prefix match silently never fires. Buffer must be >= PATH_MAX.
extern "c" fn realpath(path: [*:0]const u8, resolved: [*]u8) ?[*:0]const u8;
extern "c" fn _exit(code: c_int) noreturn;

// libdispatch, for hopping to the main thread from the ctl socket.
// dispatch_get_main_queue() is a macro for &_dispatch_main_q.
extern "c" var _dispatch_main_q: u8;
extern "c" fn dispatch_async_f(queue: *anyopaque, ctx: ?*anyopaque, work: *const fn (?*anyopaque) callconv(.c) void) void;

// CVDisplayLink (CoreVideo). Deprecated in recent macOS but present and the
// simplest C-callable frame clock; swap for CAMetalDisplayLink later.
const CVDisplayLinkRef = ?*anyopaque;
extern "c" fn CVDisplayLinkCreateWithActiveCGDisplays(out: *CVDisplayLinkRef) i32;
extern "c" fn CVDisplayLinkSetOutputCallback(link: CVDisplayLinkRef, cb: *const fn (CVDisplayLinkRef, ?*const anyopaque, ?*const anyopaque, u64, ?*u64, ?*anyopaque) callconv(.c) i32, ctx: ?*anyopaque) i32;
extern "c" fn CVDisplayLinkStart(link: CVDisplayLinkRef) i32;
extern "c" fn CVDisplayLinkGetActualOutputVideoRefreshPeriod(link: CVDisplayLinkRef) f64;
extern "c" fn CVDisplayLinkSetCurrentCGDisplay(link: CVDisplayLinkRef, display: u32) i32;

const NSEventMaskKeyDown: u64 = 1 << 10;
const NSEventMaskLeftMouseDown: u64 = 1 << 1;
const NSEventMaskLeftMouseUp: u64 = 1 << 2;
const NSEventMaskLeftMouseDragged: u64 = 1 << 6;
const NSEventMaskScrollWheel: u64 = 1 << 22;
const flag_shift: u64 = 1 << 17;
const flag_ctrl: u64 = 1 << 18;
const flag_alt: u64 = 1 << 19;
const flag_cmd: u64 = 1 << 20;

const win_w: f64 = 1024;
const win_h: f64 = 700;

/// The active theme (theme.zig builtins, picked by config). Set once
/// in App.create before any session or draw exists; read everywhere.
var th: themepkg.Theme = themepkg.default;

/// Startup phase timings, µs. Written once (create() and the ctl bind),
/// read by the `boottime` ctl verb. This exists because config is about
/// to stop being a TOML parse and start being a materialized environment
/// graph — the cost of loading it at launch must stay measured, not
/// assumed, and the e2e `startup` bench reads these numbers.
pub const BootTimes = struct {
    /// CACurrentMediaTime at create() entry — the app's one clock.
    start: f64 = 0,
    config_us: u64 = 0,
    keybinds_us: u64 = 0,
    appkit_us: u64 = 0,
    renderer_us: u64 = 0,
    session_us: u64 = 0,
    create_us: u64 = 0,
    ctl_ready_us: u64 = 0,
};
pub var boot_times: BootTimes = .{};

pub fn usSince(t: f64) u64 {
    const d = (CACurrentMediaTime() - t) * 1_000_000.0;
    return if (d > 0) @intFromFloat(d) else 0;
}

fn rgb3(c: [3]u8) vt.color.RGB {
    return .{ .r = c[0], .g = c[1], .b = c[2] };
}

fn rgb4(c: [4]u8) vt.color.RGB {
    return .{ .r = c[0], .g = c[1], .b = c[2] };
}

/// The emulator default colors for new sessions under this theme.
fn termColors() vt.Terminal.Colors {
    if (!th.override_term) return .default;
    var pal = vt.color.default;
    for (th.ansi, 0..) |c, i| pal[i] = rgb3(c);
    return .{
        .background = .init(rgb3(th.term_bg)),
        .foreground = .init(rgb3(th.term_fg)),
        .cursor = .init(rgb3(th.cursor)),
        .palette = .init(pal),
    };
}

// ---------------------------------------------------------------- IME
//
// A stock NSView returns nil from -inputContext: AppKit's way of saying
// "this thing does not take text". No dead keys (⌥e e → é), no CJK, no
// candidate window — which is where rook was until now. So we define
// one view class of our own that conforms to NSTextInputClient and
// answers the questions an input method asks.
//
// The contract with the key path is deliberate. The IME gets FIRST
// REFUSAL on every unmodified key. If it commits text, that text is the
// input. If it is composing, we hold the preedit and nothing reaches the
// pty. If it turns the key into a Cocoa selector (-insertNewline:,
// -moveUp:, -deleteBackward:), we drop the selector on the floor and
// encode the key ourselves — a terminal wants \r and \x1b[A, not
// AppKit's idea of what a key means. That fallback is why Return, Tab,
// ESC and the arrows behave exactly as they did before this existed.

const NSRange = extern struct { location: u64, length: u64 };
const NSNotFound: u64 = 0x7fff_ffff_ffff_ffff;

/// One window, one app: the input-method callbacks arrive as plain C
/// functions with no context pointer, so the App is a file-scope
/// singleton for them (`th`, the theme, is the same shape).
var ime_app: ?*App = null;
var view_class: ?objc.Class = null;

/// Read an NSString (or the string of an NSAttributedString — the IME
/// sends either) into `buf`. Returns the byte count.
fn imeStringBytes(obj_id: objc.c.id, buf: []u8) usize {
    if (obj_id == null) return 0;
    var s = objc.Object.fromId(obj_id);
    if (s.msgSend(bool, "respondsToSelector:", .{objc.sel("string").value})) {
        s = s.msgSend(objc.Object, "string", .{});
        if (s.value == null) return 0;
    }
    const cstr = s.msgSend(?[*:0]const u8, "UTF8String", .{}) orelse return 0;
    const span = std.mem.span(cstr);
    const n = @min(span.len, buf.len);
    @memcpy(buf[0..n], span[0..n]);
    return n;
}

fn imeAcceptsFirstResponder(_: objc.c.id, _: objc.c.SEL) callconv(.c) bool {
    return true;
}

fn imeHasMarkedText(_: objc.c.id, _: objc.c.SEL) callconv(.c) bool {
    const app = ime_app orelse return false;
    return app.ime_marked_len > 0;
}

fn imeMarkedRange(_: objc.c.id, _: objc.c.SEL) callconv(.c) NSRange {
    const app = ime_app orelse return .{ .location = NSNotFound, .length = 0 };
    if (app.ime_marked_len == 0) return .{ .location = NSNotFound, .length = 0 };
    return .{ .location = 0, .length = app.ime_marked_len };
}

/// We have no document to select in — the pty owns the text. An empty
/// range at the origin is the honest answer and the one every terminal
/// gives.
fn imeSelectedRange(_: objc.c.id, _: objc.c.SEL) callconv(.c) NSRange {
    return .{ .location = 0, .length = 0 };
}

fn imeSetMarkedText(_: objc.c.id, _: objc.c.SEL, text: objc.c.id, _: NSRange, _: NSRange) callconv(.c) void {
    const app = ime_app orelse return;
    app.setMarked(imeStringBytes(text, &app.ime_marked));
}

fn imeUnmarkText(_: objc.c.id, _: objc.c.SEL) callconv(.c) void {
    const app = ime_app orelse return;
    app.setMarked(0);
}

fn imeValidAttributes(_: objc.c.id, _: objc.c.SEL) callconv(.c) objc.c.id {
    return objc.getClass("NSArray").?.msgSend(objc.Object, "array", .{}).value;
}

fn imeAttributedSubstring(_: objc.c.id, _: objc.c.SEL, _: NSRange, _: ?*NSRange) callconv(.c) objc.c.id {
    return null;
}

/// The input method committed text. It cannot go to the pane from here:
/// this runs inside handleEvent:, and the leader machine has to see the
/// bytes first. So it lands in a buffer the key path drains.
fn imeInsertText(_: objc.c.id, _: objc.c.SEL, text: objc.c.id, _: NSRange) callconv(.c) void {
    const app = ime_app orelse return;
    app.ime_text_len = imeStringBytes(text, &app.ime_text);
    app.setMarked(0);
}

fn imeCharacterIndexForPoint(_: objc.c.id, _: objc.c.SEL, _: NSPoint) callconv(.c) u64 {
    return NSNotFound;
}

/// Where to put the candidate window: the focused pane's cursor, in
/// screen coordinates. Get this wrong and a Japanese user types into a
/// list floating over the wrong half of the display.
fn imeFirstRect(_: objc.c.id, _: objc.c.SEL, _: NSRange, actual: ?*NSRange) callconv(.c) NSRect {
    if (actual) |a| a.* = .{ .location = 0, .length = 0 };
    const app = ime_app orelse return .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 0, .height = 0 } };
    return app.cursorScreenRect();
}

/// Deliberately empty. Every key the IME reduces to a Cocoa selector is
/// a key we encode ourselves — see the contract at the top of this
/// section.
fn imeDoCommandBySelector(_: objc.c.id, _: objc.c.SEL, _: objc.c.SEL) callconv(.c) void {}

/// The view class, built once. Fails open: no class means a stock
/// NSView, which is exactly the behavior that shipped before IME.
fn rookViewClass() ?objc.Class {
    if (view_class) |c| return c;
    const cls = objc.allocateClassPair(objc.getClass("NSView").?, "RookTextView") orelse return null;
    // -inputContext checks conformance, not just respondsToSelector:.
    if (objc.getProtocol("NSTextInputClient")) |p| {
        _ = objc.c.class_addProtocol(cls.value, p.value);
    }
    _ = cls.addMethod("acceptsFirstResponder", imeAcceptsFirstResponder);
    _ = cls.addMethod("hasMarkedText", imeHasMarkedText);
    _ = cls.addMethod("markedRange", imeMarkedRange);
    _ = cls.addMethod("selectedRange", imeSelectedRange);
    _ = cls.addMethod("setMarkedText:selectedRange:replacementRange:", imeSetMarkedText);
    _ = cls.addMethod("unmarkText", imeUnmarkText);
    _ = cls.addMethod("validAttributesForMarkedText", imeValidAttributes);
    _ = cls.addMethod("attributedSubstringForProposedRange:actualRange:", imeAttributedSubstring);
    _ = cls.addMethod("insertText:replacementRange:", imeInsertText);
    _ = cls.addMethod("characterIndexForPoint:", imeCharacterIndexForPoint);
    _ = cls.addMethod("firstRectForCharacterRange:actualRange:", imeFirstRect);
    _ = cls.addMethod("doCommandBySelector:", imeDoCommandBySelector);
    objc.registerClassPair(cls);
    view_class = cls;
    return cls;
}

/// Build the blur backdrop and adopt `view` (the Metal layer's host)
/// into it. Returns the view to install as the window's contentView,
/// or null to keep plain alpha. `glass` wants NSGlassEffectView
/// (macOS 26 Liquid Glass); missing class falls back to the boring
/// blur, which is also the recommended default — glass is a foreground
/// material and whole-window use has known staleness bugs (26.2).
fn makeBackdrop(blur: @import("config.zig").Blur, rect: NSRect, view: objc.Object) ?objc.Object {
    switch (blur) {
        .none => return null,
        .blur => {
            const cls = objc.getClass("NSVisualEffectView") orelse return null;
            const bd = cls.msgSend(objc.Object, "alloc", .{})
                .msgSend(objc.Object, "initWithFrame:", .{rect});
            bd.msgSend(void, "setBlendingMode:", .{@as(i64, 0)}); // behindWindow
            bd.msgSend(void, "setMaterial:", .{@as(i64, 21)}); // underWindowBackground
            // Active always: the backdrop must not dim when the window
            // loses key (terminals live unfocused half the day).
            bd.msgSend(void, "setState:", .{@as(i64, 1)});
            bd.msgSend(void, "addSubview:", .{view.value});
            // width | height sizable — track the backdrop through resizes.
            view.msgSend(void, "setAutoresizingMask:", .{@as(u64, 18)});
            std.debug.print("rook: background-blur — NSVisualEffectView behind-window\n", .{});
            return bd;
        },
        .glass, .glass_clear => {
            const cls = objc.getClass("NSGlassEffectView") orelse {
                std.debug.print("rook: NSGlassEffectView unavailable (needs macOS 26) — falling back to blur\n", .{});
                return makeBackdrop(.blur, rect, view);
            };
            const bd = cls.msgSend(objc.Object, "alloc", .{})
                .msgSend(objc.Object, "initWithFrame:", .{rect});
            if (blur == .glass_clear) {
                // Style enum was in flux across Tahoe betas — probe first.
                if (bd.msgSend(bool, "respondsToSelector:", .{objc.sel("setStyle:")}))
                    bd.msgSend(void, "setStyle:", .{@as(i64, 1)}); // clear
            }
            bd.msgSend(void, "setContentView:", .{view.value});
            std.debug.print("rook: background-blur {s} — NSGlassEffectView (Liquid Glass)\n", .{@tagName(blur)});
            return bd;
        },
    }
}

fn nsString(s: [*:0]const u8) objc.Object {
    const NSString = objc.getClass("NSString").?;
    return NSString.msgSend(objc.Object, "stringWithUTF8String:", .{s});
}

/// An NSString from bytes that are not NUL-terminated.
fn nsStringLen(bytes: []const u8) objc.Object {
    return objc.getClass("NSString").?.msgSend(objc.Object, "alloc", .{})
        .msgSend(objc.Object, "initWithBytes:length:encoding:", .{
        @as(*const anyopaque, bytes.ptr),
        @as(u64, bytes.len),
        @as(u64, 4), // NSUTF8StringEncoding
    });
}

const MonitorBlock = objc.Block(struct { app: *App }, .{objc.c.id}, objc.c.id);
/// UNUserNotificationCenter's authorization completion handler.
const AuthBlock = objc.Block(struct {}, .{ bool, objc.c.id }, void);
const ResizeBlock = objc.Block(struct { app: *App }, .{objc.c.id}, void);
const PresentedBlock = objc.Block(struct { app: *App, dirty: u8, commit_t: f64 }, .{objc.c.id}, void);
const CompletedBlock = objc.Block(struct { app: *App }, .{objc.c.id}, void);

/// What the palette is listing. The widget, filter, key handling and
/// draw path are shared; only the row text and what Enter does differ.
pub const PalMode = enum { workspaces, commands, files, plugins, actions };

/// The onboarding questions.
///
/// One today. The shape is a LIST OF STEPS on purpose — "what editor are
/// you coming from", "which theme", "import your tmux config" are the same
/// question with different choices, and a wizard that can only ask one
/// thing has to be rewritten to ask two.
pub const SetupChoice = struct {
    label: []const u8,
    detail: []const u8,
    lang: envpkg.Lang,
};

pub const setup_choices = [_]SetupChoice{
    .{ .label = "Go", .detail = "a Go program — go.mod and main.go", .lang = .go },
    .{ .label = "TypeScript", .detail = "a TypeScript program — config.ts", .lang = .ts },
};

/// Which side pane a panel is slotted into. Panels are placement-
/// agnostic: the tenant draws into a rect and does not know which edge
/// it came from.
pub const Side = enum { left, right };

/// The side pane's tenants. One today; the switch in drawSidePane is
/// where §2's inbox/deck/threads/review join it, the same way pal_mode
/// grew a second list. Deliberately an enum rather than a vtable — a
/// tenant interface designed against ONE tenant is a guess.
pub const Panel = enum { search, plugin, config };

/// One `attention.raise`: a plugin saying a human is needed.
///
/// The plugin that raised it is recorded alongside, and is not something
/// the plugin gets to state — provenance a caller can set is not
/// provenance. `attention.raise` is the one verb whose whole job is to
/// interrupt someone, so being able to say WHO is the difference between
/// a signal and a nuisance you cannot turn off.
/// Copy into a fixed buffer, truncating rather than failing — every
/// caller here is a label, and a label that is too long is still worth
/// most of what it says.
fn copyStr(dst: []u8, len: *usize, src: []const u8) void {
    const n = @min(dst.len, src.len);
    @memcpy(dst[0..n], src[0..n]);
    len.* = n;
}

pub const Raise = struct {
    seq: u32 = 0,
    from: [64]u8 = @splat(0),
    from_len: usize = 0,
    title: [96]u8 = @splat(0),
    title_len: usize = 0,
    body: [160]u8 = @splat(0),
    body_len: usize = 0,

    pub fn fromStr(self: *const Raise) []const u8 {
        return self.from[0..self.from_len];
    }
    pub fn titleStr(self: *const Raise) []const u8 {
        return self.title[0..self.title_len];
    }
    pub fn bodyStr(self: *const Raise) []const u8 {
        return self.body[0..self.body_len];
    }
};

/// One clickable row of the which-key sheet. `click` is false for the
/// collapsed "1…9" teaching row — a row that says "tabs 1–9" and then
/// jumps to tab 1 on click would be the menu lying about itself.
const WkHit = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    action: registrypkg.Action,
    arg: u8,
    click: bool,
};

/// A which-key row before geometry: the chord char and what it runs.
/// Pub for ctl's `whichkey` verb — the blind reader of the same list.
pub const WkItem = struct {
    ch: u8,
    title: []const u8,
    action: registrypkg.Action,
    arg: u8,
    click: bool,
};

/// What produced the list in the results panel.
const PanelKind = enum { grep, references };

/// A queued "open this path outside the asking editor" — the tree's
/// beside-open and :sp/:vsp. Queued because the ask fires on the key
/// path under draw_lock and pane surgery takes it again.
const PendingOpen = struct {
    len: usize,
    line: usize,
    /// BYTE column on that line. A definition names an identifier, not
    /// a line — landing in column one and making you find the symbol is
    /// what `targetSelectionRange` exists to avoid.
    col: usize = 0,
    /// Bytes of pending_open_find that name WHAT the jump is for. A
    /// results panel records scan-time line numbers, and the buffer may
    /// have moved on — an edit above the hit shifts every line below
    /// it. Carrying the needle lets the landing re-anchor to the match
    /// instead of trusting a number that stopped being true.
    find_len: usize = 0,
    how: @import("editor.zig").OpenHow,
    from: u32,
};

/// How long an armed leader sits unanswered before the sheet reveals.
/// Long enough that a practiced chord never flashes it, short enough
/// that hesitation is answered — which-key's own default neighborhood.
const wk_delay_s: f64 = 0.35;

/// The cursor blink mark: 1.1s period, on for the first 55% — the
/// mock's `cursorblink` keyframes, which are also everyone's.
const blink_period_s: f64 = 1.1;
const blink_on_s: f64 = 0.6;

/// A chord char as the glyph a menu shows: named keys get a symbol,
/// everything else spells itself. The buffer is for the plain-char
/// case; the symbols are static.
fn keyGlyph(ch: u8, buf: *[4]u8) []const u8 {
    return switch (ch) {
        ' ' => "␣",
        '\t' => "⇥",
        0x1b => "⎋",
        else => blk: {
            buf[0] = ch;
            break :blk buf[0..1];
        },
    };
}

pub const App = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    app: objc.Object,
    window: objc.Object,
    layer: objc.Object,
    device: objc.Object,
    queue: objc.Object,
    renderer: renderpkg.Renderer,
    shell: [*:0]const u8,
    keybinds: @import("config.zig").Keybinds,

    /// Declared plugins (plugins.zig). Read at launch; nothing spawns
    /// until something asks unless a declaration said `eager`.
    plugins: @import("plugins.zig").Registry,

    // ---- the plugin panel ----
    /// Which plugin the side pane is showing, and its last answer.
    /// The fetch runs OFF the key path: items.list has a deadline of
    /// seconds, and a panel that blocks the frame while a subprocess
    /// thinks is a panel that drops the window.
    plug_name: [64]u8 = @splat(0),
    plug_name_len: usize = 0,
    plug: @import("plugins.zig").Snapshot = .{},
    plug_sel: usize = 0,
    /// First flat index drawn — selection-follows scroll, adjusted by the
    /// draw pass so the selected row is always on screen.
    plug_scroll: usize = 0,
    /// What the last frame actually drew: the flat index range and one
    /// click band per drawn top-level row group. The click map and the
    /// ctl introspection both read the DRAWN truth rather than recompute
    /// it — two layout walks would be two chances to disagree.
    plug_drawn: [2]usize = .{ 0, 0 },
    plug_hit: [plugpkg.max_items][3]f32 = undefined, // y0, y1, flat idx
    plug_hit_n: usize = 0,
    plug_loading: std.atomic.Value(bool) = .init(false),
    /// Set by the key path (which holds draw_lock) and drained by the
    /// caller after it releases — startPluginFetch takes the lock itself,
    /// so calling it inline would deadlock. Same shape as pending_cmd.
    plug_refetch: bool = false,
    /// The panel's self-refresh, raised by drawFrame's tick (which runs
    /// under draw_lock, which startPluginFetch also takes) and acted on
    /// by drawNow after the lock is gone — the pending_cmd arrangement,
    /// for the same reason.
    plug_auto_wanted: bool = false,

    /// Where the panel's keys go. Enter descends into the selected row's
    /// actions, and an action the plugin marked `confirm` descends once
    /// more — a plugin action can delete a branch, and the confirm is the
    /// plugin's to ask for rather than the host's to guess at.
    plug_mode: enum { rows, actions, confirm, input } = .rows,
    plug_act_sel: usize = 0,
    /// One line of typed payload for an action that declared INPUT_TEXT —
    /// the vague reply the agent expands, the text a plugin asked for.
    plug_input: [512]u8 = @splat(0),
    plug_input_len: usize = 0,
    /// What the last action said. A human pressed a key; something has to
    /// answer, including when the answer is a refusal.
    plug_msg: [160]u8 = @splat(0),
    plug_msg_len: usize = 0,
    plug_acting: std.atomic.Value(bool) = .init(false),
    /// Queued like plug_refetch, and for the same reason.
    plug_run: bool = false,
    /// The plugin the picker chose, drained after the lock — showPlugin
    /// takes draw_lock and the palette's Enter is holding it.
    plug_pending: [64]u8 = @splat(0),
    plug_pending_len: usize = 0,
    /// Queued: the copy takes draw_lock and the key path holds it.
    plug_pin_wanted: bool = false,

    // ---- apply: config is a program, and rook runs it ----
    /// Hash of the config SOURCE (main.go / config.ts), polled beside the
    /// graph's own digest. When it moves, the program is re-run — running a
    /// build step is not a human's job.
    env_src_digest: u64 = 0,
    env_checking: std.atomic.Value(bool) = .init(false),
    /// Queued by the poll and drained outside draw_lock, because the check
    /// forks a toolchain and takes a second.
    env_check_wanted: bool = false,
    /// What running the program produced, and how it differs from what rook
    /// is running. Held, NOT applied — that is the whole point.
    env_diff: envpkg.Diff = .{},
    env_candidate: []u8 = &.{},
    env_log: [512]u8 = @splat(0),
    env_log_len: usize = 0,
    /// Chosen in the setup palette, drained outside draw_lock — writing
    /// files and running `go mod tidy` is not frame-loop work.
    setup_wanted: ?envpkg.Lang = null,
    /// Nothing configured at all: ask, once, after the window is up.
    setup_needed: bool = false,
    /// The welcome screen. Its OWN screen rather than a palette: a palette
    /// is for picking something out of a list you already understand, and
    /// the first thing rook ever shows you has to explain itself first.
    welcome_open: bool = false,
    welcome_sel: usize = 0,
    /// The pending-config panel's cursor, and its queued apply.
    cfg_sel: usize = 0,
    env_apply_wanted: bool = false,

    /// What plugins have raised. A ring rather than a list: attention that
    /// nobody looked at for a hundred events is not attention, and an
    /// unbounded queue fed by a subprocess is a subprocess that can grow
    /// rook's memory without limit.
    att: [16]Raise = @splat(.{}),
    att_n: usize = 0,
    att_seq: u32 = 0,

    /// Leader chord armed: the next key resolves a binding (or the
    /// leader again types it literally). Shown in the bar while armed.
    leader_pending: std.atomic.Value(bool) = .init(false),

    // ---- which-key: the leader teaches itself ----
    /// The sheet listing every live chord, revealed only when an armed
    /// leader has sat unanswered for wk_delay — a fast chord never sees
    /// it, a hesitant one gets the menu. All fields under draw_lock.
    wk_visible: bool = false,
    /// When the leader armed (CACurrentMediaTime); the reveal check
    /// compares against this on every display-link tick.
    wk_armed_at: f64 = 0,
    /// Row hit rects, rebuilt by drawWhichKey each frame it shows.
    /// Sized for Keybinds' 32 entries plus the collapsed 1–9 row.
    wk_hits: [33]WkHit = undefined,
    wk_n: usize = 0,
    /// The sheet's own rect (x, y, w, h) — a click inside it that
    /// misses every row is a dismiss, not a click-through to the pane.
    wk_rect: [4]f32 = .{ 0, 0, 0, 0 },

    /// Status-bar hint hit zones (x extents), rebuilt by drawBar each
    /// frame: "␣ menu" arms the leader with the sheet, "⌘K commands"
    /// opens the palette. Zero-width when there was no room to draw.
    hint_menu_x: [2]f32 = .{ 0, 0 },
    hint_cmd_x: [2]f32 = .{ 0, 0 },

    /// Status-bar WHERE-YOU-ARE segments: the focused pane's git
    /// branch (read off .git/HEAD at the HUD tick — the pane's cwd is
    /// the authority, so the segment follows `cd` and follows an agent
    /// switching branches under you), plus the click zones for the
    /// workspace and branch segments. Zero-width when not drawn.
    bar_branch: [64]u8 = undefined,
    bar_branch_len: usize = 0,
    seg_ws_x: [2]f32 = .{ 0, 0 },
    seg_branch_x: [2]f32 = .{ 0, 0 },

    /// The chrome arrangement (config: top-bar, status-left,
    /// status-right, tab-style — or a preset bundling them). The two
    /// bars share one segment vocabulary; identity is arrangement.
    cfg_top_bar: cfgpkg.SegList = cfgpkg.segs(.{ .tabs, .title }),
    cfg_status_left: cfgpkg.SegList = cfgpkg.segs(.{ .workspace, .branch, .cwd }),
    cfg_status_right: cfgpkg.SegList = cfgpkg.segs(.{ .hints, .hud }),
    cfg_tab_style: cfgpkg.TabStyle = .chips,
    /// Programs ⌃HJKL yields to (config: nav-yield). Read on the
    /// keystroke by navYields().
    cfg_nav_yield: cfgpkg.NameList = cfgpkg.names(.{ "vim", "nvim", "vi", "view", "tmux" }),
    /// Per-tab hit zones for a `tabs` segment living in the STATUS
    /// bar (the top strip's chips keep chip_x). current-style records
    /// one zone; a click there cycles.
    bar_tab_x: [12][2]f32 = undefined,
    bar_tab_n: usize = 0,

    // ---- cursor blink ----
    /// config `cursor-blink`: the focused pane's cursor blinks on the
    /// mark every terminal shares (1.1s period, ~55% on).
    cursor_blink: bool = true,
    /// config `pane-dim`: how far unfocused panes' colors slide toward
    /// their own background (0 = off). Applied at fill time, so it
    /// costs nothing while nothing draws.
    pane_dim: f32 = 0,
    /// Current phase; true = cursor drawn. Forced true (solid) whenever
    /// blinking doesn't apply, so every fill path can read it blindly.
    blink_phase_on: bool = true,
    /// Phase zero — reset on every input so the cursor is SOLID while
    /// you type and only blinks once your hands stop.
    blink_epoch: f64 = 0,
    /// isActive, cached off the 2Hz HUD tick: blink pauses (solid) in
    /// the background, so the measured zero-idle-frames property still
    /// holds where it matters — an app you are not looking at.
    app_active: bool = true,

    // The scene: tabs of split trees. Mutated only under draw_lock.
    /// Workspace sessions (tmux's sessions): each owns a full tab set.
    spaces: std.ArrayListUnmanaged(*panespkg.Space) = .empty,
    active_space: usize = 0,
    next_pane_id: u32 = 2,
    next_tab_id: u32 = 2,
    px_w: f32,
    px_h: f32,
    /// The spatial system: gutter, pane padding, row height, gap.
    /// Recomputed on every resize (the backing scale can change when a
    /// window moves between displays).
    m: @import("ui.zig").Metrics,
    /// One device pixel: the split gap, and every hairline rule.
    sep: f32 = 2,
    /// Status bar height in px; panes tile the content area above it.
    bar_h: f32,
    /// Top tab bar height in px — tabs are first-class chrome (wails
    /// rook's named tabs), not a corner of the status bar.
    tab_h: f32,
    /// Glass mode only: the titlebar strip's height in px. The layer
    /// extends under the (transparent) titlebar, so all chrome shifts
    /// down by this much; the strip itself stays a pure drag region.
    top_inset: f32 = 0,
    /// window-padding, points and px: breathing room around the pane
    /// area (bars stay full-width; the gap shows the theme bg).
    pad_pts: f32 = 0,
    pad: f32 = 0,

    // The palette — first modal chrome tenant (workspace switcher).
    // Open, it intercepts the whole key path; items come fresh from
    // rook.db each open. All state mutates under draw_lock.
    pal_open: bool = false,
    /// Which list the palette is showing. One widget, two sources — the
    /// filter/keys/draw path is shared and only the row text and what
    /// Enter does differ. `pal_filtered` indexes whichever source the
    /// mode names.
    pal_mode: PalMode = .workspaces,
    pal_input: [96]u8 = undefined,
    pal_input_len: usize = 0,
    pal_sel: usize = 0,
    pal_items: []workspacespkg.Entry = &.{},
    pal_filtered: [64]usize = undefined,
    pal_nfiltered: usize = 0,
    /// ⌘P's file index — walked at open, freed at the next open. A
    /// repo's file list is thousands of entries where the other two
    /// modes have tens, so this mode SCORES its matches and keeps the
    /// best 64 in `pal_filtered` (parallel `pal_scores`); the other
    /// modes keep source order, which is already meaningful for them.
    pal_files: filelistpkg.Index = .{},
    /// The code actions a server offered, owned, and the file they were
    /// offered about. Held rather than re-requested: the picker is a
    /// list you scroll, and re-asking on every keystroke would make the
    /// list move under the filter.
    pal_actions: []lsppkg.CodeAction = &.{},
    pal_actions_path: []u8 = &.{},
    pal_scores: [64]i32 = undefined,
    // ---- side pane: the container every §2 panel lands in ----
    /// Closed by default. An empty container costs nothing but a branch,
    /// and the inbox is only worth screen space once something is in it.
    side_open: bool = false,
    side: Side = .right,
    side_panel: Panel = .search,

    // --- the resource monitor ------------------------------------
    /// Sampling state, owned by the sampler thread once it starts.
    /// One sampler for the whole app rather than one per pane: the
    /// process table is a property of the MACHINE, and two panes
    /// sampling it independently would differ by their phase and disagree.
    procs: procmon.Sampler = undefined,
    procs_ready: bool = false,
    /// The sampler runs only while a monitor pane is visible. An
    /// always-on 1Hz walk of 1800 processes is 0.3% of a core spent on
    /// a screen nobody is looking at, and rook's whole pitch is that it
    /// costs nothing when idle.
    sampling: std.atomic.Value(bool) = .init(false),
    /// The live disk scan, if any. One at a time — a second scan would
    /// double the IO for a tree the first is already walking.
    scan: ?*diskscan.Scan = null,
    scan_prog: diskscan.Progress = .{},
    scanning: std.atomic.Value(bool) = .init(false),
    reclaiming: std.atomic.Value(bool) = .init(false),
    // ---- find in files (⌘⇧F) ----
    /// The query box and the results it produced. Two states, because
    /// a search panel is two things: a box you type in, then a list
    /// you walk. `sr_typing` says which one has the keys.
    sr_query: [128]u8 = undefined,
    sr_query_len: usize = 0,
    sr_typing: bool = true,
    sr_sel: usize = 0,
    sr_top: usize = 0,
    sr: searchpkg.Results = .{},
    /// Set while a scan is in flight, so the panel can say so rather
    /// than looking like a search that found nothing.
    sr_running: std.atomic.Value(bool) = .init(false),
    /// Root + query handed to the worker; published back under the
    /// draw_lock when it finishes.
    sr_pending: ?searchpkg.Results = null,
    /// Which question the list is answering, and which one is on its way.
    /// The panel has two producers now, and they differ in what the BOX
    /// means: a grep is what you typed, a reference list is what a
    /// server said about a symbol. A panel that showed the stale query
    /// over somebody else's list would be claiming you searched for it.
    sr_kind: PanelKind = .grep,
    sr_pending_kind: PanelKind = .grep,
    /// Columns, not pixels: the pane beside it is a character grid, and
    /// a width in px makes the split land mid-cell at some font sizes.
    side_cols: f32 = 34,

    /// Every file open in any pane, and how many panes hold it. The
    /// rook-buffers model made real: one file is one document, however
    /// many windows are looking at it.
    docs: docspkg.Registry = undefined,

    // ---- language servers ----
    /// Owns every running server, their roots, and the diagnostics they
    /// publish. Nothing spawns until a file of a known language opens.
    lsp: lspmgrpkg.Manager = undefined,
    /// The grammar loader — one for the whole app, since a dylib opened
    /// per pane is the same image mapped once per split.
    grammars: grammarpkg.Registry = undefined,
    /// Declared languages — the routing half of the LSP. Owned here
    /// because the manager borrows it and every server entry's name
    /// points into its arena.
    langs: langpkg.Registry = undefined,
    /// Set when an answer is queued, so the poster posts it now.
    /// The side pane takes the key path. Needed the moment a tenant is
    /// INTERACTIVE. Modal like the palette, but it owns a region rather
    /// than the screen, so it yields back to the panes instead of closing.
    side_focus: bool = false,

    /// A command the palette picked, waiting for draw_lock to be RELEASED.
    /// The palette's key path runs under the lock and every dispatch
    /// target takes it again (newTab, selectTab, splitFocused, …), so
    /// running one inline is a self-deadlock. Drained by drainPendingCmd
    /// at each of the three places that let go of the lock.
    pending_cmd: ?registrypkg.Spec = null,
    /// A queued open-outside-the-editor; see PendingOpen.
    pending_open: ?PendingOpen = null,
    pending_open_path: [1024]u8 = undefined,
    /// The needle a queued jump re-anchors by; see PendingOpen.find_len.
    pending_open_find: [256]u8 = undefined,
    /// A queued `:qa`-family request. See editorQuitAll for why it cannot
    /// run where it is asked for.
    pending_quit_all: ?struct { write: bool, quit: bool, force: bool } = null,


    /// IME state. `ime_marked` is PREEDIT — what the input method is
    /// composing and has not committed. It is drawn at the cursor and
    /// never reaches a pty: an unfinished か is not input yet.
    /// `ime_text` is the sink insertText: writes into during one event,
    /// because the callback runs inside handleEvent: and the leader
    /// machine has to see those bytes before any pane does.
    ime_marked: [128]u8 = undefined,
    ime_marked_len: usize = 0,
    ime_text: [128]u8 = undefined,
    ime_text_len: usize = 0,
    /// The view that owns the input context (and is first responder).
    ime_view: objc.Object = .{ .value = null },
    /// Layout/focus changed: the next frame redraws even if no pane's
    /// grid is dirty.
    scene_dirty: bool = true,

    // Status-bar HUD text, recomputed at ~2Hz on the display-link tick;
    // a change flips scene_dirty, so an idle app with stable numbers
    // still draws ZERO frames (the scoreboard's idle row).
    hud_left: [96]u8 = undefined,
    hud_left_len: usize = 0,
    hud_right: [96]u8 = undefined,
    hud_right_len: usize = 0,
    /// Digest of all tab titles — OSC title changes don't dirty the
    /// grid, so the 2Hz refresh detects them here and redraws chips.
    hud_tabs: [160]u8 = undefined,
    hud_tabs_len: usize = 0,
    hud_last_t: f64 = 0,
    hud_last_bytes: u64 = 0,
    hud_mbs: f64 = 0,
    /// Config live-reload: wyhash of both config files, polled at
    /// ~1Hz off the HUD tick. Theme + keybinds apply live;
    /// font/opacity need a relaunch (renderer + window are built).
    config_digest: u64 = 0,
    hud_calls: u64 = 0,

    // fps truth: the display link's refresh period is the ceiling the
    // HUD shows optimistically; it dips only when measured FRAME COST
    // exceeds the vsync budget (capability, not demand — dirty-skip
    // gaps must never read as lag).
    link: CVDisplayLinkRef = null,
    /// Display refresh period in µs; 0 until the link has ticked once.
    ///
    /// Written from the DISPLAY-LINK thread and read under draw_lock,
    /// so it is atomic — but the reason it is atomic is the smaller
    /// half. CoreVideo must never be QUERIED while draw_lock is held:
    /// the call blocks inside CoreVideo waiting on the link's own IO
    /// thread, and that thread is in `drawNow` waiting for draw_lock.
    /// That inversion wedges the whole app, and it is not theoretical —
    /// a `sample` of a hung instance showed exactly it, every thread
    /// queued on the lock behind a reader thread parked inside
    /// `CVDisplayLinkGetActualOutputVideoRefreshPeriod`.
    ///
    /// It bites only in the window before the first tick caches a
    /// value, which is why it reads as a rare startup hang rather than
    /// a bug. The link answers the question on its own thread now, and
    /// nothing under the lock does anything but read this.
    display_period_us: std.atomic.Value(u64) = .init(0),

    /// Focused pane's session, readable without draw_lock (the input
    /// kick compares pointers only — never dereferences).
    focused_session: std.atomic.Value(?*sessionpkg.Session) = .init(null),

    frame_count: std.atomic.Value(u64) = .init(0),
    activate: bool = true,
    pending_w: f64 = 0,
    pending_h: f64 = 0,
    pend_key_code: u16 = 0,
    pend_key_mods: u64 = 0,
    pend_key_chars: [16]u8 = undefined,
    pend_key_len: usize = 0,

    /// Pending keystroke timestamp (CACurrentMediaTime clock; NSEvent
    /// timestamps share it). Consumed by the presented handler of the
    /// first frame after the mark that carried the FOCUSED pane's echo.
    input_mark: std.atomic.Value(f64) = .init(0),
    last_presented: std.atomic.Value(f64) = .init(0),

    /// Serializes scene access across display link, input kick, keys,
    /// resize, and ctl. See the file comment for lock order.
    draw_lock: sessionpkg.Lock = .{},

    /// proc_pidinfo(PROC_PIDVNODEPATHINFO) scratch: 2 × (152-byte
    /// vnode_info + 1024-byte path). Written under draw_lock.
    cwd_info: [2352]u8 = undefined,

    /// Tab-chip x extents (px) recorded by drawTabBar for click hit
    /// tests. Written/read under draw_lock.
    chip_x: [16][2]f32 = undefined,
    chip_n: usize = 0,

    /// Wheel accumulator (points); one scroll step per cell height.
    wheel_accum: f64 = 0,

    /// Background alpha (255 = opaque). <255 means the layer/window
    /// went non-opaque at create: default backgrounds and the clear
    /// color carry this alpha; explicit cell colors stay solid.
    bg_alpha: u8 = 255,
    bg_opacity: f64 = 1.0,
    /// What BEL does (config `bell`). Live-reloadable, unlike the
    /// renderer-shaped settings around it.
    cfg_bell: @import("config.zig").Bell = .visual,
    /// Notification bookkeeping: authorization is asked once lazily, the
    /// unbundled warning is printed once, and the last one posted is kept
    /// for ctl `notify` (a banner is the one thing a blind test can't see).
    notify_asked: bool = false,
    notify_warned: bool = false,
    notify_seq: u32 = 0,
    notify_last: [384]u8 = undefined,
    notify_last_len: usize = 0,
    /// Whether OSC 52 writes are honoured (config `clipboard-write`).
    /// Held here as well as on each Session so a session spawned after
    /// a live reload inherits the current answer.
    cfg_clip_allow: bool = true,
    /// config buffer-line: the per-pane document chips.
    cfg_bufline: cfgpkg.BufferLine = .multiple,
    /// config editor-mode = insert: files open ready to type.
    cfg_ed_insert: bool = false,
    /// config activity-bar: the left icon rail.
    cfg_activity_bar: bool = false,
    /// config explorer-auto: the tree sidebar opens at launch.
    cfg_explorer_auto: bool = false,
    /// config editor-format-on-save: `:w` formats before it writes.
    cfg_fmt_on_save: bool = false,
    cfg_suggest: bool = true,
    /// Icon rail hit zones (y extents), rebuilt each frame it draws.
    rail_y: [8][2]f32 = undefined,
    rail_n: usize = 0,
    /// Scrollback bytes for panes spawned later. NOT live-reloadable —
    /// a pane's limit is fixed when its PageList is built, so a reload
    /// would silently give new panes a different history depth from the
    /// ones already open. Relaunch, like font and opacity.
    cfg_scrollback: usize = 10 * 1024 * 1024,
    /// The last OSC 52 payload we put on the pasteboard, for ctl
    /// `clipboard` — which reads the real pasteboard back, so this is
    /// only here to tell "rook wrote it" from "something else did".
    clip_last: [1024]u8 = undefined,
    clip_last_len: usize = 0,

    /// Active mouse-drag selection: the pane and its anchor cell
    /// (viewport coords at mousedown). Under draw_lock; cleared by
    /// reap if the pane dies mid-drag.
    drag_pane: ?*panespkg.Pane = null,
    drag_anchor: [2]u16 = .{ 0, 0 },

    /// Mid-drag mouse-reporting state: the press went to the app (SGR
    /// or legacy), so motion and release follow it there too.
    drag_report: bool = false,
    drag_last_cell: [2]u16 = .{ 0, 0 },

    /// Active separator drag: the split being resized and its union
    /// rect (ratio = pointer position within it). Cleared by reap
    /// (tree mutation invalidates the pointer) and on mouse-up.
    drag_split: ?*panespkg.Split = null,
    drag_split_rect: panespkg.Rect = .{},
    /// Mid-drag on the side pane's divider: the drag writes side_cols
    /// live, so the panes beside it reflow while you pull.
    drag_side: bool = false,

    // ctl `shot` handoff: the socket thread stores a path and flips the
    // flag; the render thread services it after the next commit.
    shot_state: std.atomic.Value(u8) = .init(0),
    shot_path: [1024]u8 = undefined,
    shot_len: usize = 0,

    pub fn markInput(self: *App, t: f64) void {
        self.input_mark.store(t, .release);
        // Typing keeps the cursor solid: every input restarts the blink
        // at phase zero (on). Every caller holds draw_lock, which is
        // what makes the two plain fields safe to touch here.
        self.blink_epoch = t;
        if (!self.blink_phase_on) {
            self.blink_phase_on = true;
            self.scene_dirty = true;
        }
    }

    fn drawNow(self: *App) void {
        {
            self.draw_lock.lock();
            defer self.draw_lock.unlock();
            self.drawFrame();
        }
        // OUTSIDE the lock, for the reason pending_open exists: pane
        // surgery cannot run while the frame holds it. Everything else
        // that queues an open is driven by input, which drains right
        // after — a language server's answer is the first thing that
        // arrives with no keystroke behind it, so the frame loop has to
        // drain too or a `gd` reply sits in the queue until you happen
        // to press a key.
        self.drainPendingCmd();
        // Same shape: startPluginFetch takes draw_lock, so the frame
        // only raised the flag.
        if (self.plug_auto_wanted) {
            self.plug_auto_wanted = false;
            if (!self.plug_loading.load(.acquire)) self.startPluginFetch();
        }
    }

    pub fn requestShot(self: *App, path: []const u8) bool {
        if (path.len == 0 or path.len > self.shot_path.len) return false;
        if (self.shot_state.cmpxchgStrong(0, 1, .acq_rel, .monotonic) != null) return false;
        @memcpy(self.shot_path[0..path.len], path);
        self.shot_len = path.len;
        self.shot_state.store(2, .release); // armed
        // FORCE a frame. The shot is serviced by the display link while
        // drawing, and this app draws NOTHING when idle — that is a
        // measured property, not an accident. Without this, a shot of a
        // quiet screen simply never happens: it times out, and because
        // the state stays armed, every later shot answers "err busy"
        // forever. Cost is one frame per shot, which is what a shot is.
        self.draw_lock.lock();
        self.scene_dirty = true;
        self.draw_lock.unlock();
        return true;
    }

    pub fn shotPending(self: *App) bool {
        return self.shot_state.load(.acquire) != 0;
    }

    /// Disarm a shot that never got serviced, so one timeout does not
    /// wedge the surface for the rest of the process's life.
    pub fn cancelShot(self: *App) void {
        self.shot_state.store(0, .release);
    }

    pub fn create(init: std.process.Init) !*App {
        const gpa = init.gpa;
        boot_times.start = CACurrentMediaTime();
        var bt = boot_times.start;
        const cfg = @import("config.zig").load(init.io, gpa);
        boot_times.config_us = usSince(bt);
        bt = CACurrentMediaTime();
        const keybinds = @import("config.zig").loadKeybinds(init.io, gpa);
        boot_times.keybinds_us = usSince(bt);
        // Declarations only — reading them is a JSON pass over a file
        // already in cache. Spawning is what costs, and that is lazy.
        const plugins = @import("plugins.zig").load(init.io, gpa);
        if (themepkg.byName(cfg.theme)) |t| {
            th = t.*;
        } else std.debug.print("rook config: unknown theme '{s}' (builtin: default, nocturne)\n", .{cfg.theme});

        bt = CACurrentMediaTime();
        const NSApplication = objc.getClass("NSApplication").?;
        const app = NSApplication.msgSend(objc.Object, "sharedApplication", .{});
        // NSApplicationActivationPolicyRegular = 0: real app with Dock icon.
        _ = app.msgSend(bool, "setActivationPolicy:", .{@as(i64, 0)});

        const device_id = MTLCreateSystemDefaultDevice();
        if (device_id == null) return error.NoMetalDevice;
        const device = objc.Object.fromId(device_id);
        const queue = device.msgSend(objc.Object, "newCommandQueue", .{});

        const layer = objc.getClass("CAMetalLayer").?.msgSend(objc.Object, "layer", .{});
        layer.msgSend(void, "setDevice:", .{device.value});
        // MTLPixelFormatBGRA8Unorm = 80
        layer.msgSend(void, "setPixelFormat:", .{@as(u64, 80)});
        // Double- not triple-buffer: one whole frame less key-to-photon.
        layer.msgSend(void, "setMaximumDrawableCount:", .{@as(u64, 2)});
        // false so the ctl `shot` command can read our own drawable back —
        // dev-tool visibility outranks the marginal framebufferOnly win.
        layer.msgSend(void, "setFramebufferOnly:", .{false});
        // Opaque is a hard requirement for direct-to-display scan-out —
        // a non-opaque layer always goes through the compositor. The
        // present_lag ring is the detector: ~12ms composited, ~4ms
        // direct. background-opacity < 1 knowingly trades that away.
        const opaque_bg = cfg.background_opacity >= 1.0;
        layer.msgSend(void, "setOpaque:", .{opaque_bg});

        const rect = NSRect{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = win_w, .height = win_h } };
        // titled | closable | miniaturizable | resizable = 15
        var style: u64 = 15;
        // Glass mode: the layer must extend under the titlebar or the
        // titlebar stays an opaque AppKit slab above the tint.
        if (!opaque_bg) style |= 1 << 15; // fullSizeContentView
        const window = objc.getClass("NSWindow").?
            .msgSend(objc.Object, "alloc", .{})
            .msgSend(objc.Object, "initWithContentRect:styleMask:backing:defer:", .{ rect, style, @as(u64, 2), false });
        window.msgSend(void, "setTitle:", .{nsString("rook")});
        window.msgSend(void, "center", .{});
        window.msgSend(void, "setReleasedWhenClosed:", .{false});
        if (!opaque_bg) {
            window.msgSend(void, "setOpaque:", .{false});
            const clear = objc.getClass("NSColor").?.msgSend(objc.Object, "clearColor", .{});
            window.msgSend(void, "setBackgroundColor:", .{clear.value});
            // The strip is ours now: no material, no title text —
            // traffic lights float over our tinted drag strip.
            window.msgSend(void, "setTitlebarAppearsTransparent:", .{true});
            window.msgSend(void, "setTitleVisibility:", .{@as(i64, 1)}); // hidden
            std.debug.print("rook: background-opacity {d:.2} — compositor path (direct scan-out off)\n", .{cfg.background_opacity});
        }

        // Our own NSView subclass, so the thing has an input context
        // (see the IME section); a failed class build falls back to the
        // stock view and the pre-IME behavior.
        const view = (rookViewClass() orelse objc.getClass("NSView").?)
            .msgSend(objc.Object, "alloc", .{})
            .msgSend(objc.Object, "initWithFrame:", .{rect});
        view.msgSend(void, "setWantsLayer:", .{true});
        view.msgSend(void, "setLayer:", .{layer.value});
        view.msgSend(void, "setPostsFrameChangedNotifications:", .{true});

        // Frosted backdrop: our translucent layer draws over a system
        // material that blurs whatever is behind the window — the thing
        // that makes transparency legible over a busy desktop. The
        // backdrop becomes the contentView; the resize observer watches
        // the contentView, so it must post frame changes too.
        var blur = cfg.background_blur;
        if (blur != .none and opaque_bg) {
            std.debug.print("rook config: background-blur needs background-opacity < 1 — ignoring\n", .{});
            blur = .none;
        }
        var content = view;
        if (makeBackdrop(blur, rect, view)) |bd| content = bd;
        content.msgSend(void, "setPostsFrameChangedNotifications:", .{true});
        window.msgSend(void, "setContentView:", .{content.value});

        // Retina: drawable size in pixels, not points.
        const scale = window.msgSend(f64, "backingScaleFactor", .{});
        layer.msgSend(void, "setContentsScale:", .{scale});
        const px_w = win_w * scale;
        const px_h = win_h * scale;
        layer.msgSend(void, "setDrawableSize:", .{NSSize{ .width = px_w, .height = px_h }});

        boot_times.appkit_us = usSince(bt);
        // Nerd Font base (default) so prompt icons resolve without
        // fallback; the CoreText cascade catches everything else.
        bt = CACurrentMediaTime();
        const renderer = try renderpkg.Renderer.init(gpa, device, cfg.font_family, cfg.font_size * scale, 64 * 1024);
        boot_times.renderer_us = usSince(bt);
        const m = @import("ui.zig").Metrics.compute(@floatCast(scale), renderer.cell_h);
        const bar_h: f32 = m.row;
        // An empty top-bar list hides the strip and the panes reclaim
        // its row — chrome is arrangement, and "none" is an arrangement.
        const tab_h: f32 = if (cfg.top_bar.n == 0) 0 else bar_h;
        // Standard macOS titlebar is 28pt; with fullSizeContentView we
        // draw under it and shift chrome down instead.
        const top_inset: f32 = if (opaque_bg) 0 else @floatCast(28 * scale);
        const pad: f32 = @floatCast(cfg.window_padding * scale);
        // Two insets, not one: window padding is outside the pane box,
        // pane padding is inside it, and the first shell sees both.
        const inset = pad * 2 + m.pane_pad * 2;
        const cols: u16 = @intFromFloat(@max(2, @divFloor(@as(f32, @floatCast(px_w)) - inset, renderer.cell_w)));
        const rows: u16 = @intFromFloat(@max(2, @divFloor(@as(f32, @floatCast(px_h)) - bar_h - tab_h - top_inset - inset, renderer.cell_h)));

        const shell = getenv("SHELL") orelse "/bin/zsh";
        bt = CACurrentMediaTime();
        const session = try sessionpkg.Session.start(gpa, init.io, shell, null, null, termColors(), @intCast(cols), @intCast(rows), @intCast(renderer.cellw_px), @intCast(renderer.cellh_px), cfg.scrollback);
        boot_times.session_us = usSince(bt);

        const self = try gpa.create(App);
        const pane = try gpa.create(panespkg.Pane);
        pane.* = .{ .id = 1, .content = .{ .term = .{ .session = session } }, .cols = cols, .rows = rows };
        session.kick = &inputKick;
        session.kick_ctx = self;
        // From `cfg`, NOT self.cfg_clip_allow: `self.*` is assigned
        // below, so reading a field off it here is uninitialised memory.
        session.clip_allow = cfg.clipboard_write == .allow;
        const tab_one = try gpa.create(panespkg.Tab);
        tab_one.* = .{ .id = 1, .root = .{ .leaf = pane }, .focused = pane };
        try tab_one.panes.append(gpa, pane);
        self.* = .{
            .gpa = gpa,
            .io = init.io,
            .app = app,
            .window = window,
            .layer = layer,
            .device = device,
            .queue = queue,
            .renderer = renderer,
            .shell = shell,
            .keybinds = keybinds,
            .px_w = @floatCast(px_w),
            .px_h = @floatCast(px_h),
            .m = m,
            .sep = @floatCast(@max(1.0, @round(scale))),
            .bar_h = bar_h,
            .tab_h = tab_h,
            .cfg_top_bar = cfg.top_bar,
            .cfg_status_left = cfg.status_left,
            .cfg_status_right = cfg.status_right,
            .cfg_tab_style = cfg.tab_style,
            .top_inset = top_inset,
            .pad_pts = @floatCast(cfg.window_padding),
            .pad = pad,
            .bg_opacity = cfg.background_opacity,
            .cfg_bell = cfg.bell,
            .cfg_clip_allow = cfg.clipboard_write == .allow,
            .cfg_bufline = cfg.buffer_line,
            .cfg_nav_yield = cfg.nav_yield,
            .cfg_ed_insert = cfg.editor_insert,
            .cfg_activity_bar = cfg.activity_bar,
            .cfg_explorer_auto = cfg.explorer_auto,
            .cfg_fmt_on_save = cfg.format_on_save,
            .cfg_suggest = cfg.suggest,
            .cursor_blink = cfg.cursor_blink,
            .pane_dim = @floatCast(cfg.pane_dim),
            .cfg_scrollback = cfg.scrollback,
            .bg_alpha = @intFromFloat(@round(cfg.background_opacity * 255.0)),
            .ime_view = view,
            .plugins = plugins,
        };
        // The input-method callbacks are context-free C functions; one
        // window means one App to find. Set before the view can become
        // first responder.
        ime_app = self;
        window.msgSend(void, "makeFirstResponder:", .{view.value});
        self.focused_session.store(session, .release);
        // Workspace registry up front — space one takes the name of
        // whatever workspace the launch cwd is inside (else scratch),
        // and tab chips wear their workspace from the first frame.
        self.pal_items = workspacespkg.load(init.io, gpa);
        const space_one = try gpa.create(panespkg.Space);
        space_one.* = .{};
        var cwdbuf: [1024]u8 = undefined;
        if (getcwd(&cwdbuf, cwdbuf.len)) |cwd| {
            const c = std.mem.span(cwd);
            for (self.pal_items) |e| {
                if (std.mem.startsWith(u8, c, e.root) and (c.len == e.root.len or c[e.root.len] == '/')) {
                    space_one.setName(e.name);
                    break;
                }
            }
        }
        try space_one.tabs.append(gpa, tab_one);
        try self.spaces.append(gpa, space_one);
        panespkg.layout(tab_one.root, self.paneArea(), self.sep);
        // Nothing spawns here: the manager is a table until a file of a
        // known language opens. That is deliberate — a language server
        // costs ~1s and ~100MB, and launch owes it nothing.
        self.docs = docspkg.Registry.init(gpa);
        // The registry BEFORE the manager: the manager holds a pointer
        // to it, and its languages have to be declared before the first
        // file can route to one.
        self.langs = langpkg.Registry.init(gpa);
        self.langs.loadGraph(init.io);
        self.lsp = lspmgrpkg.Manager.init(gpa, init.io, &self.langs);
        self.lsp.resolve_ctx = self;
        self.lsp.resolve = &lspResolveHook;
        self.grammars = grammarpkg.Registry.init(gpa);
        self.grammars.loadGraph(init.io);
        self.lsp.enabled = cfg.lsp;

        // Both halves of the plugin wire, in this order: the host has to be
        // reachable BEFORE anything spawns, or an eager plugin that raises
        // attention on startup gets told rook cannot do that.
        self.plugins.setHost(.{ .ctx = self, .call = &pluginInbound });
        self.plugins.startEager(gpa);

        // First run: nothing configured at all, so ask. Only when there is
        // NOTHING — a config.toml, a hand-written graph or a config program
        // all mean the question has been answered, and re-asking someone
        // who already decided is how an onboarding step becomes an
        // annoyance to be dismissed forever.
        {
            var dirbuf: [1024]u8 = undefined;
            if (cfgpkg.configDir(&dirbuf)) |dir| {
                const cwd = std.Io.Dir.cwd();
                var has: bool = envpkg.findSource(init.io, dir) != null;
                if (!has) {
                    var pb: [1088]u8 = undefined;
                    if (cfgpkg.envPath(&pb)) |gp| has = cwd.access(init.io, gp, .{}) != error.FileNotFound;
                }
                if (!has) {
                    var pb2: [1088]u8 = undefined;
                    if (cfgpkg.cfgPath(&pb2)) |cp| has = cwd.access(init.io, cp, .{}) != error.FileNotFound;
                }
                self.setup_needed = !has;
            }
        }
        boot_times.create_us = usSince(boot_times.start);
        return self;
    }

    pub fn run(self: *App) void {
        self.window.msgSend(void, "makeKeyAndOrderFront:", .{@as(objc.c.id, null)});
        // --no-activate: probe/tooling launches must not steal focus.
        if (self.activate) self.app.msgSend(void, "activateIgnoringOtherApps:", .{true});

        // The launch sidebar, before ctl binds: an e2e or an agent that
        // connects the instant the socket answers must not race the
        // pane it is about to assert on.
        {
            self.draw_lock.lock();
            defer self.draw_lock.unlock();
            self.explorerAutoLocked();
        }

        @import("ctl.zig").start(self) catch |err| {
            std.debug.print("rook ctl: failed to start: {}\n", .{err});
        };

        // The app's last word before AppKit exits, and the ONLY path out
        // of `NSApp run` we get to observe. It reaped rook-host here; the
        // daemon left in the strip and the observer is kept because it is
        // the seam anything with a lifetime beyond the window hangs off.
        var term_ctx = ResizeBlock.init(.{ .app = self }, &terminateCallback);
        const nc = objc.getClass("NSNotificationCenter").?
            .msgSend(objc.Object, "defaultCenter", .{});
        _ = nc.msgSend(objc.Object, "addObserverForName:object:queue:usingBlock:", .{
            nsString("NSApplicationWillTerminateNotification").value,
            @as(objc.c.id, null),
            @as(objc.c.id, null),
            &term_ctx,
        });

        // Keys → pty (Cmd+Q quits). AppKit copies the handler block, so the
        // stack context is fine here.
        var block_ctx = MonitorBlock.init(.{ .app = self }, &monitorCallback);
        const NSEvent = objc.getClass("NSEvent").?;
        _ = NSEvent.msgSend(objc.Object, "addLocalMonitorForEventsMatchingMask:handler:", .{
            NSEventMaskKeyDown,
            &block_ctx,
        });

        // Mouse: click-to-focus (panes + tab chips), wheel scroll.
        var mouse_ctx = MonitorBlock.init(.{ .app = self }, &mouseCallback);
        _ = NSEvent.msgSend(objc.Object, "addLocalMonitorForEventsMatchingMask:handler:", .{
            NSEventMaskLeftMouseDown | NSEventMaskLeftMouseUp |
                NSEventMaskLeftMouseDragged | NSEventMaskScrollWheel,
            &mouse_ctx,
        });

        // Resize: view frame changes retarget the drawable, the layout,
        // every pane's emulator (reflow) and pty. Runs on the main thread.
        var resize_ctx = ResizeBlock.init(.{ .app = self }, &resizeCallback);
        const center = objc.getClass("NSNotificationCenter").?
            .msgSend(objc.Object, "defaultCenter", .{});
        const view = self.window.msgSend(objc.Object, "contentView", .{});
        _ = center.msgSend(objc.Object, "addObserverForName:object:queue:usingBlock:", .{
            nsString("NSViewFrameDidChangeNotification").value,
            view.value,
            @as(objc.c.id, null),
            &resize_ctx,
        });

        // Screen changes: dragging to another monitor (or a monitor
        // disconnect) can land the window on a display with a different
        // scale WITHOUT a frame change, and the frame observer above
        // never fires — the scale goes stale and everything renders at
        // the wrong DPI until the next manual resize. Zed shipped that
        // bug (#38269). The same hook re-paces the frame clock: the
        // link was created against the default display, and a 60Hz
        // external monitor deserves 60Hz ticks, not the main panel's.
        var screen_ctx = ResizeBlock.init(.{ .app = self }, &screenChangedCallback);
        _ = center.msgSend(objc.Object, "addObserverForName:object:queue:usingBlock:", .{
            nsString("NSWindowDidChangeScreenNotification").value,
            self.window.value,
            @as(objc.c.id, null),
            &screen_ctx,
        });

        // Frame clock off the main thread.
        var link: CVDisplayLinkRef = null;
        _ = CVDisplayLinkCreateWithActiveCGDisplays(&link);
        _ = CVDisplayLinkSetOutputCallback(link, &displayLinkCallback, self);
        _ = CVDisplayLinkStart(link);
        self.link = link;

        self.app.msgSend(void, "run", .{});
    }

    /// ctl `winsize`: resize the window from any thread (points, not px).
    pub fn requestWinSize(self: *App, w: f64, h: f64) void {
        self.pending_w = w;
        self.pending_h = h;
        dispatch_async_f(@ptrCast(&_dispatch_main_q), self, &applyWinSize);
    }

    fn applyPostKey(ctx: ?*anyopaque) callconv(.c) void {
        const self: *App = @ptrCast(@alignCast(ctx.?));
        const s = nsStringLen(self.pend_key_chars[0..self.pend_key_len]);
        const ev = objc.getClass("NSEvent").?.msgSend(
            objc.Object,
            "keyEventWithType:location:modifierFlags:timestamp:windowNumber:context:characters:charactersIgnoringModifiers:isARepeat:keyCode:",
            .{
                @as(u64, 10), // NSEventTypeKeyDown
                NSPoint{ .x = 0, .y = 0 },
                self.pend_key_mods,
                CACurrentMediaTime(),
                self.window.msgSend(i64, "windowNumber", .{}),
                @as(objc.c.id, null),
                s.value,
                s.value,
                false,
                self.pend_key_code,
            },
        );
        if (ev.value == null) return;
        self.app.msgSend(void, "postEvent:atStart:", .{ ev.value, true });
    }

    fn applyWinSize(ctx: ?*anyopaque) callconv(.c) void {
        const self: *App = @ptrCast(@alignCast(ctx.?));
        self.window.msgSend(void, "setContentSize:", .{NSSize{ .width = self.pending_w, .height = self.pending_h }});
    }

    /// ctl `nskey`: synthesize a real NSEvent and post it to our own
    /// event queue, from any thread.
    ///
    /// This exists because `press` and `type` write bytes straight into
    /// the app and therefore cannot test anything AppKit does on the way
    /// in — the IME above being the whole of it. A posted event goes
    /// through NSApp's dispatch, the local monitor, the input context:
    /// the real path, minus a finger. Dead keys are drivable this way
    /// (⌥e is keycode 14 with the option mask), which is the only way to
    /// prove composition works without a human at the keyboard.
    pub fn postKey(self: *App, code: u16, mods: u64, chars: []const u8) void {
        self.pend_key_code = code;
        self.pend_key_mods = mods;
        const n = @min(chars.len, self.pend_key_chars.len);
        @memcpy(self.pend_key_chars[0..n], chars[0..n]);
        self.pend_key_len = n;
        dispatch_async_f(@ptrCast(&_dispatch_main_q), self, &applyPostKey);
    }

    /// ctl `fullscreen`: toggle native fullscreen from any thread — the
    /// most reliable direct-to-display geometry.
    pub fn requestFullscreen(self: *App) void {
        dispatch_async_f(@ptrCast(&_dispatch_main_q), self, &applyFullscreen);
    }

    fn applyFullscreen(ctx: ?*anyopaque) callconv(.c) void {
        const self: *App = @ptrCast(@alignCast(ctx.?));
        self.window.msgSend(void, "toggleFullScreen:", .{@as(objc.c.id, null)});
    }

    /// Main thread, on every content-view frame change.
    pub fn viewResized(self: *App) void {
        const view = self.window.msgSend(objc.Object, "contentView", .{});
        if (view.value == null) return;
        const bounds = view.msgSend(NSRect, "bounds", .{});
        const scale = self.window.msgSend(f64, "backingScaleFactor", .{});
        const px_w = bounds.size.width * scale;
        const px_h = bounds.size.height * scale;
        if (px_w < 1 or px_h < 1) return;

        // The drawable must track the view in PIXELS or CoreAnimation
        // scales the framebuffer to fit — the squished-glyph bug.
        self.layer.msgSend(void, "setContentsScale:", .{scale});
        self.layer.msgSend(void, "setDrawableSize:", .{NSSize{ .width = px_w, .height = px_h }});

        self.draw_lock.lock();
        defer self.draw_lock.unlock();
        self.px_w = @floatCast(px_w);
        self.px_h = @floatCast(px_h);
        self.sep = @floatCast(@max(1.0, @round(scale)));
        self.m = @import("ui.zig").Metrics.compute(@floatCast(scale), self.renderer.cell_h);
        self.bar_h = self.m.row;
        self.tab_h = if (self.cfg_top_bar.n == 0) 0 else self.bar_h;
        if (self.top_inset > 0) self.top_inset = @floatCast(28 * scale);
        self.pad = @floatCast(self.pad_pts * scale);
        self.relayoutLocked();
        self.scene_dirty = true;
    }

    /// Pane-area height: the window minus the tab bar and status bar
    /// (and, in glass mode, the titlebar strip we draw under).
    fn contentH(self: *App) f32 {
        return @max(1, self.px_h - self.bar_h - self.tab_h - self.top_inset);
    }

    /// Where panes start: below the titlebar strip and tab bar.
    fn contentY(self: *App) f32 {
        return self.top_inset + self.tab_h;
    }

    /// Width the side pane takes, or 0 when closed. Snapped to whole
    /// cells so the terminal beside it still lands on the grid.
    fn sideWidth(self: *App) f32 {
        if (!self.side_open) return 0;
        // Never more than half the window: a side pane that can squeeze
        // the panes to nothing is a side pane that can lose your shell.
        return @min(@round(self.side_cols * self.renderer.cell_w), self.px_w / 2);
    }

    /// The icon rail's width (config `activity-bar`), or 0 when off.
    /// VS Code's activity bar — window chrome at the far left edge,
    /// outside even the side pane.
    pub fn railWidth(self: *App) f32 {
        if (!self.cfg_activity_bar) return 0;
        return @round(3 * self.renderer.cell_w);
    }

    /// The side pane's own rect. Full content height — it is WINDOW
    /// chrome, not a tab's, so it does not move when you switch tabs
    /// and every tab sees the same inbox.
    pub fn sideArea(self: *App) panespkg.Rect {
        const w = self.sideWidth();
        return .{
            .x = if (self.side == .left) self.railWidth() else self.px_w - w,
            .y = self.contentY(),
            .w = w,
            .h = @max(1, self.contentH()),
        };
    }

    /// The rect panes tile: the content area inset by window-padding,
    /// minus whatever the side pane and the icon rail took.
    fn paneArea(self: *App) panespkg.Rect {
        const side = self.sideWidth();
        const rail = self.railWidth();
        return .{
            .x = rail + self.pad + if (self.side == .left) side else 0,
            .y = self.contentY() + self.pad,
            .w = @max(1, self.px_w - self.pad * 2 - side - rail),
            .h = @max(1, self.contentH() - self.pad * 2),
        };
    }

    /// Where a pane's FIRST CELL sits inside its box.
    ///
    /// The box is the slot the tree handed out — it fills, tiles and
    /// hit-tests against that. The grid is inset from it, so text never
    /// touches a split separator or the focus ring. One function because
    /// four call sites map between pixels and cells (draw, click,
    /// cursor, resize) and three of them agreeing is a bug you find with
    /// the mouse.
    fn gridOrigin(self: *App, p: *panespkg.Pane) struct { x: f32, y: f32 } {
        return .{ .x = p.rect.x + self.m.pane_pad, .y = p.rect.y + self.m.pane_pad };
    }

    pub fn activeSpace(self: *App) *panespkg.Space {
        return self.spaces.items[self.active_space];
    }

    pub fn activeTab(self: *App) *panespkg.Tab {
        const s = self.activeSpace();
        return s.tabs.items[s.active_tab];
    }

    /// A click in scene px coords: tab chips select, panes focus.
    /// Shared by the NSEvent monitor and ctl \`click\` (blind-testable).
    pub fn clickAt(self: *App, x: f32, y: f32, local: bool) void {
        {
            self.draw_lock.lock();
            defer self.draw_lock.unlock();
            self.clickLocked(x, y, local);
        }
        // Outside the locked block: chrome clicks (a which-key row, a
        // status-bar hint) queue through pending_cmd because every
        // dispatch target takes draw_lock again — same handoff the
        // palette's Enter uses.
        self.drainPendingCmd();
    }

    fn clickLocked(self: *App, x: f32, y: f32, local: bool) void {
        if (y < self.top_inset) return; // titlebar drag strip — AppKit's
        if (y < self.contentY()) {
            for (self.chip_x[0..self.chip_n], 0..) |cx, i| {
                if (x >= cx[0] and x <= cx[1]) {
                    self.activateTabLocked(i);
                    break;
                }
            }
            return;
        }
        // The which-key sheet, when it is up: a row click runs the
        // command it teaches, anywhere else dismisses — either way the
        // chord is spent, exactly like answering it from the keyboard.
        if (self.leader_pending.load(.acquire) and self.wk_visible) {
            self.leader_pending.store(false, .release);
            self.wk_visible = false;
            self.scene_dirty = true;
            const r = self.wk_rect;
            if (x >= r[0] and x < r[0] + r[2] and y >= r[1] and y < r[1] + r[3]) {
                for (self.wk_hits[0..self.wk_n]) |hit| {
                    if (!hit.click) continue;
                    if (x >= hit.x and x < hit.x + hit.w and y >= hit.y and y < hit.y + hit.h) {
                        self.pending_cmd = .{ .action = hit.action, .arg = hit.arg };
                        break;
                    }
                }
                // Inside the sheet, row or not: never falls through to
                // the pane underneath it.
                return;
            }
            // Outside: dismissed; the click still lands below.
        }
        // Status-bar segments and hints: the mouse route into the
        // things the bar names. "menu" arms the leader with the sheet
        // shown NOW — a click is a request for the menu, not a
        // hesitation to time.
        if (y >= self.px_h - self.bar_h) {
            // A tabs segment's chips first: index-name clicks select
            // that tab; the current-style chip cycles to the next.
            for (self.bar_tab_x[0..self.bar_tab_n], 0..) |zx, i| {
                if (x >= zx[0] and x < zx[1]) {
                    const sp = self.activeSpace();
                    if (self.cfg_tab_style == .current) {
                        self.activateTabLocked((sp.active_tab + 1) % sp.tabs.items.len);
                    } else if (i < sp.tabs.items.len) {
                        self.activateTabLocked(i);
                    }
                    return;
                }
            }
            if (x >= self.seg_ws_x[0] and x < self.seg_ws_x[1]) {
                self.pending_cmd = .{ .action = .workspace_switch };
            } else if (x >= self.hint_menu_x[0] and x < self.hint_menu_x[1]) {
                self.wk_visible = true;
                self.wk_armed_at = 0;
                self.scene_dirty = true;
                self.leader_pending.store(true, .release);
            } else if (x >= self.hint_cmd_x[0] and x < self.hint_cmd_x[1]) {
                self.pending_cmd = .{ .action = .palette_commands };
            }
            return;
        }
        // The icon rail: each box runs the command it shows. Queued
        // like every chrome click — dispatch retakes draw_lock.
        if (x < self.railWidth() and y >= self.contentY()) {
            for (self.rail_y[0..self.rail_n], 0..) |zy, i| {
                if (y >= zy[0] and y < zy[1]) {
                    self.pending_cmd = .{ .action = rail_items[i].action };
                    break;
                }
            }
            return;
        }
        // The side pane's inner edge is a resize handle with the splits'
        // ±4px slop, checked before the panes because the slop overlaps
        // the pane beside it. The pane wins nothing by winning: a click
        // 4px from the divider was aimed at the divider.
        if (self.side_open) {
            const sr = self.sideArea();
            const edge = if (self.side == .left) sr.x + sr.w else sr.x;
            if (@abs(x - edge) <= 4 and y >= self.contentY()) {
                self.drag_side = true;
                return;
            }
            if (x >= sr.x and x < sr.x + sr.w and y >= sr.y and y < sr.y + sr.h) {
                // A click in the panel gives it the keys; a row click
                // moves the selection, and clicking the row that HAS the
                // selection opens its actions — the second click is the
                // Enter. Bands come from the last drawn frame, the same
                // truth the eye aimed the mouse with.
                self.side_focus = true;
                self.scene_dirty = true;
                if (self.side_panel == .plugin and self.plug_mode == .rows) {
                    for (self.plug_hit[0..self.plug_hit_n]) |hb| {
                        if (y >= hb[0] and y < hb[1]) {
                            const hit_idx: usize = @intFromFloat(hb[2]);
                            if (hit_idx == self.plug_sel) {
                                if (self.plugItemLocked()) |sel_it| {
                                    if (sel_it.actions_n > 0) {
                                        self.plug_mode = .actions;
                                        self.plug_act_sel = 0;
                                        self.plug_msg_len = 0;
                                    }
                                }
                            } else self.plug_sel = hit_idx;
                            break;
                        }
                    }
                }
                return;
            }
        }
        const t = self.activeTab();
        // Separators are resize handles first (±4px grab slop) — but a
        // zoomed tab shows none, and dragging an invisible one would
        // resize a split you can't see.
        if (if (t.zoomed == null) panespkg.hitSeparator(t.root, x, y, 4) else null) |sp| {
            self.drag_split = sp;
            self.drag_split_rect = panespkg.splitRect(sp);
            return;
        }
        for (t.panes.items) |p| {
            const r = p.rect;
            if (x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h) {
                self.setFocusLocked(p);
                if (p.editor()) |ed| {
                    // The buffer line's chips. mouseCell only claims
                    // row zero while the line is up, so a click
                    // anywhere else keeps meaning "focus the pane".
                    const cell = self.cellAt(p, x, y);
                    if (ed.mouseCell(cell[0], cell[1])) self.scene_dirty = true;
                }
                if (p.term()) |tm| {
                    const cell = self.cellAt(p, x, y);
                    const mm = tm.session.mouseMode();
                    if (!local and mm.mode != .none) {
                        // The app owns the mouse (shift forces local).
                        sendMouse(tm, 0, cell, true, mm.sgr);
                        self.drag_pane = p;
                        self.drag_report = true;
                        self.drag_last_cell = cell;
                        break;
                    }
                    // A fresh click clears the old selection and
                    // anchors a possible drag.
                    tm.session.clearSelection();
                    self.drag_pane = p;
                    self.drag_report = false;
                    self.drag_anchor = cell;
                }
                break;
            }
        }
    }

    /// Encode one mouse event to the pty — SGR (1006) or legacy X10
    /// bytes. btn: 0 left, 3 release(legacy), 32+ motion, 64/65 wheel.
    fn sendMouse(tm: *panespkg.Term, btn: u8, cell: [2]u16, press: bool, sgr: bool) void {
        var buf: [32]u8 = undefined;
        if (sgr) {
            const seq = std.fmt.bufPrint(&buf, "\x1b[<{d};{d};{d}{c}", .{
                btn,
                cell[0] + 1,
                cell[1] + 1,
                @as(u8, if (press) 'M' else 'm'),
            }) catch return;
            tm.session.write(seq);
            return;
        }
        if (cell[0] > 222 or cell[1] > 222) return;
        buf[0] = 0x1b;
        buf[1] = '[';
        buf[2] = 'M';
        buf[3] = 32 +% (if (press) btn else 3);
        buf[4] = 33 +% @as(u8, @intCast(cell[0]));
        buf[5] = 33 +% @as(u8, @intCast(cell[1]));
        tm.session.write(buf[0..6]);
    }

    fn cellAt(self: *App, p: *panespkg.Pane, x: f32, y: f32) [2]u16 {
        const o = self.gridOrigin(p);
        const cx: f32 = @max(0, (x - o.x) / self.renderer.cell_w);
        const cy: f32 = @max(0, (y - o.y) / self.renderer.cell_h);
        return .{
            @intCast(@min(@as(u32, @intFromFloat(cx)), p.cols - 1)),
            @intCast(@min(@as(u32, @intFromFloat(cy)), p.rows - 1)),
        };
    }

    /// Mouse drag: extend the selection from the anchor to the cell
    /// under the pointer.
    pub fn dragTo(self: *App, x: f32, y: f32) void {
        self.draw_lock.lock();
        defer self.draw_lock.unlock();
        if (self.drag_side) {
            const cw = @max(1, self.renderer.cell_w);
            const w = if (self.side == .left) x - self.railWidth() else self.px_w - x;
            // Live: every pane beside it reflows as you pull. The floor
            // keeps the pane readable and its divider grabbable; the
            // ceiling is sideWidth's own half-window rule, restated in
            // cols so the stored value never exceeds what draws.
            self.side_cols = std.math.clamp(w / cw, 20, @max(20, (self.px_w / 2) / cw));
            self.relayoutLocked();
            self.scene_dirty = true;
            return;
        }
        if (self.drag_split) |sp| {
            const r = self.drag_split_rect;
            const ratio = if (sp.horiz)
                (x - r.x) / @max(1, r.w)
            else
                (y - r.y) / @max(1, r.h);
            sp.ratio = std.math.clamp(ratio, 0.1, 0.9);
            self.relayoutLocked();
            self.scene_dirty = true;
            return;
        }
        const p = self.drag_pane orelse return;
        const tm = p.term() orelse return;
        const cur = self.cellAt(p, x, y);
        if (self.drag_report) {
            if (cur[0] == self.drag_last_cell[0] and cur[1] == self.drag_last_cell[1]) return;
            self.drag_last_cell = cur;
            const mm = tm.session.mouseMode();
            // Motion only for button-event (1002) / any-event (1003).
            if (mm.mode == .button or mm.mode == .any) {
                sendMouse(tm, 32, cur, true, mm.sgr);
            }
            return;
        }
        tm.session.setSelection(self.drag_anchor[0], self.drag_anchor[1], cur[0], cur[1]);
    }

    pub fn dragEnd(self: *App) void {
        self.draw_lock.lock();
        defer self.draw_lock.unlock();
        if (self.drag_report) {
            if (self.drag_pane) |p| if (p.term()) |tm| {
                const mm = tm.session.mouseMode();
                sendMouse(tm, 0, self.drag_last_cell, false, mm.sgr);
            };
            self.drag_report = false;
        }
        self.drag_pane = null;
        self.drag_split = null;
        self.drag_side = false;
    }

    /// ⌘C: focused terminal's selection (or editor's register) → the
    /// system pasteboard. Returns the copied text (caller frees) so
    /// ctl \`copy\` can verify without reading the pasteboard.
    /// The SENTINEL is part of the type on purpose. selectionString
    /// allocates len+1 bytes; slicing the sentinel off to get a plain
    /// []const u8 hands the caller a length that doesn't match the
    /// allocation, and freeing it is an invalid free — which only
    /// aborts when len and len+1 land in different size classes, so it
    /// hid for as long as the copied strings happened to be lucky.
    /// Allocator.free adds the sentinel back when the type carries it.
    pub fn copyFocused(self: *App) ?[:0]const u8 {
        self.draw_lock.lock();
        const text: ?[:0]const u8 = switch (self.activeTab().focused.content) {
            .term => |*tm| tm.session.selectionText(self.gpa),
            .edit => |ed| blk: {
                // Visual selection yanks first; otherwise the last yank.
                if (ed.mode == .visual or ed.mode == .visual_line) ed.key("y");
                if (ed.reg.items.len == 0) break :blk null;
                break :blk self.gpa.dupeZ(u8, ed.reg.items) catch null;
            },
            // The monitor has no selection model yet. Copying the
            // selected row's path is the obvious next thing and is
            // deliberately not guessed at here.
            .monitor => null,
        };
        self.draw_lock.unlock();
        const t = text orelse return null;

        const pb = objc.getClass("NSPasteboard").?.msgSend(objc.Object, "generalPasteboard", .{});
        _ = pb.msgSend(i64, "clearContents", .{});
        // NSString from bytes (not NUL-terminated).
        const nss = objc.getClass("NSString").?.msgSend(objc.Object, "alloc", .{})
            .msgSend(objc.Object, "initWithBytes:length:encoding:", .{
            @as(*const anyopaque, t.ptr),
            @as(u64, t.len),
            @as(u64, 4), // NSUTF8StringEncoding
        });
        _ = pb.msgSend(bool, "setString:forType:", .{ nss.value, nsString("public.utf8-plain-text").value });
        return t;
    }

    /// ⌘V: the system pasteboard → the focused pane. Returns the text
    /// pasted (caller frees) so ctl `paste` can report what landed.
    pub fn pasteFocused(self: *App) ?[]const u8 {
        const pb = objc.getClass("NSPasteboard").?.msgSend(objc.Object, "generalPasteboard", .{});
        const nss = pb.msgSend(objc.Object, "stringForType:", .{nsString("public.utf8-plain-text").value});
        if (nss.value == null) return null;
        const cstr = nss.msgSend(?[*:0]const u8, "UTF8String", .{}) orelse return null;
        const text = self.gpa.dupe(u8, std.mem.span(cstr)) catch return null;
        if (text.len == 0) {
            self.gpa.free(text);
            return null;
        }
        self.pasteText(text);
        return text;
    }

    /// Route pasted text to the focused pane. Split from pasteFocused so
    /// ctl can drive the identical path with literal text — ⌘V carries a
    /// modifier the ctl `press` verb can't express, and an unverifiable
    /// input path is the one that rots.
    pub fn pasteText(self: *App, text: []const u8) void {
        self.draw_lock.lock();
        defer self.draw_lock.unlock();
        self.scene_dirty = true;

        if (self.pal_open) {
            // A filter is one line: take the first, drop the controls.
            const line = text[0 .. std.mem.indexOfScalar(u8, text, '\n') orelse text.len];
            for (line) |ch| {
                if (ch >= 0x20 and ch != 0x7f) self.palKeyLocked(&[_]u8{ch});
            }
            // No drain here: pasting only ever types into the filter —
            // palKeyLocked's Enter path is what queues a command, and
            // the control bytes that would reach it are stripped above.
            return;
        }

        const p = self.activeTab().focused;
        switch (p.content) {
            .edit => |ed| ed.pasteText(text),
            // Nothing on the monitor takes text.
            .monitor => {},
            .term => |*t| {
                // Copy mode is a viewport, not an input mode — pasting
                // means you're done reading history, same as typing.
                t.copy_mode = false;
                const bytes = pastepkg.encode(self.gpa, text, t.session.bracketedPaste()) catch return;
                defer self.gpa.free(bytes);
                t.session.write(bytes);
                t.session.scrollTo(.active);
            },
        }
    }

    /// Record new preedit length and redraw. Called from the IME
    /// callbacks, which run on the main thread inside handleEvent:.
    fn setMarked(self: *App, len: usize) void {
        self.ime_marked_len = len;
        self.draw_lock.lock();
        self.scene_dirty = true;
        self.draw_lock.unlock();
    }

    /// The focused pane's cursor as a pixel rect in the scene (top-left
    /// origin, the renderer's coordinates). Terminals answer from the
    /// emulator's viewport cursor; editors from their own grid, gutter
    /// included. Caller holds draw_lock.
    fn cursorPxLocked(self: *App) struct { x: f32, y: f32 } {
        const p = self.activeTab().focused;
        const cw = self.renderer.cell_w;
        const ch = self.renderer.cell_h;
        var col: f32 = 0;
        var row: f32 = 0;
        switch (p.content) {
            .term => |*tm| if (tm.rs.cursor.viewport) |cur| {
                col = @floatFromInt(cur.x);
                row = @floatFromInt(cur.y);
            },
            .edit => |ed| {
                const c = ed.cursorCell();
                col = @floatFromInt(c.col);
                row = @floatFromInt(c.row);
            },
            // No text cursor: selection is a highlighted ROW, so there
            // is no caret for an IME box to sit under.
            .monitor => {},
        }
        const o = self.gridOrigin(p);
        return .{ .x = o.x + col * cw, .y = o.y + row * ch };
    }

    /// Same point, in SCREEN coordinates and points — what AppKit wants
    /// for the candidate window. Scene pixels are top-left origin and
    /// retina-scaled; screen points are bottom-left origin.
    fn cursorScreenRect(self: *App) NSRect {
        self.draw_lock.lock();
        const px = self.cursorPxLocked();
        const ch = self.renderer.cell_h;
        const cw = self.renderer.cell_w;
        self.draw_lock.unlock();

        const scale: f32 = @floatCast(self.layer.msgSend(f64, "contentsScale", .{}));
        const view_h = self.px_h / scale;
        const rect_in_window = NSRect{
            .origin = .{ .x = px.x / scale, .y = view_h - (px.y + ch) / scale },
            .size = .{ .width = cw / scale, .height = ch / scale },
        };
        return self.window.msgSend(NSRect, "convertRectToScreen:", .{rect_in_window});
    }

    /// Preedit: what the input method is composing, drawn AT the cursor
    /// with an underline, the way every text field shows it. It is not
    /// input yet, so it lives entirely in chrome — the emulator never
    /// sees it, and `dump` will not show it (`shot` will).
    fn drawPreedit(self: *App, ui: *@import("ui.zig").Ui) void {
        const at = self.cursorPxLocked();
        const text = self.ime_marked[0..self.ime_marked_len];
        const w = ui.text(at.x, at.y, text, th.ed_bg, th.accent);
        ui.rect(at.x, at.y + self.renderer.cell_h - 2, w, 2, th.bar_value);
    }

    /// Wheel steps (+ = scroll up) routed to the pane under the point:
    /// editors move their viewport, alt-screen terminals get arrows,
    /// primary-screen terminal scrollback lands with the scrollback
    /// slice.
    pub fn wheelAt(self: *App, x: f32, y: f32, lines_in: i64) void {
        self.draw_lock.lock();
        defer self.draw_lock.unlock();
        var lines = lines_in;
        const t = self.activeTab();
        for (t.panes.items) |p| {
            const r = p.rect;
            if (!(x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h)) continue;
            switch (p.content) {
                .edit => |ed| {
                    ed.scroll(-lines);
                    self.scene_dirty = true;
                },
                .monitor => |m| {
                    m.scrollBy(lines);
                    self.scene_dirty = true;
                },
                .term => |*tm| {
                    const mm = tm.session.mouseMode();
                    if (mm.mode != .none) {
                        // Wheel events to the app: 64 up, 65 down.
                        const cell = self.cellAt(p, x, y);
                        const btn: u8 = if (lines > 0) 64 else 65;
                        var n: i64 = if (lines < 0) -lines else lines;
                        if (n > 10) n = 10;
                        while (n > 0) : (n -= 1) sendMouse(tm, btn, cell, true, mm.sgr);
                        break;
                    }
                    const alt = tm.session.term.screens.active_key == .alternate;
                    if (alt) {
                        // Alt-screen apps take arrows (vim/less).
                        const seq: []const u8 = if (lines > 0) "\x1b[A" else "\x1b[B";
                        if (lines < 0) lines = -lines;
                        var n: i64 = 0;
                        while (n < lines and n < 20) : (n += 1) tm.session.write(seq);
                    } else {
                        // Primary screen: scroll the viewport into
                        // history; typing snaps back.
                        tm.session.scrollViewport(@intCast(-lines));
                    }
                },
            }
            break;
        }
    }

    /// The focused pane's shell cwd via libproc — new tabs and splits
    /// open where you are, the tmux/wails behavior (TODO.md item one).
    /// Buffer-owned by App; valid until the next call.
    fn focusedCwd(self: *App) ?[*:0]const u8 {
        return self.paneCwd(self.activeTab().focused);
    }

    /// A pane's shell cwd via the kernel (proc_pidinfo) — a takeover
    /// editor's parked shell counts (the pane is still "at" that dir).
    fn paneCwd(self: *App, p: *panespkg.Pane) ?[*:0]const u8 {
        const tm = p.term() orelse (if (p.under) |*ut| ut else return null);
        // struct proc_vnodepathinfo { vnode_info_path pvi_cdir; ... };
        // vip_path (MAXPATHLEN) sits after the 152-byte vnode_info.
        const n = proc_pidinfo(tm.session.pid, PROC_PIDVNODEPATHINFO, 0, &self.cwd_info, self.cwd_info.len);
        if (n <= 152) return null;
        const path: [*:0]const u8 = @ptrCast(self.cwd_info[152..]);
        if (path[0] != '/') return null;
        return path;
    }

    /// Spawn a shell session wrapped in a fresh pane. Caller inserts it
    /// into a tree and a tab (holding draw_lock — focusedCwd reads the
    /// focused pane).
    fn makePane(self: *App, cwd: ?[*:0]const u8) !*panespkg.Pane {
        return self.makePaneCmd(cwd, null);
    }

    /// …with a command the shell runs instead of going interactive. The
    /// pane lives as long as the command does, which is what `session.spawn`
    /// means by a session.
    fn makePaneCmd(self: *App, cwd: ?[*:0]const u8, cmd: ?[*:0]const u8) !*panespkg.Pane {
        const session = try sessionpkg.Session.start(self.gpa, self.io, self.shell, cwd, cmd, termColors(), 80, 24, @intCast(self.renderer.cellw_px), @intCast(self.renderer.cellh_px), self.cfg_scrollback);
        session.kick = &inputKick;
        session.kick_ctx = self;
        session.clip_allow = self.cfg_clip_allow;
        const pane = try self.gpa.create(panespkg.Pane);
        pane.* = .{ .id = self.next_pane_id, .content = .{ .term = .{ .session = session } } };
        self.next_pane_id += 1;
        return pane;
    }

    /// The focused pane's session, or null when an editor holds focus.
    fn focusedTermSession(self: *App) ?*sessionpkg.Session {
        return if (self.activeTab().focused.term()) |t| t.session else null;
    }

    /// Open `path` in an editor: retarget a focused editor pane in
    /// place (the rook-buffers model), else TAKE OVER the focused
    /// terminal pane — the shell parks in `pane.under` and keeps
    /// running; editor :q restores it, like vim in a terminal.
    /// Open a file with the cursor on `line` (1-based). The review
    /// panel's Enter: a finding names a place, and landing anywhere else
    /// makes you hunt for it.
    pub fn openEditorAtLine(self: *App, path: []const u8, line: i64) bool {
        return self.openEditorAt(path, line, 0);
    }

    /// …and at a COLUMN, for callers that know one. Clamped to the line,
    /// which is the whole reason it is applied here rather than by the
    /// caller: only this side has the buffer.
    pub fn openEditorAt(self: *App, path: []const u8, line: i64, col: usize) bool {
        if (!self.openEditor(path)) return false;
        self.draw_lock.lock();
        defer self.draw_lock.unlock();
        const ed = self.activeTab().focused.editor() orelse return true;
        const n = ed.lineCountB();
        ed.cline = @min(@as(usize, @intCast(@max(line, 1))) - 1, n -| 1);
        ed.ccol = @min(col, ed.lineCap(ed.cline));
        ed.goal = ed.renderColAt(ed.cline, ed.ccol);
        self.scene_dirty = true;
        return true;
    }

    /// …and verified against WHAT the jump was for. A results panel
    /// records scan-time line numbers, and an edit above a hit shifts
    /// every line below it — trusting the number after that lands you
    /// on the wrong line with no sign anything is off. So the landing
    /// checks: if the recorded spot still holds the match it stands,
    /// and if not, the NEAREST line that does is where the hit went.
    /// A match nowhere in the file falls back to the recorded numbers,
    /// clamped — the least wrong place left.
    pub fn openEditorAtMatch(self: *App, path: []const u8, line: i64, col: usize, needle: []const u8) bool {
        if (!self.openEditor(path)) return false;
        self.draw_lock.lock();
        defer self.draw_lock.unlock();
        const ed = self.activeTab().focused.editor() orelse return true;
        const n = ed.lineCountB();
        var want: usize = @min(@as(usize, @intCast(@max(line, 1))) - 1, n -| 1);
        var wcol: usize = col;
        if (needle.len > 0) relocate: {
            const sensitive = searchpkg.caseSensitive(needle);
            // The recorded spot still holds the match: done. Checked at
            // the exact column, not anywhere-in-line — a second
            // occurrence earlier in the line must not pass for the one
            // the panel showed.
            const text = ed.lineText(want);
            if (wcol + needle.len <= text.len and
                searchpkg.find(text[wcol .. wcol + needle.len], needle, sensitive) != null)
            {
                break :relocate;
            }
            // It moved. Walk outward from where it was — the nearest
            // matching line is almost always the same hit, shifted.
            var d: usize = 0;
            while (d < n) : (d += 1) {
                if (want >= d) {
                    if (searchpkg.find(ed.lineText(want - d), needle, sensitive)) |at| {
                        want -= d;
                        wcol = at;
                        break :relocate;
                    }
                }
                if (d > 0 and want + d < n) {
                    if (searchpkg.find(ed.lineText(want + d), needle, sensitive)) |at| {
                        want += d;
                        wcol = at;
                        break :relocate;
                    }
                }
                if (want < d and want + d >= n) break;
            }
        }
        ed.cline = want;
        ed.ccol = @min(wcol, ed.lineCap(ed.cline));
        ed.goal = ed.renderColAt(ed.cline, ed.ccol);
        self.scene_dirty = true;
        return true;
    }

    pub fn openEditor(self: *App, path: []const u8) bool {
        self.draw_lock.lock();
        defer self.draw_lock.unlock();
        const t = self.activeTab();
        const p = t.focused;
        if (p.editor()) |ed| {
            // Retarget is an open as far as the server is concerned:
            // new path, new document, new diagnostics. `open` says so
            // itself now, through on_retarget — attaching here as well
            // would didOpen the document twice.
            ed.open(path, false) catch return false;
            self.scene_dirty = true;
            return true;
        }
        const ed = self.newEditorLocked(path) orelse return false;
        var tm = p.content.term;
        tm.copy_mode = false;
        p.under = tm;
        p.content = .{ .edit = ed };
        p.drawn_cursor = 0xffff_ffff;
        self.focused_session.store(self.focusedTermSession(), .release);
        self.refreshHudLocked(CACurrentMediaTime());
        self.scene_dirty = true;
        return true;
    }

    /// Recompute the ACTIVE tab's pane rects and resize changed grids.
    /// Background tabs relayout on activation. Caller holds draw_lock.
    fn relayoutLocked(self: *App) void {
        const t = self.activeTab();
        panespkg.layoutTab(t, self.paneArea(), self.sep);
        for (t.panes.items) |p| {
            // Zero rect = zoomed out of sight. Leave its grid alone;
            // resizing hidden panes to a 2x2 minimum would reflow their
            // scrollback on every zoom and again on every unzoom.
            if (p.rect.w == 0 or p.rect.h == 0) continue;
            const inset = self.m.pane_pad * 2;
            const cols: u16 = @intFromFloat(@max(2, @divFloor(p.rect.w - inset, self.renderer.cell_w)));
            const rows: u16 = @intFromFloat(@max(2, @divFloor(p.rect.h - inset, self.renderer.cell_h)));
            if (cols == p.cols and rows == p.rows) continue;
            p.cols = cols;
            p.rows = rows;
            switch (p.content) {
                .term => |*tm| tm.session.resize(cols, rows, @intCast(self.renderer.cellw_px), @intCast(self.renderer.cellh_px)),
                .edit => |ed| ed.render_dirty = true,
                // The grid is rebuilt from the sample on every fill, so
                // a resize needs nothing but a repaint.
                .monitor => |m| m.render_dirty = true,
            }
            // A parked shell must track pane dims too, or a resize
            // during takeover restores a mis-sized grid.
            if (p.under) |*ut| ut.session.resize(cols, rows, @intCast(self.renderer.cellw_px), @intCast(self.renderer.cellh_px));
        }
    }

    /// Split the focused pane; the new pane takes focus. Any thread.
    pub fn splitFocused(self: *App, horiz: bool) void {
        self.draw_lock.lock();
        defer self.draw_lock.unlock();
        const t = self.activeTab();
        const pane = self.makePane(self.focusedCwd()) catch |err| {
            std.debug.print("rook: split failed: {}\n", .{err});
            return;
        };
        if (!panespkg.splitAt(self.gpa, &t.root, t.focused, pane, horiz)) {
            std.debug.print("rook: split target missing\n", .{});
            return;
        }
        t.panes.append(self.gpa, pane) catch {};
        self.setFocusLocked(pane);
        self.relayoutLocked();
        // No synchronous draw: encoding from the calling thread contends
        // on nextDrawable (measured wedge from the ctl thread). The
        // display link sees scene_dirty within a tick.
        self.refreshHudLocked(CACurrentMediaTime());
        self.scene_dirty = true;
    }

    /// Open a new tab with one fresh shell and activate it. Any thread.
    pub fn newTab(self: *App) void {
        self.draw_lock.lock();
        defer self.draw_lock.unlock();
        self.newTabLocked(self.focusedCwd());
    }

    fn newTabLocked(self: *App, cwd: ?[*:0]const u8) void {
        const pane = self.makePane(cwd) catch |err| {
            std.debug.print("rook: new tab failed: {}\n", .{err});
            return;
        };
        const t = self.gpa.create(panespkg.Tab) catch return;
        t.* = .{ .id = self.next_tab_id, .root = .{ .leaf = pane }, .focused = pane };
        self.next_tab_id += 1;
        t.panes.append(self.gpa, pane) catch {};
        const s = self.activeSpace();
        s.tabs.append(self.gpa, t) catch return;
        self.activateTabLocked(s.tabs.items.len - 1);
    }

    /// Switch to tab index i (0-based). Any thread.
    pub fn selectTab(self: *App, i: usize) bool {
        self.draw_lock.lock();
        defer self.draw_lock.unlock();
        if (i >= self.activeSpace().tabs.items.len) return false;
        self.activateTabLocked(i);
        return true;
    }

    /// Cycle tabs by delta (±1) within the active space. Any thread.
    pub fn cycleTab(self: *App, delta: i32) void {
        self.draw_lock.lock();
        defer self.draw_lock.unlock();
        const n: i64 = @intCast(self.activeSpace().tabs.items.len);
        const cur: i64 = @intCast(self.activeSpace().active_tab);
        self.activateTabLocked(@intCast(@mod(cur + delta, n)));
    }

    fn activateTabLocked(self: *App, i: usize) void {
        self.activeSpace().active_tab = i;
        // Looking at it IS the acknowledgement. No separate dismiss.
        self.activeSpace().tabs.items[i].bell = false;
        self.focused_session.store(self.focusedTermSession(), .release);
        // The window may have resized while this tab was hidden.
        self.relayoutLocked();
        self.refreshHudLocked(CACurrentMediaTime());
        self.scene_dirty = true;
    }

    /// Switch workspace sessions — the whole window swaps tab sets.
    fn activateSpaceLocked(self: *App, i: usize) void {
        self.active_space = i;
        const s = self.activeSpace();
        if (s.active_tab >= s.tabs.items.len) s.active_tab = s.tabs.items.len -| 1;
        self.activateTabLocked(s.active_tab);
    }

    /// Route input to the focused pane under the scene lock: terminal
    /// bytes go to the pty, editor bytes drive the modal machine. Both
    /// mark input — the editor's echo is synchronous, so its dirty
    /// frame carries the key→photon mark the same way a pty echo does.
    /// Returns true when CHROME consumed the bytes (welcome, palette, a
    /// focused side panel) — `ctl press` reports consumed/typed from
    /// this, and it used to answer from the leader machine alone, which
    /// called a key the panel ate "typed".
    pub fn writeFocused(self: *App, bytes: []const u8, ts: f64) bool {
        var chrome: bool = undefined;
        {
            self.draw_lock.lock();
            defer self.draw_lock.unlock();
            self.markInput(ts);
            chrome = self.routeChromeKeyLocked(bytes);
            if (!chrome)
                self.paneInput(self.activeTab().focused, bytes);
        }
        // Outside the block on purpose — see pending_cmd.
        self.drainPendingCmd();
        return chrome;
    }

    /// THE routing rule for untargeted input: the palette owns the whole
    /// screen, then a focused side pane owns its region, then nothing —
    /// the caller sends it to the pane.
    ///
    /// One function because there are TWO entry points (real keys and
    /// ctl) and keeping the priority in both is how they drift: adding
    /// the threads panel to one of them and not the other is exactly the
    /// bug this replaced. Returns true if chrome consumed the bytes.
    /// Caller holds draw_lock.
    pub fn routeChromeKeyLocked(self: *App, bytes: []const u8) bool {
        if (self.welcome_open) {
            self.welcomeKeyLocked(bytes);
            return true;
        }
        if (self.pal_open) {
            self.palKeyLocked(bytes);
            return true;
        }
        if (!self.side_focus) return false;
        switch (self.side_panel) {
            .search => self.searchKeyLocked(bytes),
            .plugin => self.pluginKeyLocked(bytes),
            .config => self.configKeyLocked(bytes),
        }
        return true;
    }

    /// The question the ENCODER has to ask, and the mirror of the
    /// routing rule directly above: is a live pty going to receive
    /// these bytes, and if so what has it asked for?
    ///
    /// It lives here, touching the same fields in the same order, for
    /// the reason that function gives for existing at all — a priority
    /// kept in two places drifts. Adding a tenant means adding it to
    /// both, and they are adjacent so that you see the second one.
    ///
    /// Null means chrome or an editor owns the keys. Those read the
    /// small stream rook has always spoken — bare arrows, a plain tab —
    /// and would mis-parse a `CSI 1;5D` into three typed characters.
    /// Only a terminal gets the full encoding, because only a terminal
    /// can say what it wants. Caller holds draw_lock.
    pub fn ptyModesLocked(self: *App) ?keyenc.Modes {
        if (self.pal_open) return null;
        if (self.side_focus) return null;
        const tm = switch (self.activeTab().focused.content) {
            .term => |*t| t,
            .edit, .monitor => return null,
        };
        // Read without the session mutex, like the alt-screen check in
        // the event monitor: both screens outlive any single keystroke,
        // so the worst a race costs is one key encoded against the mode
        // set from a frame ago.
        const k = tm.session.term.screens.active.kitty_keyboard.current();
        return .{
            .cursor_keys = tm.session.term.modes.get(.cursor_keys),
            .kitty = .{
                .disambiguate = k.disambiguate,
                .report_events = k.report_events,
                .report_alternates = k.report_alternates,
                .report_all = k.report_all,
                .report_associated = k.report_associated,
            },
        };
    }

    /// Route input into a pane: editors take the modal machine, a
    /// copy-mode terminal scrolls, a live terminal writes to the pty
    /// (and typing snaps a scrolled viewport back — every terminal's
    /// convention). ONE path for NSEvents and ctl. Caller holds
    /// draw_lock.
    pub fn paneInput(self: *App, p: *panespkg.Pane, bytes: []const u8) void {
        switch (p.content) {
            .term => |*t| {
                if (t.copy_mode) {
                    self.copyModeKey(t, bytes);
                    return;
                }
                t.session.write(bytes);
                t.session.scrollTo(.active);
            },
            .edit => |ed| ed.key(bytes),
            .monitor => |m| {
                // One byte at a time: the view model's key table is
                // single-char, and a paste or a multi-byte escape must
                // not be replayed as a run of commands.
                for (bytes) |b| self.monitorActLocked(p, m, m.key(b));
            },
        }
    }

    /// Perform what the monitor's key table asked for.
    ///
    /// The split is deliberate: `monitor.zig` decides WHAT should happen
    /// and cannot do any of it — it has no threads, no allocator for
    /// subprocesses and no filesystem. Everything that touches the
    /// machine is here, which is also what keeps the destructive path
    /// down to one reviewable function. Caller holds draw_lock.
    fn monitorActLocked(self: *App, p: *panespkg.Pane, m: *monitorpkg.Monitor, act: monitorpkg.Monitor.Act) void {
        switch (act) {
            .none => {},
            .redraw => self.scene_dirty = true,
            .close => {
                m.closed = true;
                self.scene_dirty = true;
            },
            .drill => {
                const sc = m.scan orelse return;
                const parent = &sc.nodes.items[m.disk_root];
                if (m.sel >= parent.children.items.len) return;
                const into = parent.children.items[m.sel];
                // A leaf is not a dead end you bounce off silently — say
                // so, or the key reads as broken.
                if (sc.nodes.items[into].children.items.len == 0) {
                    m.setMsg("nothing under this one at the scanned depth — s rescans deeper");
                    self.scene_dirty = true;
                    return;
                }
                m.disk_stack.append(self.gpa, m.disk_root) catch return;
                m.disk_root = into;
                m.sel = 0;
                m.scroll = 0;
                diskscan.sortChildren(sc, into);
                self.scene_dirty = true;
            },
            .rescan => self.startDiskScan(m),
            .reclaim => self.startReclaim(m),
        }
        _ = p;
    }

    /// Close the focused pane (⌘W): a terminal gets hung up — SIGHUP to
    /// the shell's AND the foreground process group, with an off-thread
    /// escalation to SIGTERM/SIGKILL for anything that traps it — and
    /// the normal reap collapses the pane once the shell exits; an
    /// editor takes :q semantics — unsaved changes refuse with a status
    /// message (:q! or :wq inside the editor to force).
    pub fn closeFocused(self: *App) void {
        self.draw_lock.lock();
        defer self.draw_lock.unlock();
        switch (self.activeTab().focused.content) {
            .term => |*tm| tm.session.hangup(),
            .edit => |ed| {
                if (ed.buf.isModified()) {
                    ed.setStatusUnsaved();
                } else ed.closed = true;
                ed.render_dirty = true;
            },
            // Nothing unsaved can exist here, so ⌘W just goes.
            .monitor => |m| {
                m.closed = true;
                m.render_dirty = true;
            },
        }
        self.scene_dirty = true;
    }

    /// ⌘Q's half of the same teardown, for EVERY live session at once —
    /// including shells parked under a takeover editor or monitor.
    /// Relying on process exit is not enough: closing a master delivers
    /// the kernel's SIGHUP only to the foreground group, and a job that
    /// traps it survives the app. The group ids are captured under
    /// draw_lock while every master is still open; the signalling and
    /// its one grace period run OUTSIDE the lock, blocking this (main)
    /// thread on purpose — quit is past the last frame, and a detached
    /// thread would not outlive the process exit that follows.
    pub fn hangupAllSessions(self: *App) void {
        var groups: std.ArrayListUnmanaged(ptypkg.ProcessGroups) = .empty;
        defer groups.deinit(self.gpa);
        self.draw_lock.lock();
        for (self.spaces.items) |space| {
            for (space.tabs.items) |t| {
                for (t.panes.items) |p| {
                    switch (p.content) {
                        .term => |*tm| groups.append(self.gpa, ptypkg.ProcessGroups.capture(tm.session.pty.master, tm.session.pid)) catch {},
                        else => {},
                    }
                    if (p.under) |ut| groups.append(self.gpa, ptypkg.ProcessGroups.capture(ut.session.pty.master, ut.session.pid)) catch {};
                }
            }
        }
        self.draw_lock.unlock();
        ptypkg.terminateAll(groups.items);
    }

    /// Enter tmux-style copy mode on the focused terminal pane.
    pub fn enterCopyMode(self: *App) void {
        self.draw_lock.lock();
        defer self.draw_lock.unlock();
        if (self.activeTab().focused.term()) |tm| {
            tm.copy_mode = true;
            tm.copy_g = false;
            self.scene_dirty = true;
        }
    }

    /// Copy-mode keys: vim motions scroll the viewport; q/ESC/i/Enter
    /// snap back to the live screen and exit. Caller holds draw_lock.
    fn copyModeKey(self: *App, tm: *panespkg.Term, bytes: []const u8) void {
        const rows: isize = @intCast(@max(2, self.activeTab().focused.rows));
        for (bytes) |ch| {
            // The `/` prompt owns every key while it is open, motions
            // included — you are typing a needle, not scrolling.
            if (tm.search_input) {
                switch (ch) {
                    '\r', '\n' => {
                        tm.search_input = false;
                        self.runSearchLocked(tm);
                    },
                    0x1b => { // ESC abandons the prompt, not the mode
                        tm.search_input = false;
                        tm.search_len = 0;
                    },
                    0x7f, 0x08 => {
                        // Backspacing past the first character closes the
                        // prompt, the way vim's / does.
                        if (tm.search_len == 0) {
                            tm.search_input = false;
                        } else tm.search_len -= 1;
                    },
                    else => if (ch >= 0x20 and ch < 0x7f and tm.search_len < tm.search_buf.len) {
                        tm.search_buf[tm.search_len] = ch;
                        tm.search_len += 1;
                    },
                }
                continue;
            }
            if (tm.copy_g and ch == 'g') {
                tm.copy_g = false;
                tm.session.scrollTo(.top);
                continue;
            }
            tm.copy_g = false;
            switch (ch) {
                'g' => tm.copy_g = true,
                'j' => tm.session.scrollViewport(1),
                'k' => tm.session.scrollViewport(-1),
                'd', 0x04 => tm.session.scrollViewport(@divTrunc(rows, 2)),
                'u', 0x15 => tm.session.scrollViewport(-@divTrunc(rows, 2)),
                'f', 0x06 => tm.session.scrollViewport(rows - 1),
                'b', 0x02 => tm.session.scrollViewport(-(rows - 1)),
                'G' => tm.session.scrollTo(.active),
                '/' => {
                    tm.search_input = true;
                    tm.search_len = 0;
                },
                // Vim's directions: n keeps going the way / went (back
                // through history), N turns around.
                'n' => self.stepSearchLocked(tm, true),
                'N' => self.stepSearchLocked(tm, false),
                'q', 0x1b, 'i', '\r' => {
                    tm.copy_mode = false;
                    tm.session.scrollTo(.active);
                    self.endSearchLocked(tm);
                },
                else => {},
            }
        }
        self.scene_dirty = true;
    }

    /// Run the typed needle and jump to the first hit. Caller holds
    /// draw_lock.
    fn runSearchLocked(self: *App, tm: *panespkg.Term) void {
        tm.search_i = 0;
        tm.search_n = tm.session.searchBegin(tm.search_buf[0..tm.search_len]);
        if (tm.search_n == 0) return;
        // The library orders matches newest-first, so the first `next`
        // lands on the hit CLOSEST TO THE BOTTOM — nearest to where you
        // were looking, which is what searching backwards should mean.
        self.stepSearchLocked(tm, true);
    }

    /// Move to the next/previous match. Caller holds draw_lock.
    fn stepSearchLocked(self: *App, tm: *panespkg.Term, next: bool) void {
        if (tm.search_n == 0) return;
        const rows: u16 = @intCast(@min(self.activeTab().focused.rows, std.math.maxInt(u16)));
        if (!tm.session.searchSelect(next, rows)) {
            // The only way this fails after a successful begin is the
            // screen changing under us (alt screen); the session has
            // already dropped the search, so drop our readout too.
            tm.search_n = 0;
            tm.search_i = 0;
            return;
        }
        const w = tm.session.searchWhere();
        tm.search_i = w.idx;
        tm.search_n = w.n;
    }

    fn endSearchLocked(_: *App, tm: *panespkg.Term) void {
        tm.session.searchEnd();
        tm.session.clearSelection();
        tm.search_input = false;
        tm.search_len = 0;
        tm.search_i = 0;
        tm.search_n = 0;
    }

    fn barDirty(self: *App) void {
        self.draw_lock.lock();
        self.scene_dirty = true;
        self.draw_lock.unlock();
    }

    // ------------------------------------------------------------ palette
    // The workspace switcher, and the seed of every future picker
    // (file finder, themes, commands): type-to-filter over a list, a
    // modal that owns the key path while open.

    /// Open the workspace picker with a fresh read of the environment
    /// graph, so it lists what config last applied. Any thread.
    pub fn openPalette(self: *App) void {
        self.draw_lock.lock();
        defer self.draw_lock.unlock();
        workspacespkg.free(self.gpa, self.pal_items);
        self.pal_items = workspacespkg.load(self.io, self.gpa);
        self.pal_mode = .workspaces;
        self.resetPaletteLocked();
    }

    /// Open the COMMAND palette (⌘K) over registry.zig. Any thread.
    /// No load step — the command table is static, which is also why
    /// this one can never fail or block on sqlite.
    pub fn openCommandPalette(self: *App) void {
        self.draw_lock.lock();
        defer self.draw_lock.unlock();
        self.pal_mode = .commands;
        self.resetPaletteLocked();
    }

    /// Open the FILE finder (⌘P) over the focused pane's repo.
    ///
    /// The root is the focused pane's own context, not the space's:
    /// `cd` is sacred, so a shell that walked into a submodule finds
    /// the submodule's files. Walked fresh at every open — a file
    /// created by the agent you are watching has to be findable
    /// without a restart, and a repo-sized walk is milliseconds.
    pub fn openFilePalette(self: *App) void {
        self.draw_lock.lock();
        defer self.draw_lock.unlock();
        var rootbuf: [1024]u8 = undefined;
        const root = self.paneRootLocked(self.activeTab().focused, &rootbuf) orelse "";
        self.pal_files.deinit(self.gpa);
        self.pal_files = filelistpkg.load(self.gpa, root);
        self.pal_mode = .files;
        self.resetPaletteLocked();
    }

    /// Open the PLUGIN picker (`<leader>p`).
    ///
    /// The bridge between a command table that is compiled in and plugins
    /// that are declared at runtime: one command that lists them, rather
    /// than a command per plugin that the registry could not hold. Without
    /// it a plugin is reachable only from the ctl socket, which makes every
    /// plugin invisible to anyone using rook as a GUI.
    ///
    /// No load step — the registry was read at launch and does not move.
    pub fn openPluginPalette(self: *App) void {
        self.draw_lock.lock();
        defer self.draw_lock.unlock();
        self.pal_mode = .plugins;
        self.resetPaletteLocked();
    }

    fn resetPaletteLocked(self: *App) void {
        self.pal_input_len = 0;
        self.pal_sel = 0;
        self.pal_open = true;
        self.palRefilterLocked();
        self.scene_dirty = true;
    }

    /// Close hides; pal_items PERSISTS between opens (openPalette
    /// refreshes it; startup space-naming resolves against it).
    fn closePaletteLocked(self: *App) void {
        self.pal_open = false;
        self.pal_nfiltered = 0;
        self.scene_dirty = true;
    }

    /// A command's LIVE chord, resolved from config's binding table —
    /// "` g", "␣ v" — or null when no chord reaches it. This is what
    /// the palette shows over registry's hand-written `keys` strings:
    /// those don't follow a rebind, and a hint that teaches yesterday's
    /// key is worse than none. Caller holds draw_lock.
    pub fn liveChordHint(self: *App, action: registrypkg.Action, arg: u8, buf: []u8) ?[]const u8 {
        const ld = self.keybinds.leader orelse return null;
        for (self.keybinds.entries[0..self.keybinds.n]) |e| {
            if (e.action == action and e.arg == arg) {
                var lg: [4]u8 = undefined;
                var cg: [4]u8 = undefined;
                return std.fmt.bufPrint(buf, "{s} {s}", .{ keyGlyph(ld, &lg), keyGlyph(e.ch, &cg) }) catch null;
            }
        }
        return null;
    }

    /// Case-insensitive subsequence match — the telescope basic. Items
    /// keep db order (already ranked by last_used).
    fn fuzzyMatch(hay: []const u8, needle: []const u8) bool {
        return fuzzy.matches(hay, needle);
    }

    /// Subsequence match with a SCORE, for the one list long enough to
    /// need ranking. A file picker that returns matches in walk order
    /// is a file picker you scroll, which is the thing ⌘P exists not
    /// to do. Higher is better; null is no match.
    ///
    /// The weights, and the reasoning behind them, live in fuzzy.zig
    /// with the completion menu's — one matcher, two profiles, because
    /// the walk and the traceback are the same and only the table of
    /// bonuses differs.
    fn fuzzyScore(hay: []const u8, needle: []const u8) ?i32 {
        const m = fuzzy.match(hay, needle, fuzzy.path) orelse return null;
        return m.score;
    }

    /// Keep the best `pal_filtered.len` by score, insertion-sorted —
    /// the list is thousands long and only the top dozen is ever seen,
    /// so a full sort would be work nobody looks at.
    fn palInsertScored(self: *App, idx: usize, score: i32) void {
        var at = self.pal_nfiltered;
        if (at == self.pal_filtered.len) {
            if (score <= self.pal_scores[at - 1]) return;
            at -= 1;
        } else {
            self.pal_nfiltered += 1;
        }
        while (at > 0 and self.pal_scores[at - 1] < score) : (at -= 1) {
            self.pal_scores[at] = self.pal_scores[at - 1];
            self.pal_filtered[at] = self.pal_filtered[at - 1];
        }
        self.pal_scores[at] = score;
        self.pal_filtered[at] = idx;
    }

    fn palRefilterLocked(self: *App) void {
        const needle = self.pal_input[0..self.pal_input_len];
        self.pal_nfiltered = 0;
        switch (self.pal_mode) {
            // The one list that RANKS: thousands of paths, of which
            // only the top dozen is ever read.
            .files => for (self.pal_files.paths, 0..) |path, i| {
                const sc = fuzzyScore(path, needle) orelse continue;
                self.palInsertScored(i, sc);
            },
            // Name and state both: "up" and "failed" are worth filtering
            // on when several are declared and one is broken.
            .plugins => for (self.plugins.items, 0..) |*p, i| {
                if (self.pal_nfiltered >= self.pal_filtered.len) break;
                if (fuzzyMatch(p.spec.name, needle) or fuzzyMatch(@tagName(p.state), needle)) {
                    self.pal_filtered[self.pal_nfiltered] = i;
                    self.pal_nfiltered += 1;
                }
            },
            .workspaces => for (self.pal_items, 0..) |e, i| {
                if (self.pal_nfiltered >= self.pal_filtered.len) break;
                // Children match on "parent/name" so "rook/zig" and "rz"
                // both find the zig worktree.
                var lbl: [64]u8 = undefined;
                const label = if (e.parent.len > 0)
                    std.fmt.bufPrint(&lbl, "{s}/{s}", .{ e.parent, e.name }) catch e.name
                else
                    e.name;
                if (fuzzyMatch(label, needle) or fuzzyMatch(e.root, needle)) {
                    self.pal_filtered[self.pal_nfiltered] = i;
                    self.pal_nfiltered += 1;
                }
            },
            // The action's title is all a human has; its KIND is what
            // an agent (and a habit) knows it by — "source.organize"
            // finds the one you meant without reading the list.
            .actions => for (self.pal_actions, 0..) |a, i| {
                if (self.pal_nfiltered >= self.pal_filtered.len) break;
                if (fuzzyMatch(a.title, needle) or fuzzyMatch(a.kind, needle)) {
                    self.pal_filtered[self.pal_nfiltered] = i;
                    self.pal_nfiltered += 1;
                }
            },
            // Title AND id, so both "split right" and "pane.split" find
            // it: the title is what a human scans, the id is what an
            // agent and the config file already know it by.
            .commands => for (registrypkg.commands, 0..) |c, i| {
                if (self.pal_nfiltered >= self.pal_filtered.len) break;
                if (!c.palette) continue;
                if (fuzzyMatch(c.title, needle) or fuzzyMatch(c.id, needle)) {
                    self.pal_filtered[self.pal_nfiltered] = i;
                    self.pal_nfiltered += 1;
                }
            },
        }
        if (self.pal_sel >= self.pal_nfiltered) self.pal_sel = self.pal_nfiltered -| 1;
    }

    /// Palette input — same stream contract as the editor: NSEvents
    /// deliver chars and whole CSI arrows, ctl delivers strings.
    /// Pub for ctl's writeTarget (blind-drivable modal).
    pub fn palKeyLocked(self: *App, bytes: []const u8) void {
        var i: usize = 0;
        while (i < bytes.len) {
            const b = bytes[i];
            if (b == 0x1b and i + 2 < bytes.len and bytes[i + 1] == '[') {
                switch (bytes[i + 2]) {
                    'A' => self.pal_sel -|= 1,
                    'B' => self.pal_sel = @min(self.pal_sel + 1, self.pal_nfiltered -| 1),
                    else => {},
                }
                i += 3;
                continue;
            }
            switch (b) {
                0x1b => {
                    self.closePaletteLocked();
                    return;
                },
                '\r', '\n' => {
                    self.palActivateLocked();
                    return;
                },
                0x10, 0x0b => self.pal_sel -|= 1, // ⌃P / ⌃K
                0x0e => self.pal_sel = @min(self.pal_sel + 1, self.pal_nfiltered -| 1), // ⌃N
                0x7f, 0x08 => {
                    self.pal_input_len -|= 1;
                    self.palRefilterLocked();
                },
                else => if (b >= 0x20 and b < 0x7f and self.pal_input_len < self.pal_input.len) {
                    // VS Code's own prefix: `>` as the first character
                    // of the file finder switches to commands. Real
                    // muscle memory — ⌘P then ">" is how a lot of
                    // people reach the command palette at all.
                    if (b == '>' and self.pal_mode == .files and self.pal_input_len == 0) {
                        self.pal_mode = .commands;
                        self.pal_sel = 0;
                        self.palRefilterLocked();
                        i += 1;
                        continue;
                    }
                    self.pal_input[self.pal_input_len] = b;
                    self.pal_input_len += 1;
                    self.palRefilterLocked();
                },
            }
            i += 1;
        }
        self.scene_dirty = true;
    }

    /// Enter: attach the workspace's SESSION — tmux semantics. An
    /// existing space (matched by name) swaps in with its whole tab
    /// set intact; a first visit creates the space with one shell in
    /// the workspace root. cd stays sacred inside — the space is where
    /// your windows live, not a fence.
    fn palActivateLocked(self: *App) void {
        if (self.pal_sel >= self.pal_nfiltered) {
            self.closePaletteLocked();
            return;
        }
        if (self.pal_mode == .files) {
            const rel = self.pal_files.paths[self.pal_filtered[self.pal_sel]];
            var abs: [1024]u8 = undefined;
            const full = std.fmt.bufPrint(&abs, "{s}/{s}", .{ self.pal_files.root, rel }) catch {
                self.closePaletteLocked();
                return;
            };
            self.closePaletteLocked();
            // Through the same queue every other chrome-initiated open
            // uses: we are under draw_lock, and pane surgery is not.
            // `.here` is VS Code's ⌘P too — the file lands where you
            // are looking, and the pane you were in keeps its history.
            if (full.len <= self.pending_open_path.len) {
                @memcpy(self.pending_open_path[0..full.len], full);
                self.pending_open = .{
                    .len = full.len,
                    .line = 0,
                    .how = .here,
                    .from = self.activeTab().focused.id,
                };
            }
            return;
        }
        if (self.pal_mode == .actions) {
            const a = self.pal_actions[self.pal_filtered[self.pal_sel]];
            const path = self.pal_actions_path;
            const ed = self.editorShowingLocked(path);
            self.closePaletteLocked();
            if (a.command_only) {
                // Shown in the list rather than hidden, because an
                // action you cannot see is indistinguishable from a
                // server that never offered it — and then refused
                // here, which is the only honest place to refuse.
                if (ed) |e| {
                    e.setStatus("\"{s}\" runs a server command, which rook cannot do yet", .{a.title}, true);
                    e.render_dirty = true;
                }
                return;
            }
            if (a.edit.len > 0) {
                self.applyWorkspaceEditLocked(path, a.edit, a.file_ops, "applied", a.title);
                return;
            }
            if (a.deferred) {
                // The server kept the edit back until it knew you
                // wanted it. Asking now is the whole point of resolve.
                if (self.lsp.codeActionResolve(path, a.raw)) {
                    if (ed) |e| {
                        e.setStatus("applying {s}…", .{a.title}, false);
                        e.render_dirty = true;
                    }
                    return;
                }
            }
            if (ed) |e| {
                e.setStatus("\"{s}\" had nothing to apply", .{a.title}, true);
                e.render_dirty = true;
            }
            return;
        }
        if (self.pal_mode == .plugins) {
            const p = &self.plugins.items[self.pal_filtered[self.pal_sel]];
            copyStr(&self.plug_pending, &self.plug_pending_len, p.spec.name);
            self.closePaletteLocked();
            return;
        }
        if (self.pal_mode == .commands) {
            const c = registrypkg.commands[self.pal_filtered[self.pal_sel]];
            // Close FIRST: a command may open the palette again
            // (palette.commands does), and dispatching while still open
            // would leave the modal on screen owning the key path with
            // stale filter state behind it.
            self.closePaletteLocked();
            // dispatch takes the lock itself in the paths that mutate
            // panes, so this must not be holding it. palKeyLocked's
            // caller owns draw_lock — hand off through the same deferred
            // route the leader machine uses.
            self.pending_cmd = .{ .action = c.action, .arg = c.arg };
            return;
        }
        const e = self.pal_items[self.pal_filtered[self.pal_sel]];
        var rootbuf: [1024:0]u8 = undefined;
        if (e.root.len >= rootbuf.len) {
            self.closePaletteLocked();
            return;
        }
        @memcpy(rootbuf[0..e.root.len], e.root);
        rootbuf[e.root.len] = 0;
        var namebuf: [24]u8 = undefined;
        const nlen = @min(e.name.len, namebuf.len);
        @memcpy(namebuf[0..nlen], e.name[0..nlen]);
        self.closePaletteLocked();
        const name = namebuf[0..nlen];

        for (self.spaces.items, 0..) |s, si| {
            if (std.mem.eql(u8, s.label(), name)) {
                self.activateSpaceLocked(si);
                return;
            }
        }
        // First visit: a fresh session, one shell in the root.
        const pane = self.makePane(rootbuf[0..e.root.len :0]) catch return;
        const t = self.gpa.create(panespkg.Tab) catch return;
        t.* = .{ .id = self.next_tab_id, .root = .{ .leaf = pane }, .focused = pane };
        self.next_tab_id += 1;
        t.panes.append(self.gpa, pane) catch {};
        const s = self.gpa.create(panespkg.Space) catch return;
        s.* = .{};
        s.setName(name);
        s.tabs.append(self.gpa, t) catch return;
        self.spaces.append(self.gpa, s) catch return;
        self.activateSpaceLocked(self.spaces.items.len - 1);
    }

    /// THE one switch over Action. Every surface — keybinds, the ⌘
    /// chords, the palette, ctl `run` — funnels here, so a capability is
    /// wired once and reachable from all of them. Adding a value to
    /// registry.Action fails the build until it lands in this switch,
    /// which is the property that keeps the table honest.
    ///
    /// Must NOT be called holding draw_lock; the arms take it.
    pub fn dispatch(self: *App, spec: registrypkg.Spec) void {
        switch (spec.action) {
            .split_right => self.splitFocused(true),
            .split_down => self.splitFocused(false),
            .focus_left => _ = self.focusMove(.left),
            .focus_right => _ = self.focusMove(.right),
            .focus_up => _ = self.focusMove(.up),
            .focus_down => _ = self.focusMove(.down),
            .pane_close => self.closeFocused(),
            .pane_zoom => _ = self.toggleZoom(),
            .copy_mode => self.enterCopyMode(),
            .tab_new => self.newTab(),
            .tab_next => self.cycleTab(1),
            .tab_prev => self.cycleTab(-1),
            .tab_select => _ = self.selectTab(@as(usize, spec.arg) - 1),
            .workspace_switch => self.openPalette(),
            .palette_commands => self.openCommandPalette(),
            .palette_files => self.openFilePalette(),
            .palette_plugins => self.openPluginPalette(),
            .env_apply => _ = self.applyEnv(),
            .plugin_pin => self.copyPluginPin(),
            .config_preview => self.showConfigPreview(true),
            .config_edit => self.editConfig(),
            .config_setup => self.openSetupPalette(),
            .panel_search => self.openSearchPanel(),
            .editor_format => self.formatFocused(),
            .app_fullscreen => self.requestFullscreen(),
            .panel_flip => self.flipSidePane(),
            .panel_close => self.closeSidePane(),
            .tree_toggle => self.treeCommand(false),
            .tree_reveal => self.treeCommand(true),
            .monitor_open => self.showMonitor(true),
        }
    }

    /// `<leader>⇥` / `<leader>o` — the file tree as a DEDICATED
    /// sidebar pane, NERDTree's contract: toggle opens it as a split
    /// at the tab's LEFT edge (nothing you were looking at moves) and
    /// closes it by REMOVING the pane; reveal opens or focuses it
    /// pointed at the current file. Only the pinned sidebar
    /// beside-opens its files — `:e .`'s in-pane tree keeps netrw's
    /// open-in-place.
    fn treeCommand(self: *App, reveal: bool) void {
        self.draw_lock.lock();
        defer self.draw_lock.unlock();
        const t = self.activeTab();
        const p = t.focused;

        var pinned: ?*panespkg.Pane = null;
        for (t.panes.items) |tp| {
            if (tp.editor()) |ted| {
                if (ted.is_dir and ted.tree_pinned) {
                    pinned = tp;
                    break;
                }
            }
        }

        if (!reveal) {
            if (pinned) |tp| {
                // Toggle OFF: remove the pane; the reap heals the
                // layout. A tab that is ONLY the tree keeps it —
                // closing the last pane closes the tab, and a toggle
                // must never do that.
                if (t.panes.items.len < 2) return;
                tp.editor().?.closed = true;
                self.scene_dirty = true;
                return;
            }
        }

        // The reveal target, noted before any panes move: the focused
        // pane's file. A terminal has none — reveal just opens/focuses.
        var target_buf: [1024]u8 = undefined;
        var target: ?[]const u8 = null;
        if (reveal) {
            if (p.editor()) |fed| {
                if (!fed.is_dir and !fed.synthetic) if (fed.buf.path) |bp| {
                    if (bp.len <= target_buf.len) {
                        @memcpy(target_buf[0..bp.len], bp);
                        target = target_buf[0..bp.len];
                    }
                };
            }
        }

        const tree_pane = pinned orelse self.openTreePaneLocked() orelse return;
        if (target) |tg| tree_pane.editor().?.treeReveal(tg);
        self.setFocusLocked(tree_pane);
        self.scene_dirty = true;
    }

    /// config `explorer-auto`: the sidebar is already there when the
    /// window opens, VS Code's own behaviour. Two rules make it feel
    /// like orientation rather than an interruption:
    ///
    /// Repo-GATED — a Dock launch lands in $HOME, and a sidebar
    /// listing a home directory is noise. Being inside a repository
    /// is the "you opened a project" signal.
    ///
    /// Focus STAYS on the shell. You launched a terminal; the tree is
    /// context, and a sidebar that swallowed the first thing you
    /// typed would be a worse start than no sidebar at all.
    fn explorerAutoLocked(self: *App) void {
        if (!self.cfg_explorer_auto) return;
        var buf: [1024]u8 = undefined;
        const cwd = getcwd(&buf, buf.len) orelse return;
        var rbuf: [1024]u8 = undefined;
        // repoRootFs returns null OUTSIDE a repo — which is exactly
        // the gate, so the fallback-to-cwd the other callers want is
        // deliberately not applied here.
        if (@import("git.zig").repoRootFs(self.io, self.gpa, std.mem.span(cwd), &rbuf) == null) return;
        const keep = self.activeTab().focused;
        const tree_pane = self.openTreePaneLocked() orelse return;
        _ = tree_pane;
        self.setFocusLocked(keep);
        self.scene_dirty = true;
    }

    /// Create the dedicated tree pane: a split at the TAB's left edge,
    /// full height, sidebar-wide (side_cols, the side panes' own
    /// number), rooted at the repo of wherever the focused pane is —
    /// the filesystem .git probe, directory itself as the fallback.
    /// Caller holds draw_lock.
    /// The repo root a pane is "in": its file's directory for an
    /// editor, its live cwd for a terminal, walked up to the nearest
    /// .git — an ANCHOR, not a fence (the fallback is the directory
    /// itself, so a non-repo still works). The tree and ⌘P share it so
    /// the two surfaces can never disagree about where you are.
    fn paneRootLocked(self: *App, p: *panespkg.Pane, buf: []u8) ?[]const u8 {
        var own_buf: [1024]u8 = undefined;
        const start: []const u8 = blk: {
            if (p.editor()) |ed| {
                if (!ed.synthetic) if (ed.buf.path) |bp| {
                    if (ed.is_dir) break :blk bp; // in-pane tree: same root
                    break :blk std.fs.path.dirname(bp) orelse bp;
                };
            }
            if (self.paneCwd(p)) |cwd| break :blk std.mem.span(cwd);
            // A pane whose process has not started yet (the first
            // shell, one tick after launch) or has died must not make
            // the tree impossible: the app's own cwd is where that
            // shell was going to be anyway.
            const own = getcwd(&own_buf, own_buf.len) orelse return null;
            break :blk std.mem.span(own);
        };
        return @import("git.zig").repoRootFs(self.io, self.gpa, start, buf) orelse start;
    }

    fn openTreePaneLocked(self: *App) ?*panespkg.Pane {
        const t = self.activeTab();
        const p = t.focused;
        var root_buf: [1024]u8 = undefined;
        const root = self.paneRootLocked(p, &root_buf) orelse return null;

        const ed = self.newEditorLocked(root) orelse return null;
        if (!ed.is_dir) {
            ed.destroy();
            return null;
        }
        ed.tree_pinned = true;
        self.attachDocsLocked(ed);
        self.lspAttachLocked(ed);
        self.attachCommands(ed);
        const pane = self.gpa.create(panespkg.Pane) catch {
            ed.destroy();
            return null;
        };
        pane.* = .{ .id = self.next_pane_id, .content = .{ .edit = ed } };
        self.next_pane_id += 1;

        // topleft vsplit: the new split becomes the tab's root, tree
        // on the left, the WHOLE existing layout on the right.
        const s = self.gpa.create(panespkg.Split) catch {
            ed.destroy();
            self.gpa.destroy(pane);
            return null;
        };
        t.zoomed = null;
        const area = self.paneArea();
        const want = self.side_cols * self.renderer.cell_w + self.m.pane_pad * 2;
        s.* = .{
            .horiz = true,
            .ratio = std.math.clamp(want / @max(1, area.w), 0.1, 0.5),
            .a = .{ .leaf = pane },
            .b = t.root,
        };
        t.root = .{ .split = s };
        t.panes.append(self.gpa, pane) catch {};
        self.relayoutLocked();
        self.refreshHudLocked(CACurrentMediaTime());
        return pane;
    }

    /// Close the side pane, whatever tenant is in it.
    ///
    /// It used to be toggleSidePane, and every tenant closed itself by
    /// being toggled again. Search deliberately does NOT toggle — ⌘⇧F
    /// with results up means "search again", never "throw away what I am
    /// reading" — so when the other tenants left in the strip the pane
    /// became openable and not closeable. This is the way out.
    pub fn closeSidePane(self: *App) void {
        self.draw_lock.lock();
        defer self.draw_lock.unlock();
        if (!self.side_open) return;
        self.side_open = false;
        self.side_focus = false;
        // The panes beside it must retile: their COLUMN COUNT changes,
        // which means a pty resize, not just a redraw.
        self.relayoutLocked();
        self.scene_dirty = true;
    }

    /// Focus the pane whose shell cwd best matches `raw`.
    ///
    /// This is the link back to "where an agent is" in an app with no
    /// host sessions: panes are in-process, so the only correspondence
    /// between a host-side agent and a window is the directory they
    /// share. Exact beats parent, and a deeper parent beats a shallower
    /// one, so the pane the agent actually runs in outranks a shell
    /// parked at the repo root.
    ///
    /// Shared by the ask form's ⌃G and the agent deck's Enter — one
    /// notion of "go there", so they cannot drift apart.
    pub fn jumpToCwdLocked(self: *App, raw: []const u8) bool {
        if (raw.len == 0) return false;
        // Resolve first: paneCwd is the kernel's already-resolved path,
        // and a path under /tmp (a symlink to /private/tmp on macOS)
        // arrives unresolved. Without this the prefix match silently
        // never fires and the jump looks like it does nothing.
        var rawz: [1024:0]u8 = undefined;
        var resolved: [1024]u8 = undefined;
        var want = raw;
        if (raw.len < rawz.len) {
            @memcpy(rawz[0..raw.len], raw);
            rawz[raw.len] = 0;
            if (realpath(&rawz, &resolved)) |r| want = std.mem.span(r);
        }

        var best: ?*panespkg.Pane = null;
        var best_space: usize = 0;
        var best_tab: usize = 0;
        var best_score: usize = 0;
        for (self.spaces.items, 0..) |s, si| {
            for (s.tabs.items, 0..) |t, ti| {
                for (t.panes.items) |p| {
                    const c = self.paneCwd(p) orelse continue;
                    const cwd = std.mem.span(c);
                    // The pane's cwd must be the ask's directory or an
                    // ancestor of it; score by how specific it is.
                    if (!std.mem.startsWith(u8, want, cwd)) continue;
                    if (want.len != cwd.len and cwd[cwd.len - 1] != '/' and want[cwd.len] != '/') continue;
                    if (cwd.len <= best_score) continue;
                    best = p;
                    best_space = si;
                    best_tab = ti;
                    best_score = cwd.len;
                }
            }
        }
        const p = best orelse return false;
        if (best_space != self.active_space) self.activateSpaceLocked(best_space);
        const s = self.activeSpace();
        if (best_tab != s.active_tab) self.activateTabLocked(best_tab);
        self.setFocusLocked(p);
        self.scene_dirty = true;
        return true;
    }

    /// The deck's key path — vim keys over the list, Enter to go there.
    /// Caller holds draw_lock.
    /// Open the search panel focused, with the box ready to type.
    /// ⌘⇧F, the rail's magnifier, and `panel.search` all land here.
    pub fn openSearchPanel(self: *App) void {
        // NOT a toggle, unlike the other tenants: ⌘⇧F means "search",
        // and pressing it with the panel already up means "search
        // again" — never "close the results I am reading". Reaching
        // for the key twice must not be how you lose them.
        {
            self.draw_lock.lock();
            defer self.draw_lock.unlock();
            const was = self.side_open and self.side_panel == .search;
            self.side_panel = .search;
            self.side_open = true;
            // The query and its results SURVIVE a reopen (VS Code's
            // panel does too) — the box just takes the keys again.
            self.sr_typing = true;
            self.side_focus = true;
            if (!was) self.relayoutLocked();
            self.scene_dirty = true;
        }
    }

    /// The absolute path behind a result row.
    ///
    /// A grep only ever produces paths inside the root, but a reference
    /// list reaches the standard library and the module cache — those
    /// are stored absolute, and joining one onto the root would build a
    /// path that resolves to nothing.
    fn hitPath(self: *App, buf: []u8, shown: []const u8) ?[]const u8 {
        if (shown.len > 0 and shown[0] == '/') return shown;
        return std.fmt.bufPrint(buf, "{s}/{s}", .{ self.sr.root, shown }) catch null;
    }

    /// Run the query on a worker: a repo-wide scan is milliseconds but
    /// not microseconds, and the frame must never wait on a
    /// filesystem. The result is published through `sr_pending`, which
    /// the draw tick swaps in under the lock.
    fn startSearchLocked(self: *App) void {
        if (self.sr_query_len == 0) return;
        if (self.sr_running.load(.acquire)) return;
        var rootbuf: [1024]u8 = undefined;
        const root = self.paneRootLocked(self.activeTab().focused, &rootbuf) orelse return;
        const Args = struct { app: *App, root: [1024]u8, root_len: usize, q: [128]u8, q_len: usize };
        const a = self.gpa.create(Args) catch return;
        a.* = .{ .app = self, .root = undefined, .root_len = root.len, .q = undefined, .q_len = self.sr_query_len };
        @memcpy(a.root[0..root.len], root);
        @memcpy(a.q[0..self.sr_query_len], self.sr_query[0..self.sr_query_len]);
        self.sr_running.store(true, .release);
        const T = struct {
            fn go(args: *Args) void {
                const app = args.app;
                const res = searchpkg.run(app.gpa, args.root[0..args.root_len], args.q[0..args.q_len]);
                app.draw_lock.lock();
                // A second search may have been queued while this ran;
                // the newest answer wins and the older one is dropped.
                if (app.sr_pending) |*old| {
                    var o = old.*;
                    o.deinit(app.gpa);
                }
                app.sr_pending = res;
                app.sr_pending_kind = .grep;
                app.scene_dirty = true;
                app.draw_lock.unlock();
                app.sr_running.store(false, .release);
                app.gpa.destroy(args);
            }
        };
        if (std.Thread.spawn(.{}, T.go, .{a})) |t| {
            t.detach();
        } else |_| {
            self.sr_running.store(false, .release);
            self.gpa.destroy(a);
        }
    }

    /// Swap in a finished search. Caller holds draw_lock (the draw
    /// tick does).
    fn drainSearchLocked(self: *App) void {
        const done = self.sr_pending orelse return;
        self.sr_pending = null;
        self.sr.deinit(self.gpa);
        self.sr = done;
        self.sr_kind = self.sr_pending_kind;
        self.sr_sel = 0;
        self.sr_top = 0;
        // The box hands the keys to the list the moment there is a
        // list — you searched to read the answer, not to keep typing.
        if (self.sr.hits.len > 0) self.sr_typing = false;
        self.scene_dirty = true;
    }

    /// The search panel's keys. Two states: typing the query, then
    /// walking the results (j/k/Enter, vim's and VS Code's list keys
    /// both). `/` or `i` puts you back in the box.
    pub fn searchKeyLocked(self: *App, bytes: []const u8) void {
        var i: usize = 0;
        while (i < bytes.len) {
            const b = bytes[i];
            if (b == 0x1b and i + 2 < bytes.len and bytes[i + 1] == '[') {
                switch (bytes[i + 2]) {
                    'A' => {
                        self.sr_typing = false;
                        self.sr_sel -|= 1;
                    },
                    'B' => {
                        self.sr_typing = false;
                        self.sr_sel = @min(self.sr_sel + 1, self.sr.hits.len -| 1);
                    },
                    else => {},
                }
                i += 3;
                self.scene_dirty = true;
                continue;
            }
            if (self.sr_typing) {
                switch (b) {
                    0x1b => {
                        self.side_focus = false;
                        self.scene_dirty = true;
                        return;
                    },
                    '\r', '\n' => self.startSearchLocked(),
                    0x7f, 0x08 => self.sr_query_len -|= 1,
                    else => if (b >= 0x20 and b < 0x7f and self.sr_query_len < self.sr_query.len) {
                        self.sr_query[self.sr_query_len] = b;
                        self.sr_query_len += 1;
                    },
                }
                i += 1;
                self.scene_dirty = true;
                continue;
            }
            switch (b) {
                0x1b => {
                    self.side_focus = false;
                    self.scene_dirty = true;
                    return;
                },
                'k', 0x10 => self.sr_sel -|= 1,
                'j', 0x0e => self.sr_sel = @min(self.sr_sel + 1, self.sr.hits.len -| 1),
                'g' => self.sr_sel = 0,
                'G' => self.sr_sel = self.sr.hits.len -| 1,
                '/', 'i' => self.sr_typing = true,
                '\r', '\n' => {
                    // Jump to the hit. The panel STAYS — VS Code keeps
                    // its results while you walk them, and a list that
                    // closed on the first jump would make finding the
                    // second hit a re-search.
                    if (self.sr_sel < self.sr.hits.len) {
                        const hit = self.sr.hits[self.sr_sel];
                        var abs: [1024]u8 = undefined;
                        const full = self.hitPath(&abs, self.sr.files[hit.file]) orelse return;
                        if (full.len <= self.pending_open_path.len) {
                            @memcpy(self.pending_open_path[0..full.len], full);
                            // The query rides along so the landing can
                            // re-anchor: these line numbers were true
                            // when the scan ran, and any edit since
                            // has shifted them.
                            const flen = @min(self.sr.query.len, self.pending_open_find.len);
                            @memcpy(self.pending_open_find[0..flen], self.sr.query[0..flen]);
                            self.pending_open = .{
                                .len = full.len,
                                .line = hit.line -| 1,
                                // A grep hit's column is where the text
                                // matched; a reference's is the symbol.
                                // Either way it is the thing you came to
                                // look at, so land on it — and it is
                                // the FILE's column, not the shown
                                // text's, or a jump into indented code
                                // lands inside the indent.
                                .col = hit.file_col,
                                .find_len = flen,
                                .how = .here,
                                .from = self.activeTab().focused.id,
                            };
                        }
                        self.side_focus = false;
                    }
                },
                else => {},
            }
            i += 1;
            self.scene_dirty = true;
        }
    }

    // ------------------------------------------------------ documents

    /// Create an editor with the app's seams already installed.
    ///
    /// One helper rather than four call sites, and the ORDER is the
    /// reason: the document registry has to be reachable before the
    /// first open, or a pane's first file is the one that never gets
    /// shared — which is exactly the file you were looking at.
    fn newEditorLocked(self: *App, path: ?[]const u8) ?*editorpkg.Editor {
        const ed = editorpkg.Editor.create(self.gpa, self.io, null) catch return null;
        self.attachDocsLocked(ed);
        self.attachCommands(ed);
        if (path) |p| {
            ed.open(p, false) catch {
                ed.destroy();
                return null;
            };
        }
        // AFTER the open: attach() picks the language from the path,
        // and an editor that has not opened its file yet has none. The
        // editor calls hl_set_path itself on every later retarget, so
        // this is the only place that needs to think about it.
        self.attachSyntaxLocked(ed);
        self.lspAttachLocked(ed);
        // Installed AFTER the first attach, so this open does not fire
        // it and didOpen the same document twice. Every LATER open on
        // this editor — and there is no other way for one to happen —
        // goes through the hook.
        ed.retarget_ctx = self;
        ed.on_retarget = &lspRetargetHook;
        ed.lsp_explain = &lspExplainHook;
        return ed;
    }

    /// Re-scan the grammar search path and re-attach every editor, so
    /// a grammar installed a moment ago takes effect now.
    pub fn reloadGrammars(self: *App) void {
        self.draw_lock.lock();
        defer self.draw_lock.unlock();
        // Re-read the graph too: `rook syntax reload` after editing
        // config should mean the same thing as a relaunch, and the
        // declarations are half of what it is reloading.
        self.grammars.loadGraph(self.io);
        self.grammars.forget();
        // Languages ride along: `rook syntax reload` is the developer's
        // "pick up my config edit", and a declaration reload that took
        // half the graph would be a trap.
        self.langs.loadGraph(self.io);
        self.lsp.forgetResolutions();
        self.lspRetryAttachLocked();
        for (self.spaces.items) |space| for (space.tabs.items) |tab| {
            for (tab.panes.items) |p| {
                const ed = p.editor() orelse continue;
                // setPath again through the seam the editor already
                // owns: it drops the old tree and query and asks the
                // loader afresh, which is exactly the reload.
                if (ed.hl_set_path) |f| f(ed.hl_ctx.?, ed.buf.path);
                ed.render_dirty = true;
            }
        };
        self.scene_dirty = true;
    }

    /// How the focused pane's highlighting is going, in one line.
    ///
    /// `off` and `plain` are different answers and the difference is
    /// the point: one means rook has no grammar for this file, the
    /// other means it is not a language rook knows about at all.
    pub fn syntaxStateLocked(self: *App, ed: *editorpkg.Editor) []const u8 {
        _ = self;
        if (ed.hl_ctx == null) return "off\tno highlighter attached";
        const hl: *syntaxpkg.Highlighter = @ptrCast(@alignCast(ed.hl_ctx.?));
        if (hl.fault.len > 0) return hl.fault;
        const p = ed.buf.path orelse return "plain\tno file";
        if (syntaxpkg.langForPath(p) == null) return "plain\tno grammar maps to this extension";
        return if (hl.highlighting()) "on" else "plain\tnothing parsed yet";
    }

    /// Give a new editor a highlighter. Cheap when no grammar is
    /// available — the loader answers from its cache and the editor
    /// renders plain text, which is the path headless tests take.
    fn attachSyntaxLocked(self: *App, ed: *editorpkg.Editor) void {
        syntaxpkg.attach(ed, self.gpa, &self.grammars);
    }

    fn attachDocsLocked(self: *App, ed: *editorpkg.Editor) void {
        ed.doc_ctx = self;
        ed.doc_find = &docFindHook;
        ed.doc_publish = &docPublishHook;
        ed.doc_release = &docReleaseHook;
    }

    fn docFindHook(ctx: *anyopaque, path: []const u8) ?*bufferpkg.Buffer {
        const self: *App = @ptrCast(@alignCast(ctx));
        return self.docs.acquire(path);
    }

    fn docPublishHook(ctx: *anyopaque, doc: *bufferpkg.Buffer) bool {
        const self: *App = @ptrCast(@alignCast(ctx));
        return self.docs.publish(doc);
    }

    fn docReleaseHook(ctx: *anyopaque, doc: *bufferpkg.Buffer) void {
        const self: *App = @ptrCast(@alignCast(ctx));
        self.docs.release(doc);
    }

    /// Let every view notice edits made through another one. Runs on
    /// the frame loop beside the LSP tick, and costs one integer
    /// compare per pane when nothing has changed.
    fn reconcileViewsLocked(self: *App) void {
        for (self.spaces.items) |space| for (space.tabs.items) |tab| {
            for (tab.panes.items) |p| {
                const ed = p.editor() orelse continue;
                ed.reconcile();
            }
        };
    }

    // ---------------------------------------------------- language servers

    /// Attach the seam and open the document. Called wherever an editor
    /// is created or retargeted at a file — the server needs the TEXT,
    /// not the path, because the buffer may already differ from disk.
    fn lspAttachLocked(self: *App, ed: *editorpkg.Editor) void {
        const path = ed.buf.path orelse return;
        if (ed.is_dir or ed.buf.readonly) return;
        const srv = self.lsp.ensure(path) orelse return;

        ed.lsp_ctx = self;
        ed.lsp_hover = &lspHoverHook;
        ed.lsp_definition = &lspDefinitionHook;
        ed.lsp_references = &lspReferencesHook;
        ed.lsp_rename = &lspRenameHook;
        ed.lsp_completion = &lspCompletionHook;
        ed.lsp_completion_resolve = &lspCompletionResolveHook;
        ed.lsp_format = &lspFormatHook;
        ed.lsp_code_action = &lspCodeActionHook;
        ed.fmt_on_save = self.cfg_fmt_on_save;
        // The sign column appears now rather than when the first error
        // does, so the document never shifts sideways under your cursor.
        ed.diag_gutter = true;

        const text = ed.buf.rope.dupeRange(self.gpa, 0, ed.buf.rope.byteLen()) catch return;
        defer self.gpa.free(text);
        srv.didOpen(path, text);
        ed.buf.lsp_version = ed.buf.version;
        // A file opened a second time in a server that already knows it
        // still needs its diagnostics on screen — they were published
        // while no pane was showing them.
        self.applyDiagsLocked(ed, path);
    }

    /// Say WHY this file has no server, in the words that fit the
    /// reason.
    ///
    /// Four different problems used to share one sentence. "No language
    /// server for this file" is true of a `.md` file, of a Zig repo on a
    /// machine with no zls, of a project whose resolver is still
    /// thinking, and of one whose resolver refused with a fix in hand —
    /// and only the last of those is a sentence anybody can act on.
    fn lspExplainHook(ctx: *anyopaque, ed: *editorpkg.Editor) void {
        const self: *App = @ptrCast(@alignCast(ctx));
        self.lspExplainLocked(ed);
    }

    fn lspExplainLocked(self: *App, ed: *editorpkg.Editor) void {
        const path = ed.buf.path orelse return;
        // Ask again, so `why` describes THIS file rather than whatever
        // was routed last. ensure() returns a running server or null
        // without doing work, so this costs a lookup.
        _ = self.lsp.ensure(path);
        switch (self.lsp.why) {
            .undeclared => {
                const ext = std.fs.path.extension(path);
                if (ext.len > 1) {
                    ed.setStatus("no language declared for {s} files", .{ext}, false);
                } else ed.setStatus("no language declared for this file", .{}, false);
            },
            .no_binary => {
                if (self.langs.forPath(path)) |spec| {
                    const bin = if (spec.argv.len > 0) spec.argv[0] else spec.name;
                    ed.setStatus("{s} is declared but {s} is not installed", .{ spec.name, bin }, false);
                } else ed.setStatus("the declared server is not installed", .{}, false);
            },
            .resolving => ed.setStatus("working out which server this project wants…", .{}, false),
            // The resolver's own words, which is the whole reason it was
            // asked rather than guessed at.
            .refused => {
                const why = self.lsp.refusal(path);
                if (why.len > 0) {
                    ed.setStatus("{s}", .{why}, false);
                } else ed.setStatus("no server for this project", .{}, false);
            },
        }
    }

    /// Ask a plugin what to run for a project.
    ///
    /// On a WORKER, always. A plugin call is a round trip to another
    /// process with a deadline measured in seconds, and this is reached
    /// from `ensure` under the draw lock — doing it inline would freeze
    /// the window for as long as the plugin took to think. The answer
    /// lands through `Manager.resolved`, and the frame loop's re-attach
    /// pass picks the server up on a later tick.
    fn lspResolveHook(ctx: *anyopaque, plugin: []const u8, lang: []const u8, root: []const u8) void {
        const self: *App = @ptrCast(@alignCast(ctx));
        const Args = struct {
            app: *App,
            plugin: [64]u8,
            plugin_len: usize,
            lang: [64]u8,
            lang_len: usize,
            root: [1024]u8,
            root_len: usize,
        };
        const a = self.gpa.create(Args) catch return;
        a.* = .{
            .app = self,
            .plugin = undefined,
            .plugin_len = @min(plugin.len, 64),
            .lang = undefined,
            .lang_len = @min(lang.len, 64),
            .root = undefined,
            .root_len = @min(root.len, 1024),
        };
        @memcpy(a.plugin[0..a.plugin_len], plugin[0..a.plugin_len]);
        @memcpy(a.lang[0..a.lang_len], lang[0..a.lang_len]);
        @memcpy(a.root[0..a.root_len], root[0..a.root_len]);

        const T = struct {
            fn go(args: *Args) void {
                const app = args.app;
                const pl = @import("plugins.zig");
                defer app.gpa.destroy(args);
                const lang_s = args.lang[0..args.lang_len];
                const root_s = args.root[0..args.root_len];

                var dir_buf: [1024]u8 = undefined;
                const dir = langpkg.serversDir(&dir_buf, lang_s) orelse "";
                var res = pl.resolveLanguage(
                    app.plugins.find(args.plugin[0..args.plugin_len]),
                    app.gpa,
                    lang_s,
                    root_s,
                    dir,
                );
                defer res.deinit(app.gpa);

                app.draw_lock.lock();
                defer app.draw_lock.unlock();
                app.lsp.resolved(lang_s, root_s, res.argv(), res.settings(), res.errStr(), res.note());
                // Whatever the answer, panes waiting on it need another
                // look: a server that just started has to be attached,
                // and a refusal has a message to show.
                app.lspRetryAttachLocked();
                app.scene_dirty = true;
            }
        };
        if (std.Thread.spawn(.{}, T.go, .{a})) |t| t.detach() else |_| self.gpa.destroy(a);
    }

    /// Re-attach any editor holding a document with no server.
    ///
    /// Cheap and idempotent: `lspAttachLocked` starts with `ensure`,
    /// which returns the running server or null without doing work. It
    /// exists because attaching is normally driven by an OPEN, and a
    /// server can arrive long after the file did — a resolver answering,
    /// or a config apply declaring the language that was missing.
    fn lspRetryAttachLocked(self: *App) void {
        for (self.spaces.items) |space| for (space.tabs.items) |tab| {
            for (tab.panes.items) |p| {
                const ed = p.editor() orelse continue;
                if (ed.lsp_ctx != null) continue;
                self.lspAttachLocked(ed);
            }
        };
    }

    /// Take the language-server seams back off an editor.
    ///
    /// Needed because a retarget can land on a file no server serves:
    /// go to a `.zig` file from a `.go` one and the hooks left behind
    /// would point at a manager that is about to answer questions about
    /// a document it was never told exists. The gutter goes too — a
    /// reserved sign column on a file with no server is a column that
    /// will never hold anything.
    fn lspDetachLocked(_: *App, ed: *editorpkg.Editor) void {
        ed.lsp_ctx = null;
        ed.lsp_hover = null;
        ed.lsp_definition = null;
        ed.lsp_references = null;
        ed.lsp_rename = null;
        ed.lsp_completion = null;
        ed.lsp_completion_resolve = null;
        ed.lsp_format = null;
        ed.lsp_code_action = null;
        ed.fmt_on_save = false;
        ed.diag_gutter = false;
    }

    /// The pane retargeted itself — `:e`, or Enter on a row of an
    /// in-pane file tree. Neither goes anywhere near the app's own open
    /// path, so without this the document arrives with the PREVIOUS
    /// file's server attached, or with none at all.
    fn lspRetargetHook(ctx: *anyopaque, ed: *editorpkg.Editor) void {
        const self: *App = @ptrCast(@alignCast(ctx));
        // Detach first, unconditionally: attach returns early when
        // there is no server for the new path, and "early" must not
        // mean "keeps the old one".
        self.lspDetachLocked(ed);
        self.lspAttachLocked(ed);
    }

    /// Push whatever this buffer has become to its server. Called from
    /// the frame loop, so it is a version COMPARISON on an idle frame
    /// and nothing more.
    fn lspSyncLocked(self: *App, ed: *editorpkg.Editor) void {
        if (ed.lsp_ctx == null) return;
        // Against the DOCUMENT's mark, not this view's: two panes on one
        // file must send one didChange, and which pane you typed in must
        // not decide whether the server hears about it.
        if (ed.buf.version == ed.buf.lsp_version) return;
        const path = ed.buf.path orelse return;
        const srv = self.lsp.ensure(path) orelse return;
        const text = ed.buf.rope.dupeRange(self.gpa, 0, ed.buf.rope.byteLen()) catch return;
        defer self.gpa.free(text);
        srv.didChange(path, text);
        ed.buf.lsp_version = ed.buf.version;
    }

    /// Diagnostics arrive in UTF-16 columns; the editor counts bytes.
    /// The conversion needs the LINE, which is why it happens here —
    /// against the rope that is actually on screen — rather than in the
    /// manager, which only has ranges.
    fn applyDiagsLocked(self: *App, ed: *editorpkg.Editor, path: []const u8) void {
        const items = self.lsp.diagsFor(path);
        var out: std.ArrayListUnmanaged(editorpkg.Diag) = .empty;
        defer out.deinit(self.gpa);
        const last_line = ed.lineCountB() -| 1;
        for (items) |d| {
            // A diagnostic past the end of the buffer is one the server
            // computed against text we have since changed. Clamping it
            // to the last line beats dropping it: the error is real
            // until the next publish says otherwise.
            const line = @min(d.range.start.line, @as(u32, @intCast(last_line)));
            const end_line = @min(d.range.end.line, @as(u32, @intCast(last_line)));
            const text = ed.lineText(line);
            const end_text = ed.lineText(end_line);
            out.append(self.gpa, .{
                .line = line,
                .col = @intCast(lsppkg.byteColFromUtf16(text, d.range.start.col)),
                .end_line = end_line,
                .end_col = @intCast(lsppkg.byteColFromUtf16(end_text, d.range.end.col)),
                .severity = switch (d.severity) {
                    .err => .err,
                    .warn => .warn,
                    .info => .info,
                    .hint => .hint,
                },
                .message = d.message,
                .source = d.source,
            }) catch break;
        }
        ed.setDiagnostics(out.items);
    }

    /// How long typing has to stop before the buffer is pushed to its
    /// server. Short enough to feel live, long enough that a burst of
    /// keystrokes is one message rather than thirty.
    const lsp_debounce_s: f64 = 0.15;

    /// Push settled buffers. An idle frame walks the panes and compares
    /// two integers.
    fn lspTickLocked(self: *App, now: f64) void {
        for (self.spaces.items) |space| for (space.tabs.items) |tab| {
            for (tab.panes.items) |p| {
                const ed = p.editor() orelse continue;
                // A write waiting on a formatter that is not coming.
                // Checked before the lsp_ctx guard, because a server
                // that DIED still leaves a save owed — and this is the
                // only thing that will ever notice.
                if (ed.formatOverdue(now)) {
                    ed.finishPendingWrite("formatter timed out");
                    self.scene_dirty = true;
                }
                if (ed.lsp_ctx == null) continue;
                if (ed.buf.version == ed.buf.lsp_version) continue;
                if (ed.buf.version != ed.lsp_seen_version) {
                    ed.lsp_seen_version = ed.buf.version;
                    ed.lsp_seen_at = now;
                    continue;
                }
                if (now - ed.lsp_seen_at < lsp_debounce_s) continue;
                self.lspSyncLocked(ed);
            }
        };
    }

    /// Everything the servers produced since the last frame.
    fn drainLspLocked(self: *App) void {
        if (!self.lsp.drain()) return;
        self.scene_dirty = true;

        const changed = self.lsp.takeChanged();
        defer self.lsp.freeChanged(changed);
        for (changed) |path| {
            for (self.spaces.items) |space| for (space.tabs.items) |tab| {
                for (tab.panes.items) |p| {
                    const ed = p.editor() orelse continue;
                    const bp = ed.buf.path orelse continue;
                    // Case-INSENSITIVE: see lspmgr.samePath. A server
                    // that normalizes the case of what we sent it must
                    // not have its diagnostics land nowhere.
                    if (!lspmgrpkg.samePath(bp, path)) continue;
                    self.applyDiagsLocked(ed, path);
                }
            };
        }

        while (self.lsp.nextAnswer()) |ans| {
            var a = ans;
            defer a.deinit(self.gpa);
            switch (a) {
                .hover => |h| {
                    const ed = self.editorShowingLocked(h.path) orelse continue;
                    // A float: hover is markdown, usually a signature
                    // and a paragraph, and a status row can only ever
                    // show you the first line of it.
                    //
                    // A pane too small to host one still gets that
                    // first line rather than nothing — which is the
                    // whole reason showHover reports instead of quietly
                    // drawing off the edge. Which line it is differs
                    // per server; see hoverSummary.
                    if (!ed.showHover(h.text)) {
                        const first = lspmgrpkg.hoverSummary(h.text);
                        if (first.len == 0) {
                            ed.setStatus("nothing to show here", .{}, false);
                        } else ed.setStatus("{s}", .{first}, false);
                    }
                    ed.render_dirty = true;
                },
                .definition => |d| {
                    const ed = self.editorShowingLocked(d.path) orelse continue;
                    _ = ed;
                    // Route through the same queue ⌘P and search use:
                    // opening a file cannot happen under the draw lock
                    // from here, and a definition in ANOTHER file is the
                    // ordinary case.
                    if (d.target.len <= self.pending_open_path.len) {
                        @memcpy(self.pending_open_path[0..d.target.len], d.target);
                        self.pending_open = .{
                            .len = d.target.len,
                            .line = d.line,
                            // UTF-16 → bytes needs the TARGET's line, and
                            // the target file may not be open yet. The
                            // ASCII case (every identifier in practice)
                            // is identical either way; the honest fix is
                            // to convert after the open, which is a seam
                            // worth taking when a non-ASCII identifier
                            // actually shows up.
                            .col = d.col,
                            .how = .here,
                            .from = self.activeTab().focused.id,
                        };
                    }
                },
                .references => |r| self.startRefsLocked(r.sites, r.symbol),
                .rename => |r| self.applyRenameLocked(r),
                .code_actions => |ca| self.takeCodeActionsLocked(ca.path, ca.items, ca.resolved),
                .formatting => |f| {
                    const ed = self.editorShowingLocked(f.path) orelse continue;
                    // The server formatted the text as it stood when the
                    // request was made. A keystroke since then means
                    // every offset in this reply is measured against a
                    // document that no longer exists — the same refusal
                    // a rename makes, and here it must still release the
                    // write that was waiting. A bare :Format has no
                    // write to release, so the refusal has to say
                    // itself.
                    if (ed.buf.version != ed.buf.fmt_req_version) {
                        if (ed.fmt_save != null) {
                            ed.finishPendingWrite("changed while formatting");
                        } else {
                            ed.setStatus("changed while the formatter was answering — nothing reformatted", .{}, true);
                        }
                        ed.render_dirty = true;
                        continue;
                    }
                    // Resolve here, where the conversion from the
                    // protocol's line/UTF-16 coordinates to the rope's
                    // bytes belongs — the same place a rename does it.
                    const text = ed.buf.rope.dupeRange(self.gpa, 0, ed.buf.rope.byteLen()) catch continue;
                    defer self.gpa.free(text);
                    const sp = lsppkg.resolveEdits(self.gpa, text, f.edits) orelse {
                        // Overlapping edits: the same refusal a rename
                        // makes, and here it must still release the
                        // write that was waiting.
                        ed.finishPendingWrite("formatter's edits overlapped");
                        continue;
                    };
                    defer self.gpa.free(sp);
                    var out = self.gpa.alloc(editorpkg.Editor.Splice, sp.len) catch continue;
                    defer self.gpa.free(out);
                    for (sp, 0..) |s, i| out[i] = .{ .start = s.start, .end = s.end, .text = s.text };
                    ed.takeFormat(out);
                },
                .completion => |c| {
                    const ed = self.editorShowingLocked(c.path) orelse continue;
                    const items = self.gpa.alloc(editorpkg.Editor.CplItem, c.items.len) catch continue;
                    defer self.gpa.free(items);
                    for (c.items, 0..) |it, i| {
                        items[i] = .{
                            .text = it.insert,
                            .detail = it.detail,
                            .kind = it.kind,
                            .doc = it.doc,
                            .raw = it.raw,
                        };
                    }
                    // The PREFIX and BASE the request was made for
                    // travel with the answer, so the editor can tell an
                    // answer to what you are typing now, where you are
                    // typing it, from an answer to what you were typing
                    // two keystrokes ago somewhere else. Reading the
                    // editor's current state here instead would make
                    // those checks compare a value with itself.
                    ed.takeCompletions(items, c.prefix, c.base);
                },
                .completion_doc => |d| {
                    const ed = self.editorShowingLocked(d.path) orelse continue;
                    ed.takeCompletionDoc(d.word, d.doc, d.detail);
                },
                .none => |n| {
                    const ed = self.editorShowingLocked(n.path) orelse continue;
                    switch (n.kind) {
                        .hover => ed.setStatus("nothing to show here", .{}, false),
                        .definition => ed.setStatus("no definition found", .{}, false),
                        // Not an error, and worth saying plainly: a
                        // symbol nobody uses is a real answer, and one
                        // you often went looking for on purpose.
                        .references => ed.setStatus("no references found", .{}, false),
                        // A null or an error reply to rename. Servers
                        // refuse positions that are not renameable — a
                        // keyword, a literal, a symbol from a dependency
                        // — and that refusal is the answer.
                        .rename => ed.setStatus("cannot rename here", .{}, false),
                        // The server had nothing to offer. Silent: the
                        // buffer's own words may still be filling the
                        // menu, and a message over a working ring
                        // would read as a failure of the ring.
                        .completion => ed.takeCompletions(&.{}, ed.cplPrefix(), ed.cpl_base),
                        // A resolve that came back with nothing. Silent
                        // on purpose: the row is fine, it simply has no
                        // prose, and the panel beside it stays shut.
                        // The editor still has to hear it, or the "one
                        // in flight" latch would hold that word forever.
                        .completion_resolve => ed.forgetCompletionResolve(),
                        // A server that will not format this file. The
                        // `:w` behind it must still happen.
                        .formatting => ed.finishPendingWrite("no formatter for this file"),
                        .code_action => ed.setStatus("nothing to do here", .{}, false),
                        // A resolve that came back empty. The action was
                        // real and picking it did nothing, which is the
                        // one outcome worth naming.
                        .code_action_resolve => ed.setStatus("that action had no edit to apply", .{}, true),
                    }
                    ed.render_dirty = true;
                },
            }
        }
    }

    /// The focused editor showing `path`, else any editor showing it.
    /// An answer belongs to where you are looking, and a pane that has
    /// since moved on gets nothing.
    fn editorShowingLocked(self: *App, path: []const u8) ?*editorpkg.Editor {
        if (self.activeTab().focused.editor()) |ed| {
            if (ed.buf.path) |bp| {
                if (lspmgrpkg.samePath(bp, path)) return ed;
            }
        }
        for (self.spaces.items) |space| for (space.tabs.items) |tab| {
            for (tab.panes.items) |p| {
                const ed = p.editor() orelse continue;
                const bp = ed.buf.path orelse continue;
                if (lspmgrpkg.samePath(bp, path)) return ed;
            }
        };
        return null;
    }

    /// The cursor, in the protocol's coordinates.
    fn lspPos(ed: *editorpkg.Editor) lsppkg.Position {
        return .{
            .line = @intCast(ed.cline),
            .col = lsppkg.utf16FromByteCol(ed.lineText(ed.cline), ed.ccol),
        };
    }

    fn lspHoverHook(ctx: *anyopaque, ed: *editorpkg.Editor) void {
        const self: *App = @ptrCast(@alignCast(ctx));
        const path = ed.buf.path orelse return;
        // The buffer the server has must be the buffer you are looking
        // at, or the position means something else.
        self.lspSyncLocked(ed);
        if (!self.lsp.hover(path, lspPos(ed))) {
            self.lspExplainLocked(ed);
        }
    }

    fn lspDefinitionHook(ctx: *anyopaque, ed: *editorpkg.Editor) void {
        const self: *App = @ptrCast(@alignCast(ctx));
        const path = ed.buf.path orelse return;
        self.lspSyncLocked(ed);
        if (!self.lsp.definition(path, lspPos(ed))) {
            // No server: the editor's own first-occurrence search is
            // still a better answer than nothing.
            ed.gotoDefinitionFallback();
        }
    }

    fn lspReferencesHook(ctx: *anyopaque, ed: *editorpkg.Editor) void {
        const self: *App = @ptrCast(@alignCast(ctx));
        const path = ed.buf.path orelse return;
        self.lspSyncLocked(ed);
        // The word is a LABEL — the server answers from the position.
        // Taking it now rather than when the reply lands is what keeps
        // the list titled with what you asked about.
        const word = if (ed.wordUnder()) |w| w.text else "";
        if (!self.lsp.references(path, lspPos(ed), word)) {
            self.lspExplainLocked(ed);
            return;
        }
        // A repo-wide question takes a visible moment. Saying so beats a
        // key that looks like it did nothing for half a second.
        if (word.len > 0) {
            ed.setStatus("finding references to {s}…", .{word}, false);
        } else ed.setStatus("finding references…", .{}, false);
        ed.render_dirty = true;
    }

    /// How long a `:w` waits for a formatter before writing anyway.
    ///
    /// Generous, because gofmt on a big file through a busy gopls is
    /// not instant, and short enough that a dead server costs you a
    /// pause rather than a hang. What it is NOT is a way to lose a
    /// save: when it expires the file is written unformatted and the
    /// status row says so.
    const fmt_deadline_s: f64 = 1.5;

    fn lspFormatHook(ctx: *anyopaque, ed: *editorpkg.Editor) void {
        const self: *App = @ptrCast(@alignCast(ctx));
        const path = ed.buf.path orelse return;
        self.lspSyncLocked(ed);
        if (!self.lsp.formatting(path, editorpkg.tab_width, true)) {
            // No server for this file. Not an error and not a wait —
            // whatever `:w` was going to do, it does now.
            ed.finishPendingWrite(null);
            return;
        }
        // What the server is formatting. The reply is only good against
        // this exact text — see the .formatting arm.
        ed.buf.fmt_req_version = ed.buf.version;
        ed.fmt_deadline = CACurrentMediaTime() + fmt_deadline_s;
    }

    /// `:Format` / the palette entry. Same request as format-on-save,
    /// with no write waiting behind it.
    pub fn formatFocused(self: *App) void {
        self.draw_lock.lock();
        defer self.draw_lock.unlock();
        const ed = self.activeTab().focused.editor() orelse return;
        if (ed.buf.path == null) {
            ed.setStatus("nothing to format — no file behind this buffer", .{}, true);
            return;
        }
        lspFormatHook(self, ed);
        ed.setStatus("formatting…", .{}, false);
        ed.render_dirty = true;
        self.scene_dirty = true;
    }

    fn lspCodeActionHook(ctx: *anyopaque, ed: *editorpkg.Editor) void {
        const self: *App = @ptrCast(@alignCast(ctx));
        const path = ed.buf.path orelse return;
        self.lspSyncLocked(ed);
        // The cursor's line, start to end — not the cursor's exact
        // column. A quick fix hangs off a diagnostic that spans some
        // part of the line, and asking about a single point misses
        // every fix whose diagnostic starts one character over.
        const line: u32 = @intCast(ed.cline);
        const eol = lsppkg.utf16FromByteCol(ed.lineText(ed.cline), ed.lineCap(ed.cline));
        if (!self.lsp.codeAction(path, .{
            .start = .{ .line = line, .col = 0 },
            .end = .{ .line = line, .col = eol },
        })) {
            self.lspExplainLocked(ed);
            return;
        }
        ed.setStatus("asking what can be done here…", .{}, false);
        ed.render_dirty = true;
    }

    /// A server has answered with what it can do here.
    ///
    /// Two arrivals reach this. The first is a LIST, and it opens the
    /// picker. The second is a resolve — one action, now carrying the
    /// edit it deferred — and that one is applied, because you already
    /// chose it and being asked to choose it again would be absurd.
    fn takeCodeActionsLocked(self: *App, path: []const u8, items: []const lsppkg.CodeAction, resolved: bool) void {
        if (resolved) {
            if (items.len == 0) return;
            const a = items[0];
            if (a.edit.len == 0) {
                if (self.editorShowingLocked(path)) |ed| {
                    ed.setStatus("\"{s}\" resolved to nothing to change", .{a.title}, true);
                    ed.render_dirty = true;
                }
                return;
            }
            self.applyWorkspaceEditLocked(path, a.edit, a.file_ops, "applied", a.title);
            return;
        }

        self.freeActionsLocked();
        const owned = self.gpa.alloc(lsppkg.CodeAction, items.len) catch return;
        var n: usize = 0;
        for (items) |a| {
            owned[n] = .{
                .title = self.gpa.dupe(u8, a.title) catch break,
                .kind = self.gpa.dupe(u8, a.kind) catch break,
                .raw = self.gpa.dupe(u8, a.raw) catch break,
                // The edit comes along. An action that already carries
                // one applies straight from the picker — resolving it
                // anyway would be a round trip to be told what we were
                // already holding, and a server that does not implement
                // resolve would answer nothing at all.
                .edit = lsppkg.dupeFileEdits(self.gpa, a.edit) orelse &.{},
                .file_ops = a.file_ops,
                .deferred = a.deferred,
                .command_only = a.command_only,
            };
            n += 1;
        }
        self.pal_actions = self.gpa.realloc(owned, n) catch owned[0..n];
        self.pal_actions_path = self.gpa.dupe(u8, path) catch &.{};
        self.pal_mode = .actions;
        self.resetPaletteLocked();
    }

    fn freeActionsLocked(self: *App) void {
        lsppkg.freeCodeActions(self.gpa, self.pal_actions);
        self.pal_actions = &.{};
        self.gpa.free(self.pal_actions_path);
        self.pal_actions_path = &.{};
    }

    fn lspCompletionHook(ctx: *anyopaque, ed: *editorpkg.Editor) void {
        const self: *App = @ptrCast(@alignCast(ctx));
        const path = ed.buf.path orelse return;
        // On the KEYSTROKE path, and a full-text didChange with it —
        // the one place the 150ms debounce is deliberately skipped,
        // because a completion computed against the text before the
        // word you are typing offers the wrong words.
        self.lspSyncLocked(ed);
        _ = self.lsp.completion(path, lspPos(ed), ed.cplPrefix(), ed.cpl_base);
    }

    /// Ask about ONE candidate — the row the selection is resting on.
    ///
    /// No didChange first, unlike the completion hook: the document has
    /// not moved since the list was computed, and a resolve is about an
    /// item the server already handed us rather than about a position.
    fn lspCompletionResolveHook(ctx: *anyopaque, ed: *editorpkg.Editor, raw: []const u8, word: []const u8) void {
        const self: *App = @ptrCast(@alignCast(ctx));
        const path = ed.buf.path orelse return;
        _ = self.lsp.completionResolve(path, raw, word);
    }

    fn lspRenameHook(ctx: *anyopaque, ed: *editorpkg.Editor, new_name: []const u8) void {
        const self: *App = @ptrCast(@alignCast(ctx));
        const path = ed.buf.path orelse return;
        // EVERY open buffer, not just this one. A rename's edits come
        // back addressed to files this pane has never touched, and an
        // offset computed against a version of some other pane's buffer
        // that the server never saw would land in the wrong place. The
        // asking editor is synced by the same loop.
        self.lspSyncAllLocked();
        if (!self.lsp.rename(path, lspPos(ed), new_name)) {
            self.lspExplainLocked(ed);
            return;
        }
        ed.setStatus("renaming to {s}…", .{new_name}, false);
        ed.render_dirty = true;
    }

    /// Push every editor whose buffer the server has not seen yet.
    ///
    /// The debounce exists so typing does not flood the pipe. A rename
    /// is not typing: it is one deliberate question whose answer is
    /// applied to files by offset, so every buffer has to be the one
    /// the server measured against.
    fn lspSyncAllLocked(self: *App) void {
        for (self.spaces.items) |space| for (space.tabs.items) |tab| {
            for (tab.panes.items) |p| {
                const ed = p.editor() orelse continue;
                self.lspSyncLocked(ed);
            }
        };
    }

    /// One file a rename touches, resolved and ready to edit.
    const RenameTarget = struct {
        path: []const u8,
        buf: *bufferpkg.Buffer,
        /// We loaded this one ourselves because no pane had it open —
        /// so we also save it and put it down. A document some pane is
        /// showing is neither ours to save nor ours to free.
        own: bool,
        /// Byte offsets, ordered last-first. See lsp.resolveEdits.
        splices: []lsppkg.Splice,
    };

    /// Carry out a rename the server has described.
    ///
    /// TWO PHASES, and the split is the whole design. Phase one resolves
    /// every file — opens it, measures every edit against the text the
    /// server actually saw, and refuses on anything it does not like.
    /// Nothing is mutated until every file has passed. A rename that
    /// edited four files and then discovered the fifth was unreadable
    /// would leave a repo that compiles nowhere and an undo you have to
    /// perform in four places.
    ///
    /// What it will not do is refuse quietly. Every abort names the file
    /// and the reason, because "nothing happened" and "nothing happened
    /// because the server wants to move a file" are different facts.
    fn applyRenameLocked(self: *App, r: lspmgrpkg.RenameEdit) void {
        self.applyWorkspaceEditLocked(r.path, r.files, r.file_ops, "renamed to", r.symbol);
    }

    /// Carry out a WorkspaceEdit. `verb`/`what` name it in the report —
    /// "renamed to foo", "applied Organize imports" — because the two
    /// callers differ in nothing else.
    fn applyWorkspaceEditLocked(
        self: *App,
        from_path: []const u8,
        files: []const lsppkg.FileEdits,
        file_ops: bool,
        verb: []const u8,
        what: []const u8,
    ) void {
        const asking = self.editorShowingLocked(from_path);
        const say = struct {
            fn f(ed: ?*editorpkg.Editor, comptime fmt: []const u8, args: anytype, bad: bool) void {
                const e = ed orelse return;
                e.setStatus(fmt, args, bad);
                e.render_dirty = true;
            }
        }.f;

        if (file_ops) {
            // gopls asks for this when the symbol owns its file. Doing
            // the text half alone would leave a repo that references a
            // name in a file still called the old thing.
            say(asking, "that also moves files, which rook cannot do yet — nothing changed", .{}, true);
            return;
        }
        if (files.len == 0) {
            say(asking, "nothing to change", .{}, false);
            return;
        }

        var targets: std.ArrayListUnmanaged(RenameTarget) = .empty;
        defer targets.deinit(self.gpa);
        // Unwinds a phase-one abort: whatever we loaded is put back
        // down, and nothing has been edited yet, so there is nothing to
        // undo.
        var ok = true;
        defer if (!ok) {
            for (targets.items) |t| {
                self.gpa.free(t.splices);
                if (!t.own) continue;
                t.buf.deinit(self.gpa);
                self.gpa.destroy(t.buf);
            }
        };

        for (files) |f| {
            // The two WorkspaceEdit shapes can both name one file, and
            // applying its edits twice would rename `foo` to `barbar`.
            var seen = false;
            for (targets.items) |t| {
                if (lspmgrpkg.samePath(t.path, f.path)) seen = true;
            }
            if (seen) continue;

            var target: RenameTarget = .{ .path = f.path, .buf = undefined, .own = false, .splices = &.{} };
            if (self.editorShowingLocked(f.path)) |ed| {
                target.buf = ed.buf;
                // The server answered about the text we sent it. If the
                // buffer has moved on since, every offset in this reply
                // is measured against a document that no longer exists.
                if (ed.buf.version != ed.buf.lsp_version) {
                    say(asking, "{s} changed while the server was answering — nothing renamed", .{ed.displayName()}, true);
                    ok = false;
                    return;
                }
            } else {
                const owned = self.gpa.create(bufferpkg.Buffer) catch {
                    ok = false;
                    return;
                };
                owned.* = bufferpkg.Buffer.initFromFile(self.gpa, self.io, f.path) catch {
                    self.gpa.destroy(owned);
                    say(asking, "cannot read {s} — nothing renamed", .{std.fs.path.basename(f.path)}, true);
                    ok = false;
                    return;
                };
                target.buf = owned;
                target.own = true;
            }
            if (target.buf.readonly) {
                say(asking, "{s} is not editable — nothing renamed", .{std.fs.path.basename(f.path)}, true);
                ok = false;
                if (target.own) {
                    target.buf.deinit(self.gpa);
                    self.gpa.destroy(target.buf);
                }
                return;
            }

            const text = target.buf.rope.dupeRange(self.gpa, 0, target.buf.rope.byteLen()) catch {
                ok = false;
                if (target.own) {
                    target.buf.deinit(self.gpa);
                    self.gpa.destroy(target.buf);
                }
                return;
            };
            defer self.gpa.free(text);
            target.splices = lsppkg.resolveEdits(self.gpa, text, f.edits) orelse {
                say(asking, "the server's edits for {s} overlap — nothing renamed", .{std.fs.path.basename(f.path)}, true);
                ok = false;
                if (target.own) {
                    target.buf.deinit(self.gpa);
                    self.gpa.destroy(target.buf);
                }
                return;
            };
            targets.append(self.gpa, target) catch {
                self.gpa.free(target.splices);
                ok = false;
                if (target.own) {
                    target.buf.deinit(self.gpa);
                    self.gpa.destroy(target.buf);
                }
                return;
            };
        }

        // Phase two. Everything below here succeeds or is reported; the
        // validation that could refuse has already happened.
        var open_n: usize = 0;
        var written_n: usize = 0;
        var failed_n: usize = 0;
        for (targets.items) |t| {
            // ONE undo group per file, so `u` in a pane takes back that
            // pane's whole share of the rename rather than one
            // occurrence of it.
            t.buf.newUndoGroup();
            t.buf.group_pinned = true;
            for (t.splices) |s| {
                t.buf.deleteRange(self.gpa, s.start, s.end) catch {};
                t.buf.insert(self.gpa, s.start, s.text) catch {};
            }
            t.buf.group_pinned = false;
            self.gpa.free(t.splices);

            if (!t.own) {
                open_n += 1;
                continue;
            }
            // A file nobody is looking at has nowhere to show a dirty
            // flag and nobody to press `:w`, so it is written now —
            // through save(), which keeps the atomic replace, the
            // permissions and the clobber guard.
            if (t.buf.save(self.gpa, self.io, false)) {
                written_n += 1;
            } else |_| failed_n += 1;
            t.buf.deinit(self.gpa);
            self.gpa.destroy(t.buf);
        }

        self.scene_dirty = true;
        // Open buffers are left UNSAVED on purpose: the change is in
        // front of you, `u` takes it back, and `:wa` commits it. Files
        // you cannot see got no such review, which is why they are
        // written — the asymmetry is the honest one, and saying which
        // is which is why this line is as long as it is.
        if (failed_n > 0) {
            say(asking, "{s} {s} — {d} written, {d} unsaved, {d} FAILED to write", .{ verb, what, written_n, open_n, failed_n }, true);
        } else if (open_n > 0 and written_n > 0) {
            say(asking, "{s} {s} in {d} files — {d} written, {d} open and unsaved (:wa)", .{ verb, what, open_n + written_n, written_n, open_n }, false);
        } else if (written_n > 0) {
            say(asking, "{s} {s} in {d} files, all written", .{ verb, what, written_n }, false);
        } else {
            say(asking, "{s} {s} in {d} open {s} — unsaved (:wa writes them)", .{ verb, what, open_n, @as([]const u8, if (open_n == 1) "file" else "files") }, false);
        }
    }

    /// Read an answered references list into the panel, off the frame.
    ///
    /// The sites arrive as positions with no text, and the panel shows
    /// text — so somebody opens every file named. That is a filesystem
    /// walk, which never happens on the frame; it goes to a worker and
    /// comes back through `sr_pending`, exactly as a grep does.
    const RefJob = struct {
        app: *App,
        root: []u8,
        label: []u8,
        marks: []searchpkg.Mark,
        /// The absolute paths `marks` borrow, owned here.
        paths: [][]u8,

        fn deinit(job: *RefJob, gpa: std.mem.Allocator) void {
            for (job.paths) |p| gpa.free(p);
            gpa.free(job.paths);
            gpa.free(job.marks);
            gpa.free(job.root);
            gpa.free(job.label);
            gpa.destroy(job);
        }
    };

    fn startRefsLocked(self: *App, sites: []const lspmgrpkg.Site, symbol: []const u8) void {
        var rootbuf: [1024]u8 = undefined;
        // "" is a legal root: relativeTo then shows absolute paths,
        // which is the right answer for a pane with no repo under it.
        const root = self.paneRootLocked(self.activeTab().focused, &rootbuf) orelse "";

        const job = self.gpa.create(RefJob) catch return;
        job.* = .{
            .app = self,
            .root = self.gpa.dupe(u8, root) catch {
                self.gpa.destroy(job);
                return;
            },
            .label = self.gpa.dupe(u8, symbol) catch {
                self.gpa.free(job.root);
                self.gpa.destroy(job);
                return;
            },
            .marks = self.gpa.alloc(searchpkg.Mark, sites.len) catch {
                self.gpa.free(job.root);
                self.gpa.free(job.label);
                self.gpa.destroy(job);
                return;
            },
            .paths = self.gpa.alloc([]u8, sites.len) catch {
                self.gpa.free(job.marks);
                self.gpa.free(job.root);
                self.gpa.free(job.label);
                self.gpa.destroy(job);
                return;
            },
        };
        // Copied rather than borrowed: the Answer these came from is
        // freed the moment this frame's drain loop moves on, and the
        // worker outlives it.
        var n: usize = 0;
        for (sites) |s| {
            const p = self.gpa.dupe(u8, s.path) catch continue;
            job.paths[n] = p;
            job.marks[n] = .{ .path = p, .line = s.line, .col = s.col };
            n += 1;
        }
        job.paths = self.gpa.realloc(job.paths, n) catch job.paths[0..n];
        job.marks = self.gpa.realloc(job.marks, n) catch job.marks[0..n];

        self.sr_running.store(true, .release);
        const T = struct {
            fn go(j: *RefJob) void {
                const app = j.app;
                const res = searchpkg.atMarks(app.gpa, j.root, j.label, j.marks);
                app.draw_lock.lock();
                if (app.sr_pending) |*old| {
                    var o = old.*;
                    o.deinit(app.gpa);
                }
                app.sr_pending = res;
                app.sr_pending_kind = .references;
                app.scene_dirty = true;
                app.draw_lock.unlock();
                app.sr_running.store(false, .release);
                j.deinit(app.gpa);
            }
        };
        if (std.Thread.spawn(.{}, T.go, .{job})) |t| {
            t.detach();
        } else |_| {
            self.sr_running.store(false, .release);
            job.deinit(self.gpa);
        }

        // Show the panel now, holding "searching…", rather than when the
        // list is ready: a key whose whole effect arrives late reads as
        // a key that did nothing.
        const was = self.side_open and self.side_panel == .search;
        self.side_panel = .search;
        self.side_open = true;
        self.sr_kind = .references;
        // The LIST takes the keys, and the box does not — you asked a
        // question, and the answer is something to walk. Taking focus is
        // right here and wrong for diagnostics, and the difference is
        // that this one is a key you pressed: `gr` means "show me", and
        // a panel you then had to ⌃L into would make it two gestures.
        // ESC hands the keys straight back.
        self.sr_typing = false;
        self.side_focus = true;
        if (!was) self.relayoutLocked();
        self.scene_dirty = true;
    }

    /// Put rendered text into an editor pane, under a display name.
    ///
    /// Takeover, exactly like `edit`: the shell parks underneath and
    /// `:q` gives it back. A transcript is something you read beside
    /// your work and then dismiss, which is the same shape.
    pub fn openTextPane(self: *App, name: []const u8, text: []const u8) void {
        self.draw_lock.lock();
        defer self.draw_lock.unlock();
        const t = self.activeTab();
        const p = t.focused;
        if (p.editor()) |ed| {
            ed.openText(name, text) catch return;
            self.scene_dirty = true;
            return;
        }
        const ed = self.newEditorLocked(null) orelse return;
        ed.openText(name, text) catch {
            ed.destroy();
            return;
        };
        var tm = p.content.term;
        tm.copy_mode = false;
        p.under = tm;
        p.content = .{ .edit = ed };
        p.drawn_cursor = 0xffff_ffff;
        self.focused_session.store(self.focusedTermSession(), .release);
        self.refreshHudLocked(CACurrentMediaTime());
        self.scene_dirty = true;
    }

    fn queueVerdictLocked(self: *App, state: []const u8) void {
        if (self.rev_sel >= self.rev.slice().len) return;
        const f = self.rev.slice()[self.rev_sel];
        const k = @min(state.len, self.rev_set.len);
        @memcpy(self.rev_set[0..k], state[0..k]);
        self.rev_set_len = k;
        self.rev_set_id = f.id;
        // Move on immediately: the next finding is where you are going
        // anyway, and waiting for a round trip to advance would make
        // triaging 52 of them feel like 52 round trips.
        self.rev_sel = @min(self.rev_sel + 1, self.rev.slice().len -| 1);
        self.rev_wake.store(true, .release);
        self.scene_dirty = true;
    }

    fn flipSidePane(self: *App) void {
        self.draw_lock.lock();
        defer self.draw_lock.unlock();
        self.side = if (self.side == .left) .right else .left;
        self.relayoutLocked();
        self.scene_dirty = true;
    }

    /// Let an editor's `:` reach the command registry (`:PaneSplitRight`).
    pub fn attachCommands(self: *App, ed: *editorpkg.Editor) void {
        ed.cmd_ctx = self;
        ed.app_command = &editorExCommand;
        ed.app_quit_all = &editorQuitAll;
        ed.app_open = &editorOpenRequest;
        ed.leader = self.keybinds.ed_leader;
        ed.leader_binds = self.keybinds.edBinds();
        ed.bufline_mode = switch (self.cfg_bufline) {
            .off => .off,
            .multiple => .multiple,
            .always => .always,
        };
        ed.default_insert = self.cfg_ed_insert;
        ed.suggest_on = self.cfg_suggest;
        // create() opened the file before this ran; the default mode
        // applies now that the editor knows what it is.
        ed.applyDefaultMode();
    }

    /// The editor asked for a path OUTSIDE itself (tree beside-open,
    /// :sp/:vsp). Fired on the key path under draw_lock, so it only
    /// QUEUES — pane surgery happens in drainPendingOpen, lock-free.
    fn editorOpenRequest(ctx: *anyopaque, path: []const u8, line: usize, how: editorpkg.OpenHow) bool {
        const self: *App = @ptrCast(@alignCast(ctx));
        if (path.len == 0 or path.len > self.pending_open_path.len) return false;
        @memcpy(self.pending_open_path[0..path.len], path);
        self.pending_open = .{
            .len = path.len,
            .line = line,
            .how = how,
            .from = self.activeTab().focused.id,
        };
        return true;
    }

    /// Serve a queued open-beside: reuse the editor pane to the right
    /// of the asking pane, or split a fresh EDITOR pane off it (no
    /// shell underneath — this pane exists for the document). The
    /// asking pane stays; for the tree that is the whole point — it
    /// keeps standing as the sidebar while files open beside it.
    fn drainPendingOpen(self: *App) void {
        self.draw_lock.lock();
        const req = self.pending_open orelse {
            self.draw_lock.unlock();
            return;
        };
        self.pending_open = null;
        var pbuf: [1024]u8 = undefined;
        @memcpy(pbuf[0..req.len], self.pending_open_path[0..req.len]);
        const path = pbuf[0..req.len];
        // Copied under the lock for the same reason the path is: a new
        // request queued between unlock and open would overwrite it.
        var fbuf: [256]u8 = undefined;
        @memcpy(fbuf[0..req.find_len], self.pending_open_find[0..req.find_len]);
        const needle = fbuf[0..req.find_len];

        const t = self.activeTab();
        var src: ?*panespkg.Pane = null;
        for (t.panes.items) |p| {
            if (p.id == req.from) {
                src = p;
                break;
            }
        }
        const src_pane = src orelse {
            self.draw_lock.unlock();
            return;
        };

        // Here: THIS pane takes the document — an editor retargets in
        // place (rook-buffers: the pane is the window, and its buffer
        // list grows by one), a terminal is taken over with the shell
        // parked underneath. That is exactly `openEditor`, which is
        // also what ctl `edit` and `rook edit` mean by opening a file,
        // so ⌘P lands where every other open already lands. A TREE is
        // the exception: retargeting the sidebar to a file would
        // dissolve the sidebar, so it beside-opens instead.
        if (req.how == .here) {
            const is_tree = if (src_pane.editor()) |ed| ed.is_dir else false;
            if (!is_tree) {
                self.setFocusLocked(src_pane);
                self.draw_lock.unlock();
                if (req.line > 0 or req.col > 0) {
                    if (needle.len > 0) {
                        _ = self.openEditorAtMatch(path, @intCast(req.line + 1), req.col, needle);
                    } else _ = self.openEditorAt(path, @intCast(req.line + 1), req.col);
                } else _ = self.openEditor(path);
                return;
            }
        }

        // Beside: the pane to the right, if it is already a document
        // pane, retargets in place — rook-buffers' own rule.
        if (req.how == .beside) {
            if (panespkg.navigate(t.panes.items, src_pane, .right)) |nb| {
                if (nb.editor()) |ned| {
                    if (!ned.is_dir) {
                        // `open` re-attaches through on_retarget.
                        ned.open(path, false) catch {
                            self.draw_lock.unlock();
                            return;
                        };
                        if (req.line > 0) ned.cline = @min(req.line, ned.lineCountB() -| 1);
                        self.setFocusLocked(nb);
                        self.scene_dirty = true;
                        self.draw_lock.unlock();
                        return;
                    }
                }
            }
        }

        // Split a fresh editor pane off the asker.
        const ed = self.newEditorLocked(path) orelse {
            self.draw_lock.unlock();
            return;
        };
        self.attachCommands(ed);
        if (req.line > 0) ed.cline = @min(req.line, ed.lineCountB() -| 1);
        const pane = self.gpa.create(panespkg.Pane) catch {
            ed.destroy();
            self.draw_lock.unlock();
            return;
        };
        pane.* = .{ .id = self.next_pane_id, .content = .{ .edit = ed } };
        self.next_pane_id += 1;
        const horiz = req.how != .split_down;
        // The pinned SIDEBAR never splits itself — it is a list, not a
        // document, and halving 34 columns leaves two unusable slivers.
        // Its file goes into the sibling subtree instead: the sidebar's
        // root split keeps its ratio and the document lands first among
        // everything to the tree's right (NERDTree's own shape).
        const placed = blk: {
            const sed = src_pane.editor() orelse break :blk false;
            if (!sed.is_dir or !sed.tree_pinned) break :blk false;
            const sp = panespkg.splitOf(&t.root, src_pane) orelse break :blk false;
            if (sp.a != .leaf or sp.a.leaf != src_pane) break :blk false;
            const inner = self.gpa.create(panespkg.Split) catch break :blk false;
            inner.* = .{ .horiz = true, .a = .{ .leaf = pane }, .b = sp.b };
            sp.b = .{ .split = inner };
            break :blk true;
        };
        if (!placed and !panespkg.splitAt(self.gpa, &t.root, src_pane, pane, horiz)) {
            ed.destroy();
            self.gpa.destroy(pane);
            self.draw_lock.unlock();
            return;
        }
        t.panes.append(self.gpa, pane) catch {};
        self.setFocusLocked(pane);
        self.relayoutLocked();
        self.refreshHudLocked(CACurrentMediaTime());
        self.scene_dirty = true;
        self.draw_lock.unlock();
    }

    /// `:qa` / `:wa` / `:wqa`, queued.
    ///
    /// Queued and not done here for a reason the stack makes unavoidable:
    /// this is called from inside the issuing editor's execCommand, and
    /// that editor is one of the panes "all" covers. Closing it now would
    /// free the buffer the ex parser is still reading.
    fn editorQuitAll(ctx: *anyopaque, write: bool, quit: bool, force: bool) void {
        const self: *App = @ptrCast(@alignCast(ctx));
        self.pending_quit_all = .{ .write = write, .quit = quit, .force = force };
    }

    /// Write and/or close every editor pane, in every tab.
    ///
    /// Every tab, because "all" means all — and the pane reaper already
    /// walks all of them, restoring a parked shell where there is one and
    /// collapsing the pane where there is not. Terminals are untouched:
    /// the editor is a tenant of rook, not rook itself.
    ///
    /// Each buffer goes through the editor's OWN ex verb rather than a
    /// second copy of the write path, so the clobber guard, projected
    /// buffers and `!` behave here exactly as they do when you type them.
    pub fn drainQuitAll(self: *App) void {
        self.draw_lock.lock();
        const req = self.pending_quit_all;
        self.pending_quit_all = null;
        self.draw_lock.unlock();
        const r = req orelse return;

        self.draw_lock.lock();
        defer self.draw_lock.unlock();
        for (self.spaces.items) |space| {
            for (space.tabs.items) |t| {
                for (t.panes.items) |p| {
                    const ed = p.editor() orelse continue;
                    // Three verbs, not two. `:wa` writes and leaves the
                    // pane open; only the quitting forms close it.
                    ed.runEx(if (!r.quit)
                        (if (r.force) "w!" else "w")
                    else if (r.write)
                        (if (r.force) "x!" else "x")
                    else if (r.force) "q!" else "q");
                }
            }
        }
        self.scene_dirty = true;
    }

    /// The editor's ex-command bridge. QUEUES rather than dispatching:
    /// this runs inside the editor's key handling, which runs under
    /// draw_lock, and every command target takes it again. Both callers
    /// of paneInput drain after unlocking — the same route the palette's
    /// Enter takes, and for the same reason.
    fn editorExCommand(ctx: *anyopaque, name: []const u8) bool {
        const self: *App = @ptrCast(@alignCast(ctx));
        // Two spellings reach this seam: derived ex names from `:`
        // (PaneSplitRight) and raw registry ids from the editor
        // leader's own bindings (tree.toggle). They cannot collide —
        // ids are lowercase, ex names lead with a capital.
        const c = registrypkg.byId(name) orelse registrypkg.byExName(name) orelse return false;
        self.pending_cmd = .{ .action = c.action, .arg = c.arg };
        return true;
    }

    /// Run whatever the palette queued, now that the lock is free.
    /// Idempotent and cheap: the common case is a null check.
    pub fn drainPendingCmd(self: *App) void {
        self.draw_lock.lock();
        const spec = self.pending_cmd;
        self.pending_cmd = null;
        self.draw_lock.unlock();
        if (spec) |s| self.dispatch(s);
        self.drainPendingOpen();
        self.drainQuitAll();
        // The plugin panel's r and its Enter: both start workers, and
        // startPluginFetch/Act take draw_lock — so the key path can only
        // ask for them, never call them.
        self.draw_lock.lock();
        const check = self.env_check_wanted;
        const setup = self.setup_wanted;
        const apply_now = self.env_apply_wanted;
        const pin_now = self.plug_pin_wanted;
        self.plug_pin_wanted = false;
        self.env_apply_wanted = false;
        self.env_check_wanted = false;
        self.setup_wanted = null;
        const refetch = self.plug_refetch;
        const act = self.plug_run;
        var chosen: [64]u8 = undefined;
        const chosen_len = self.plug_pending_len;
        if (chosen_len > 0) @memcpy(chosen[0..chosen_len], self.plug_pending[0..chosen_len]);
        self.plug_refetch = false;
        self.plug_run = false;
        self.plug_pending_len = 0;
        self.draw_lock.unlock();
        if (pin_now) self.copyPluginPin();
        if (apply_now) _ = self.applyEnv();
        if (setup) |l| self.startSetup(l);
        if (check) self.startEnvCheck();
        if (chosen_len > 0) _ = self.showPlugin(chosen[0..chosen_len]);
        if (refetch) self.startPluginFetch();
        if (act) self.startPluginAct();
    }

    /// The leader state machine — ONE path for real keystrokes (the
    /// event monitor) and ctl `press`, so chords are testable blind.
    /// Returns true if the key was consumed (armed a chord, resolved
    /// one, or was swallowed as an unknown chord).
    pub fn handleCharKey(self: *App, ch: u8, ts: f64) bool {
        const ld = self.keybinds.leader orelse return false;
        // The palette owns the whole key path while open (typing a
        // leader char into a filter must not arm a chord).
        if (self.pal_open) return false;
        // The leader works in editors too (pane nav must not dead-end
        // there) — a literal leader char costs a double-tap, same as
        // the terminal. Seth's call in TODO.md.
        if (self.leader_pending.swap(false, .acq_rel)) {
            self.wkClose();
            if (ch == ld) {
                // Double-tap: the leader typed literally.
                _ = self.writeFocused(&[1]u8{ch}, ts);
                return true;
            }
            if (self.keybinds.lookup(ch)) |b| {
                self.dispatch(.{ .action = b.action, .arg = b.arg });
                return true;
            }
            return true; // unknown chord: swallowed, tmux-style
        }
        if (ch == ld) {
            // Arm, and start the which-key clock: the sheet reveals only
            // if this chord goes unanswered for wk_delay_s (drawFrame's
            // tick check), so practiced hands never see it flash.
            self.draw_lock.lock();
            self.wk_visible = false;
            self.wk_armed_at = ts;
            self.scene_dirty = true;
            self.draw_lock.unlock();
            self.leader_pending.store(true, .release);
            return true;
        }
        return false;
    }

    /// Disarm cleanup shared by every way a chord ends: hide the
    /// which-key sheet and repaint the bar's armed cell.
    fn wkClose(self: *App) void {
        self.draw_lock.lock();
        self.wk_visible = false;
        self.scene_dirty = true;
        self.draw_lock.unlock();
    }

    fn setFocusLocked(self: *App, pane: *panespkg.Pane) void {
        const t = self.activeTab();
        // Focusing a DIFFERENT pane unzooms, tmux-style. Focus must
        // never land somewhere invisible; clicking the zoomed pane
        // itself is not a move and keeps the zoom.
        if (t.focused != pane and t.zoomed != null) {
            t.zoomed = null;
            self.relayoutLocked();
        }
        t.focused = pane;
        self.focused_session.store(if (pane.term()) |t2| t2.session else null, .release);
        self.scene_dirty = true;
    }

    /// `<leader>z`: the focused pane takes the whole tab, or gives it
    /// back. A no-op in a single-pane tab — there is nothing to hide,
    /// and a zoom you can't see is a zoom you can't get out of. Any
    /// thread.
    pub fn toggleZoom(self: *App) bool {
        self.draw_lock.lock();
        defer self.draw_lock.unlock();
        const t = self.activeTab();
        if (t.zoomed != null) {
            t.zoomed = null;
        } else {
            if (t.panes.items.len < 2) return false;
            t.zoomed = t.focused;
        }
        self.relayoutLocked();
        self.scene_dirty = true;
        return true;
    }

    /// Does the focused pane's program own ⌃HJKL for itself?
    ///
    /// Asked fresh on every press, because the answer changes the
    /// instant you type `vim` and again the instant you leave it —
    /// anything cached is wrong for exactly as long as it is cached.
    /// Two syscalls; the keystroke does not notice.
    ///
    /// Only terminals can answer. An editor pane is rook's own and
    /// keeps the keys; a shell at its prompt is not in the list and
    /// keeps nothing.
    pub fn navYields(self: *App) bool {
        self.draw_lock.lock();
        const session = switch (self.activeTab().focused.content) {
            .term => |*tm| tm.session,
            // rook's own panes keep ctrl+hjkl: there is no foreground
            // program to hand it to.
            .edit, .monitor => {
                self.draw_lock.unlock();
                return false;
            },
        };
        self.draw_lock.unlock();

        var buf: [cfgpkg.NameList.max_len]u8 = undefined;
        const name = session.fgName(&buf) orelse return false;
        return self.cfg_nav_yield.has(name);
    }

    /// Move focus in a direction within the active tab. Any thread.
    /// Returns false if no pane lies that way.
    pub fn focusMove(self: *App, dir: panespkg.NavDir) bool {
        self.draw_lock.lock();
        defer self.draw_lock.unlock();
        const t = self.activeTab();
        // navigate() reads RECTS, and a zoomed tab's hidden panes have
        // none — so unzoom first or every direction reads as "nothing
        // there" and ctrl+hjkl silently dies. If nothing does lie that
        // way, put the zoom back: unzooming for a keystroke that
        // otherwise did nothing is its own small betrayal, and zoom is
        // one pointer, so restoring it is exact.
        const was_zoomed = t.zoomed;
        if (was_zoomed != null) {
            t.zoomed = null;
            self.relayoutLocked();
        }
        const target = panespkg.navigate(t.panes.items, t.focused, dir) orelse {
            if (was_zoomed) |z| {
                t.zoomed = z;
                self.relayoutLocked();
            }
            return false;
        };
        self.setFocusLocked(target);
        return true;
    }

    /// ⌃HJKL while the side panel HOLDS the keys. The chord stays
    /// chrome: away-from-the-panel hands focus back to the panes,
    /// up/down move the panel's own selection, and everything else is
    /// consumed — the old behavior moved pane focus invisibly UNDER a
    /// panel that kept eating the typing, which read as broken focus.
    /// Returns true when the key is spoken for.
    pub fn sidePaneNav(self: *App, dir: panespkg.NavDir) bool {
        self.draw_lock.lock();
        defer self.draw_lock.unlock();
        if (!self.side_open or !self.side_focus) return false;
        const away: panespkg.NavDir = if (self.side == .left) .right else .left;
        if (dir == away) {
            self.side_focus = false;
            self.scene_dirty = true;
            return true;
        }
        switch (dir) {
            .up, .down => if (self.side_panel == .plugin) {
                self.plugMoveLocked(dir == .down);
                self.scene_dirty = true;
            },
            else => {},
        }
        return true;
    }

    /// The other half: the panel is open but unfocused, and the chord
    /// walked off the edge pane toward it — step INTO the panel, the
    /// same way one more ⌃L would have entered one more split. Costs
    /// the cooked control byte at the edge, the same trade ⌃HJKL nav
    /// made on day one.
    pub fn sidePaneEnter(self: *App, dir: panespkg.NavDir) bool {
        self.draw_lock.lock();
        defer self.draw_lock.unlock();
        if (!self.side_open or self.side_focus) return false;
        const toward: panespkg.NavDir = if (self.side == .left) .left else .right;
        if (dir != toward) return false;
        self.side_focus = true;
        self.scene_dirty = true;
        return true;
    }

    /// Focus a pane by id, switching space and tab if it lives elsewhere.
    pub fn focusById(self: *App, id: u32) bool {
        self.draw_lock.lock();
        defer self.draw_lock.unlock();
        for (self.spaces.items, 0..) |s, si| {
            for (s.tabs.items, 0..) |t, ti| {
                for (t.panes.items) |p| {
                    if (p.id == id) {
                        if (si != self.active_space) self.activateSpaceLocked(si);
                        if (ti != s.active_tab) self.activateTabLocked(ti);
                        self.setFocusLocked(p);
                        return true;
                    }
                }
            }
        }
        return false;
    }

    /// Collapse panes whose shell exited — across ALL tabs (background
    /// shells exit too); an emptied tab closes, the last tab closing
    /// exits the app. Caller holds draw_lock; never runs on a reader
    /// thread (Session.deinit joins it).
    fn reapExitedLocked(self: *App) void {
        var changed = false;
        var si: usize = 0;
        while (si < self.spaces.items.len) : (si += 1) {
        const space = self.spaces.items[si];
        var ti: usize = 0;
        while (ti < space.tabs.items.len) {
            const t = space.tabs.items[ti];
            var i: usize = 0;
            while (i < t.panes.items.len) {
                const p = t.panes.items[i];
                const done = switch (p.content) {
                    .term => |*tm| tm.session.exited.load(.acquire),
                    .edit => |ed| blk: {
                        if (!ed.closed) break :blk false;
                        const ut = p.under orelse break :blk true;
                        // Takeover editor closing: restore the parked
                        // shell instead of collapsing the pane. (If the
                        // shell died while parked, the term arm catches
                        // it next frame.)
                        ed.destroy();
                        p.under = null;
                        p.content = .{ .term = ut };
                        p.drawn_cursor = 0xffff_ffff;
                        changed = true;
                        break :blk false;
                    },
                    .monitor => |m| blk: {
                        if (!m.closed) break :blk false;
                        const ut = p.under orelse break :blk true;
                        // Same handshake the takeover editor gets: the
                        // monitor was opened OVER a shell, so closing it
                        // puts the shell back rather than collapsing the
                        // pane out from under a running command.
                        m.deinit();
                        self.gpa.destroy(m);
                        p.under = null;
                        p.content = .{ .term = ut };
                        p.drawn_cursor = 0xffff_ffff;
                        changed = true;
                        break :blk false;
                    },
                };
                if (!done) {
                    i += 1;
                    continue;
                }
                changed = true;
                if (self.drag_pane == p) self.drag_pane = null;
                // The zoomed pane is about to be freed; a stale pointer
                // here would lay out a dead pane over the whole tab.
                if (t.zoomed == p) t.zoomed = null;
                self.drag_split = null; // tree is about to mutate
                _ = panespkg.removeAt(self.gpa, &t.root, p);
                _ = t.panes.swapRemove(i);
                const was_focused = t.focused == p;
                switch (p.content) {
                    .term => |*tm| {
                        tm.session.deinit();
                        tm.rs.deinit(self.gpa);
                    },
                    .edit => |ed| ed.destroy(),
                    .monitor => |m| {
                        m.deinit();
                        self.gpa.destroy(m);
                    },
                }
                self.gpa.destroy(p);
                if (t.panes.items.len > 0 and was_focused) t.focused = t.panes.items[0];
            }
            if (t.panes.items.len == 0) {
                t.panes.deinit(self.gpa);
                self.gpa.destroy(t);
                _ = space.tabs.orderedRemove(ti);
                if (space.active_tab >= space.tabs.items.len) space.active_tab = space.tabs.items.len -| 1;
                continue;
            }
            ti += 1;
        }
        }
        // A space whose last tab closed collapses (tmux: session ends);
        // the LAST space closing exits the app.
        var sj: usize = 0;
        while (sj < self.spaces.items.len) {
            const s = self.spaces.items[sj];
            if (s.tabs.items.len > 0) {
                sj += 1;
                continue;
            }
            changed = true;
            s.tabs.deinit(self.gpa);
            self.gpa.destroy(s);
            _ = self.spaces.orderedRemove(sj);
            if (self.spaces.items.len == 0) {
                // Last shell of the last space: the terminal's work is done.
                _exit(0);
            }
            if (self.active_space >= self.spaces.items.len) self.active_space = self.spaces.items.len - 1;
        }
        if (changed) {
            self.focused_session.store(self.focusedTermSession(), .release);
            self.relayoutLocked();
            self.refreshHudLocked(CACurrentMediaTime());
            self.scene_dirty = true;
        }
    }

    /// Is there a cursor on screen worth blinking? The focused pane's
    /// terminal cursor — a terminal that hid its cursor (DECTCEM) has
    /// nothing to blink, and unfocused terminals draw no cursor at all
    /// — or ANY visible editor's: editors blink focused or not (the
    /// solid-marker design read as broken from one pane over), so a
    /// visible unfocused editor keeps the phase ticking. Reads the
    /// last snapshot's cursor state, which is exactly what the fills
    /// will draw. Caller holds draw_lock.
    fn focusedCursorShowing(self: *App) bool {
        const atab = self.activeTab();
        switch (atab.focused.content) {
            .term => |*tm| if (tm.rs.cursor.visible and tm.rs.cursor.viewport != null) return true,
            .edit => return true,
            // Row selection is drawn solid; there is nothing to blink,
            // so the monitor must not keep the blink timer alive (that
            // would cost a frame every 550ms for no visible change).
            .monitor => return false,
        }
        for (atab.panes.items) |p| {
            if (p.rect.w == 0) continue;
            if (p.content == .edit) return true;
        }
        return false;
    }

    fn drawFrame(self: *App) void {
        const pool = objc.AutoreleasePool.init();
        defer pool.deinit();

        const tick = self.frame_count.fetchAdd(1, .monotonic);
        const t_start = CACurrentMediaTime();

        self.reapExitedLocked();
        self.drainClipboardLocked();
        self.drainSearchLocked();
        self.reconcileViewsLocked();
        self.drainLspLocked();
        self.lspTickLocked(CACurrentMediaTime());

        // HUD refresh at ~2Hz. Runs on skipped ticks too, so the bar
        // stays live during idle — but only a text CHANGE causes a draw.
        if (tick % 60 == 0) self.refreshHudLocked(t_start);

        // The plugin panel refreshes itself while it is open (~2s): a
        // watcher whose panel shows open-time state is a photograph, not
        // a panel. Rows mode only — a menu or a confirm mid-interaction
        // must not have the ground move under it — and only after one
        // GOOD answer (plug.live): a failing plugin is retried by the
        // human's `r`, not by a clock.
        if (tick % 240 == 0 and self.side_open and self.side_panel == .plugin and
            self.plug_mode == .rows and self.plug.live)
        {
            self.plug_auto_wanted = true;
        }

        // Which-key reveal: an armed leader that has sat unanswered for
        // wk_delay_s gets the menu. Checked on every tick because the
        // reveal is TIME crossing a threshold, not state changing — no
        // event will arrive to flip a dirty flag for it.
        if (self.leader_pending.load(.acquire) and !self.wk_visible and
            t_start - self.wk_armed_at >= wk_delay_s)
        {
            self.wk_visible = true;
            self.scene_dirty = true;
        }

        // Cursor blink: the one continuous animation, kept honest about
        // the zero-idle-frames property — it only ticks while rook is
        // frontmost AND the focused pane is actually showing a cursor.
        // Everywhere else the phase is forced solid, so backgrounded
        // rook still draws nothing at all.
        if (self.cursor_blink and self.app_active and self.focusedCursorShowing()) {
            const on = @mod(t_start - self.blink_epoch, blink_period_s) < blink_on_s;
            if (on != self.blink_phase_on) {
                self.blink_phase_on = on;
                self.scene_dirty = true;
            }
        } else if (!self.blink_phase_on) {
            self.blink_phase_on = true;
            self.scene_dirty = true;
        }

        // Snapshot every ACTIVE-TAB pane under its session lock, with
        // priority over the readers' parse loops. Background tabs are
        // never snapshotted — their emulators advance, their render
        // work is zero. focused_dirty means the FOCUSED PANE'S GRID
        // changed — chrome/HUD-only frames must never consume the
        // key-to-photon mark (that skew was measured: a 2Hz HUD refresh
        // stole marks and moved quiet-key p50 by ~4ms).
        const atab = self.activeTab();
        var any_dirty = self.scene_dirty;
        var focused_dirty = false;
        for (atab.panes.items) |p| {
            // Hidden by zoom: same deal as a background tab — the
            // emulator keeps advancing, the render work is zero.
            if (p.rect.w == 0) {
                p.dirty = false;
                p.drawn_cols = 0;
                continue;
            }
            switch (p.content) {
                .monitor => |m| {
                    // Polled, not evented: a new sample arrives with no
                    // keystroke, so the sampler sets render_dirty and
                    // this is where it turns into a frame.
                    p.dirty = m.render_dirty;
                    m.render_dirty = false;
                },
                .term => |*tm| {
                    tm.session.lockForSnapshot();
                    tm.rs.update(self.gpa, &tm.session.term) catch {
                        tm.session.unlockForSnapshot();
                        p.dirty = false;
                        continue;
                    };
                    tm.session.unlockForSnapshot();
                    p.dirty = tm.rs.dirty != .@"false";
                    tm.rs.dirty = .@"false";
                    // Cursor-only changes (backspace's \b, arrows, DECTCEM
                    // hide/show) dirty no row — compare against what the last
                    // fill drew, or the on-screen cursor goes stale. The cursor
                    // move IS the key's visible echo, so it legitimately sets
                    // focused_dirty and consumes the key→photon mark.
                    if (p == atab.focused and cursorKey(tm) != p.drawn_cursor) p.dirty = true;
                },
                .edit => |ed| {
                    p.dirty = ed.render_dirty;
                    ed.render_dirty = false;
                },
            }
            if (p.dirty) {
                any_dirty = true;
                if (p == atab.focused) focused_dirty = true;
            }
        }
        const t_update = CACurrentMediaTime();

        // A clean scene means nothing to draw: skip the whole frame. This
        // is both the honest idle number (zero work) and the honest
        // latency number — the key mark is consumed only by a frame that
        // actually carried the focused pane's echo.
        //
        // Zed keeps presenting for a second after input here, to stop a
        // ProMotion panel downclocking between keystrokes. Tried, and
        // REVERTED against measurement (PERF.md, 2026-08-06): with two
        // drawables, continuous presenting saturates the swapchain and
        // every echo frame queues behind a hold frame — quiet-key p50
        // went 23.1 → 31.7ms, drawable_wait 60µs → 5.3ms. The skip IS
        // the latency strategy; do not put the hold back without a
        // pacing design that leaves a drawable free.
        const shot_wanted = self.shot_state.load(.acquire) == 2;
        if (!any_dirty and !shot_wanted) {
            _ = stats.global.frames_skipped.fetchAdd(1, .monotonic);
            return;
        }
        self.scene_dirty = false;
        stats.global.frame_update.recordSeconds(t_update - t_start);

        // Fill the frame's GPU cell buffer: each pane bump-allocates a
        // slot. The snapshot is the authority on grid dims; during a
        // resize it may briefly disagree with the rect, which is fine.
        // beginFrame first: this frame writes a ring slot the GPU is
        // done with, never the one it may still be reading.
        self.renderer.beginFrame();
        const cells = self.renderer.cells();
        var off: usize = 0;
        for (atab.panes.items) |p| {
            p.drawn_cols = 0;
            p.drawn_rows = 0;
            if (p.rect.w == 0) continue;
            const cols: usize = switch (p.content) {
                .term => |*tm| tm.rs.cols,
                .edit, .monitor => p.cols,
            };
            var rows: usize = switch (p.content) {
                .term => |*tm| tm.rs.rows,
                .edit, .monitor => p.rows,
            };
            if (cols == 0 or rows == 0) continue;
            if (off + cols * rows > self.renderer.cells_cap) {
                rows = (self.renderer.cells_cap - off) / cols;
                if (rows == 0) continue;
            }
            switch (p.content) {
                .term => |*tm| {
                    self.fillPane(tm, p == atab.focused, cells[off .. off + cols * rows], cols, rows);
                    p.drawn_cursor = cursorKey(tm);
                },
                .edit => |ed| self.fillEditorPane(ed, p == atab.focused, cells[off .. off + cols * rows], cols, rows),
                .monitor => |m| self.fillMonitorPane(m, p == atab.focused, cells[off .. off + cols * rows], cols, rows),
            }
            p.buf_off = off;
            p.drawn_cols = @intCast(cols);
            p.drawn_rows = @intCast(rows);
            off += cols * rows;
        }

        const t_fill = CACurrentMediaTime();
        stats.global.frame_fill.recordSeconds(t_fill - t_update);

        const drawable = self.layer.msgSend(objc.Object, "nextDrawable", .{});
        if (drawable.value == null) {
            // The emulator's dirty state was already consumed above —
            // losing this frame would freeze the change until the NEXT
            // one arrives. Re-arm and retry on a later tick.
            self.scene_dirty = true;
            return;
        }
        // Backpressure (waiting for a free drawable) is pacing, not
        // work — its own ring, so the fps capability math stays honest.
        const t_acquired = CACurrentMediaTime();
        stats.global.drawable_wait.recordSeconds(t_acquired - t_fill);

        const clear_bg = switch (atab.focused.content) {
            .term => |*tm| tm.rs.colors.background,
            .edit, .monitor => rgb4(th.ed_bg),
        };

        const desc = objc.getClass("MTLRenderPassDescriptor").?
            .msgSend(objc.Object, "renderPassDescriptor", .{});
        const attachment = desc.msgSend(objc.Object, "colorAttachments", .{})
            .msgSend(objc.Object, "objectAtIndexedSubscript:", .{@as(u64, 0)});
        attachment.msgSend(void, "setTexture:", .{drawable.msgSend(objc.Object, "texture", .{}).value});
        // MTLLoadActionClear = 2, MTLStoreActionStore = 1
        attachment.msgSend(void, "setLoadAction:", .{@as(u64, 2)});
        attachment.msgSend(void, "setStoreAction:", .{@as(u64, 1)});
        attachment.msgSend(void, "setClearColor:", .{MTLClearColor{
            .r = @as(f64, @floatFromInt(clear_bg.r)) / 255.0 * self.bg_opacity,
            .g = @as(f64, @floatFromInt(clear_bg.g)) / 255.0 * self.bg_opacity,
            .b = @as(f64, @floatFromInt(clear_bg.b)) / 255.0 * self.bg_opacity,
            .a = self.bg_opacity,
        }});

        const size = self.layer.msgSend(NSSize, "drawableSize", .{});
        const vp_w: f32 = @floatCast(size.width);
        const vp_h: f32 = @floatCast(size.height);
        const cmd = self.queue.msgSend(objc.Object, "commandBuffer", .{});
        const enc = cmd.msgSend(objc.Object, "renderCommandEncoderWithDescriptor:", .{desc.value});

        // Scene: pane backgrounds (full rect, covers the sub-cell
        // remainder), grids, separators, focus edges.
        for (atab.panes.items) |p| {
            const bg = switch (p.content) {
                .term => |*tm| tm.rs.colors.background,
                .edit, .monitor => rgb4(th.ed_bg),
            };
            self.renderer.drawRect(enc, vp_w, vp_h, p.rect.x, p.rect.y, p.rect.w, p.rect.h, .{ bg.r, bg.g, bg.b, self.bg_alpha });
        }
        // Floating cards, UNDER the grids that sit on them. The only
        // layer in the frame that draws between a pane's background and
        // its text, and the completion menu is its one tenant.
        for (atab.panes.items) |p| {
            if (p.drawn_cols == 0) continue;
            self.drawCompletionCard(enc, vp_w, vp_h, p);
        }
        for (atab.panes.items) |p| {
            if (p.drawn_cols == 0) continue;
            const o = self.gridOrigin(p);
            self.renderer.drawGrid(enc, vp_w, vp_h, o.x, o.y, p.buf_off, p.drawn_cols, p.drawn_rows);
        }
        // Zoomed: one pane fills the area, so there are no boundaries to
        // draw and no focus edge to telegraph (focus is unambiguous).
        if (atab.panes.items.len > 1 and atab.zoomed == null) {
            var sep_buf: [64]panespkg.Rect = undefined;
            var nsep: usize = 0;
            panespkg.collectSeparators(atab.root, &sep_buf, &nsep);
            for (sep_buf[0..nsep]) |r| {
                self.renderer.drawRect(enc, vp_w, vp_h, r.x, r.y, r.w, r.h, th.sep);
            }
            // The focused pane claims its share of adjacent separators
            // in the accent color — cheap, unambiguous focus telegraph.
            //
            // Against the PANE AREA, not the window: the outer bound is
            // the tiled region, which window-padding and an open side
            // pane both move. Comparing to the window drew accent on
            // edges with no neighbour behind them, so the telegraph read
            // as a box around the pane instead of a claim on the
            // separators it actually touches.
            const fr = atab.focused.rect;
            const area = self.paneArea();
            const s = self.sep;
            if (fr.x > area.x + 0.5) self.renderer.drawRect(enc, vp_w, vp_h, fr.x - s, fr.y, s, fr.h, th.accent);
            if (fr.x + fr.w < area.x + area.w - 0.5) self.renderer.drawRect(enc, vp_w, vp_h, fr.x + fr.w, fr.y, s, fr.h, th.accent);
            if (fr.y > area.y + 0.5) self.renderer.drawRect(enc, vp_w, vp_h, fr.x, fr.y - s, fr.w, s, th.accent);
            if (fr.y + fr.h < area.y + area.h - 0.5) self.renderer.drawRect(enc, vp_w, vp_h, fr.x, fr.y + fr.h, fr.w, s, th.accent);
        }
        var ui = @import("ui.zig").Ui{
            .r = &self.renderer,
            .enc = enc,
            .vp_w = vp_w,
            .vp_h = vp_h,
            .cells = self.renderer.cells(),
            .off = off,
        };
        self.drawBar(&ui);
        self.drawTabBar(&ui);
        self.drawActivityBar(&ui);
        // Before the palette: the modal draws LAST and over everything,
        // side pane included.
        if (self.side_open) self.drawSidePane(&ui);
        if (self.ime_marked_len > 0) self.drawPreedit(&ui);
        // Unconditional: it is also the clearer of its own hit rects
        // when the sheet isn't showing.
        self.drawWhichKey(&ui);
        if (self.pal_open) self.drawPalette(&ui);
        // Over EVERYTHING, palette included: it is a screen, not a layer.
        if (self.welcome_open) self.drawWelcome(&ui);

        enc.msgSend(void, "endEncoding", .{});

        // GPU time when the buffer completes; photon time when the
        // drawable actually presents. Both handlers are copied by Metal.
        var completed_ctx = CompletedBlock.init(.{ .app = self }, &completedCallback);
        cmd.msgSend(void, "addCompletedHandler:", .{&completed_ctx});
        var presented_ctx = PresentedBlock.init(.{ .app = self, .dirty = @intFromBool(focused_dirty), .commit_t = CACurrentMediaTime() }, &presentedCallback);
        drawable.msgSend(void, "addPresentedHandler:", .{&presented_ctx});

        cmd.msgSend(void, "presentDrawable:", .{drawable.value});
        cmd.msgSend(void, "commit", .{});

        const t_commit = CACurrentMediaTime();
        stats.global.frame_encode.recordSeconds(t_commit - t_acquired);
        _ = stats.global.frames_drawn.fetchAdd(1, .monotonic);
        if (focused_dirty) {
            const mark = self.input_mark.load(.acquire);
            if (mark > 0 and t_commit > mark) stats.global.key_commit.recordSeconds(t_commit - mark);
        }

        // Service a pending ctl `shot`: wait for this frame's GPU work,
        // read our own drawable back, write PNG. Render-thread only.
        if (self.shot_state.load(.acquire) == 2) {
            cmd.msgSend(void, "waitUntilCompleted", .{});
            self.captureShot(drawable);
            self.shot_state.store(0, .release);
        }
    }

    /// The display's refresh period in µs (the fps ceiling). Queried
    /// lazily — the link reports 0 before its first tick.
    fn displayPeriodUs(self: *App) f64 {
        const p = self.display_period_us.load(.monotonic);
        return if (p > 0) @floatFromInt(p) else 8333;
    }

    /// Recompute the status-bar text; flip scene_dirty only when it
    /// changed. Caller holds draw_lock.
    /// Reload keybinds + theme when a config file changes (1Hz poll
    /// off the HUD tick). Caller holds draw_lock.
    /// Notice a file that changed under an OPEN buffer.
    ///
    /// The whole premise of rook is that agents rewrite your files while
    /// you look at them, and until this existed you found out at `:w` —
    /// after typing into a stale copy. So the two cases split by who has
    /// something to lose:
    ///
    /// UNMODIFIED buffers RELOAD. You have no edits, the file is the
    /// truth, and a pane you left open on a file an agent is working
    /// through should show what the agent wrote. This is the case that
    /// makes an editor pane useful as a WATCHER.
    ///
    /// MODIFIED buffers only say so — `[!]` beside your `[+]`. Merging
    /// is yours; the only thing worse than not reloading is reloading
    /// over an edit.
    ///
    /// Every pane in every space, not just the visible one: a background
    /// tab holding a stale buffer is exactly the one you would not think
    /// to distrust when you come back to it. One stat per editor pane at
    /// 1Hz, and it dirties the scene only when something actually
    /// changed, so the zero-idle-frames property holds.
    /// Caller holds draw_lock.
    fn pollBuffersLocked(self: *App) void {
        for (self.spaces.items) |space| {
            for (space.tabs.items) |t| {
                for (t.panes.items) |p| {
                    const ed = switch (p.content) {
                        .edit => |e| e,
                        .term, .monitor => continue,
                    };
                    if (ed.synthetic or ed.is_dir) continue;
                    switch (ed.buf.onDisk(self.io)) {
                        .same => {
                            if (ed.disk_changed or ed.disk_gone) {
                                ed.disk_changed = false;
                                ed.disk_gone = false;
                                ed.render_dirty = true;
                                self.scene_dirty = true;
                            }
                        },
                        .gone => {
                            // Never reloaded: what the pane holds is now
                            // the only copy, and replacing it with the
                            // emptiness on disk would finish the
                            // deletion. The badge says so; `:w` still
                            // guards, and `:w!` recreates on purpose.
                            if (!ed.disk_gone) {
                                ed.disk_gone = true;
                                ed.disk_changed = false;
                                ed.setStatus("{s} was deleted on disk — the buffer is the only copy (:w! recreates it)", .{ed.displayName()}, true);
                                ed.render_dirty = true;
                                self.scene_dirty = true;
                            }
                        },
                        .changed => {
                            ed.disk_gone = false;
                            if (ed.buf.isModified()) {
                                if (!ed.disk_changed) {
                                    ed.disk_changed = true;
                                    ed.render_dirty = true;
                                    self.scene_dirty = true;
                                }
                            } else {
                                // A reload that fails leaves the buffer
                                // exactly as it was, which is the right
                                // outcome for a transient read error —
                                // we try again next tick.
                                ed.reload() catch continue;
                                self.scene_dirty = true;
                            }
                        },
                    }
                }
            }
        }
    }

    fn pollConfigLocked(self: *App) void {
        // The SOURCE, first and separately: editing main.go must not apply
        // anything, it must offer. The graph's own digest below still
        // applies live, because writing environment.json IS the apply.
        var dirbuf: [1024]u8 = undefined;
        if (cfgpkg.configDir(&dirbuf)) |dir| {
            const sd = envpkg.sourceDigest(self.io, self.gpa, dir);
            if (sd != 0 and sd != self.env_src_digest) {
                // FIRST sight is decided by mtime, not by the digest: at
                // launch there is no previous digest to compare against, and
                // calling that "no change" would mean an edit made while
                // rook was closed is never mentioned at all. After launch the
                // digest is the authority — a touched file with the same
                // bytes is not a change.
                var gbuf: [1088]u8 = undefined;
                self.env_check_wanted = self.env_src_digest != 0 or
                    (if (cfgpkg.envPath(&gbuf)) |gp| envpkg.sourceNewerThanGraph(self.io, dir, gp) else false);
                self.env_src_digest = sd;
            }
        }

        const d = cfgpkg.digest(self.io, self.gpa);
        defer self.config_digest = d;
        if (self.config_digest == 0 or d == self.config_digest) return;

        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const cfg = cfgpkg.load(self.io, arena.allocator());
        self.keybinds = cfgpkg.loadKeybinds(self.io, arena.allocator());
        self.leader_pending.store(false, .release);
        self.cfg_bell = cfg.bell;
        self.cfg_clip_allow = cfg.clipboard_write == .allow;
        self.cfg_bufline = cfg.buffer_line;
        self.cfg_nav_yield = cfg.nav_yield;
        self.cursor_blink = cfg.cursor_blink;
        if (self.pane_dim != @as(f32, @floatCast(cfg.pane_dim))) {
            self.pane_dim = @floatCast(cfg.pane_dim);
            self.scene_dirty = true;
        }

        // Chrome arrangement: a preset (or hand-set lists) landing on
        // a LIVE app. Hiding or showing the top strip is a retile —
        // pty resizes and all — same path a window resize takes.
        const chrome_changed = !self.cfg_top_bar.eql(&cfg.top_bar) or
            !self.cfg_status_left.eql(&cfg.status_left) or
            !self.cfg_status_right.eql(&cfg.status_right) or
            self.cfg_tab_style != cfg.tab_style or
            self.cfg_activity_bar != cfg.activity_bar;
        self.cfg_top_bar = cfg.top_bar;
        self.cfg_status_left = cfg.status_left;
        self.cfg_status_right = cfg.status_right;
        self.cfg_tab_style = cfg.tab_style;
        self.cfg_activity_bar = cfg.activity_bar;
        self.cfg_ed_insert = cfg.editor_insert;
        self.cfg_fmt_on_save = cfg.format_on_save;
        self.cfg_suggest = cfg.suggest;
        if (chrome_changed) {
            self.tab_h = if (self.cfg_top_bar.n == 0) 0 else self.bar_h;
            self.relayoutLocked();
        }

        if (themepkg.byName(cfg.theme)) |t| {
            th = t.*;
        } else std.debug.print("rook config: unknown theme '{s}'\n", .{cfg.theme});

        // Retint every live emulator; the palette dirty flag forces a
        // full RenderState rebuild next snapshot. Editors also take
        // the reloaded editor leader — a rebind must not need every
        // pane reopened.
        const tc = termColors();
        for (self.spaces.items) |space| for (space.tabs.items) |tab| {
            for (tab.panes.items) |p| {
                if (p.term()) |tm| {
                    tm.session.mutex.lock();
                    tm.session.term.colors = tc;
                    tm.session.term.flags.dirty.palette = true;
                    tm.session.clip_allow = self.cfg_clip_allow;
                    tm.session.mutex.unlock();
                } else if (p.editor()) |ed| ed.render_dirty = true;
                if (p.editor()) |ed| {
                    ed.leader = self.keybinds.ed_leader;
                    ed.leader_binds = self.keybinds.edBinds();
                    ed.bufline_mode = switch (self.cfg_bufline) {
                        .off => .off,
                        .multiple => .multiple,
                        .always => .always,
                    };
                    // The default applies to the NEXT open; a live
                    // editor's current mode is the user's, not ours.
                    ed.default_insert = self.cfg_ed_insert;
                    ed.suggest_on = self.cfg_suggest;
                    // This one DOES apply live: it is about what the
                    // next `:w` does, and waiting for a reopen to
                    // honour a setting you just changed is the kind of
                    // thing that makes people distrust a reload.
                    ed.fmt_on_save = self.cfg_fmt_on_save;
                }
            }
        };
        self.scene_dirty = true;
        std.debug.print("rook: config reloaded (theme {s}; font/opacity/scrollback need relaunch)\n", .{th.name});
    }

    /// Drain BEL flags raised by reader threads and turn them into the
    /// things a bell actually means. Main thread, under draw_lock, off
    /// the 2Hz HUD tick — half a second late is imperceptible for an
    /// attention signal, and it keeps AppKit off the parse path.
    ///
    /// A bell in the tab you are already looking at, in an app that is
    /// frontmost, has nothing to tell you: you are watching it happen.
    /// So the chip dot is only set for tabs you are NOT on, and the dock
    /// is only disturbed when rook isn't the active app — which is
    /// exactly the case the signal exists for, an agent finishing in a
    /// space you left.
    fn drainBellsLocked(self: *App) void {
        if (self.cfg_bell == .none) return;
        const frontmost = self.app.msgSend(bool, "isActive", .{});
        var rang = false;
        for (self.spaces.items, 0..) |space, si| {
            for (space.tabs.items, 0..) |tab, ti| {
                var tab_rang = false;
                for (tab.panes.items) |p| {
                    if (p.term()) |tm| {
                        if (tm.session.bell.swap(false, .acquire)) tab_rang = true;
                    }
                }
                if (!tab_rang) continue;
                rang = true;
                const watching = frontmost and si == self.active_space and ti == space.active_tab;
                if (!watching and !tab.bell) {
                    tab.bell = true;
                    self.scene_dirty = true;
                }
            }
        }
        if (!rang) return;
        if (self.cfg_bell == .audible or self.cfg_bell == .all) NSBeep();
        // NSInformationalRequest bounces once and stops; the critical
        // variant bounces until you focus the app, which is the wrong
        // manners for a shell that finished a build.
        if (!frontmost) _ = self.app.msgSend(c_long, "requestUserAttention:", .{@as(c_long, 10)});
    }

    /// Post an OSC 9 / OSC 777 notification through UNUserNotificationCenter.
    ///
    /// GUARDED ON THE BUNDLE. currentNotificationCenter raises an
    /// NSException when the process has no bundle identifier, which is
    /// exactly how a `zig build run` binary runs — so an unbundled dev
    /// instance would die on the first notification instead of skipping
    /// it. The installed app has an identifier and takes this path.
    fn postNotification(self: *App, title: []const u8, body: []const u8) void {
        const bundle = objc.getClass("NSBundle").?.msgSend(objc.Object, "mainBundle", .{});
        if (bundle.value == null) return;
        if (bundle.msgSend(objc.Object, "bundleIdentifier", .{}).value == null) {
            if (!self.notify_warned) {
                self.notify_warned = true;
                std.debug.print("rook: notifications need the app bundle (run /Applications/rook.app)\n", .{});
            }
            return;
        }
        const Center = objc.getClass("UNUserNotificationCenter") orelse return;
        const center = Center.msgSend(objc.Object, "currentNotificationCenter", .{});
        if (center.value == null) return;

        // Ask once, lazily. At startup this would pop a permission
        // dialog on every probe launch; here it costs one prompt the
        // first time something actually wants to notify.
        if (!self.notify_asked) {
            self.notify_asked = true;
            var auth = AuthBlock.init(.{}, &authCallback);
            // alert | sound = 1 | 2
            center.msgSend(void, "requestAuthorizationWithOptions:completionHandler:", .{ @as(u64, 3), &auth });
        }

        const Content = objc.getClass("UNMutableNotificationContent") orelse return;
        const content = Content.msgSend(objc.Object, "alloc", .{}).msgSend(objc.Object, "init", .{});
        defer content.msgSend(void, "release", .{});
        // OSC 9 has no title of its own; the app's name is the honest one.
        content.msgSend(void, "setTitle:", .{if (title.len > 0) nsStringLen(title).value else nsString("rook").value});
        content.msgSend(void, "setBody:", .{nsStringLen(body).value});

        const Request = objc.getClass("UNNotificationRequest") orelse return;
        var idbuf: [64]u8 = undefined;
        self.notify_seq +%= 1;
        const ident = std.fmt.bufPrint(&idbuf, "rook.osc.{d}", .{self.notify_seq}) catch return;
        const req = Request.msgSend(objc.Object, "requestWithIdentifier:content:trigger:", .{
            nsStringLen(ident).value,
            content.value,
            @as(objc.c.id, null),
        });
        center.msgSend(void, "addNotificationRequest:withCompletionHandler:", .{ req.value, @as(objc.c.id, null) });
    }

    /// Drain notification requests raised by reader threads. Separate
    /// from the bell drain only because it needs each session's mutex:
    /// the title/body live in the Session and the reader can overwrite
    /// them mid-parse.
    fn drainNotificationsLocked(self: *App) void {
        for (self.spaces.items) |space| {
            for (space.tabs.items) |tab| {
                for (tab.panes.items) |p| {
                    const tm = p.term() orelse continue;
                    var title_buf: [96]u8 = undefined;
                    var body_buf: [256]u8 = undefined;
                    var tl: usize = 0;
                    var bl: usize = 0;
                    tm.session.mutex.lock();
                    if (tm.session.notify_pending) {
                        tm.session.notify_pending = false;
                        tl = tm.session.notify_title_len;
                        bl = tm.session.notify_body_len;
                        @memcpy(title_buf[0..tl], tm.session.notify_title[0..tl]);
                        @memcpy(body_buf[0..bl], tm.session.notify_body[0..bl]);
                    }
                    tm.session.mutex.unlock();
                    if (tl == 0 and bl == 0) continue;
                    self.notify_last_len = @min(tl + bl + 3, self.notify_last.len);
                    _ = std.fmt.bufPrint(&self.notify_last, "{s} | {s}", .{ title_buf[0..tl], body_buf[0..bl] }) catch {};
                    self.postNotification(title_buf[0..tl], body_buf[0..bl]);
                }
            }
        }
    }

    /// Drain OSC 52 writes onto the system pasteboard.
    ///
    /// The copy out of the session is made under that session's mutex
    /// and the pasteboard call is made after releasing it: NSPasteboard
    /// crosses into another process, and holding a terminal's parse lock
    /// across an XPC round-trip would stall the reader on the firehose.
    ///
    /// This runs per FRAME, not on the 2Hz HUD tick the bell and
    /// notifications ride: those are attention signals where half a
    /// second is imperceptible, but a yank can be followed immediately
    /// by ⌘V, and pasting the previous clipboard would be a real bug.
    /// The atomic flag makes the common (nothing pending) pass a load
    /// per pane, so per-frame costs nothing.
    fn drainClipboardLocked(self: *App) void {
        for (self.spaces.items) |space| {
            for (space.tabs.items) |tab| {
                for (tab.panes.items) |p| {
                    const tm = p.term() orelse continue;
                    if (!tm.session.clip_pending.load(.acquire)) continue;
                    var text: ?[]u8 = null;
                    tm.session.mutex.lock();
                    tm.session.clip_pending.store(false, .release);
                    text = self.gpa.dupe(u8, tm.session.clip_buf[0..tm.session.clip_len]) catch null;
                    tm.session.mutex.unlock();
                    const t = text orelse continue;
                    defer self.gpa.free(t);
                    self.setPasteboard(t);
                    self.clip_last_len = @min(t.len, self.clip_last.len);
                    @memcpy(self.clip_last[0..self.clip_last_len], t[0..self.clip_last_len]);
                }
            }
        }
    }

    /// Read the general pasteboard's text into `buf` (truncating).
    /// Lives here rather than in ctl.zig because objc and the NSString
    /// helpers do — and it carries its own autorelease pool, since ctl
    /// calls it from its own thread where AppKit gives you none.
    pub fn pasteboardText(_: *App, buf: []u8) []const u8 {
        const pool = objc.AutoreleasePool.init();
        defer pool.deinit();
        const pb = objc.getClass("NSPasteboard").?.msgSend(objc.Object, "generalPasteboard", .{});
        const nss = pb.msgSend(objc.Object, "stringForType:", .{nsString("public.utf8-plain-text").value});
        if (nss.value == null) return "";
        const cstr = nss.msgSend(?[*:0]const u8, "UTF8String", .{}) orelse return "";
        const text = std.mem.span(cstr);
        const n = @min(text.len, buf.len);
        @memcpy(buf[0..n], text[0..n]);
        return buf[0..n];
    }

    /// Replace the general pasteboard's text. An empty write clears it,
    /// which is what OSC 52 with an empty payload asks for.
    fn setPasteboard(_: *App, text: []const u8) void {
        const pb = objc.getClass("NSPasteboard").?.msgSend(objc.Object, "generalPasteboard", .{});
        _ = pb.msgSend(i64, "clearContents", .{});
        if (text.len == 0) return;
        _ = pb.msgSend(bool, "setString:forType:", .{
            nsStringLen(text).value,
            nsString("public.utf8-plain-text").value,
        });
    }

    fn refreshHudLocked(self: *App, now: f64) void {
        self.hud_calls +%= 1;
        // Cached at 2Hz for the blink gate: frontmost-ness changes at
        // human speed, and asking AppKit on every 120Hz tick would be
        // an objc round-trip spent answering the same thing.
        self.app_active = self.app.msgSend(bool, "isActive", .{});
        self.drainBellsLocked();
        self.drainNotificationsLocked();
        if (self.hud_calls % 2 == 0) self.pollConfigLocked();
        // Onboarding opens ITSELF only over a window you are looking at.
        // The palette takes the keys while it is up, so a prompt that
        // appeared on a background window would silently eat the first
        // thing typed into a terminal — which is exactly what a new user
        // does next. Backgrounded, it waits; `⌘K → Set Up Config` is
        // always there.
        if (self.setup_needed and self.app_active) {
            self.setup_needed = false;
            self.welcome_open = true;
            self.welcome_sel = 0;
            self.scene_dirty = true;
        }
        if (self.hud_calls % 2 == 1) self.pollBuffersLocked();
        const bytes = stats.global.bytes_in.load(.monotonic);
        if (self.hud_last_t > 0 and now > self.hud_last_t) {
            self.hud_mbs = @as(f64, @floatFromInt(bytes -| self.hud_last_bytes)) / (now - self.hud_last_t) / 1e6;
        }
        self.hud_last_t = now;
        self.hud_last_bytes = bytes;

        const key = stats.global.key_present.summarize();

        // Optimistic fps: the display's rate, dipping only when typical
        // FRAME COST can't fit the vsync budget — the only case a user
        // would feel as lag. (Seth's call: demand pacing must never
        // read as a performance problem.) Cost = the slower of the CPU
        // side (update+fill+encode, lock waits included) and the GPU;
        // p50s, so a one-off stall doesn't linger as a fake cap.
        const vsync = self.displayPeriodUs();
        var fps: u64 = @intFromFloat(@round(1e6 / vsync));
        const upd = stats.global.frame_update.summarize();
        const fill = stats.global.frame_fill.summarize();
        const enc_s = stats.global.frame_encode.summarize();
        const gpu = stats.global.frame_gpu.summarize();
        if (upd.n > 0 and gpu.n > 0) {
            const cpu_cost: f64 = @floatFromInt(upd.p50 + fill.p50 + enc_s.p50);
            const cost = @max(cpu_cost, @as(f64, @floatFromInt(gpu.p50)));
            if (cost > vsync) fps = @intFromFloat(@round(1e6 / cost));
        }

        // The left zone is WHERE YOU ARE: the focused pane's cwd, named
        // the way a human would (workspace name + remainder), and the
        // branch of the repo owning it. Both anchored to the PANE's live
        // cwd rather than the space's root — cd is sacred, and an agent
        // switching branches in a worktree should be visible from the
        // pane sitting in it. The old "rook · N panes · #id" told you
        // what the splits already show.
        var left: [96]u8 = undefined;
        const t = self.activeTab();
        const cwd: []const u8 = if (self.paneCwd(t.focused)) |c| std.mem.span(c) else "";
        const l = self.cwdLabel(cwd, &left);
        var brbuf: [64]u8 = undefined;
        const br: []const u8 = if (cwd.len > 0)
            @import("git.zig").headBranch(self.io, self.gpa, cwd, &brbuf) orelse ""
        else
            "";
        var right: [96]u8 = undefined;
        const r = std.fmt.bufPrint(&right, "{d}.{d}ms key · {d}fps · {d}MB/s · {d}MB", .{
            key.p50 / 1000,
            (key.p50 % 1000) / 100,
            fps,
            @as(u64, @intFromFloat(@round(self.hud_mbs))),
            stats.maxRssMb(),
        }) catch return;

        var tabs_buf: [256]u8 = undefined;
        var tw: std.Io.Writer = .fixed(&tabs_buf);
        for (self.activeSpace().tabs.items) |tb| {
            switch (tb.focused.content) {
                .term => |*tm| {
                    tm.session.mutex.lock();
                    if (tm.session.term.getTitle()) |tt| {
                        tw.print("{s};", .{tt[0..@min(tt.len, 24)]}) catch {};
                    } else tw.print(";", .{}) catch {};
                    tm.session.mutex.unlock();
                },
                .edit => |ed| tw.print("{s};", .{ed.displayName()}) catch {},
                .monitor => tw.print("monitor;", .{}) catch {},
            }
        }
        const td = tabs_buf[0..tw.end];

        if (std.mem.eql(u8, l, self.hud_left[0..self.hud_left_len]) and
            std.mem.eql(u8, r, self.hud_right[0..self.hud_right_len]) and
            std.mem.eql(u8, td, self.hud_tabs[0..self.hud_tabs_len]) and
            std.mem.eql(u8, br, self.bar_branch[0..self.bar_branch_len])) return;
        @memcpy(self.hud_left[0..l.len], l);
        self.hud_left_len = l.len;
        @memcpy(self.hud_right[0..r.len], r);
        self.hud_right_len = r.len;
        @memcpy(self.hud_tabs[0..td.len], td);
        self.hud_tabs_len = td.len;
        @memcpy(self.bar_branch[0..br.len], br);
        self.bar_branch_len = br.len;
        self.scene_dirty = true;
    }

    /// Chrome background at the window's alpha — the bars are glass
    /// exactly like default-bg cells (accent highlights stay solid).
    fn glassBg(self: *App, c: [4]u8) [4]u8 {
        return .{ c[0], c[1], c[2], self.bg_alpha };
    }

    // The STATUS bar's colors. A theme may give the bottom bar its own
    // identity (VS Code's blue) via th.status_*; everything drawn ON
    // the bar asks these, never th.bar_*/th.accent directly — an
    // accent-colored glyph on an accent-colored bar is invisible.
    fn statusBg(self: *App) [4]u8 {
        return self.glassBg(th.status_bg orelse th.bar_bg);
    }
    fn statusFg() [4]u8 {
        return th.status_fg orelse th.bar_fg;
    }
    fn statusValue() [4]u8 {
        return th.status_value orelse th.bar_value;
    }
    fn statusAccent() [4]u8 {
        return th.status_accent orelse th.accent;
    }

    /// The status bar: tenant one of the ui layer.
    fn drawBar(self: *App, ui: *@import("ui.zig").Ui) void {
        const by = self.px_h - self.bar_h;
        const chip_fg = th.status_bg orelse th.bar_bg;
        ui.rect(0, by, self.px_w, self.bar_h, self.statusBg());
        // The rule is what makes it a BAR. bar_bg sits one step below
        // the terminal background — a two-value difference that reads as
        // nothing at all, so without this the status line looked like
        // text that had scrolled to the bottom of the shell.
        ui.rect(0, by, self.px_w, self.sep, th.sep);
        const ty = by + (self.bar_h - self.renderer.cell_h) / 2;
        const pad = self.m.gutter;
        var x: f32 = pad;
        // Armed leader: an accent cell showing the leader key, tmux's
        // prefix indicator. Through keyGlyph, or a SPACE leader arms an
        // indicator that shows nothing at all.
        if (self.leader_pending.load(.acquire)) {
            if (self.keybinds.leader) |ld| {
                var gb: [4]u8 = undefined;
                var lbuf: [8]u8 = undefined;
                const s = std.fmt.bufPrint(&lbuf, " {s} ", .{keyGlyph(ld, &gb)}) catch " ";
                x += ui.text(x, ty, s, chip_fg, statusAccent()) + self.renderer.cell_w / 2;
            }
        }
        if (self.activeTab().focused.term()) |tm| {
            if (tm.copy_mode) {
                x += ui.text(x, ty, " SCROLL ", chip_fg, statusAccent()) + self.renderer.cell_w / 2;
            }
            // The needle, while typing it and after. `n` is unusable if
            // you can't see what you're stepping through; `0/0` is how
            // a search that found nothing says so.
            if (tm.search_input or tm.search_n > 0) {
                var sb: [96]u8 = undefined;
                const label = if (tm.search_input)
                    std.fmt.bufPrint(&sb, " /{s}_ ", .{tm.search_buf[0..tm.search_len]}) catch ""
                else
                    std.fmt.bufPrint(&sb, " /{s} {d}/{d} ", .{ tm.search_buf[0..tm.search_len], tm.search_i, tm.search_n }) catch "";
                x += ui.text(x, ty, label, chip_fg, statusValue()) + self.renderer.cell_w / 2;
            } else if (tm.search_len > 0 and tm.copy_mode) {
                x += ui.text(x, ty, " /no match ", chip_fg, statusAccent()) + self.renderer.cell_w / 2;
            }
        }
        // The SEGMENT ENGINE. What renders here is config's two lists
        // (status-left / status-right — tmux's own keys), drawn in
        // declared order. MEASURE before drawing, then shed OFF THE
        // ENDS when narrow — the last segment of status-right yields
        // first, then backward through it, then the end of
        // status-left. A rule the user can predict from their lists,
        // because the window's size is the window manager's — what
        // shows at each width must not be, or every layout assertion
        // is a coin flip against AppKit's clamping.
        // cwd is FLEXIBLE: it reserves nothing, fills the gap between
        // the clusters, and can never push a fixed segment off.
        const cw = self.renderer.cell_w;
        const bg = self.statusBg();
        const name = self.activeSpace().label();
        const br = self.bar_branch[0..self.bar_branch_len];

        self.hint_menu_x = .{ 0, 0 };
        self.hint_cmd_x = .{ 0, 0 };
        self.seg_ws_x = .{ 0, 0 };
        self.seg_branch_x = .{ 0, 0 };
        self.bar_tab_n = 0;

        const left = self.cfg_status_left.slice();
        const right = self.cfg_status_right.slice();
        var left_w: [8]f32 = @splat(0);
        var right_w: [8]f32 = @splat(0);
        for (left, 0..) |s, i| left_w[i] = self.segWidth(s, name, br);
        for (right, 0..) |s, i| right_w[i] = self.segWidth(s, name, br);

        const budget = self.px_w - pad - x;
        var total: f32 = 0;
        for (left_w[0..left.len]) |w| total += w;
        for (right_w[0..right.len]) |w| total += w;
        while (total > budget) {
            var ir = right.len;
            var shed = false;
            while (ir > 0) : (ir -= 1) {
                if (right_w[ir - 1] > 0) {
                    total -= right_w[ir - 1];
                    right_w[ir - 1] = 0;
                    shed = true;
                    break;
                }
            }
            if (shed) continue;
            var il = left.len;
            while (il > 0) : (il -= 1) {
                if (left_w[il - 1] > 0) {
                    total -= left_w[il - 1];
                    left_w[il - 1] = 0;
                    shed = true;
                    break;
                }
            }
            if (!shed) break;
        }

        for (left, 0..) |s, i| {
            if (left_w[i] > 0) self.drawSegment(ui, s, &x, ty, name, br);
        }
        const left_end = x;
        var rtotal: f32 = 0;
        for (right_w[0..right.len]) |w| rtotal += w;
        var rx = self.px_w - pad - rtotal;
        const right_start = rx;
        for (right, 0..) |s, i| {
            if (right_w[i] > 0) self.drawSegment(ui, s, &rx, ty, name, br);
        }

        // The flexible cwd, into whatever gap the clusters left — if
        // that gap is enough to say something ("…s/s…" is not).
        const gap_end = if (rtotal > 0) right_start - 2 * cw else right_start;
        const room: usize = @intFromFloat(@max(0, (gap_end - left_end) / cw));
        if (self.hud_left_len > 0 and room >= 10) {
            var clipbuf: [96]u8 = undefined;
            const s = @import("ui.zig").clip(&clipbuf, self.hud_left[0..self.hud_left_len], room);
            if (self.cfg_status_left.has(.cwd)) {
                _ = ui.text(left_end, ty, s, statusFg(), bg);
            } else if (self.cfg_status_right.has(.cwd)) {
                _ = ui.textRight(gap_end, ty, s, statusFg(), bg);
            }
        }
    }

    /// A status-bar segment's reserved width in px, trailing gap
    /// included. 0 = nothing to render this frame (an empty branch, a
    /// leaderless hints pair) — and 0 is also what the shed loop
    /// writes, so "hidden" and "empty" are one case to the draw pass.
    fn segWidth(self: *App, s: cfgpkg.Segment, name: []const u8, br: []const u8) f32 {
        const cw = self.renderer.cell_w;
        return switch (s) {
            .workspace => @as(f32, @floatFromInt(2 + name.len)) * cw + 2 * cw,
            .branch => if (br.len > 0) @as(f32, @floatFromInt(2 + br.len)) * cw + 2 * cw else 0,
            // Flexible: reserves nothing (drawn into the leftover gap).
            .cwd => 0,
            .hints => blk: {
                const menu: f32 = if (self.keybinds.leader != null) 6 * cw + 3 * cw else 0;
                break :blk menu + 11 * cw + 2 * cw;
            },
            .hud => if (self.hud_right_len > 0) @as(f32, @floatFromInt(self.hud_right_len)) * cw + 2 * cw else 0,
            .tabs => self.barTabsSeg(null, 0, 0),
            // Top-strip only; in the status bar it renders nothing.
            .title => 0,
        };
    }

    /// Draw one segment at x (which advances past it, trailing gap
    /// included), recording its click zones. The same vocabulary the
    /// top strip uses — a segment is a segment wherever it lands.
    fn drawSegment(self: *App, ui: *@import("ui.zig").Ui, s: cfgpkg.Segment, x: *f32, ty: f32, name: []const u8, br: []const u8) void {
        const cw = self.renderer.cell_w;
        const bg = self.statusBg();
        switch (s) {
            .workspace => {
                const x0 = x.*;
                x.* += ui.text(x.*, ty, "● ", statusAccent(), bg);
                x.* += ui.text(x.*, ty, name, statusValue(), bg);
                self.seg_ws_x = .{ x0, x.* };
                x.* += 2 * cw;
            },
            .branch => {
                const x0 = x.*;
                x.* += ui.text(x.*, ty, "⎇ ", statusFg(), bg);
                x.* += ui.text(x.*, ty, br, statusValue(), bg);
                self.seg_branch_x = .{ x0, x.* };
                x.* += 2 * cw;
            },
            .cwd, .title => {},
            .hints => {
                // "␣ menu" arms the leader with its sheet shown NOW,
                // "⌘K commands" opens the palette — the mouse routes
                // into the things the bar names, key glyph in accent
                // (the mock's vocabulary: the key is the loud part).
                if (self.keybinds.leader) |ld| {
                    var gb: [4]u8 = undefined;
                    const g = keyGlyph(ld, &gb);
                    const x0 = x.*;
                    var tx = x.* + ui.text(x.*, ty, g, statusAccent(), bg);
                    _ = ui.text(tx + cw, ty, "menu", statusFg(), bg);
                    tx += cw + 4 * cw;
                    self.hint_menu_x = .{ x0, tx };
                    x.* = tx + 3 * cw;
                }
                const x0 = x.*;
                var tx = x.* + ui.text(x.*, ty, "⌘K", statusAccent(), bg);
                _ = ui.text(tx + cw, ty, "commands", statusFg(), bg);
                tx += cw + 8 * cw;
                self.hint_cmd_x = .{ x0, tx };
                x.* = tx + 2 * cw;
            },
            .hud => {
                if (self.hud_right_len > 0) {
                    x.* += ui.text(x.*, ty, self.hud_right[0..self.hud_right_len], statusValue(), bg);
                    x.* += 2 * cw;
                }
            },
            .tabs => x.* += self.barTabsSeg(ui, x.*, ty),
        }
    }

    /// The `tabs` segment for the STATUS bar, in both roles: measure
    /// (ui = null, returns width) and draw (returns width, records
    /// per-tab hit zones). One function because a measured width that
    /// disagrees with the drawn one is a shed rule that lies.
    /// index-name is tmux's window list; current is one compact chip
    /// of the active tab (click cycles).
    fn barTabsSeg(self: *App, ui: ?*@import("ui.zig").Ui, x_start: f32, ty: f32) f32 {
        const cw = self.renderer.cell_w;
        const bg = self.statusBg();
        const space = self.activeSpace();
        const by = self.px_h - self.bar_h;
        var x = x_start;

        if (self.cfg_tab_style == .current) {
            const t = space.tabs.items[space.active_tab];
            var tbuf: [24]u8 = undefined;
            const title = tabTitle(t, &tbuf);
            var chip: [40]u8 = undefined;
            const label = std.fmt.bufPrint(&chip, "{d}/{d} {s}", .{ space.active_tab + 1, space.tabs.items.len, title }) catch return 0;
            const w = @as(f32, @floatFromInt(std.unicode.utf8CountCodepoints(label) catch label.len)) * cw;
            if (ui) |u| {
                _ = u.text(x, ty, label, statusValue(), bg);
                if (self.bar_tab_x.len > 0) {
                    self.bar_tab_x[0] = .{ x, x + w };
                    self.bar_tab_n = 1;
                }
            }
            return w + 2 * cw;
        }

        // index-name: every tab, active on a lifted pill, bells in
        // accent — the chip vocabulary at one-row scale. On a
        // status-tinted bar (VS Code's blue) the pill is a white wash:
        // chip_active_bg belongs to the dark chrome, not to the tint.
        const pill: [4]u8 = if (th.status_bg != null)
            .{ 255, 255, 255, 48 }
        else
            self.glassBg(th.chip_active_bg);
        for (space.tabs.items, 0..) |t, i| {
            var tbuf: [24]u8 = undefined;
            const title = tabTitle(t, &tbuf);
            var chip: [44]u8 = undefined;
            const z: []const u8 = if (t.zoomed != null) "Z" else "";
            const label = if (t.bell)
                std.fmt.bufPrint(&chip, " •{d}:{s}{s} ", .{ i + 1, title, z }) catch continue
            else
                std.fmt.bufPrint(&chip, " {d}:{s}{s} ", .{ i + 1, title, z }) catch continue;
            const w = @as(f32, @floatFromInt(std.unicode.utf8CountCodepoints(label) catch label.len)) * cw;
            if (ui) |u| {
                const is_active = i == space.active_tab;
                const fg = if (is_active) statusValue() else if (t.bell) statusAccent() else statusFg();
                if (is_active)
                    u.roundRect(x, by + self.m.gap / 2, w, self.bar_h - self.m.gap, pill, .{ .radius = self.m.radius });
                _ = u.textOver(x, ty, label, fg);
                if (i < self.bar_tab_x.len) {
                    self.bar_tab_x[i] = .{ x, x + w };
                    self.bar_tab_n = i + 1;
                }
            }
            x += w + cw / 2;
        }
        return (x - x_start) + cw + cw / 2;
    }

    /// The which-key row model: the LIVE bindings — config's table,
    /// never registry's hand-written display strings, which a rebind
    /// does not update — each resolved back to its command title.
    /// tab.select's nine digit chords collapse to one teaching row.
    /// Shared by the sheet and ctl `whichkey`, so what the menu shows
    /// and what a blind test reads are one list. Caller holds draw_lock.
    pub fn wkItemsLocked(self: *App, out: []WkItem) usize {
        var n: usize = 0;
        var tabs_done = false;
        for (self.keybinds.entries[0..self.keybinds.n]) |e| {
            if (n >= out.len) break;
            if (e.action == .tab_select) {
                if (tabs_done) continue;
                tabs_done = true;
                // ch 0 sorts the teaching row first; click=false because
                // a row that says "1–9" and then jumps to one tab in
                // particular would be the menu lying about itself.
                out[n] = .{ .ch = 0, .title = "tab 1-9", .action = .tab_select, .arg = 0, .click = false };
                n += 1;
                continue;
            }
            const c = registrypkg.byAction(e.action, e.arg) orelse continue;
            out[n] = .{ .ch = e.ch, .title = c.title, .action = e.action, .arg = e.arg, .click = true };
            n += 1;
        }
        // Sorted by chord char, so the grid reads as an index rather
        // than as the order the config file happened to bind things in.
        std.mem.sort(WkItem, out[0..n], {}, struct {
            fn lt(_: void, a: WkItem, b: WkItem) bool {
                return a.ch < b.ch;
            }
        }.lt);
        return n;
    }

    /// The which-key sheet: every live chord as a clickable row, laid
    /// as a grid in a sheet above the status bar. SOLID colors like the
    /// palette — a modal must read instantly, glass or not. Also the
    /// writer of wk_hits/wk_rect, which clickLocked and ctl `whichkey`
    /// read; both are cleared whenever the sheet isn't on screen so a
    /// stale rect can never eat a click.
    fn drawWhichKey(self: *App, ui: *@import("ui.zig").Ui) void {
        self.wk_n = 0;
        self.wk_rect = .{ 0, 0, 0, 0 };
        if (!self.wk_visible or !self.leader_pending.load(.acquire)) return;
        const ld = self.keybinds.leader orelse return;
        var items: [40]WkItem = undefined;
        const n = self.wkItemsLocked(&items);
        if (n == 0) return;

        const cw = self.renderer.cell_w;
        const ch = self.renderer.cell_h;
        const row_h = self.bar_h;
        const gut = self.m.gutter;

        // One column fits the widest row: key column (3 cells, sized
        // for "1…9") + gap + title + trailing air.
        var maxt: usize = 0;
        for (items[0..n]) |it| maxt = @max(maxt, it.title.len);
        const col_w = @as(f32, @floatFromInt(3 + 1 + maxt + 3)) * cw;
        const avail = self.px_w - 2 * gut;
        const ncols: usize = @max(1, @min(n, @as(usize, @intFromFloat(@max(1, avail / col_w)))));
        const nrows = (n + ncols - 1) / ncols;

        const h = row_h * @as(f32, @floatFromInt(nrows + 1)) + self.m.gap * 2 + self.sep;
        const y0 = self.px_h - self.bar_h - h;

        // Elevation, then the sheet, then its top rule. Full-width and
        // sitting ON the status bar — it reads as the bar unfolding,
        // which is where the armed-leader cell it explains lives.
        ui.shadow(0, y0, self.px_w, h, 0, self.m.elevation, .{ 0, 0, 0, 150 });
        ui.rect(0, y0, self.px_w, h, th.bar_bg);
        ui.rect(0, y0, self.px_w, self.sep, th.sep);

        // Header: the armed key, and both ways to answer it. The mouse
        // is a first-class answer on purpose — every click runs the
        // command whose key it just showed you.
        var gb: [4]u8 = undefined;
        const hty = y0 + self.sep + self.m.gap + (row_h - ch) / 2;
        var hx = gut;
        hx += ui.textOver(hx, hty, keyGlyph(ld, &gb), th.accent);
        hx += ui.textOver(hx + cw, hty, "— press a key, or click", th.bar_fg) + cw;
        _ = ui.textOverRight(self.px_w - gut, hty, "esc dismiss", th.bar_fg);

        for (items[0..n], 0..) |it, i| {
            const col = i % ncols;
            const row = i / ncols;
            const rx = gut + @as(f32, @floatFromInt(col)) * col_w;
            const ry = y0 + self.sep + self.m.gap + row_h * @as(f32, @floatFromInt(row + 1));
            const rty = ry + (row_h - ch) / 2;
            const key: []const u8 = if (it.click) keyGlyph(it.ch, &gb) else "1…9";
            _ = ui.textOver(rx, rty, key, th.accent);
            _ = ui.textOver(rx + 4 * cw, rty, it.title, th.bar_value);
            self.wk_hits[i] = .{
                .x = rx,
                .y = ry,
                .w = col_w - cw,
                .h = row_h,
                .action = it.action,
                .arg = it.arg,
                .click = it.click,
            };
        }
        self.wk_n = n;
        self.wk_rect = .{ 0, y0, self.px_w, h };
    }

    /// A tab's display title: the focused pane's OSC 0/2 title (read
    /// from the emulator under its lock) or the editor's file name.
    /// Shared by the top strip's chips and the status bar's tabs
    /// segment — one tab, one name, wherever it renders.
    fn tabTitle(t: *panespkg.Tab, buf: []u8) []const u8 {
        var title: []const u8 = "shell";
        if (t.focused.content == .monitor) return "monitor";
        switch (t.focused.content) {
            .term => |*tm| {
                tm.session.mutex.lock();
                if (tm.session.term.getTitle()) |tt| {
                    const n = @min(tt.len, buf.len);
                    @memcpy(buf[0..n], tt[0..n]);
                    if (n > 0) title = buf[0..n];
                }
                tm.session.mutex.unlock();
            },
            .monitor => {},
            .edit => |ed| {
                const dn = ed.displayName();
                const n = @min(dn.len, buf.len);
                @memcpy(buf[0..n], dn[0..n]);
                if (n > 0) title = buf[0..n];
            },
        }
        return title;
    }

    /// The icon rail's items — glyph, name, and the command each click
    /// runs. One table so draw, click, and ctl `statusbar` agree (the
    /// registry pattern in miniature). rook's surfaces in VS Code's
    /// order-of-thought: files, search, source control, then the two
    /// panels that ARE rook — agents and review.
    const RailItem = struct {
        glyph: []const u8,
        title: []const u8,
        action: cfgpkg.Action,
    };
    pub const rail_items = [_]RailItem{
        .{ .glyph = "\u{f07b}", .title = "explorer", .action = .tree_toggle },
        .{ .glyph = "\u{f002}", .title = "search", .action = .panel_search },
    };

    /// Is a rail item's surface currently up? Only the side-pane
    /// tenants can answer honestly (the tree is per-pane, the palette
    /// is modal) — the rest never light.
    fn railActive(_: *App, _: cfgpkg.Action) bool {
        // Every side-pane tenant that could light this left in the strip;
        // the survivors (tree, palette) are per-pane or modal and never do.
        return false;
    }

    /// The icon rail (config `activity-bar`; the vscode preset turns
    /// it on) — VS Code's activity bar carrying rook's surfaces, one
    /// click each, always visible. Window chrome like the side pane:
    /// same rail from every tab, drawn from the same pipelines.
    fn drawActivityBar(self: *App, ui: *@import("ui.zig").Ui) void {
        self.rail_n = 0;
        const w = self.railWidth();
        if (w <= 0) return;
        const y0 = self.contentY();
        const h = @max(1, self.contentH());
        ui.rect(0, y0, w, h, self.glassBg(th.bar_bg));
        // The hairline on the edge that faces the panes — the side
        // pane's rule, for the side pane's reason.
        ui.rect(w - self.sep, y0, self.sep, h, th.sep);
        const ch = self.renderer.cell_h;
        const cw = self.renderer.cell_w;
        const box = @round(self.bar_h * 1.5);
        var y = y0 + self.m.gap;
        for (rail_items, 0..) |it, i| {
            if (y + box > y0 + h) break;
            const active = self.railActive(it.action);
            const fg = if (active) th.bar_value else th.bar_fg;
            _ = ui.text((w - cw) / 2, y + (box - ch) / 2, it.glyph, fg, self.glassBg(th.bar_bg));
            // The open surface wears an accent edge, VS Code's own
            // telegraph for "this icon is the panel you see".
            if (active) ui.rect(0, y, self.sep * 2, box, th.accent);
            if (i < self.rail_y.len) {
                self.rail_y[i] = .{ y, y + box };
                self.rail_n = i + 1;
            }
            y += box;
        }
    }

    /// The top strip — tabs as first-class chrome (the wails app's
    /// named tabs). Each chip shows its tab's title; the active chip
    /// gets a lifted background and an accent underline. What renders
    /// is config's `top-bar` list (presence, not order: tabs left,
    /// title center, usage right); an empty list skipped the strip
    /// before we were ever called (tab_h = 0).
    fn drawTabBar(self: *App, ui: *@import("ui.zig").Ui) void {
        self.chip_n = 0;
        if (self.contentY() <= 0) return;
        // One slab from the window top: in glass mode it also tints the
        // titlebar strip the traffic lights float over.
        ui.rect(0, 0, self.px_w, self.contentY(), self.glassBg(th.bar_bg));
        // Same rule as the status bar's, on the other edge — the chrome
        // and the panes are one flat field of colour without them.
        ui.rect(0, self.contentY() - self.sep, self.px_w, self.sep, th.sep);
        const ty = self.top_inset + (self.tab_h - self.renderer.cell_h) / 2;

        // The TITLE ZONE: workspace name centered, usage cluster right.
        // Glass mode owns a real titlebar strip; opaque shares the tab
        // row (the native titlebar isn't ours to draw in).
        const zone_ty = if (self.top_inset > 0)
            (self.top_inset - self.renderer.cell_h) / 2
        else
            ty;
        const cw = self.renderer.cell_w;
        if (self.cfg_top_bar.has(.title)) {
            const name = self.activeSpace().label();
            const nx = (self.px_w - @as(f32, @floatFromInt(name.len)) * cw) / 2;
            _ = ui.text(nx, zone_ty, name, th.bar_value, self.glassBg(th.bar_bg));
        }
        if (!self.cfg_top_bar.has(.tabs) or self.tab_h <= 0) return;
        // Chip TEXT lands on the same gutter the status bar's text does —
        // the two bars are the window's edges and must line up. The
        // label carries a leading pad space, so the box starts a cell
        // before it.
        var x: f32 = @max(0, self.m.gutter - cw);
        const space = self.activeSpace();
        for (space.tabs.items, 0..) |t, i| {
            const is_active = i == space.active_tab;

            // " {n} {title} ", title truncated to keep chips tidy.
            var title_buf: [24]u8 = undefined;
            const title = tabTitle(t, &title_buf);
            // A belled tab wears a dot before its number. The bell says
            // "something wants you"; the dot says WHICH tab, which is
            // the half a dock bounce can't deliver.
            // And a zoomed tab wears tmux's Z. Without it, a zoomed tab
            // is indistinguishable from a tab that only ever had one
            // pane — and the way out is a keystroke you'd have no
            // reason to reach for.
            var chip: [44]u8 = undefined;
            const z: []const u8 = if (t.zoomed != null) " Z" else "";
            const label = if (t.bell)
                std.fmt.bufPrint(&chip, " • {d} {s}{s} ", .{ i + 1, title, z }) catch continue
            else
                std.fmt.bufPrint(&chip, " {d} {s}{s} ", .{ i + 1, title, z }) catch continue;

            const fg = if (is_active) th.bar_value else if (t.bell) th.accent else th.bar_fg;
            // A chip is a SHAPE, not a run of coloured cells. Painting
            // the pill first and drawing the glyphs over it is what lets
            // it have corners at all — text() would lay a square
            // background back over them.
            const w = @as(f32, @floatFromInt(std.unicode.utf8CountCodepoints(label) catch label.len)) * cw;
            const chip_y = ty - (self.tab_h - self.renderer.cell_h) / 2 + self.m.gap / 2;
            const chip_h = self.tab_h - self.m.gap;
            if (is_active)
                ui.roundRect(x, chip_y, w, chip_h, self.glassBg(th.chip_active_bg), .{ .radius = self.m.radius });
            _ = ui.textOver(x, ty, label, fg);
            // The underline says which tab owns the content below, which
            // the lifted fill alone does not. Inset by the radius so it
            // starts where the chip's edge is actually straight.
            if (is_active)
                ui.rect(x + self.m.radius, self.contentY() - self.sep * 2, w - self.m.radius * 2, self.sep * 2, th.accent);
            if (i < self.chip_x.len) {
                self.chip_x[i] = .{ x, x + w };
                self.chip_n = i + 1;
            }
            x += w + self.renderer.cell_w / 2;
            if (x > self.px_w) break;
        }
    }

    /// The palette panel: floats over the panes, SOLID colors on
    /// purpose (a modal must read instantly, glass or not). Input row
    /// on top, filtered rows under it, selected row lifted + accent
    /// edge — the chip vocabulary at palette scale.
    /// The side pane: a titled slab with one tenant drawn into it.
    /// Chrome, so it draws from the same pipelines and atlases as the
    /// grid — a widget is never its own draw path.
    fn drawSidePane(self: *App, ui: *@import("ui.zig").Ui) void {
        const r = self.sideArea();
        if (r.w <= 0) return;
        const ch = self.renderer.cell_h;
        const row_h = self.bar_h;

        ui.rect(r.x, r.y, r.w, r.h, self.glassBg(th.bar_bg));
        // A hairline on the edge that faces the panes, so the boundary
        // reads even when the tenant is empty.
        const edge_x = if (self.side == .left) r.x + r.w - self.sep else r.x;
        ui.rect(edge_x, r.y, self.sep, r.h, th.sep);

        var y = r.y;
        const tx = r.x + self.m.gutter;
        _ = ui.text(tx, y + (row_h - ch) / 2, switch (self.side_panel) {
            .search => "SEARCH",
            .plugin => self.plug_name[0..self.plug_name_len],
            .config => "PENDING CONFIG",
        }, th.bar_value, self.glassBg(th.bar_bg));
        // The focus telegraph: an interactive panel has to look like it
        // is the thing your keys are going to.
        if (self.side_focus)
            ui.rect(r.x, r.y, r.w, self.sep, th.accent);
        y += row_h;
        // The header names the tenant; the rule says where it stops. The
        // same divider the palette puts under its input, for the same
        // reason — a title that runs straight into its rows is just the
        // first row.
        ui.rect(r.x, y, r.w, self.sep, th.sep);
        y += self.sep + self.m.gap;

        switch (self.side_panel) {
            .search => self.drawSearch(ui, r, y),
            .plugin => self.drawPlugin(ui, r, y),
            .config => self.drawConfig(ui, r, y),
        }
    }

    /// The selected row in a side panel: a rounded highlight inset from
    /// the panel's edges, so it reads as a row IN the panel rather than
    /// a band across it. One helper because four tenants draw the same
    /// row, and a selection that looked different in each would be four
    /// vocabularies for one idea.
    fn drawRowSelection(self: *App, ui: *@import("ui.zig").Ui, r: panespkg.Rect, y: f32, h: f32) void {
        ui.roundRect(r.x + self.m.gap, y, r.w - self.m.gap * 2, h, th.chip_active_bg, .{ .radius = self.m.radius });
    }

    /// Find in files: the query box, then the hits GROUPED BY FILE —
    /// a path header, then its lines indented under it. A flat list of
    /// 200 hits is a list you scroll; grouped, it is a list you read.
    // -----------------------------------------------------------------
    // The resource monitor
    // -----------------------------------------------------------------

    /// Open the monitor in the focused pane, parking whatever is there.
    ///
    /// A takeover rather than a split, matching `rook edit`: the monitor
    /// is something you glance at and dismiss, and a split would make
    /// "close it again" a layout decision instead of one keystroke.
    /// `toggle` is what separates the keybinding from ctl. Pressing the
    /// chord again should dismiss the monitor; `ctl monitor disk`
    /// selecting a tab on an open monitor must NOT close it, which is
    /// exactly the bug an e2e run caught the first time these shared
    /// one entry point.
    pub fn showMonitor(self: *App, toggle: bool) void {
        self.draw_lock.lock();
        const p = self.activeTab().focused;
        if (p.monitor()) |m| {
            if (toggle) m.closed = true;
            self.scene_dirty = true;
            self.draw_lock.unlock();
            return;
        }

        const m = self.gpa.create(monitorpkg.Monitor) catch {
            self.draw_lock.unlock();
            return;
        };
        m.* = monitorpkg.Monitor.init(self.gpa);
        m.vol = diskscan.volumeFor(".");
        // Park a terminal the way the takeover editor does, so closing
        // the monitor puts a running shell back rather than killing it.
        switch (p.content) {
            .term => |*tm| {
                p.under = tm.*;
                p.content = .{ .monitor = m };
            },
            .edit => |ed| {
                ed.destroy();
                p.content = .{ .monitor = m };
            },
            .monitor => unreachable, // handled above
        }
        p.drawn_cursor = 0xffff_ffff;
        self.scene_dirty = true;
        self.draw_lock.unlock();

        self.startSampler();
    }

    /// Whether any visible pane is a monitor. Drives the sampler's
    /// lifetime — see the `sampling` field.
    fn monitorVisibleLocked(self: *App) bool {
        for (self.activeTab().panes.items) |p| {
            if (p.rect.w == 0) continue;
            if (p.content == .monitor) return true;
        }
        return false;
    }

    /// Start the sampling thread if it is not already running.
    ///
    /// One sample is ~4ms for 1800 processes, which is far too much for
    /// the frame path and nothing at all for a worker at 1Hz. The thread
    /// exits on its own once no monitor pane is visible, so a closed
    /// monitor leaves no residual cost.
    fn startSampler(self: *App) void {
        if (self.sampling.swap(true, .acq_rel)) return;
        const T = struct {
            fn go(app: *App) void {
                if (!app.procs_ready) {
                    app.procs = procmon.Sampler.init(app.gpa);
                    app.procs_ready = true;
                }
                var panes_buf: [64]procmon.PaneProc = undefined;
                var labels_buf: [64]monitorpkg.Monitor.PaneLabel = undefined;
                var label_text: [64][24]u8 = undefined;

                while (true) {
                    // Collect the pane→pid map under the lock, then do
                    // the syscalls outside it: 4ms of libproc calls
                    // holding the draw lock is 4ms of dropped frames.
                    var n: usize = 0;
                    var nl: usize = 0;
                    var sort: procmon.SortKey = .cpu;
                    {
                        app.draw_lock.lock();
                        defer app.draw_lock.unlock();
                        if (!app.monitorVisibleLocked()) break;
                        for (app.activeTab().panes.items) |p| {
                            if (n >= panes_buf.len) break;
                            const tm = p.term() orelse (if (p.under) |*u| u else continue);
                            panes_buf[n] = .{ .pane_id = p.id, .pid = tm.session.pid };
                            n += 1;
                            const txt = std.fmt.bufPrint(&label_text[nl], "▸{d}", .{p.id}) catch continue;
                            labels_buf[nl] = .{ .id = p.id, .text = txt };
                            nl += 1;
                        }
                        for (app.activeTab().panes.items) |p| {
                            if (p.monitor()) |m| sort = m.sort;
                        }
                    }

                    var snap = app.procs.sample(panes_buf[0..n], sort) catch {
                        _ = usleep(1_000_000);
                        continue;
                    };

                    {
                        app.draw_lock.lock();
                        defer app.draw_lock.unlock();
                        var handed = false;
                        for (app.activeTab().panes.items) |p| {
                            const m = p.monitor() orelse continue;
                            // One snapshot, one owner. A second monitor
                            // pane borrows nothing — it would double-free
                            // on close — so only the first takes it.
                            if (handed) continue;
                            m.snap.deinit(app.gpa);
                            m.snap = snap;
                            m.pane_labels = labels_buf[0..nl];
                            m.render_dirty = true;
                            handed = true;
                        }
                        if (!handed) snap.deinit(app.gpa);
                        app.scene_dirty = true;
                    }
                    _ = usleep(1_000_000);
                }
                app.sampling.store(false, .release);
            }
        };
        if (std.Thread.spawn(.{}, T.go, .{self})) |t| t.detach() else |_| {
            self.sampling.store(false, .release);
        }
    }

    /// Walk the pane's repo root (or home) on a worker.
    fn startDiskScan(self: *App, m: *monitorpkg.Monitor) void {
        if (self.scanning.swap(true, .acq_rel)) {
            // A second scan would double the IO on a tree the first is
            // already walking, so say so rather than queue it.
            m.setMsg("a scan is already running");
            self.scene_dirty = true;
            return;
        }
        var root_buf: [1024]u8 = undefined;
        var root_len: usize = 0;
        {
            var scratch: [1024]u8 = undefined;
            if (self.paneRootLocked(self.activeTab().focused, &scratch)) |r| {
                root_len = @min(root_buf.len, r.len);
                @memcpy(root_buf[0..root_len], r[0..root_len]);
            }
        }
        if (root_len == 0) {
            const home = std.c.getenv("HOME") orelse {
                self.scanning.store(false, .release);
                m.setMsg("no HOME to scan");
                return;
            };
            const h = std.mem.sliceTo(home, 0);
            root_len = @min(root_buf.len, h.len);
            @memcpy(root_buf[0..root_len], h[0..root_len]);
        }

        // Drop the previous tree only after the new walk is under way?
        // No — the monitor points into it, so it has to be detached
        // here, under the lock the drawing thread also takes.
        m.scan = null;
        m.disk_root = 0;
        m.disk_stack.clearRetainingCapacity();
        m.sel = 0;
        m.scroll = 0;
        if (self.scan) |old| {
            old.deinit(self.gpa);
            self.gpa.destroy(old);
            self.scan = null;
        }
        self.scan_prog = .{};
        m.prog = &self.scan_prog;
        m.render_dirty = true;
        self.scene_dirty = true;

        const Job = struct {
            app: *App,
            mon: *monitorpkg.Monitor,
            path: [1024]u8,
            path_len: usize,
            fn go(j: *@This()) void {
                const app = j.app;
                const sc = app.gpa.create(diskscan.Scan) catch {
                    app.scanning.store(false, .release);
                    app.gpa.destroy(j);
                    return;
                };
                sc.* = diskscan.Scan.init(app.gpa);
                diskscan.walk(app.gpa, sc, j.path[0..j.path_len], &app.scan_prog) catch {};
                diskscan.sortChildren(sc, 0);

                app.draw_lock.lock();
                app.scan = sc;
                // The pane may have closed while we walked. Publishing
                // into a freed Monitor is the crash this check exists
                // for, so the pointer is re-derived from the live tree
                // rather than trusted from before the walk.
                for (app.activeTab().panes.items) |p| {
                    const mm = p.monitor() orelse continue;
                    if (mm != j.mon) continue;
                    mm.scan = sc;
                    mm.prog = null;
                    mm.sel = 0;
                    mm.scroll = 0;
                    mm.render_dirty = true;
                }
                app.scene_dirty = true;
                app.draw_lock.unlock();
                app.scanning.store(false, .release);
                app.gpa.destroy(j);
            }
        };
        const job = self.gpa.create(Job) catch {
            self.scanning.store(false, .release);
            return;
        };
        job.* = .{ .app = self, .mon = m, .path = root_buf, .path_len = root_len };
        if (std.Thread.spawn(.{}, Job.go, .{job})) |t| t.detach() else |_| {
            self.scanning.store(false, .release);
            self.gpa.destroy(job);
        }
    }

    /// Carry out a confirmed reclaim.
    ///
    /// Everything destructive in this feature funnels through here, and
    /// it re-checks every guarantee rather than trusting that the view
    /// already did: the path must still classify, and it must still
    /// classify as something deletable. `monitor.zig` cannot delete
    /// anything, so this function is the entire blast radius.
    fn startReclaim(self: *App, m: *monitorpkg.Monitor) void {
        const pend = m.pending orelse return;
        m.pending = null;
        const path = pend.pathStr();

        // Re-derive the class from the PATH, not from what was staged.
        // A stale category on a re-scanned tree is exactly how a `keep`
        // directory would end up deleted.
        const cat = diskscan.classify(path, true) orelse {
            m.setMsg("refused: that path no longer classifies as reclaimable");
            self.scene_dirty = true;
            return;
        };
        if (!cat.reclaim.deletable()) {
            m.setMsg("refused: that category is not deletable");
            self.scene_dirty = true;
            return;
        }
        if (self.reclaiming.swap(true, .acq_rel)) {
            m.setMsg("a reclaim is already running");
            return;
        }

        const Job = struct {
            app: *App,
            mon: *monitorpkg.Monitor,
            path: [1024]u8,
            path_len: usize,
            tool: [64]u8,
            tool_len: usize,
            fn go(j: *@This()) void {
                const app = j.app;
                const p = j.path[0..j.path_len];
                var ok = false;
                if (j.tool_len > 0) {
                    // The tool's own cleanup, where the category named
                    // one: `go clean -modcache` handles the read-only
                    // bits the module cache sets, which a recursive
                    // unlink trips over halfway and leaves in pieces.
                    ok = runTool(j.tool[0..j.tool_len]);
                } else {
                    std.Io.Dir.cwd().deleteTree(app.io, p) catch {
                        ok = false;
                    };
                    ok = true;
                }
                app.draw_lock.lock();
                for (app.activeTab().panes.items) |pane| {
                    const mm = pane.monitor() orelse continue;
                    if (mm != j.mon) continue;
                    var buf: [256]u8 = undefined;
                    mm.setMsg(std.fmt.bufPrint(&buf, "{s} {s} — rescan (s) to see the new totals", .{
                        if (ok) "reclaimed" else "FAILED to reclaim",
                        p,
                    }) catch "done");
                    mm.render_dirty = true;
                }
                app.scene_dirty = true;
                app.draw_lock.unlock();
                app.reclaiming.store(false, .release);
                app.gpa.destroy(j);
            }
        };
        const job = self.gpa.create(Job) catch {
            self.reclaiming.store(false, .release);
            return;
        };
        job.* = .{
            .app = self,
            .mon = m,
            .path = pend.path,
            .path_len = pend.path_len,
            .tool = pend.tool,
            .tool_len = pend.tool_len,
        };
        if (std.Thread.spawn(.{}, Job.go, .{job})) |t| t.detach() else |_| {
            self.reclaiming.store(false, .release);
            self.gpa.destroy(job);
        }
    }

    /// Open the side pane on a plugin and queue a fetch.
    pub fn showPlugin(self: *App, name: []const u8) bool {
        if (self.plugins.find(name) == null) return false;
        {
            self.draw_lock.lock();
            defer self.draw_lock.unlock();
            const n = @min(self.plug_name.len, name.len);
            @memcpy(self.plug_name[0..n], name[0..n]);
            self.plug_name_len = n;
            self.plug = .{};
            self.plug_sel = 0;
            self.plug_scroll = 0;
            self.plug_mode = .rows;
            self.plug_act_sel = 0;
            self.plug_msg_len = 0;
            self.side_panel = .plugin;
            self.side_open = true;
            self.side_focus = true;
            self.relayoutLocked();
            self.scene_dirty = true;
        }
        self.startPluginFetch();
        return true;
    }

    /// Fetch the panel's items on a worker.
    ///
    /// Off the key path for the same reason search is: items.list has a
    /// deadline measured in seconds, and a frame that waits on a
    /// subprocess is a dropped window. The panel says "asking…" meanwhile,
    /// because a blank panel and a slow one look the same and are not.
    fn startPluginFetch(self: *App) void {
        if (self.plug_loading.load(.acquire)) return;
        var name_buf: [64]u8 = undefined;
        var root_buf: [1024]u8 = undefined;
        var name_len: usize = 0;
        var root_len: usize = 0;
        {
            self.draw_lock.lock();
            defer self.draw_lock.unlock();
            name_len = self.plug_name_len;
            if (name_len == 0) return;
            @memcpy(name_buf[0..name_len], self.plug_name[0..name_len]);
            // COPY the returned slice. paneRootLocked only writes into the
            // buffer it is handed when it finds a repo root — otherwise it
            // returns a slice into the pane's cwd or its own stack. Taking
            // the length and keeping the buffer got a length that was right
            // and bytes that were never written.
            var scratch: [1024]u8 = undefined;
            if (self.paneRootLocked(self.activeTab().focused, &scratch)) |r| {
                root_len = @min(root_buf.len, r.len);
                @memcpy(root_buf[0..root_len], r[0..root_len]);
            }
        }

        const Args = struct {
            app: *App,
            name: [64]u8,
            name_len: usize,
            root: [1024]u8,
            root_len: usize,
        };
        const a = self.gpa.create(Args) catch return;
        a.* = .{ .app = self, .name = name_buf, .name_len = name_len, .root = root_buf, .root_len = root_len };
        self.plug_loading.store(true, .release);
        const T = struct {
            fn go(args: *Args) void {
                const app = args.app;
                const pl = @import("plugins.zig");
                // The registry is only mutated at launch, and Plugin owns
                // its own fds — so the call runs outside draw_lock, which
                // is the whole point of being on a worker.
                const snap = if (app.plugins.find(args.name[0..args.name_len])) |p|
                    pl.fetchItems(p, app.gpa, args.root[0..args.root_len])
                else
                    pl.Snapshot{};
                app.draw_lock.lock();
                // Only land it if the panel is still on the same plugin —
                // switching while a fetch is in flight must not paint one
                // plugin's items under another's name.
                if (app.plug_name_len == args.name_len and
                    std.mem.eql(u8, app.plug_name[0..app.plug_name_len], args.name[0..args.name_len]))
                {
                    // The selection follows the item's ID, not its row
                    // number: with the panel refreshing itself, a list
                    // that re-sorts under the cursor must not carry the
                    // cursor to a different item.
                    var keep: [64]u8 = undefined;
                    var keep_len: usize = 0;
                    if (app.plug_sel < app.plug.n) {
                        const cur = app.plug.items[app.plug_sel].id.get();
                        keep_len = cur.len;
                        @memcpy(keep[0..cur.len], cur);
                    }
                    app.plug = snap;
                    app.plug_sel = 0;
                    if (keep_len > 0) for (app.plug.slice(), 0..) |*it, idx| {
                        if (std.mem.eql(u8, it.id.get(), keep[0..keep_len])) {
                            app.plug_sel = idx;
                            break;
                        }
                    };
                    if (app.plug_sel >= app.plug.n) app.plug_sel = app.plug.n -| 1;
                    // A new list means the action menu was opened on an
                    // item that may no longer be the one under the cursor.
                    // Backing out is the only safe answer — a confirm left
                    // standing over a re-fetched row is a confirm for the
                    // wrong thing.
                    app.plug_mode = .rows;
                    app.plug_act_sel = 0;
                    app.scene_dirty = true;
                }
                app.draw_lock.unlock();
                app.plug_loading.store(false, .release);
                app.gpa.destroy(args);
            }
        };
        if (std.Thread.spawn(.{}, T.go, .{a})) |t| {
            t.detach();
        } else |_| {
            self.plug_loading.store(false, .release);
            self.gpa.destroy(a);
        }
    }


    /// The onboarding prompt.
    ///
    /// A palette rather than a modal: it is the surface rook already uses
    /// for "pick one of these", ESC already dismisses it, and a second
    /// question later is a second step rather than a second dialog.
    pub fn openSetupPalette(self: *App) void {
        self.draw_lock.lock();
        defer self.draw_lock.unlock();
        // A palette open behind it would take the keys back the moment
        // this closes.
        self.closePaletteLocked();
        // Asked is asked, whichever route got here. Without this, opening
        // setup by hand still left the automatic one armed, and it fired
        // later — over whatever you were doing by then.
        self.setup_needed = false;
        self.welcome_open = true;
        self.welcome_sel = 0;
        self.scene_dirty = true;
    }

    fn welcomeKeyLocked(self: *App, bytes: []const u8) void {
        const n = setup_choices.len;
        var i: usize = 0;
        while (i < bytes.len) {
            const b = bytes[i];
            if (b == 0x1b and i + 2 < bytes.len and bytes[i + 1] == '[') {
                switch (bytes[i + 2]) {
                    'A' => self.welcome_sel -|= 1,
                    'B' => self.welcome_sel = @min(self.welcome_sel + 1, n - 1),
                    else => {},
                }
                i += 3;
                continue;
            }
            switch (b) {
                // Skippable. Someone who wants a terminal right now should
                // get one; `⌘K → Set Up Config` is still there afterwards.
                0x1b => {
                    self.welcome_open = false;
                    self.scene_dirty = true;
                    return;
                },
                'k', 0x10 => self.welcome_sel -|= 1,
                'j', 0x0e => self.welcome_sel = @min(self.welcome_sel + 1, n - 1),
                0x0d => {
                    self.setup_wanted = setup_choices[self.welcome_sel].lang;
                    self.welcome_open = false;
                    self.scene_dirty = true;
                    return;
                },
                else => {},
            }
            i += 1;
        }
        self.scene_dirty = true;
    }

    /// Write the starter config and open it.
    ///
    /// Opening it is half the point: the answer to "how do I configure
    /// this" should be a file on screen with your cursor in it, not a path
    /// in a doc you have to go and find.
    fn startSetup(self: *App, lang: envpkg.Lang) void {
        const T = struct {
            fn go(app: *App, l: envpkg.Lang) void {
                var dirbuf: [1024]u8 = undefined;
                const dir = cfgpkg.configDir(&dirbuf) orelse return;
                const cwd = std.Io.Dir.cwd();
                cwd.createDirPath(app.io, dir) catch {};

                var pbuf: [1088]u8 = undefined;
                var openbuf: [1088]u8 = undefined;
                var open_len: usize = 0;
                switch (l) {
                    .go => {
                        const gm = std.fmt.bufPrint(&pbuf, "{s}/go.mod", .{dir}) catch return;
                        cwd.writeFile(app.io, .{ .sub_path = gm, .data = envpkg.go_mod }) catch return;
                        const mg = std.fmt.bufPrint(&openbuf, "{s}/main.go", .{dir}) catch return;
                        open_len = mg.len;
                        cwd.writeFile(app.io, .{ .sub_path = mg, .data = envpkg.go_main }) catch return;
                        // Resolve the SDK now, so the first apply is not the
                        // thing that discovers the module is missing.
                        _ = envpkg.tidy(dir);
                    },
                    .ts => {
                        // The SDK travels WITH the starter: @incantery/rook
                        // is not on npm, and a starter whose first line
                        // imports a package that does not exist is not a
                        // starter.
                        const sdk = std.fmt.bufPrint(&pbuf, "{s}/rook.ts", .{dir}) catch return;
                        cwd.writeFile(app.io, .{ .sub_path = sdk, .data = envpkg.ts_sdk }) catch return;
                        const ct = std.fmt.bufPrint(&openbuf, "{s}/config.ts", .{dir}) catch return;
                        open_len = ct.len;
                        cwd.writeFile(app.io, .{ .sub_path = ct, .data = envpkg.ts_main }) catch return;
                    },
                }
                if (open_len > 0) _ = app.openEditorAt(openbuf[0..open_len], 1, 0);
            }
        };
        if (std.Thread.spawn(.{}, T.go, .{ self, lang })) |t| t.detach() else |_| {}
    }

    /// Open the config program in rook's own editor.
    ///
    /// `⌘K` → "Edit Config". No path to remember, no `cd`, and no leaving
    /// rook to change rook — the editor is right there and the config is
    /// just a file.
    ///
    /// With no config program yet, this is the onboarding prompt instead:
    /// asking someone to edit a file that does not exist is not an answer.
    pub fn editConfig(self: *App) void {
        var dirbuf: [1024]u8 = undefined;
        const dir = cfgpkg.configDir(&dirbuf) orelse return;
        if (envpkg.findSource(self.io, dir)) |src| {
            _ = self.openEditorAt(src.path(), 1, 0);
            return;
        }
        // No program, but a hand-written graph: open that rather than
        // pretending there is nothing here.
        var gbuf: [1088]u8 = undefined;
        if (cfgpkg.envPath(&gbuf)) |gp| {
            if (std.Io.Dir.cwd().access(self.io, gp, .{})) |_| {
                _ = self.openEditorAt(gp, 1, 0);
                return;
            } else |_| {}
        }
        self.openSetupPalette();
    }

    // ---- apply ----

    /// Run the config program and hold the result up against what is
    /// running. On a worker: `go run` forks a compiler and takes a second,
    /// and the frame loop is not somewhere to spend one.
    fn startEnvCheck(self: *App) void {
        if (self.env_checking.load(.acquire)) return;
        self.env_checking.store(true, .release);
        const T = struct {
            fn go(app: *App) void {
                defer app.env_checking.store(false, .release);

                var dirbuf: [1024]u8 = undefined;
                const dir = cfgpkg.configDir(&dirbuf) orelse return;
                const src = envpkg.findSource(app.io, dir) orelse return;

                // Into a temp file beside the config, NOT over
                // environment.json: a candidate that is never applied must
                // leave no trace on what is running.
                var outbuf: [1088]u8 = undefined;
                const out = std.fmt.bufPrint(&outbuf, "{s}/.rook-candidate.json", .{dir}) catch return;
                const r = envpkg.run(dir, src, out);

                var candidate: []u8 = &.{};
                var d = envpkg.Diff{};
                if (r.ok) {
                    if (std.Io.Dir.cwd().readFileAlloc(app.io, out, app.gpa, .limited(1 << 20)) catch null) |data| {
                        candidate = data;
                        var abuf: [1088]u8 = undefined;
                        const applied_path = cfgpkg.envPath(&abuf);
                        const applied: []u8 = if (applied_path) |ap|
                            (std.Io.Dir.cwd().readFileAlloc(app.io, ap, app.gpa, .limited(1 << 20)) catch null) orelse &.{}
                        else
                            &.{};
                        defer if (applied.len > 0) app.gpa.free(applied);
                        d = envpkg.diff(app.gpa, applied, candidate);
                    } else {
                        d.err.set("the config program wrote no graph");
                    }
                } else {
                    // The program's OWN output, not a summary of it. A Go
                    // compile error names a line; "apply failed" sends you
                    // looking in rook.
                    d.err.set(if (r.logStr().len > 0) r.logStr() else "the config program failed");
                }
                std.Io.Dir.cwd().deleteFile(app.io, out) catch {};

                app.draw_lock.lock();
                if (app.env_candidate.len > 0) app.gpa.free(app.env_candidate);
                app.env_candidate = candidate;
                app.env_diff = d;
                copyStr(&app.env_log, &app.env_log_len, r.logStr());
                app.scene_dirty = true;
                const pending = d.ok and !d.empty();
                const broke = !d.ok;
                app.draw_lock.unlock();

                // Attention, not application. The whole point is that a
                // human decides — and a config that silently did what it
                // liked is what this replaces.
                // SHOW it, unfocused. "N changes pending" in a banner is a
                // count; the panel is the answer to what they are — and
                // opening it without focus means it informs rather than
                // interrupts.
                // SHOW it, unfocused.
                if (pending or broke) app.showConfigPreview(false);
                if (pending or broke) {
                    // Through the same door a plugin uses, params and all —
                    // config is not a special case of "a human is needed",
                    // it is an instance of it.
                    var pbuf: [512]u8 = undefined;
                    var w: std.Io.Writer = .fixed(&pbuf);
                    w.writeAll("{\"title\":") catch return;
                    plugpkg.jsonStringTo(&w, if (broke) "config is broken" else "config changes pending") catch return;
                    w.writeAll(",\"body\":") catch return;
                    var b: [160]u8 = undefined;
                    plugpkg.jsonStringTo(&w, if (broke)
                        "the config program failed — run `env` to see why"
                    else
                        std.fmt.bufPrint(&b, "{d} change(s) — apply from the palette", .{d.n + d.more}) catch "changes pending") catch return;
                    w.writeAll("}") catch return;
                    _ = app.raiseAttention("config", pbuf[0..w.end]);
                }
            }
        };
        if (std.Thread.spawn(.{}, T.go, .{self})) |t| {
            t.detach();
        } else |_| {
            self.env_checking.store(false, .release);
        }
    }

    /// Apply the held candidate: write it over environment.json.
    ///
    /// That is the whole operation. environment.json IS the applied state,
    /// so writing it is applying it, and the existing 1Hz reload picks it
    /// up the same way it always did for a hand-edited graph.
    pub fn applyEnv(self: *App) bool {
        self.draw_lock.lock();
        const ok = self.env_diff.ok and self.env_candidate.len > 0;
        const data = if (ok) self.gpa.dupe(u8, self.env_candidate) catch null else null;
        self.draw_lock.unlock();
        const bytes = data orelse return false;
        defer self.gpa.free(bytes);

        var buf: [1088]u8 = undefined;
        const path = cfgpkg.envPath(&buf) orelse return false;
        std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = path, .data = bytes }) catch return false;

        self.draw_lock.lock();
        self.env_diff = .{};
        if (self.env_candidate.len > 0) self.gpa.free(self.env_candidate);
        self.env_candidate = &.{};
        // The graph just changed, so what routes to a server may have
        // too. Re-read the declarations, forget every resolution made
        // against the old ones, and give panes with no server another
        // look — declaring a language you were missing should take
        // effect on apply, not on relaunch.
        self.langs.loadGraph(self.io);
        self.lsp.forgetResolutions();
        self.lspRetryAttachLocked();
        // The panel was opened to show a diff that no longer exists.
        if (self.side_open and self.side_panel == .config) {
            self.side_open = false;
            self.side_focus = false;
            self.relayoutLocked();
        }
        self.scene_dirty = true;
        self.draw_lock.unlock();
        return true;
    }

    // ---- the inbound verbs: what a plugin may ask rook to do ----

    /// Every inbound call lands here, on the plugin's pump thread.
    ///
    /// Grants were already checked in plugins.zig — this is the half that
    /// knows what the verbs MEAN. Refusals come back as a short reason,
    /// because the plugin author is the one who has to act on it.
    ///
    /// Synchronous on purpose: the plugin asked and is waiting, so a spawn
    /// that takes 40ms holds the pump for 40ms. That is the honest
    /// semantics of a request, and doing it asynchronously would mean
    /// answering "yes" before knowing whether it worked.
    fn pluginInbound(ctx: *anyopaque, from: []const u8, op: []const u8, params: []const u8, result: *std.Io.Writer) ?[]const u8 {
        const self: *App = @ptrCast(@alignCast(ctx));
        if (std.mem.eql(u8, op, plugpkg.op_raise)) return self.raiseAttention(from, params);
        if (std.mem.eql(u8, op, plugpkg.op_spawn)) return self.spawnSession(params);
        if (std.mem.eql(u8, op, plugpkg.op_send)) return self.sessionSend(params);
        if (std.mem.eql(u8, op, plugpkg.op_clipboard)) return self.clipboardSet(params);
        if (std.mem.eql(u8, op, "panes.activity")) {
            self.activityReport(result, true);
            return null;
        }
        // Granted, but not something rook knows how to do — which is a
        // config naming a verb from a newer rook, not a plugin misbehaving.
        return "rook does not know that verb";
    }

    /// `panes.activity` (and `ctl activity`) — the substrate half of
    /// "is that session alive": per terminal pane, how long since the
    /// child last wrote and since the human last typed there. The two
    /// travel different directions through different code paths, so
    /// "the TUI is redrawing" and "the human is present" are separate
    /// facts, not a heuristic. A transcript-watching plugin joins this
    /// against what it reads on cwd + foreground program.
    fn activityReport(self: *App, w: *std.Io.Writer, comptime as_json: bool) void {
        const now = sessionpkg.clockMs();
        self.draw_lock.lock();
        defer self.draw_lock.unlock();
        if (as_json) w.writeAll("{\"panes\":[") catch return;
        var first = true;
        for (self.spaces.items) |s| for (s.tabs.items) |t| for (t.panes.items) |p| {
            const tm = p.term() orelse (if (p.under) |*ut| ut else continue);
            const out_ms = tm.session.last_out_ms.load(.monotonic);
            const in_ms = tm.session.last_in_ms.load(.monotonic);
            const out_bytes = tm.session.out_bytes.load(.monotonic);
            const out_age: i64 = if (out_ms == 0) -1 else now - out_ms;
            const in_age: i64 = if (in_ms == 0) -1 else now - in_ms;
            var fgbuf: [1024]u8 = undefined;
            const fg_path = tm.session.fgPath(&fgbuf) orelse "-";
            const fg = std.fs.path.basename(fg_path);
            const cwd: []const u8 = if (self.paneCwd(p)) |c| std.mem.span(c) else "";
            if (as_json) {
                if (!first) w.writeAll(",") catch return;
                w.print("{{\"id\":{d},\"outMs\":{d},\"inMs\":{d},\"outBytes\":{d},\"fg\":", .{ p.id, out_age, in_age, out_bytes }) catch return;
                plugpkg.jsonStringTo(w, fg) catch return;
                // The full path too: Claude Code's versioned install runs
                // as a binary named `2.1.220`, and only the path still
                // says whose it is.
                w.writeAll(",\"path\":") catch return;
                plugpkg.jsonStringTo(w, fg_path) catch return;
                w.writeAll(",\"cwd\":") catch return;
                plugpkg.jsonStringTo(w, cwd) catch return;
                w.writeAll("}") catch return;
            } else {
                w.print("{d}\t{d}\t{d}\t{d}\t{s}\t{s}\n", .{ p.id, out_age, in_age, out_bytes, fg, cwd }) catch return;
            }
            first = false;
        };
        if (as_json) w.writeAll("]}") catch return;
        if (!as_json and first) w.writeAll("none\n") catch return;
    }

    /// The ctl face of the same report.
    pub fn activityText(self: *App, w: *std.Io.Writer) void {
        self.activityReport(w, false);
    }

    /// `attention.raise` — a plugin says a human is needed.
    fn raiseAttention(self: *App, from: []const u8, params: []const u8) ?[]const u8 {
        const Wire = struct {
            title: []const u8 = "",
            body: []const u8 = "",
        };
        const parsed = std.json.parseFromSlice(Wire, self.gpa, if (params.len > 0) params else "{}", .{
            .ignore_unknown_fields = true,
        }) catch return "params did not parse";
        defer parsed.deinit();
        if (parsed.value.title.len == 0) return "attention.raise needs a title";

        var r = Raise{};
        copyStr(&r.from, &r.from_len, from);
        copyStr(&r.title, &r.title_len, parsed.value.title);
        copyStr(&r.body, &r.body_len, parsed.value.body);

        self.draw_lock.lock();
        self.att_seq += 1;
        r.seq = self.att_seq;
        // A ring: the newest wins, and the oldest falls off the end.
        if (self.att_n < self.att.len) {
            self.att[self.att_n] = r;
            self.att_n += 1;
        } else {
            std.mem.copyForwards(Raise, self.att[0 .. self.att.len - 1], self.att[1..]);
            self.att[self.att.len - 1] = r;
        }
        // What `ctl notify` reports, so a test that cannot see a banner can
        // still tell whether one was posted — the same reason the OSC 9
        // path records it.
        self.notify_last_len = @min(
            r.fromStr().len + r.titleStr().len + r.bodyStr().len + 5,
            self.notify_last.len,
        );
        _ = std.fmt.bufPrint(&self.notify_last, "{s}: {s} | {s}", .{
            r.fromStr(), r.titleStr(), r.bodyStr(),
        }) catch {};
        self.scene_dirty = true;
        self.draw_lock.unlock();

        // The banner and the dock bounce are the same ones a BEL gets:
        // attention is attention, and rook already decided what that looks
        // like. postNotification is main-thread-only work in AppKit terms,
        // but it is also what the OSC 9 reader threads already do.
        var titled: [128]u8 = undefined;
        const title = std.fmt.bufPrint(&titled, "{s}: {s}", .{ r.fromStr(), r.titleStr() }) catch r.titleStr();
        self.postNotification(title, r.bodyStr());
        if (!self.app.msgSend(bool, "isActive", .{}))
            _ = self.app.msgSend(c_long, "requestUserAttention:", .{@as(c_long, 10)});
        return null;
    }

    /// `session.spawn` — a plugin asks for a pane running something.
    ///
    /// Not a privilege escalation: the plugin is already a process rook
    /// forked, so it could run this itself. What the verb buys is that the
    /// command runs WHERE THE HUMAN CAN SEE IT — in a pane, with scrollback
    /// and a cwd — instead of invisibly inside the plugin. The grant is
    /// what keeps it from being a surprise.
    /// session.send — the membrane's hands (docs/agent/VISION.md, rung
    /// three): type a human-authored reply into an agent's pane the way
    /// the human would, per ADR 0004's TUI-only rule. Two gates, both
    /// non-negotiable:
    ///
    ///   - The pane's foreground must BE an agent TUI (claude by name,
    ///     or a path that says claude — the versioned install runs a
    ///     binary named `2.1.220`). Text typed into a shell EXECUTES,
    ///     so a wrong target is not a wrong paste, it is arbitrary
    ///     command injection. `node` is deliberately NOT enough here,
    ///     though the watcher counts it for display: a REPL eats typed
    ///     text as code too.
    ///   - A human who typed in that pane in the last 5 seconds wins.
    ///     A plugin may put text into a prompt; it does not get to
    ///     fight the keyboard for it mid-sentence.
    ///
    /// The text rides a bracketed paste (multi-line arrives as one
    /// block) and a CR submits it.
    fn sessionSend(self: *App, params: []const u8) ?[]const u8 {
        const Wire = struct { pane: u32 = 0, text: []const u8 = "" };
        const parsed = std.json.parseFromSlice(Wire, self.gpa, if (params.len > 0) params else "{}", .{
            .ignore_unknown_fields = true,
        }) catch return "params did not parse";
        defer parsed.deinit();
        const text = parsed.value.text;
        if (text.len == 0) return "session.send needs text";
        if (text.len > 8192) return "text too long to type";

        self.draw_lock.lock();
        defer self.draw_lock.unlock();
        var target: ?*panespkg.Pane = null;
        for (self.spaces.items) |s| for (s.tabs.items) |t| for (t.panes.items) |p| {
            if (p.id == parsed.value.pane) target = p;
        };
        const p = target orelse return "no such pane";
        const tm = p.term() orelse return "that pane is not a terminal";

        var fgbuf: [1024]u8 = undefined;
        const fg_path = tm.session.fgPath(&fgbuf) orelse "";
        const fg = std.fs.path.basename(fg_path);
        if (!std.mem.eql(u8, fg, "claude") and std.mem.indexOf(u8, fg_path, "claude") == null)
            return "target is not an agent TUI — typed text would execute";
        const now = sessionpkg.clockMs();
        const in_ms = tm.session.last_in_ms.load(.monotonic);
        if (in_ms != 0 and now - in_ms < 5000)
            return "a human is typing there";

        var buf: [8192 + 16]u8 = undefined;
        const framed = std.fmt.bufPrint(&buf, "\x1b[200~{s}\x1b[201~\r", .{text}) catch return "text too long to type";
        self.paneInput(p, framed);
        return null;
    }

    /// clipboard.set: a plugin hands the human text to paste — the
    /// agent's drafted reply riding to the Claude pane through the
    /// human's own ⌘V. Grant-gated like every inbound verb, and the
    /// OSC 52 `clipboard-write` option is the precedent that writing
    /// the pasteboard is a permission, not a given.
    fn clipboardSet(self: *App, params: []const u8) ?[]const u8 {
        const Wire = struct { text: []const u8 = "" };
        const parsed = std.json.parseFromSlice(Wire, self.gpa, if (params.len > 0) params else "{}", .{
            .ignore_unknown_fields = true,
        }) catch return "params did not parse";
        defer parsed.deinit();
        if (parsed.value.text.len == 0) return "clipboard.set needs text";
        // The pump assembles frames far larger than any honest paste;
        // this cap is about what a human would ever ⌘V into a prompt.
        if (parsed.value.text.len > 256 * 1024) return "text too large to paste";
        self.setPasteboard(parsed.value.text);
        return null;
    }

    fn spawnSession(self: *App, params: []const u8) ?[]const u8 {
        const Wire = struct {
            command: []const u8 = "",
            cwd: []const u8 = "",
            where: []const u8 = "",
        };
        const parsed = std.json.parseFromSlice(Wire, self.gpa, if (params.len > 0) params else "{}", .{
            .ignore_unknown_fields = true,
        }) catch return "params did not parse";
        defer parsed.deinit();
        if (parsed.value.command.len == 0) return "session.spawn needs a command";

        var cmd_buf: [4096]u8 = undefined;
        if (parsed.value.command.len >= cmd_buf.len) return "command too long";
        @memcpy(cmd_buf[0..parsed.value.command.len], parsed.value.command);
        cmd_buf[parsed.value.command.len] = 0;
        const cmd: [*:0]const u8 = @ptrCast(&cmd_buf);

        var cwd_buf: [1024]u8 = undefined;
        var cwd: ?[*:0]const u8 = null;
        if (parsed.value.cwd.len > 0) {
            if (parsed.value.cwd.len >= cwd_buf.len) return "cwd too long";
            @memcpy(cwd_buf[0..parsed.value.cwd.len], parsed.value.cwd);
            cwd_buf[parsed.value.cwd.len] = 0;
            cwd = @ptrCast(&cwd_buf);
        }
        const as_tab = std.mem.eql(u8, parsed.value.where, "tab");

        self.draw_lock.lock();
        defer self.draw_lock.unlock();
        // Inheriting the focused pane's cwd when none was named: a plugin
        // that knows nothing about the filesystem still lands somewhere
        // sensible, which is the same rule a split follows.
        const pane = self.makePaneCmd(cwd orelse self.focusedCwd(), cmd) catch return "could not start a session";
        if (as_tab) {
            const t = self.gpa.create(panespkg.Tab) catch return "out of memory";
            t.* = .{ .id = self.next_tab_id, .root = .{ .leaf = pane }, .focused = pane };
            self.next_tab_id += 1;
            t.panes.append(self.gpa, pane) catch {};
            const s = self.activeSpace();
            s.tabs.append(self.gpa, t) catch return "out of memory";
            self.activateTabLocked(s.tabs.items.len - 1);
        } else {
            const t = self.activeTab();
            if (!panespkg.splitAt(self.gpa, &t.root, t.focused, pane, true))
                return "could not place the session";
            t.panes.append(self.gpa, pane) catch {};
            // NOT focused. A plugin gets to put something on your screen;
            // it does not get to take your keystrokes mid-sentence.
            self.relayoutLocked();
        }
        self.refreshHudLocked(CACurrentMediaTime());
        self.scene_dirty = true;
        return null;
    }

    /// Run the selected action on a worker.
    ///
    /// Off the key path for the same reason the fetch is: items.act reaches
    /// whatever the plugin reaches — git, a network, a human's laptop fan —
    /// and a frame that waits on that is a dropped window.
    fn startPluginAct(self: *App) void {
        if (self.plug_acting.load(.acquire)) return;
        const Args = struct {
            app: *App,
            name: [64]u8,
            name_len: usize,
            item: [64]u8,
            item_len: usize,
            action: [32]u8,
            action_len: usize,
            input: [512]u8,
            input_len: usize,
            row: usize,
        };
        const a = self.gpa.create(Args) catch return;
        a.* = std.mem.zeroInit(Args, .{ .app = self });
        {
            self.draw_lock.lock();
            defer self.draw_lock.unlock();
            const it = self.plugItemLocked() orelse {
                self.gpa.destroy(a);
                return;
            };
            if (self.plug_act_sel >= it.actions_n or self.plug_name_len == 0) {
                self.gpa.destroy(a);
                return;
            }
            const act = &it.actions[self.plug_act_sel];
            a.name_len = self.plug_name_len;
            @memcpy(a.name[0..a.name_len], self.plug_name[0..a.name_len]);
            a.item_len = it.id.get().len;
            @memcpy(a.item[0..a.item_len], it.id.get());
            a.action_len = act.id.get().len;
            @memcpy(a.action[0..a.action_len], act.id.get());
            if (self.plug_mode == .input) {
                a.input_len = self.plug_input_len;
                @memcpy(a.input[0..a.input_len], self.plug_input[0..a.input_len]);
            }
            a.row = self.plug_sel;
            self.plugSay("running…");
            self.scene_dirty = true;
        }

        self.plug_acting.store(true, .release);
        const T = struct {
            fn go(args: *Args) void {
                const app = args.app;
                const done = if (app.plugins.find(args.name[0..args.name_len])) |p|
                    plugpkg.act(p, app.gpa, args.item[0..args.item_len], args.action[0..args.action_len], args.input[0..args.input_len])
                else
                    plugpkg.Acted{};

                var stale = false;
                app.draw_lock.lock();
                // Only land it if the panel is still on the same plugin —
                // switching mid-flight must not paint one plugin's answer
                // under another's name.
                if (app.plug_name_len == args.name_len and
                    std.mem.eql(u8, app.plug_name[0..app.plug_name_len], args.name[0..args.name_len]))
                {
                    app.plugSay(if (done.msg.n > 0) done.msg.get() else "no answer");
                    if (done.ok) {
                        // It ran, so the menu has served its purpose. A
                        // refusal leaves you in the menu, because there the
                        // next thing you want is probably another action.
                        app.plug_mode = .rows;
                        if (done.item) |updated| {
                            // The plugin handed back the row as it now is,
                            // so one line repaints instead of the list
                            // relisting. Depth is the HOST's — the plugin
                            // answered about an item, not about a tree.
                            if (args.row < app.plug.n) {
                                const depth = app.plug.items[args.row].depth;
                                app.plug.items[args.row] = updated;
                                app.plug.items[args.row].depth = depth;
                            }
                        } else {
                            // It did not, so the list is now a guess.
                            stale = true;
                        }
                    }
                    app.scene_dirty = true;
                }
                app.draw_lock.unlock();
                app.plug_acting.store(false, .release);
                app.gpa.destroy(args);
                // After the unlock: startPluginFetch takes the lock itself.
                if (stale) app.startPluginFetch();
            }
        };
        if (std.Thread.spawn(.{}, T.go, .{a})) |t| {
            t.detach();
        } else |_| {
            self.plug_acting.store(false, .release);
            self.gpa.destroy(a);
        }
    }

    /// The selected item, or null when the panel has nothing.
    fn plugItemLocked(self: *App) ?*const plugpkg.Item {
        const rows = self.plug.slice();
        if (self.plug_sel >= rows.len) return null;
        return &rows[self.plug_sel];
    }

    fn plugSay(self: *App, msg: []const u8) void {
        copyStr(&self.plug_msg, &self.plug_msg_len, msg);
    }

    /// The plugin panel's keys: move, descend into an action, confirm it,
    /// and hand the keys back.
    ///
    /// Three modes rather than one, because an action can DELETE a branch.
    /// Enter on a row opens what the item offers; Enter on an action runs
    /// it, unless the plugin marked it `confirm`, in which case y/n stands
    /// between the human and it. The plugin decides that — only the plugin
    /// knows which of its actions destroys something.
    pub fn pluginKeyLocked(self: *App, bytes: []const u8) void {
        const n = self.plug.slice().len;
        var i: usize = 0;
        while (i < bytes.len) {
            const b = bytes[i];
            // Arrows move in whichever list has the keys.
            if (b == 0x1b and i + 2 < bytes.len and bytes[i + 1] == '[') {
                const up = bytes[i + 2] == 'A';
                const down = bytes[i + 2] == 'B';
                if (up or down) self.plugMoveLocked(down);
                i += 3;
                continue;
            }
            switch (self.plug_mode) {
                .rows => switch (b) {
                    0x1b => { // ESC yields the keys back to the panes
                        self.side_focus = false;
                        self.scene_dirty = true;
                        return;
                    },
                    'k', 0x10 => self.plug_sel -|= 1,
                    'j', 0x0e => self.plug_sel = @min(self.plug_sel + 1, n -| 1),
                    'g' => self.plug_sel = 0,
                    'G' => self.plug_sel = n -| 1,
                    'r' => self.plug_refetch = true, // drained after the lock
                // vim's yank. The panel is where you are when you have just
                // watched a downloaded plugin work and want to pin it.
                'y' => self.plug_pin_wanted = true,
                    0x0d => if (self.plugItemLocked()) |it| {
                        // Silence here would read as a broken key. An item
                        // with nothing to do says so.
                        if (it.actions_n == 0) {
                            self.plugSay("no actions on this item");
                        } else {
                            self.plug_mode = .actions;
                            self.plug_act_sel = 0;
                            self.plug_msg_len = 0;
                        }
                    },
                    else => {},
                },
                .actions => switch (b) {
                    // ESC backs out one level rather than closing the
                    // panel: the human descended, so the way out is up.
                    0x1b => self.plug_mode = .rows,
                    'k', 0x10 => self.plugMoveLocked(false),
                    'j', 0x0e => self.plugMoveLocked(true),
                    0x0d => self.plugChooseLocked(),
                    else => {},
                },
                .confirm => switch (b) {
                    'y', 'Y' => {
                        self.plug_run = true; // drained after the lock
                        self.plug_mode = .actions;
                    },
                    'n', 'N', 0x1b => {
                        self.plug_mode = .actions;
                        self.plugSay("cancelled");
                    },
                    // Anything else is NOT consent. A confirm that any key
                    // dismisses is not a confirm.
                    else => {},
                },
                // The one-line payload editor. Every printable byte is
                // TEXT here — j is a letter, not a direction.
                .input => switch (b) {
                    0x1b => self.plug_mode = .actions,
                    0x0d => if (self.plug_input_len == 0) {
                        // The refusal this mode replaced lives on at the
                        // last moment: a plugin never acts on nothing.
                        self.plugSay("type something, or ESC");
                    } else {
                        self.plug_run = true; // drained after the lock
                    },
                    0x7f, 0x08 => while (self.plug_input_len > 0) {
                        // Back to the previous rune start, not byte.
                        self.plug_input_len -= 1;
                        if (self.plug_input[self.plug_input_len] & 0xC0 != 0x80) break;
                    },
                    else => if (b >= 0x20 and self.plug_input_len < self.plug_input.len) {
                        self.plug_input[self.plug_input_len] = b;
                        self.plug_input_len += 1;
                    },
                },
            }
            i += 1;
        }
        self.scene_dirty = true;
    }

    fn plugMoveLocked(self: *App, down: bool) void {
        switch (self.plug_mode) {
            .rows => {
                const n = self.plug.slice().len;
                if (down) self.plug_sel = @min(self.plug_sel + 1, n -| 1) else self.plug_sel -|= 1;
            },
            .actions => {
                const it = self.plugItemLocked() orelse return;
                if (down) self.plug_act_sel = @min(self.plug_act_sel + 1, it.actions_n -| 1) else self.plug_act_sel -|= 1;
            },
            // A confirm is a question with two answers, and the arrow keys
            // are not either of them. The input line is TEXT — arrows do
            // not move a selection that typing is busy filling.
            .confirm, .input => {},
        }
    }

    /// Enter on an action: run it, ask first, or refuse it by name.
    fn plugChooseLocked(self: *App) void {
        const it = self.plugItemLocked() orelse return;
        if (self.plug_act_sel >= it.actions_n) return;
        const a = &it.actions[self.plug_act_sel];
        if (a.wantsInput()) {
            // VOCABULARY.md's open question 3, answered by the demo that
            // needed it: the payload belongs to the ACTION — one line,
            // typed right here under the menu. The old refusal existed so
            // a plugin never acts on nothing; the Enter in input mode
            // still enforces exactly that.
            self.plug_mode = .input;
            self.plug_input_len = 0;
            self.plug_msg_len = 0;
            return;
        }
        if (a.confirm) {
            self.plug_mode = .confirm;
            return;
        }
        self.plug_run = true;
    }

    /// Where an item's title begins: state chip, then tree indent.
    /// Arithmetic (state is ASCII, one byte one cell) rather than the
    /// draw call's return value, so the measure pass and the draw pass
    /// cannot disagree about where the title starts.
    fn plugTitleX(self: *App, it: *const plugpkg.Item, tx: f32) f32 {
        const cw = self.renderer.cell_w;
        var x = tx;
        if (it.state.n > 0) x += @as(f32, @floatFromInt(it.state.get().len)) * cw + cw;
        return x + @as(f32, @floatFromInt(it.depth)) * 2 * cw;
    }

    /// The right-aligned field shed, shared by measuring and drawing so
    /// the two cannot drift: fields shed WHOLE from the right until one
    /// would cross `floor_x`, and the survivors' left edge comes back.
    /// Pass `ui` to actually draw what survives.
    fn plugShedFields(self: *App, ui: ?*@import("ui.zig").Ui, it: *const plugpkg.Item, floor_x: f32, y: f32, right: f32) f32 {
        const cw = self.renderer.cell_w;
        const ch = self.renderer.cell_h;
        const row_h = self.bar_h;
        var fx = right;
        var fi = it.fields_n;
        while (fi > 0) {
            fi -= 1;
            const v = it.fields[fi].value.get();
            if (v.len == 0) continue;
            const w = @as(f32, @floatFromInt(v.len)) * cw + cw;
            if (fx - w < floor_x) break;
            fx -= w;
            if (ui) |u| _ = u.textOver(fx, y + (row_h - ch) / 2, v, th.bar_fg);
        }
        return fx;
    }

    /// The title's floor against the fields: it is guaranteed half the
    /// row, so a field that would cross into that sheds.
    fn plugFieldsFloor(self: *App, it: *const plugpkg.Item, x: f32, cols: usize) f32 {
        const half: usize = @max(8, cols / 2);
        const claim: f32 = @floatFromInt(@min(it.title.get().len, half));
        return x + claim * self.renderer.cell_w + self.renderer.cell_w;
    }

    /// The top-level row a flat index belongs to: itself for a parent,
    /// the nearest preceding parent for a child.
    pub fn plugParentOf(self: *App, idx: usize) usize {
        const items = self.plug.slice();
        if (items.len == 0) return 0;
        var i = @min(idx, items.len - 1);
        while (i > 0 and items[i].depth > 0) i -= 1;
        return i;
    }

    /// Collapse: children render only inside the SELECTED group —
    /// headlines scan, the group you are on reads. Selection can never
    /// land on a hidden row, because being selected is what makes a
    /// group visible; j/k walk the flat list and the collapse follows.
    pub fn plugVisible(self: *App, idx: usize) bool {
        const items = self.plug.slice();
        if (idx >= items.len or items[idx].depth == 0) return true;
        return self.plugParentOf(idx) == self.plugParentOf(self.plug_sel);
    }

    /// How many children this parent holds — the ▸ affordance's number.
    pub fn plugChildCount(self: *App, idx: usize) usize {
        const items = self.plug.slice();
        if (idx >= items.len or items[idx].depth > 0) return 0;
        var n: usize = 0;
        while (idx + 1 + n < items.len and items[idx + 1 + n].depth > 0) n += 1;
        return n;
    }

    /// Rows this item takes: a parent is one (titles scan), a child
    /// wraps (prose reads). The fold walk and the draw loop both call
    /// this, which is what keeps the fold honest.
    fn plugRowLines(self: *App, it: *const plugpkg.Item, tx: f32, right: f32, cols: usize) usize {
        if (it.depth == 0) return 1;
        const cw = self.renderer.cell_w;
        const x = self.plugTitleX(it, tx);
        const fx = self.plugShedFields(null, it, self.plugFieldsFloor(it, x, cols), 0, right);
        var wit = @import("ui.zig").WrapIter{
            .s = it.title.get(),
            .cols = @intFromFloat(@max(4, (fx - x) / cw - 1)),
        };
        const rest_cols: usize = @intFromFloat(@max(4, (right - x) / cw));
        var lines: usize = 0;
        while (wit.next()) |_| {
            lines += 1;
            wit.cols = rest_cols;
        }
        return @max(1, lines);
    }

    fn drawPlugin(self: *App, ui: *@import("ui.zig").Ui, r: panespkg.Rect, top: f32) void {
        const cw = self.renderer.cell_w;
        const ch = self.renderer.cell_h;
        const row_h = self.bar_h;
        const bg = self.glassBg(th.bar_bg);
        const tx = r.x + self.m.gutter;
        var y = top;
        var clipbuf: [256]u8 = undefined;
        const cols: usize = @intFromFloat(@max(8, (r.w - self.m.gutter * 2) / cw));

        if (self.plug_loading.load(.acquire)) {
            _ = ui.text(tx, y + (row_h - ch) / 2, "asking…", th.bar_fg, bg);
            return;
        }
        // "This plugin says there is nothing" and "we could not reach this
        // plugin" are different facts. A panel that renders both as blank
        // makes the second one invisible.
        if (!self.plug.live) {
            const msg = if (self.plug.err.n > 0) self.plug.err.get() else "no answer";
            _ = ui.text(tx, y + (row_h - ch) / 2, msg, th.ed_err, bg);
            return;
        }
        if (self.plug.n == 0) {
            _ = ui.text(tx, y + (row_h - ch) / 2, "nothing to show", th.bar_fg, bg);
            return;
        }

        // The action menu and the message both take a row off the top of
        // what the list can use, because both are drawn below it.
        const menu_rows: f32 = if (self.plug_mode == .rows) 0 else blk: {
            const it = self.plugItemLocked() orelse break :blk 0;
            break :blk @floatFromInt(it.actions_n);
        };
        const reserved = (if (self.plug.more > 0) row_h else 0) +
            (if (self.plug_msg_len > 0) row_h else 0) + menu_rows * row_h;
        const avail = r.y + r.h - top - reserved;
        const bottom = top + avail;
        const right = r.x + r.w - self.m.gutter;
        const items = self.plug.slice();
        const gap = self.m.gap * 2; // breathing room between groups

        // Selection-follows scroll over the VISIBLE rows. Group gaps
        // count in the fit walk — a fold that forgot them would lie by
        // one row per group.
        if (self.plug_sel < self.plug_scroll) self.plug_scroll = self.plug_sel;
        if (self.plug_scroll >= items.len) self.plug_scroll = 0;
        if (!self.plugVisible(self.plug_scroll)) self.plug_scroll = self.plugParentOf(self.plug_scroll);
        while (self.plug_scroll < self.plug_sel) {
            var used: f32 = 0;
            var fits = false;
            var first = true;
            var i = self.plug_scroll;
            while (i < items.len) : (i += 1) {
                if (!self.plugVisible(i)) continue;
                var lh = @as(f32, @floatFromInt(self.plugRowLines(&items[i], tx, right, cols))) * row_h;
                if (items[i].depth == 0 and !first) lh += gap;
                first = false;
                used += lh;
                if (used > avail) break;
                if (i == self.plug_sel) {
                    fits = true;
                    break;
                }
            }
            if (fits) break;
            var nxt = self.plug_scroll + 1;
            while (nxt < items.len and !self.plugVisible(nxt)) nxt += 1;
            if (nxt >= items.len) break;
            self.plug_scroll = nxt;
        }

        // The draw walk records what it drew — the click map and the ctl
        // introspection read the DRAWN truth rather than recomputing it.
        self.plug_hit_n = 0;
        self.plug_drawn = .{ self.plug_scroll, self.plug_scroll };
        var first_drawn = true;
        var idx = self.plug_scroll;
        while (idx < items.len) : (idx += 1) {
            if (!self.plugVisible(idx)) continue;
            const it = &items[idx];
            const x = self.plugTitleX(it, tx);
            const title_full = it.title.get();
            const lines = self.plugRowLines(it, tx, right, cols);
            var lh = @as(f32, @floatFromInt(lines)) * row_h;
            if (it.depth == 0 and !first_drawn) lh += gap;
            if (!first_drawn and y + lh > bottom) break;
            if (it.depth == 0 and !first_drawn) y += gap;
            first_drawn = false;
            if (self.plug_hit_n < self.plug_hit.len) {
                self.plug_hit[self.plug_hit_n] = .{ y, y + @as(f32, @floatFromInt(lines)) * row_h, @floatFromInt(idx) };
                self.plug_hit_n += 1;
            }
            self.plug_drawn[1] = idx;

            if (idx == self.plug_sel)
                self.drawRowSelection(ui, r, y, @as(f32, @floatFromInt(lines)) * row_h);

            // State first and always — it is the one thing every item has
            // and the thing a human scans down. (plugTitleX already made
            // room; children are indented rather than dropped — the only
            // structural difference between a list and a tree.)
            if (it.state.n > 0)
                _ = ui.textOver(tx, y + (row_h - ch) / 2, it.state.get(), th.accent);

            // Fields right-aligned, values only — the label is the column
            // header a list does not have room for. The title is
            // guaranteed half the row; a field that would cross into that
            // sheds, and it sheds WHOLE (right-aligned fragments of two
            // different fields read as one wrong value). Least-important-
            // first is therefore the field order a plugin should declare.
            const fx = self.plugShedFields(ui, it, self.plugFieldsFloor(it, x, cols), y, right);

            if (it.depth == 0) {
                // A parent is a title: one line, stopped a cell short of
                // whatever fields survived, so the two never overprint.
                // The fold glyph says children exist without showing them.
                var x2 = x;
                if (self.plugChildCount(idx) > 0) {
                    const open = self.plugParentOf(self.plug_sel) == idx;
                    _ = ui.textOver(x2, y + (row_h - ch) / 2, if (open) "▾" else "▸", th.bar_fg);
                    x2 += 2 * cw;
                }
                const title_cols: usize = @intFromFloat(@max(1.0, (fx - x2) / cw - 1.0));
                const title = @import("ui.zig").clip(&clipbuf, title_full, @min(cols, title_cols));
                _ = ui.textOver(x2, y + (row_h - ch) / 2, title, th.bar_value);
                y += row_h;
            } else {
                // A child is prose — a digest bullet, a sub-item — and
                // prose wraps where a title would clip, one shade down so
                // the headlines stay the thing a scan catches. The first
                // line still stops short of the fields; continuation
                // lines run the full row.
                var wit = @import("ui.zig").WrapIter{
                    .s = title_full,
                    .cols = @intFromFloat(@max(4, (fx - x) / cw - 1)),
                };
                const rest_cols: usize = @intFromFloat(@max(4, (right - x) / cw));
                var drew: usize = 0;
                while (wit.next()) |line| {
                    _ = ui.textOver(x, y + (row_h - ch) / 2, line, th.bar_fg);
                    y += row_h;
                    drew += 1;
                    wit.cols = rest_cols;
                }
                if (drew == 0) y += row_h; // an empty title still holds its row
            }

            // The actions hang UNDER the row they belong to rather than
            // replacing the list: the item you are acting on is the context
            // for the choice, and a menu that hides it takes that away.
            if (idx != self.plug_sel or self.plug_mode == .rows) continue;
            for (it.actions[0..it.actions_n], 0..) |*a, ai| {
                const on = ai == self.plug_act_sel;
                if (on) self.drawRowSelection(ui, r, y, row_h);
                var ax = tx + 2 * cw;
                // A confirm action is marked before it is chosen, so the
                // human knows which way Enter is about to go.
                const mark: []const u8 = if (a.confirm) "!" else "\u{203a}";
                ax += ui.text(ax, y + (row_h - ch) / 2, mark, if (a.confirm) th.ed_err else th.accent, bg);
                ax += cw;
                const label = @import("ui.zig").clip(&clipbuf, a.label.get(), cols);
                ax += ui.text(ax, y + (row_h - ch) / 2, label, if (on) th.bar_value else th.bar_fg, bg);
                if (on and self.plug_mode == .confirm) {
                    ax += cw;
                    _ = ui.text(ax, y + (row_h - ch) / 2, "confirm? y/n", th.ed_err, bg);
                }
                if (on and self.plug_mode == .input) {
                    // The one-line payload, tail-first: however long the
                    // typing runs, the caret stays on screen.
                    ax += cw;
                    const typed = self.plug_input[0..self.plug_input_len];
                    const room: usize = @intFromFloat(@max(4, (right - ax) / cw - 1));
                    var show = typed;
                    if (typed.len > room) {
                        var cutb = typed.len - room;
                        while (cutb < typed.len and typed[cutb] & 0xC0 == 0x80) cutb += 1;
                        show = typed[cutb..];
                    }
                    ax += ui.text(ax, y + (row_h - ch) / 2, show, th.bar_value, bg);
                    ui.rect(ax, y + (row_h - ch) / 2, cw / 4, ch, th.accent);
                }
                y += row_h;
            }
        }
        if (self.plug.more > 0) {
            var mb: [64]u8 = undefined;
            const m = std.fmt.bufPrint(&mb, "+{d} more", .{self.plug.more}) catch "+more";
            _ = ui.text(tx, y + (row_h - ch) / 2, m, th.bar_fg, bg);
            y += row_h;
        }
        // What the last action said, refusals included. A human pressed a
        // key and something has to answer.
        if (self.plug_msg_len > 0) {
            const msg = @import("ui.zig").clip(&clipbuf, self.plug_msg[0..self.plug_msg_len], cols);
            _ = ui.text(tx, y + (row_h - ch) / 2, msg, th.bar_fg, bg);
        }
    }

    fn drawSearch(self: *App, ui: *@import("ui.zig").Ui, r: panespkg.Rect, top: f32) void {
        const cw = self.renderer.cell_w;
        const ch = self.renderer.cell_h;
        const row_h = self.bar_h;
        const bg = self.glassBg(th.bar_bg);
        const tx = r.x + self.m.gutter;
        var y = top;
        var clipbuf: [256]u8 = undefined;
        const cols: usize = @intFromFloat(@max(4, (r.w - self.m.gutter * 2) / cw));

        // The box. The caret only shows while the box has the keys —
        // it is the panel's one telegraph for which half you are in.
        var qbuf: [160]u8 = undefined;
        const q = std.fmt.bufPrint(&qbuf, "/{s}", .{self.sr_query[0..self.sr_query_len]}) catch "/";
        const qw = ui.text(tx, y + (row_h - ch) / 2, q, th.bar_value, bg);
        if (self.sr_typing and self.side_focus)
            ui.rect(tx + qw, y + (row_h - ch) / 2, cw / 4, ch, th.accent);
        y += row_h;
        ui.rect(r.x, y, r.w, self.sep, th.sep);
        y += self.sep + self.m.gap;

        if (self.sr_running.load(.acquire)) {
            _ = ui.text(tx, y + (row_h - ch) / 2, "searching…", th.bar_fg, bg);
            return;
        }
        if (self.sr.query.len == 0) {
            _ = ui.text(tx, y + (row_h - ch) / 2, "type, then ⏎", th.bar_fg, bg);
            return;
        }
        if (self.sr.hits.len == 0) {
            var nb: [96]u8 = undefined;
            const msg = std.fmt.bufPrint(&nb, "no results in {d} files", .{self.sr.scanned}) catch "no results";
            _ = ui.text(tx, y + (row_h - ch) / 2, msg, th.bar_fg, bg);
            return;
        }

        // A count line, because "is this all of them" is the first
        // question a result list raises — and, for a list nobody typed,
        // what it is a list OF, since the box above says something else.
        var cbuf: [160]u8 = undefined;
        const summary = switch (self.sr_kind) {
            .grep => std.fmt.bufPrint(&cbuf, "{d} in {d} files{s}", .{
                self.sr.hits.len,
                self.sr.files.len,
                @as([]const u8, if (self.sr.truncated) " (capped)" else ""),
            }) catch "",
            .references => std.fmt.bufPrint(&cbuf, "{d} references to {s}{s}", .{
                self.sr.hits.len,
                self.sr.query,
                @as([]const u8, if (self.sr.truncated) " (capped)" else ""),
            }) catch "",
        };
        _ = ui.text(tx, y + (row_h - ch) / 2, summary, th.bar_fg, bg);
        y += row_h;

        // Keep the selection on screen: rows are hits, and the file
        // headers between them mean a fixed window would drift.
        const avail: usize = @intFromFloat(@max(1, (r.y + r.h - y) / row_h));
        const per_hit: usize = 1;
        const window = avail -| 2;
        if (self.sr_sel < self.sr_top) self.sr_top = self.sr_sel;
        if (self.sr_sel >= self.sr_top + window / per_hit) self.sr_top = self.sr_sel - window / per_hit + 1;

        var last_file: ?u32 = null;
        var idx = self.sr_top;
        while (idx < self.sr.hits.len) : (idx += 1) {
            if (y + row_h > r.y + r.h) break;
            const hit = self.sr.hits[idx];
            if (last_file == null or last_file.? != hit.file) {
                const path = self.sr.files[hit.file];
                const s = @import("ui.zig").clip(&clipbuf, path, cols);
                _ = ui.text(tx, y + (row_h - ch) / 2, s, th.bar_value, bg);
                y += row_h;
                last_file = hit.file;
                if (y + row_h > r.y + r.h) break;
            }
            const selected = idx == self.sr_sel;
            if (selected) self.drawRowSelection(ui, r, y, row_h);
            var lb: [280]u8 = undefined;
            const line = std.fmt.bufPrint(&lb, "{d}: {s}", .{ hit.line, hit.text }) catch hit.text;
            const s = @import("ui.zig").clip(&clipbuf, line, cols -| 2);
            _ = ui.textOver(tx + 2 * cw, y + (row_h - ch) / 2, s, if (selected) th.bar_value else th.bar_fg);
            y += row_h;
        }
    }

    /// Resolve a workspace-relative path against the active space's
    /// root. Review findings are stored relative to the repo, and the
    /// editor wants somewhere it can actually open.
    pub fn spaceRoot(self: *App, buf: []u8, rel: []const u8) ?[]const u8 {
        self.draw_lock.lock();
        const label = self.activeSpace().label();
        var root: []const u8 = "";
        for (self.pal_items) |e| {
            if (std.mem.eql(u8, e.name, label)) {
                root = e.root;
                break;
            }
        }
        self.draw_lock.unlock();
        if (root.len == 0) return null;
        return std.fmt.bufPrint(buf, "{s}/{s}", .{ root, rel }) catch null;
    }

    /// Name a directory the way a human would.
    ///
    /// The WORKSPACE name when the path is inside one — that is the word
    /// people actually use — with the remainder appended only when it
    /// adds something. Falling back to the last path segment alone is
    /// what made the deck label this very session "app": true, and
    /// useless, because every repo has one.
    ///
    /// Shared by the ask form's provenance line and the deck's rows, so
    /// the same directory reads the same in both. Caller holds draw_lock.
    pub fn cwdLabel(self: *App, cwd: []const u8, buf: []u8) []const u8 {
        if (cwd.len == 0) return "";
        for (self.pal_items) |e| {
            if (e.root.len == 0) continue;
            if (!std.mem.startsWith(u8, cwd, e.root)) continue;
            if (cwd.len != e.root.len and cwd[e.root.len] != '/') continue;
            if (cwd.len == e.root.len) return std.fmt.bufPrint(buf, "{s}", .{e.name}) catch e.name;
            return std.fmt.bufPrint(buf, "{s}{s}", .{ e.name, cwd[e.root.len..] }) catch e.name;
        }
        const tail = if (cwd.len > 48) cwd[cwd.len - 48 ..] else cwd;
        return std.fmt.bufPrint(buf, "{s}{s}", .{ @as([]const u8, if (tail.len < cwd.len) "…" else ""), tail }) catch cwd;
    }

    /// Word-wrap into the panel. Returns the y after the last line.
    fn wrapText(self: *App, ui: *@import("ui.zig").Ui, s: []const u8, x: f32, y0: f32, cols: usize, row_h: f32, ch: f32, fg: [4]u8, bg: [4]u8) f32 {
        var y = y0;
        var rest = s;
        while (rest.len > 0) {
            var take = @min(rest.len, cols);
            if (take < rest.len) {
                // Break at the last space that fits, else hard-break —
                // a long path or id has no spaces and must still render.
                if (std.mem.lastIndexOfScalar(u8, rest[0..take], ' ')) |sp| {
                    if (sp > 0) take = sp;
                }
            }
            _ = ui.text(x, y + (row_h - ch) / 2, rest[0..take], fg, bg);
            y += row_h;
            rest = rest[take..];
            while (rest.len > 0 and rest[0] == ' ') rest = rest[1..];
            _ = self;
        }
        return y;
    }

    /// Put the pin for the panel's plugin on the clipboard, ready to paste.
    ///
    /// In the language your config is actually written in. Handing a Go
    /// user a TypeScript line, or either of them a bare hex string they
    /// then have to wrap themselves, is the kind of "here is the
    /// information, you do the rest" that means nobody does the rest.
    pub fn copyPluginPin(self: *App) void {
        var line: [512]u8 = undefined;
        var len: usize = 0;
        {
            self.draw_lock.lock();
            defer self.draw_lock.unlock();
            if (self.plug_name_len == 0) return;
            const p = self.plugins.find(self.plug_name[0..self.plug_name_len]) orelse return;
            // Nothing to pin: a plugin declared by PATH has no artifact to
            // pin, and one rook has not run yet has no hash to offer.
            if (p.spec.source.len == 0 or p.state != .up) return;

            var dirbuf: [1024]u8 = undefined;
            const lang: envpkg.Lang = if (cfgpkg.configDir(&dirbuf)) |dir|
                if (envpkg.findSource(self.io, dir)) |src| src.lang else .go
            else
                .go;

            var gbuf: [256]u8 = undefined;
            var gw: std.Io.Writer = .fixed(&gbuf);
            for (p.spec.grants, 0..) |g, i| {
                if (i > 0) gw.writeAll(", ") catch break;
                gw.print("\"{s}\"", .{g}) catch break;
            }
            const grants = gbuf[0..gw.end];

            const s2 = switch (lang) {
                // The Go SDK's node-list shape: a declaration to paste
                // into rook.Main(...), trailing comma included.
                .go => std.fmt.bufPrint(&line, "rook.Plugin{{Source: \"{s}\", SHA256: \"{s}\", Grants: []string{{{s}}}}},", .{ p.spec.source, &p.pin, grants }),
                .ts => std.fmt.bufPrint(&line, "e.pluginPinned(\"{s}\", \"{s}\", [{s}]);", .{ p.spec.source, &p.pin, grants }),
            } catch return;
            len = s2.len;
            self.plugSay("pin copied");
            self.scene_dirty = true;
        }
        self.setPasteboard(line[0..len]);
    }

    /// Show the pending diff.
    ///
    /// `focused` is false when rook opens this ITSELF, which is the common
    /// case: changes landing is not a reason to take someone's keys
    /// mid-sentence. It is visible, and it is one ⌃L away.
    pub fn showConfigPreview(self: *App, focused: bool) void {
        self.draw_lock.lock();
        defer self.draw_lock.unlock();
        self.side_panel = .config;
        self.side_open = true;
        if (focused) self.side_focus = true;
        self.cfg_sel = 0;
        self.relayoutLocked();
        self.scene_dirty = true;
    }

    /// The preview's keys. One verb, because there is one: a diff is
    /// applied whole. Per-row Enter would imply you could take half a
    /// config, and half a config is not a state the graph has.
    pub fn configKeyLocked(self: *App, bytes: []const u8) void {
        const n = self.env_diff.slice().len;
        var i: usize = 0;
        while (i < bytes.len) {
            const b = bytes[i];
            if (b == 0x1b and i + 2 < bytes.len and bytes[i + 1] == '[') {
                switch (bytes[i + 2]) {
                    'A' => self.cfg_sel -|= 1,
                    'B' => self.cfg_sel = @min(self.cfg_sel + 1, n -| 1),
                    else => {},
                }
                i += 3;
                continue;
            }
            switch (b) {
                0x1b => {
                    self.side_focus = false;
                    self.scene_dirty = true;
                    return;
                },
                'k', 0x10 => self.cfg_sel -|= 1,
                'j', 0x0e => self.cfg_sel = @min(self.cfg_sel + 1, n -| 1),
                'g' => self.cfg_sel = 0,
                'G' => self.cfg_sel = n -| 1,
                // Queued, not done: applyEnv takes draw_lock and the key
                // path is holding it.
                '\r', '\n', 'a' => self.env_apply_wanted = true,
                else => {},
            }
            i += 1;
        }
        self.scene_dirty = true;
    }

    fn drawConfig(self: *App, ui: *@import("ui.zig").Ui, r: panespkg.Rect, top: f32) void {
        const cw = self.renderer.cell_w;
        const ch = self.renderer.cell_h;
        const row_h = self.bar_h;
        const bg = self.glassBg(th.bar_bg);
        const tx = r.x + self.m.gutter;
        var y = top;
        var clipbuf: [256]u8 = undefined;
        const cols: usize = @intFromFloat(@max(8, (r.w - self.m.gutter * 2) / cw));

        const d = &self.env_diff;
        if (self.env_checking.load(.acquire)) {
            _ = ui.text(tx, y + (row_h - ch) / 2, "running your config…", th.bar_fg, bg);
            return;
        }
        if (!d.ok) {
            // The program's OWN error, wrapped over as many rows as it
            // takes. A compile error names a line, and truncating it to
            // one row would throw away the only useful part.
            var it = std.mem.splitScalar(u8, d.err.get(), '\n');
            while (it.next()) |ln| {
                if (ln.len == 0) continue;
                if (y + row_h > r.y + r.h) break;
                _ = ui.text(tx, y + (row_h - ch) / 2, @import("ui.zig").clip(&clipbuf, ln, cols), th.ed_err, bg);
                y += row_h;
            }
            return;
        }
        if (d.empty()) {
            _ = ui.text(tx, y + (row_h - ch) / 2, "no pending changes", th.bar_fg, bg);
            return;
        }

        const avail = r.y + r.h - top - row_h; // the footer keeps a row
        const bottom = top + avail;
        for (d.slice(), 0..) |*c, idx| {
            if (y + row_h > bottom) break;
            if (idx == self.cfg_sel) self.drawRowSelection(ui, r, y, row_h);
            var x = tx;
            // The mark carries the meaning and the colour repeats it, so
            // the shape is readable without the colour.
            const mark: []const u8, const col = switch (c.kind) {
                // The theme already names the added/removed axis; a
                // config diff is a diff.
                .add => .{ "+", th.diff_add },
                .remove => .{ "-", th.diff_del },
                .change => .{ "~", th.diff_hunk },
            };
            // textOver: a per-glyph background would punch the selection
            // out from behind the row it marks.
            x += ui.textOver(x, y + (row_h - ch) / 2, mark, col);
            x += cw;
            var idbuf: [256]u8 = undefined;
            _ = ui.textOver(x, y + (row_h - ch) / 2, @import("ui.zig").clip(&idbuf, c.id.get(), cols -| 2), th.bar_value);
            y += row_h;
            // The detail gets its OWN line, indented. Side panes are narrow
            // and an id is long, so sharing a row truncated the change to
            // "value: 1…" — which is exactly the part you opened this to
            // read. The id says which node; this says what happens to it.
            if (c.detail.get().len > 0 and y + row_h <= bottom) {
                if (idx == self.cfg_sel) self.drawRowSelection(ui, r, y, row_h);
                _ = ui.textOver(tx + 2 * cw, y + (row_h - ch) / 2, @import("ui.zig").clip(&clipbuf, c.detail.get(), cols -| 2), th.bar_fg);
                y += row_h;
            }
        }
        if (d.more > 0) {
            var mb: [64]u8 = undefined;
            _ = ui.text(tx, y + (row_h - ch) / 2, std.fmt.bufPrint(&mb, "+{d} more", .{d.more}) catch "+more", th.bar_fg, bg);
            y += row_h;
        }
        // The verb, spelled out. Nothing else in this panel says what to
        // do with it, and a list of changes you cannot act on is a report.
        _ = ui.text(tx, r.y + r.h - row_h + (row_h - ch) / 2, "\u{23ce} apply   esc close", th.bar_fg, bg);
    }

    /// The welcome screen.
    ///
    /// OPAQUE and full-window, not a card over the terminal. Everything
    /// else rook floats — the palette, the which-key sheet — is something
    /// you invoked over work you were already doing. This is the opposite:
    /// there is no work behind it yet, and a translucent panel over an
    /// empty shell would read as an accident rather than a greeting.
    fn drawWelcome(self: *App, ui: *@import("ui.zig").Ui) void {
        const cw = self.renderer.cell_w;
        const ch = self.renderer.cell_h;
        const row = self.bar_h;

        ui.rect(0, 0, self.px_w, self.px_h, th.bar_bg);

        // Centred as a BLOCK, not line by line: ragged centring on a list
        // of choices makes the choices hard to compare, which is the one
        // thing this screen exists to let you do.
        const body_w = 52 * cw;
        const left = @max(cw * 2, (self.px_w - body_w) / 2);
        var y = @max(row, (self.px_h - row * 12) / 2);

        const line = struct {
            fn at(u: *@import("ui.zig").Ui, x: f32, yy: f32, s2: []const u8, c: [4]u8) void {
                _ = u.text(x, yy, s2, c, th.bar_bg);
            }
        };

        line.at(ui, left, y, "rook", th.accent);
        y += row;
        line.at(ui, left, y, "a terminal, a multiplexer and an editor", th.bar_fg);
        y += row * 2;

        // What is about to happen, before it happens. The config model is
        // the one genuinely surprising thing about rook, and finding it out
        // by having a file appear is worse than being told.
        line.at(ui, left, y, "Your configuration is a program.", th.bar_value);
        y += row;
        line.at(ui, left, y, "rook runs it, shows what would change, and", th.bar_fg);
        y += row;
        line.at(ui, left, y, "applies nothing until you say so.", th.bar_fg);
        y += row * 2;

        line.at(ui, left, y, "Which language?", th.bar_value);
        y += row;

        for (setup_choices, 0..) |c, i| {
            const on = i == self.welcome_sel;
            if (on) {
                // The same rounded selection the side pane uses, so "the
                // thing Enter acts on" looks identical everywhere.
                ui.roundRect(left - cw, y, body_w + cw, row, th.chip_active_bg, .{ .radius = self.m.radius });
            }
            // textOver, not text: a per-glyph background would punch the
            // selection out from behind the very row it marks.
            var x = left;
            x += ui.textOver(x, y + (row - ch) / 2, if (on) "\u{203a} " else "  ", th.accent);
            x += ui.textOver(x, y + (row - ch) / 2, c.label, if (on) th.bar_value else th.bar_fg);
            _ = ui.textOver(left + 16 * cw, y + (row - ch) / 2, c.detail, th.bar_fg);
            y += row;
        }
        y += row;
        line.at(ui, left, y, "\u{2191}\u{2193} move   \u{23ce} choose   esc skip for now", th.bar_fg);
    }

    fn drawPalette(self: *App, ui: *@import("ui.zig").Ui) void {
        const cw = self.renderer.cell_w;
        const row_h = self.bar_h;
        const gut = self.m.gutter;
        const shown = @min(self.pal_nfiltered, 12);
        const w = @min(self.px_w - 4 * cw, 72 * cw);
        // A row per result, the input row, the rule under it, and a pad
        // band top and bottom — a list whose last row is flush with the
        // card's edge reads as a list that got cut off.
        const h = row_h * @as(f32, @floatFromInt(shown + 1)) + self.sep + self.m.gap * 2;
        const x = (self.px_w - w) / 2;
        const y = self.contentY() + self.renderer.cell_h;

        // Elevation, then the card. A modal that shares an edge with the
        // work behind it reads as part of it; the shadow is the only
        // thing that says "this is over your terminal, and temporary".
        ui.shadow(x, y + self.m.gap, w, h, self.m.radius_card, self.m.elevation, .{ 0, 0, 0, 150 });
        // A quiet border, not an accent one. The accent is the SELECTED
        // row's mark; spending it on the container too meant the eye had
        // two equally loud things to find in a list you open to pick one
        // thing from.
        ui.roundRect(x, y, w, h, th.bar_bg, .{
            .radius = self.m.radius_card,
            .border = self.sep,
            .border_color = th.sep,
        });

        // Input row. The prompt names the mode — with two pickers on two
        // different keys, "which list am I in" has to be answerable
        // without reading the rows.
        // Every run inside the card is drawn OVER it — a per-glyph
        // background would square off the corners it sits inside.
        var tx = x + gut;
        const ty = y + self.m.gap + (row_h - self.renderer.cell_h) / 2;
        tx += ui.textOver(tx, ty, switch (self.pal_mode) {
            .workspaces => "workspace ",
            .commands => "command ",
            .files => "file ",
            // A first press with nothing declared would otherwise be an
            // empty modal with no explanation. The prompt IS the empty
            // state; there is nowhere else on a palette to put one.
            .plugins => if (self.plugins.items.len == 0) "no plugins declared " else "plugin ",
            .actions => "action ",
        }, th.bar_fg);
        tx += ui.textOver(tx, ty, self.pal_input[0..self.pal_input_len], th.bar_value);
        ui.rect(tx, ty, cw / 4, self.renderer.cell_h, th.accent); // caret

        // What you typed and what matched are two different things, and
        // the rule is what says so.
        ui.rect(x, y + self.m.gap + row_h, w, self.sep, th.sep);
        var ry = y + self.m.gap + row_h + self.sep;
        if (self.pal_nfiltered == 0) {
            _ = ui.textOver(x + gut, ry + (row_h - self.renderer.cell_h) / 2, "no matches", th.bar_fg);
            return;
        }
        for (self.pal_filtered[0..shown], 0..) |item_i, vi| {
            const selected = vi == self.pal_sel;
            if (selected) {
                // Inset from the card's edge, so the highlight reads as
                // a row IN the card rather than a band across it.
                const sx = x + self.m.gap;
                ui.roundRect(sx, ry, w - self.m.gap * 2, row_h, th.chip_active_bg, .{ .radius = self.m.radius });
                ui.rect(sx, ry + self.m.radius, self.sep * 2, row_h - self.m.radius * 2, th.accent);
            }
            const rty = ry + (row_h - self.renderer.cell_h) / 2;
            var lbl: [96]u8 = undefined;
            var kbuf: [16]u8 = undefined;
            // Both modes draw the same shape: a label on the left and one
            // quiet right-aligned detail that drops when it doesn't fit.
            const label, const detail = switch (self.pal_mode) {
                // Basename first, then the directory it lives in —
                // VS Code's own two-part row, and the shape that lets
                // you scan a column of names rather than a column of
                // paths that all start with "src/".
                .files => blk: {
                    const rel = self.pal_files.paths[item_i];
                    const cut = std.mem.lastIndexOfScalar(u8, rel, '/');
                    const base = if (cut) |c| rel[c + 1 ..] else rel;
                    const dir = if (cut) |c| rel[0..c] else "";
                    const l = std.fmt.bufPrint(&lbl, "{s}", .{base}) catch base;
                    break :blk .{ l, dir };
                },
                // The KIND is the quiet detail: it is how you tell a
                // quick fix from a whole-file source action at a
                // glance, and it is what the titles do not say.
                .actions => blk: {
                    const a = self.pal_actions[item_i];
                    const l = std.fmt.bufPrint(&lbl, "{s}", .{a.title}) catch a.title;
                    break :blk .{ l, a.kind };
                },
                .workspaces => blk: {
                    const e = self.pal_items[item_i];
                    // Worktree children sit indented under their parent as
                    // "parent/name" — legible grouped AND filtered-apart.
                    const l = if (e.parent.len > 0)
                        std.fmt.bufPrint(&lbl, "  {s}/{s}", .{ e.parent, e.name }) catch e.name
                    else
                        e.name;
                    break :blk .{ l, e.root };
                },
                .plugins => blk: {
                    const p = &self.plugins.items[item_i];
                    // State on the right, because "declared" vs "failed"
                    // is the thing you want to see before you pick one —
                    // an empty panel and a dead plugin look identical.
                    break :blk .{ p.spec.name, @tagName(p.state) };
                },
                .commands => blk: {
                    const c = registrypkg.commands[item_i];
                    const l = std.fmt.bufPrint(&lbl, "{s}: {s}", .{ c.category, c.title }) catch c.title;
                    // The LIVE chord first (config's truth), then the
                    // hand-written hint — but ONLY for chords the
                    // binding table does not own: ⌘/⌃ chords live in
                    // code and the string stays true. A "<leader>…"
                    // hint with no live entry behind it names a chord
                    // that a rebind has since given to something else,
                    // and teaching it would send you to the wrong key.
                    // Last, the id — an unbound command still shows the
                    // name an agent or a config file would call it by.
                    const live = self.liveChordHint(c.action, c.arg, &kbuf);
                    const static_ok = c.keys.len > 0 and !std.mem.startsWith(u8, c.keys, "<leader>");
                    break :blk .{ l, live orelse if (static_ok) c.keys else c.id };
                },
            };
            _ = ui.textOver(x + gut, rty, label, if (selected) th.bar_value else th.bar_fg);
            const room = w - 2 * gut - @as(f32, @floatFromInt(label.len + 2)) * cw;
            // Cells, not bytes: "␣ g" is five bytes and three columns,
            // and the byte count would drop hints that plainly fit.
            const dcells = std.unicode.utf8CountCodepoints(detail) catch detail.len;
            if (@as(f32, @floatFromInt(dcells)) * cw < room)
                _ = ui.textOverRight(x + w - gut, rty, detail, th.bar_fg);
            ry += row_h;
        }
    }

    /// Fill one pane's slot of the cell buffer from its render state.
    /// The cursor renders only in the focused pane — the second half of
    /// the focus telegraph.
    /// The cursor state a fill bakes into the grid, as one comparable
    /// word: position when visible, a sentinel when hidden or offscreen.
    fn cursorKey(tm: *panespkg.Term) u32 {
        if (!tm.rs.cursor.visible) return 0xffff_ffff;
        const cur = tm.rs.cursor.viewport orelse return 0xffff_ffff;
        return (@as(u32, cur.y) << 16) | cur.x;
    }

    /// pane-dim: one channel slid toward the pane's own background.
    fn dimTo(c: u8, toward: u8, amt: f32) u8 {
        const cf: f32 = @floatFromInt(c);
        const tf: f32 = @floatFromInt(toward);
        return @intFromFloat(std.math.clamp(@round(cf + (tf - cf) * amt), 0, 255));
    }

    fn fillPane(self: *App, tm: *panespkg.Term, focused: bool, cells: []renderpkg.CellData, cols: usize, rows: usize) void {
        const colors = &tm.rs.colors;
        const default_bg = colors.background;
        const default_fg = colors.foreground;
        const row_cells = tm.rs.row_data.items(.cells);
        const row_sels = tm.rs.row_data.items(.selection);
        const cellw_px: u16 = @intCast(self.renderer.cellw_px);
        // DECTCEM hide (TUIs that paint their own cursor, e.g. claude
        // code's inverse-space block) must actually hide ours. The
        // blink phase is one more gate — solid whenever blinking
        // doesn't apply, so this reads it blindly.
        const show_cursor = focused and tm.rs.cursor.visible and self.blink_phase_on;
        // config `pane-dim`: the unfocused pane's colors slide toward
        // its background. The background itself stays put — the pane
        // fades, it doesn't repaint.
        const dim: f32 = if (focused) 0 else self.pane_dim;
        for (0..rows) |y| {
            const raws = row_cells[y].items(.raw);
            const styles = row_cells[y].items(.style);
            // The codepoints AFTER the base, for cells holding a
            // grapheme cluster. The library keeps them beside the cell
            // rather than in it.
            const graphemes = row_cells[y].items(.grapheme);
            var prev_wide: ?renderpkg.GlyphLoc = null;
            for (0..cols) |x| {
                const raw = &raws[x];
                const styled = raw.style_id != 0;
                const st: vt.Style = if (styled) styles[x] else .{};

                var bg_explicit = true;
                var bg = st.bg(raw, &colors.palette) orelse blk: {
                    bg_explicit = false;
                    break :blk default_bg;
                };
                if (row_sels[y]) |sr| {
                    if (x >= sr[0] and x <= sr[1]) {
                        bg = .{ .r = th.sel_bg[0], .g = th.sel_bg[1], .b = th.sel_bg[2] };
                        bg_explicit = true;
                    }
                }
                var fg = st.fg(.{ .default = default_fg, .palette = &colors.palette });
                // Faint (SGR 2) is the renderer's job like inverse:
                // blend fg halfway toward bg (claude code's subdued
                // suggestion text is faint, not a palette gray).
                if (styled and st.flags.faint) {
                    fg = .{
                        .r = @intCast((@as(u16, fg.r) + bg.r) / 2),
                        .g = @intCast((@as(u16, fg.g) + bg.g) / 2),
                        .b = @intCast((@as(u16, fg.b) + bg.b) / 2),
                    };
                }

                const cp: u21 = switch (raw.content_tag) {
                    .codepoint, .codepoint_grapheme => raw.content.codepoint.data,
                    else => 0,
                };

                // A cell can hold several codepoints that are one
                // character — a flag, a skin tone, a ZWJ sequence — and
                // rasterizing only the base draws a boxed letter where
                // the flag should be. Encode the whole cluster and let
                // CoreText shape it, the same path the editor uses.
                var cbuf: [64]u8 = undefined;
                var clen: usize = 0;
                if (raw.content_tag == .codepoint_grapheme and graphemes[x].len > 0 and cp > 32) {
                    clen = std.unicode.utf8Encode(cp, &cbuf) catch 0;
                    for (graphemes[x]) |extra| {
                        if (clen + 4 > cbuf.len) break;
                        clen += std.unicode.utf8Encode(extra, cbuf[clen..]) catch break;
                    }
                }
                const cluster: ?[]const u8 = if (clen > 0) cbuf[0..clen] else null;

                var uvx: u16 = 0;
                var uvy: u16 = 0;
                var flags: u16 = 0;
                switch (raw.wide) {
                    .narrow => {
                        const loc_opt = if (cluster) |b|
                            self.renderer.glyphCluster(b, false)
                        else if (cp > 32) self.renderer.glyph(cp, false) else null;
                        if (loc_opt) |loc| {
                            uvx = loc.uvx;
                            uvy = loc.uvy;
                            flags = 1 | (@as(u16, @intFromBool(loc.color)) << 1);
                        }
                        prev_wide = null;
                    },
                    .wide => {
                        prev_wide = null;
                        const loc_opt = if (cluster) |b|
                            self.renderer.glyphCluster(b, true)
                        else if (cp > 32) self.renderer.glyph(cp, true) else null;
                        if (loc_opt) |loc| {
                            uvx = loc.uvx;
                            uvy = loc.uvy;
                            flags = 1 | (@as(u16, @intFromBool(loc.color)) << 1);
                            prev_wide = loc;
                        }
                    },
                    // The wide glyph's right half lives one cell over in
                    // the atlas slot.
                    .spacer_tail => {
                        if (prev_wide) |loc| {
                            uvx = loc.uvx + cellw_px;
                            uvy = loc.uvy;
                            flags = 1 | (@as(u16, @intFromBool(loc.color)) << 1);
                        }
                        prev_wide = null;
                    },
                    .spacer_head => prev_wide = null,
                }

                // Style.bg/fg deliberately don't apply the inverse flag
                // — that swap is the renderer's job (upstream ghostty
                // does the same in its cell fill). The cursor is one
                // more inversion on top, so cursor-over-inverse reads
                // normal.
                var inv = styled and st.flags.inverse;
                if (show_cursor) {
                    if (tm.rs.cursor.viewport) |cur| {
                        if (cur.x == x and cur.y == y) inv = !inv;
                    }
                }
                var eff_bg = if (inv) fg else bg;
                var eff_fg = if (styled and st.flags.invisible) eff_bg else if (inv) bg else fg;
                if (dim > 0) {
                    eff_fg = .{ .r = dimTo(eff_fg.r, default_bg.r, dim), .g = dimTo(eff_fg.g, default_bg.g, dim), .b = dimTo(eff_fg.b, default_bg.b, dim) };
                    eff_bg = .{ .r = dimTo(eff_bg.r, default_bg.r, dim), .g = dimTo(eff_bg.g, default_bg.g, dim), .b = dimTo(eff_bg.b, default_bg.b, dim) };
                }

                const cell_a: u8 = if (bg_explicit or inv) 255 else self.bg_alpha;
                cells[y * cols + x] = .{
                    .bg = .{ eff_bg.r, eff_bg.g, eff_bg.b, cell_a },
                    .fg = .{ eff_fg.r, eff_fg.g, eff_fg.b, 255 },
                    .uvx = uvx,
                    .uvy = uvy,
                    .flags = flags,
                };
            }
        }
    }

    /// Rasterize an editor pane: the editor lays out a styled RCell
    /// grid (pure text — the tested surface); this maps styles to
    /// colors and atlas glyphs. Last row is the editor's status line.
    fn fillEditorPane(self: *App, ed: *editorpkg.Editor, focused: bool, cells: []renderpkg.CellData, cols: usize, rows: usize) void {
        self.fillCellGrid(ed.fillGrid(cols, rows), ed, focused, cells, cols, rows);
    }

    /// The monitor draws through the editor's cell path, which is the
    /// point of it borrowing the editor's cell and style types: a new
    /// pane kind should not mean a new render path, a new theme mapping
    /// and a second place for a wide-glyph bug to live.
    fn fillMonitorPane(self: *App, m: *monitorpkg.Monitor, focused: bool, cells: []renderpkg.CellData, cols: usize, rows: usize) void {
        self.fillCellGrid(m.fillGrid(cols, rows), null, focused, cells, cols, rows);
    }

    /// The completion menu's card rect in scene pixels, or null when no
    /// menu is up.
    ///
    /// Shared with `ctl lsp`, which reports it: a rounded corner is only
    /// checkable from a screenshot if something says where to look, and
    /// a second copy of this arithmetic would be a second thing to keep
    /// in step with the fill.
    pub fn completionCardRect(self: *App, p: *panespkg.Pane) ?CardRect {
        const ed = switch (p.content) {
            .edit => |e| e,
            else => return null,
        };
        return self.cardRect(p, ed.cpl_geom orelse return null);
    }

    /// The documentation panel's card, beside the list.
    pub fn completionDocCardRect(self: *App, p: *panespkg.Pane) ?CardRect {
        const ed = switch (p.content) {
            .edit => |e| e,
            else => return null,
        };
        return self.cardRect(p, ed.cpl_doc_geom orelse return null);
    }

    /// A floating box's rect in scene pixels. `sel` is the pill's
    /// offset from the top, when the box has a highlighted row.
    pub const CardRect = struct { x: f32, y: f32, w: f32, h: f32, sel: ?f32 };

    fn cardRect(self: *App, p: *panespkg.Pane, box: editorpkg.CplBox) CardRect {
        const o = self.gridOrigin(p);
        const cw = self.renderer.cell_w;
        const ch = self.renderer.cell_h;
        return .{
            .x = o.x + @as(f32, @floatFromInt(box.col)) * cw,
            .y = o.y + @as(f32, @floatFromInt(box.row)) * ch,
            .w = @as(f32, @floatFromInt(box.w)) * cw,
            .h = @as(f32, @floatFromInt(box.h)) * ch,
            .sel = if (box.sel) |s| @as(f32, @floatFromInt(s)) * ch else null,
        };
    }

    /// The completion menu's background: a rounded card with a border,
    /// and a pill under the highlighted row.
    ///
    /// Drawn BEFORE the grid, not after — the menu's text is ordinary
    /// grid cells and has to land on top of this. That ordering is the
    /// whole reason the card can exist: the chrome's cards (the palette,
    /// the which-key sheet) draw over everything and carry their own
    /// text with `textOver`, which would cost the menu its place in `ctl
    /// dump` and every assertion that reads it.
    ///
    /// The rect is the box's cells exactly. It cannot overhang: the
    /// buffer cells around the box draw after this and paint their own
    /// backgrounds, so a halo would simply be erased. The padding is
    /// inside the box instead — its blank first and last row and column.
    /// A shadow is the one part of Zed's popover this arrangement gives
    /// up, for the same reason.
    fn drawCompletionCard(self: *App, enc: objc.Object, vp_w: f32, vp_h: f32, p: *panespkg.Pane) void {
        // The documentation panel first, so that where the two touch it
        // is the LIST's edge you see — the list is what you are picking
        // from, and the panel is what it is telling you about.
        if (self.completionDocCardRect(p)) |d| {
            self.renderer.drawRoundRect(enc, vp_w, vp_h, d.x, d.y, d.w, d.h, th.bar_bg, .{
                .radius = self.m.radius,
                .border = self.sep,
                .border_color = th.sep,
            });
        }
        const r = self.completionCardRect(p) orelse return;
        const x = r.x;
        const y = r.y;
        const w = r.w;
        const h = r.h;

        // A quiet border, like the palette's: the accent belongs to the
        // selected row and to the characters you typed, and a container
        // wearing it too gives the eye two things to find in a list you
        // opened to pick one thing from.
        self.renderer.drawRoundRect(enc, vp_w, vp_h, x, y, w, h, th.bar_bg, .{
            .radius = self.m.radius,
            .border = self.sep,
            .border_color = th.sep,
        });
        if (r.sel) |dy| {
            // Inset into the box's blank columns, so the highlight reads
            // as a row IN the card rather than a band across it.
            const inset = @round(self.renderer.cell_w / 2);
            self.renderer.drawRoundRect(
                enc,
                vp_w,
                vp_h,
                x + inset,
                y + dy,
                w - inset * 2,
                self.renderer.cell_h,
                th.chip_active_bg,
                .{ .radius = @round(self.m.radius * 0.6) },
            );
        }
    }

    /// Paint a styled cell grid into the renderer's buffer.
    ///
    /// `ed` is only for grapheme-cluster lookup and is null for tenants
    /// that never emit one (the monitor writes plain codepoints).
    fn fillCellGrid(self: *App, g: []const editorpkg.RCell, ed: ?*editorpkg.Editor, focused: bool, cells: []renderpkg.CellData, cols: usize, rows: usize) void {
        const cellw_px: u16 = @intCast(self.renderer.cellw_px);
        // config `pane-dim`, the editor's half: everything slides
        // toward ed_bg, status row included.
        const dim: f32 = if (focused) 0 else self.pane_dim;
        var prev_wide: ?renderpkg.GlyphLoc = null;
        for (g, 0..) |rc, i| {
            // The grid is walked flat, so the carry has to be dropped at
            // every row start — a tail in column zero (its left half
            // scrolled off) must not pick up the previous row's glyph.
            if (cols != 0 and i % cols == 0) prev_wide = null;
            const status_row = rows >= 1 and i >= (rows - 1) * cols;
            // Blink's off-phase draws the cursor cell as plain text —
            // the same terminal-cursor gate, in the editor's vocabulary.
            // Every editor pane, focused or not: the solid-marker design
            // read as "the cursor broke" from one pane over. Focus is
            // telegraphed by pane-dim and the mode chip instead.
            const st = if (rc.st == .cursor and !self.blink_phase_on)
                @TypeOf(rc.st).text
            else
                rc.st;
            var bg: [4]u8 = if (status_row) th.chip_active_bg else th.ed_bg;
            bg[3] = self.bg_alpha;
            var fg: [4]u8 = switch (st) {
                .text => if (status_row) th.bar_value else th.ed_fg,
                .dim => if (status_row) th.bar_fg else th.ed_dim,
                .sel => th.ed_fg,
                .cursor => th.ed_bg,
                .mode => th.bar_bg,
                .status => th.bar_value,
                .err => th.ed_err,
                .syn_comment => th.syn_comment,
                .syn_string => th.syn_string,
                .syn_number => th.syn_number,
                .syn_keyword => th.syn_keyword,
                .syn_type => th.syn_type,
                .syn_func => th.syn_func,
                .diff_add => th.diff_add,
                .diff_del => th.diff_del,
                .diff_hunk => th.diff_hunk,
                .diff_meta => th.diff_meta,
                // Directories borrow the function colour: an accent
                // that reads as structure in every builtin theme.
                .tree_dir => th.syn_func,
                // Chip text: ink on the mode's fill, set below.
                .mode_insert, .mode_visual => th.bar_bg,
                .buftab_on => th.bar_value,
                .buftab_off => th.bar_fg,
                // Diagnostics borrow colours every theme already tunes:
                // the editor's error red, the number colour for warnings
                // (amber-ish in every builtin), and dim for the rest —
                // an info that shouts is an info you learn to ignore.
                .diag_err => th.ed_err,
                .diag_warn => th.syn_number,
                .diag_info => th.ed_dim,
                // The menu borrows the chip vocabulary the buffer line
                // already uses, so a floating list reads as chrome
                // rather than as text somebody highlighted.
                .cpl_item => th.bar_fg,
                .cpl_detail => th.ed_dim,
                // The buffer's own syntax colours, so a function in the
                // menu is the colour a function is two lines up.
                .cpl_fn => th.syn_func,
                .cpl_type => th.syn_type,
                .cpl_kw => th.syn_keyword,
                .cpl_const => th.syn_number,
                // The BRIGHTEST ink the chrome has, not the accent.
                //
                // These are the characters you typed, and with fuzzy
                // matching they are scattered through the label rather
                // than being its first few — which makes them the only
                // thing saying why the row is in the list at all. The
                // accent collides: in the default theme it is the same
                // value as `syn_func`, so on a function candidate — the
                // commonest kind there is — the emphasis was invisible.
                // A near-white cannot collide with a syntax hue in any
                // theme, and brighter-than-its-neighbours is the closest
                // a character grid gets to Zed's bold.
                .cpl_match => th.bar_value,
                // The float. Its border recedes, its prose sits at the
                // chrome's ordinary weight, and the signature — the one
                // line you actually came for — is the brightest thing
                // in the box. A heading takes the accent, a link the
                // string colour, both of which every theme already
                // tunes to stand out from body text without shouting.
                .hov_border => th.ed_dim,
                .hov_prose => th.bar_fg,
                .hov_emph, .hov_code => th.bar_value,
                .hov_head => th.accent,
                .hov_link => th.syn_string,
            };
            switch (st) {
                .sel => bg = th.ed_sel_bg,
                .cursor => {
                    bg = th.ed_fg;
                    fg = if (status_row) th.chip_active_bg else th.ed_bg;
                },
                .mode => bg = th.accent,
                // Airline's convention: the mode is tellable from the
                // chip's colour alone — insert grows green, visual
                // borrows the type colour.
                .mode_insert => bg = th.diff_add,
                .mode_visual => bg = th.syn_type,
                // The buffer line: the app tab bar's chip vocabulary,
                // one scale down.
                .buftab_on => bg = th.chip_active_bg,
                .buftab_off => bg = th.bar_bg,
                // No `cpl_*` case here on purpose: every cell of the menu
                // is no-bg, and its background is the card drawn under
                // the grid — see drawCompletionCard.
                // The float lifts off the buffer on the chrome's fill,
                // and a fenced block lifts once more off that — the
                // same two-step the buffer line uses for the tab you
                // are on.
                .hov_border, .hov_prose, .hov_emph, .hov_head, .hov_link => bg = th.bar_bg,
                .hov_code => bg = th.chip_active_bg,
                else => {},
            }

            var uvx: u16 = 0;
            var uvy: u16 = 0;
            var flags: u16 = 0;
            if (rc.tail) {
                // The right half of a wide glyph: same atlas slot as the
                // cell before it, sampled one cell further across. Same
                // arrangement the terminal path uses for a spacer_tail.
                if (prev_wide) |loc| {
                    uvx = loc.uvx + cellw_px;
                    uvy = loc.uvy;
                    flags = 1 | (@as(u16, @intFromBool(loc.color)) << 1);
                }
                prev_wide = null;
            } else if (rc.cluster != 0) {
                // Several codepoints that are one character: CoreText
                // shapes the whole thing, so a mark sits over its base
                // and a ZWJ sequence ligates into the one glyph it is
                // supposed to be.
                prev_wide = null;
                // The CLUSTER's width, not the base codepoint's — `a`
                // followed by VS16 is wide and a bare `a` is not. The
                // editor already decided, and said so by putting a tail
                // in the next cell.
                const w = (i + 1) % cols != 0 and i + 1 < g.len and g[i + 1].tail;
                const ctext = if (ed) |e| e.clusterText(rc) else "";
                if (self.renderer.glyphCluster(ctext, w)) |loc| {
                    uvx = loc.uvx;
                    uvy = loc.uvy;
                    flags = 1 | (@as(u16, @intFromBool(loc.color)) << 1);
                    if (w) prev_wide = loc;
                }
            } else if (rc.cp > 32 and editorpkg.wideCp(rc.cp)) {
                prev_wide = null;
                if (self.renderer.glyph(rc.cp, true)) |loc| {
                    uvx = loc.uvx;
                    uvy = loc.uvy;
                    flags = 1 | (@as(u16, @intFromBool(loc.color)) << 1);
                    prev_wide = loc;
                }
            } else {
                prev_wide = null;
                if (rc.cp > 32) if (self.renderer.glyph(rc.cp, false)) |loc| {
                    uvx = loc.uvx;
                    uvy = loc.uvy;
                    flags = 1 | (@as(u16, @intFromBool(loc.color)) << 1);
                };
            }
            if (dim > 0) {
                for (0..3) |c| {
                    fg[c] = dimTo(fg[c], th.ed_bg[c], dim);
                    bg[c] = dimTo(bg[c], th.ed_bg[c], dim);
                }
            }
            // Let the card under the grid show through instead of
            // squaring its corners off with a cell-sized rectangle.
            if (rc.no_bg) flags |= renderpkg.flag_no_bg;
            cells[i] = .{
                .bg = bg,
                .fg = fg,
                .uvx = uvx,
                .uvy = uvy,
                .flags = flags,
            };
        }
        // The editor may produce fewer cells than the slot (tiny grid
        // clamp); blank the remainder.
        for (g.len..cells.len) |i| {
            cells[i] = .{ .bg = th.ed_bg, .fg = th.ed_fg, .uvx = 0, .uvy = 0, .flags = 0 };
        }
    }

    fn captureShot(self: *App, drawable: objc.Object) void {
        const tex = drawable.msgSend(objc.Object, "texture", .{});
        const w = tex.msgSend(u64, "width", .{});
        const h = tex.msgSend(u64, "height", .{});
        const bpr = w * 4;
        const pixels = self.gpa.alloc(u8, bpr * h) catch return;
        defer self.gpa.free(pixels);
        tex.msgSend(void, "getBytes:bytesPerRow:fromRegion:mipmapLevel:", .{
            @as(*anyopaque, pixels.ptr),
            bpr,
            renderpkg.MTLRegionPub{ .x = 0, .y = 0, .z = 0, .w = w, .h = h, .d = 1 },
            @as(u64, 0),
        });
        @import("png.zig").writeBGRA(self.shot_path[0..self.shot_len], @intCast(w), @intCast(h), @intCast(bpr), pixels) catch |err| {
            std.debug.print("rook shot: write failed: {}\n", .{err});
        };
    }
};

/// An NSString's UTF-8 bytes, or empty. The storage is the NSString's
/// own and lives as long as the event does, which outlasts the encode.
fn objcString(s: objc.Object) []const u8 {
    if (s.value == null) return "";
    const cstr = s.msgSend(?[*:0]const u8, "UTF8String", .{}) orelse return "";
    return std.mem.span(cstr);
}

/// The first codepoint of a string, or 0. keyenc wants the key as a
/// number, and a key is one codepoint by definition — anything longer
/// came from an input method, not from a keycap.
fn firstCodepoint(s: []const u8) u21 {
    if (s.len == 0) return 0;
    const n = std.unicode.utf8ByteSequenceLength(s[0]) catch return 0;
    if (n > s.len) return 0;
    return std.unicode.utf8Decode(s[0..n]) catch 0;
}

fn monitorCallback(context: *const MonitorBlock.Context, event_id: objc.c.id) callconv(.c) objc.c.id {
    const app: *App = context.app;
    const event = objc.Object.fromId(event_id);

    // The physical keyboard is the one proof a human is HERE, so the
    // focused pane's presence stamp happens before anything else can eat
    // the event. ctl-driven input deliberately does not stamp: an agent
    // typing into a pane is not a human looking at it.
    app.draw_lock.lock();
    if (app.activeTab().focused.term()) |tm|
        tm.session.last_in_ms.store(sessionpkg.clockMs(), .monotonic);
    app.draw_lock.unlock();

    const flags = event.msgSend(u64, "modifierFlags", .{});
    if (flags & flag_cmd != 0) {
        const chars = event.msgSend(objc.Object, "charactersIgnoringModifiers", .{});
        if (chars.value != null) {
            if (chars.msgSend(?[*:0]const u8, "UTF8String", .{})) |s| {
                if (s[1] == 0) switch (s[0]) {
                    'q' => {
                        app.app.msgSend(void, "terminate:", .{@as(objc.c.id, null)});
                        return null;
                    },
                    // The rook chords: ⌘D splits right, ⌘⇧D splits down,
                    // ⌘T new tab (session.new in the wails keymap),
                    // ⌘1–9 select tab, ⌘⇧[ / ⌘⇧] cycle.
                    'c' => {
                        if (app.copyFocused()) |t| app.gpa.free(t);
                        return null;
                    },
                    'v' => {
                        if (app.pasteFocused()) |t| app.gpa.free(t);
                        return null;
                    },
                    // These go through dispatch rather than calling the
                    // App method directly: "keybinds dispatch commands"
                    // is the registry's whole point, and a chord that
                    // bypassed it would be a capability the palette and
                    // ctl `run` could not reach.
                    'w' => {
                        app.dispatch(.{ .action = .pane_close });
                        return null;
                    },
                    'd' => {
                        app.dispatch(.{ .action = if (flags & flag_shift == 0) .split_right else .split_down });
                        return null;
                    },
                    'D' => {
                        app.dispatch(.{ .action = .split_down });
                        return null;
                    },
                    't' => {
                        app.dispatch(.{ .action = .tab_new });
                        return null;
                    },
                    'k' => {
                        app.dispatch(.{ .action = .palette_commands });
                        return null;
                    },
                    'p' => {
                        app.dispatch(.{ .action = .palette_files });
                        return null;
                    },
                    'F' => {
                        app.dispatch(.{ .action = .panel_search });
                        return null;
                    },
                    // ⌘S: the GUI hand's save, speaking `:w` itself so
                    // the clobber check stays one code path. Terminal
                    // panes pass it through untouched (⌘S means
                    // nothing to a shell, and swallowing it would be a
                    // chord the pty never gets to see).
                    's' => {
                        app.draw_lock.lock();
                        const ed = app.activeTab().focused.editor();
                        if (ed) |e| e.exNow("w");
                        if (ed != null) app.scene_dirty = true;
                        app.draw_lock.unlock();
                        if (ed != null) return null;
                    },
                    '1'...'9' => {
                        app.dispatch(.{ .action = .tab_select, .arg = s[0] - '0' });
                        return null;
                    },
                    '{' => {
                        app.dispatch(.{ .action = .tab_prev });
                        return null;
                    },
                    '}' => {
                        app.dispatch(.{ .action = .tab_next });
                        return null;
                    },
                    else => {},
                };
            }
        }
        return event_id; // other cmd chords stay AppKit's
    }

    // ⌃HJKL pane nav — yielding to programs that own their own splits.
    //
    // This used to yield to the alternate screen, read straight from
    // the emulator. Exact, and the wrong question: it answers "is this
    // program drawing full-screen", when what we need is "does this
    // program have splits of its own to protect". Those were the same
    // set for as long as the set was {vim}. Claude Code entered the
    // alternate screen and ⌃HJKL died in the pane rook is FOR.
    //
    // So ask by name — see Session.fgName and the `nav-yield` config.
    if (flags & flag_ctrl != 0) {
        const chars = event.msgSend(objc.Object, "charactersIgnoringModifiers", .{});
        if (chars.value != null) {
            if (chars.msgSend(?[*:0]const u8, "UTF8String", .{})) |s| {
                if (s[1] == 0) {
                    const dir: ?panespkg.NavDir = switch (s[0]) {
                        'h' => .left,
                        'j' => .down,
                        'k' => .up,
                        'l' => .right,
                        else => null,
                    };
                    if (dir) |d| {
                        // The side panel first, both directions: while it
                        // holds the keys the chord is chrome, and from the
                        // edge pane the chord walks in. navYields() is not
                        // consulted while the panel is focused — a panel
                        // is not a pty and has no splits to protect.
                        if (app.sidePaneNav(d)) return null;
                        if (!app.navYields()) {
                            if (app.focusMove(d)) return null;
                            if (app.sidePaneEnter(d)) return null;
                        }
                        // fall through: cooked control byte to the pty
                    }
                }
            }
        }
    }

    // The input method gets first refusal on unmodified keys — dead
    // keys and CJK composition exist only if something asks for them.
    // Modified keys never go: ⌃C is the terminal's, not the IME's.
    //
    // Three outcomes. Committed text (including ordinary ASCII, which
    // takes this path now) comes back through insertText: and becomes
    // the input. Composition holds the preedit and nothing reaches the
    // pane. Anything else — the IME declined, or reduced the key to a
    // Cocoa selector we dropped — falls through to the encoding below,
    // which is why Return/Tab/ESC/arrows are untouched by all this.
    var ime_bytes: ?[]const u8 = null;
    if (flags & (flag_cmd | flag_ctrl) == 0 and app.ime_view.value != null) {
        const ctx = app.ime_view.msgSend(objc.Object, "inputContext", .{});
        if (ctx.value != null) {
            const had_marked = app.ime_marked_len > 0;
            app.ime_text_len = 0;
            _ = ctx.msgSend(bool, "handleEvent:", .{event_id});
            if (app.ime_text_len > 0) ime_bytes = app.ime_text[0..app.ime_text_len];
            if (app.ime_marked_len > 0 or (had_marked and ime_bytes == null)) return null;
        }
    }

    // Everything that is not committed IME text goes through keyenc,
    // which is where the modes finally matter. What used to be here —
    // four arrows by keycode and the cooked `characters` for everything
    // else — is still the fast path for ordinary typing (keyenc returns
    // that text untouched), but it is no longer the WHOLE path: named
    // keys now carry their modifiers, arrows follow DECCKM, and
    // shift+Tab is `ESC [ Z` rather than the 0x19 macOS calls it.
    const keycode = event.msgSend(u16, "keyCode", .{});
    const chars = event.msgSend(objc.Object, "characters", .{});
    const unmod = event.msgSend(objc.Object, "charactersIgnoringModifiers", .{});
    var enc_buf: [keyenc.max_len]u8 = undefined;
    const bytes: []const u8 = ime_bytes orelse blk: {
        const key = keyenc.keyFromKeycode(keycode);
        const modes: keyenc.Modes = modes: {
            app.draw_lock.lock();
            defer app.draw_lock.unlock();
            break :modes app.ptyModesLocked() orelse .{};
        };
        break :blk keyenc.encode(&enc_buf, .{
            .key = key,
            .mods = .{
                .shift = flags & flag_shift != 0,
                // Option is Alt only for keys that compose nothing.
                // On a key that produces text it is macOS's compose
                // key and the IME above has already had its say —
                // treating it as Alt there would turn é into ESC e.
                .alt = key != .text and flags & flag_alt != 0,
                .ctrl = flags & flag_ctrl != 0,
                .super = flags & flag_cmd != 0,
            },
            .text = objcString(chars),
            .unshifted = firstCodepoint(objcString(unmod)),
        }, modes);
    };
    if (bytes.len > 0) {
        const ts = event.msgSend(f64, "timestamp", .{});
        // Leader chords see plain single-byte keys only — modified or
        // multi-byte input can never arm or resolve a chord.
        if (bytes.len == 1 and flags & (flag_ctrl | flag_alt) == 0) {
            if (app.handleCharKey(bytes[0], ts)) return null;
        }
        // The kernel's receipt time, same clock as presentedTime: this
        // makes key_present a true key-to-photon number. Writes go to
        // the focused pane, under the scene lock so reap can't free the
        // session mid-write.
        _ = app.writeFocused(bytes, ts);
    }
    return null;
}

/// Mouse: clicks focus what they land on (pane or tab chip); the
/// wheel scrolls the pane under the cursor — alt-screen terminals get
/// arrow keys (vim/less), editors scroll their viewport, primary-
/// screen terminal scrollback arrives with the scrollback slice.
fn flags_shift(event: objc.Object) bool {
    return event.msgSend(u64, "modifierFlags", .{}) & flag_shift != 0;
}

fn mouseCallback(context: *const MonitorBlock.Context, event_id: objc.c.id) callconv(.c) objc.c.id {
    const app: *App = context.app;
    const event = objc.Object.fromId(event_id);
    const etype = event.msgSend(u64, "type", .{});

    // Window coords are points, origin bottom-left; the scene is px,
    // origin top-left of the layer (= contentView).
    const loc = event.msgSend(NSPoint, "locationInWindow", .{});
    const scale = app.layer.msgSend(f64, "contentsScale", .{});
    const x: f32 = @floatCast(loc.x * scale);
    const y: f32 = app.px_h - @as(f32, @floatCast(loc.y * scale));
    if (y < 0 or y > app.px_h or x < 0 or x > app.px_w) return event_id; // outside the layer

    // Hand back what AppKit owns: the resize border, and in glass mode
    // the titlebar strip. Mouse-DOWN only — once AppKit takes a down it
    // runs its own tracking loop and the drags never reach here, while a
    // drag rook already anchored (a selection reaching the window edge)
    // must keep coming to us.
    //
    // clickAt has always bailed out of the strip with the comment
    // "titlebar drag strip — AppKit's". The intent was right and the
    // plumbing never matched it: bailing there still left the monitor
    // returning nil, so AppKit got nothing and the gestures it implements
    // — move, zoom, resize — had nowhere to happen.
    if (etype == 1 and uipkg.appKitOwns(x, y, app.px_w, app.px_h, app.top_inset, @floatCast(scale)))
        return event_id;

    if (etype == 1) { // NSEventTypeLeftMouseDown
        // Shift forces LOCAL handling (selection) when an app owns
        // the mouse — the terminal convention.
        app.clickAt(x, y, flags_shift(event));
        return null;
    }
    if (etype == 6) { // NSEventTypeLeftMouseDragged
        app.dragTo(x, y);
        return null;
    }
    if (etype == 2) { // NSEventTypeLeftMouseUp
        app.dragEnd();
        return null;
    }

    // Scroll wheel: accumulate points; one step per cell height.
    const dy = event.msgSend(f64, "scrollingDeltaY", .{});
    app.draw_lock.lock();
    app.wheel_accum += dy;
    const step: f64 = @floatCast(@max(1.0, app.renderer.cell_h / @as(f32, @floatCast(scale))));
    const lines: i64 = @intFromFloat(app.wheel_accum / step);
    app.wheel_accum -= @as(f64, @floatFromInt(lines)) * step;
    app.draw_lock.unlock();
    if (lines != 0) app.wheelAt(x, y, lines);
    return null;
}

fn resizeCallback(context: *const ResizeBlock.Context, notification: objc.c.id) callconv(.c) void {
    _ = notification;
    context.app.viewResized();
}

/// The window landed on a different display. Re-pace the frame clock
/// to it, then run the resize path — viewResized re-reads the backing
/// scale and the drawable size, which is exactly the state a screen
/// change moves without touching the frame.
fn screenChangedCallback(context: *const ResizeBlock.Context, notification: objc.c.id) callconv(.c) void {
    _ = notification;
    const self = context.app;
    // AppKit can report no screen at all while displays are being
    // reconfigured — the moment this notification is most likely to
    // fire. Skip the retarget; the scale refresh below is still safe.
    const screen = self.window.msgSend(objc.Object, "screen", .{});
    if (screen.value != null) {
        const desc = screen.msgSend(objc.Object, "deviceDescription", .{});
        const num = desc.msgSend(objc.Object, "objectForKey:", .{nsString("NSScreenNumber").value});
        if (num.value != null) {
            _ = CVDisplayLinkSetCurrentCGDisplay(self.link, num.msgSend(u32, "unsignedIntValue", .{}));
            // The cached refresh period belongs to the old display;
            // zero it so the next link tick re-asks CoreVideo.
            self.display_period_us.store(0, .monotonic);
        }
    }
    self.viewResized();
}

fn completedCallback(context: *const CompletedBlock.Context, cmd_id: objc.c.id) callconv(.c) void {
    _ = context;
    const cmd = objc.Object.fromId(cmd_id);
    const gpu_start = cmd.msgSend(f64, "GPUStartTime", .{});
    const gpu_end = cmd.msgSend(f64, "GPUEndTime", .{});
    if (gpu_end > gpu_start) stats.global.frame_gpu.recordSeconds(gpu_end - gpu_start);
}

fn presentedCallback(context: *const PresentedBlock.Context, drawable_id: objc.c.id) callconv(.c) void {
    const app = context.app;
    const t = objc.Object.fromId(drawable_id).msgSend(f64, "presentedTime", .{});
    if (t <= 0) return;

    // Pacing, not idleness: an interval that brackets an idle stretch
    // (dirty-skip means we simply didn't draw) says nothing about how
    // fast we draw — only sub-500ms gaps are pacing samples.
    const last = app.last_presented.swap(t, .acq_rel);
    if (last > 0 and t > last and t - last < 0.5) stats.global.present_interval.recordSeconds(t - last);
    if (t > context.commit_t) stats.global.present_lag.recordSeconds(t - context.commit_t);

    // Key → photon: only a frame that carried the focused pane's echo
    // may consume the pending mark.
    if (context.dirty != 0) {
        const mark = app.input_mark.swap(0, .acq_rel);
        if (mark > 0 and t > mark) stats.global.key_present.recordSeconds(t - mark);
    }
}

fn displayLinkCallback(link: CVDisplayLinkRef, now: ?*const anyopaque, output: ?*const anyopaque, flags_in: u64, flags_out: ?*u64, ctx: ?*anyopaque) callconv(.c) i32 {
    _ = now;
    _ = output;
    _ = flags_in;
    _ = flags_out;
    const self: *App = @ptrCast(@alignCast(ctx.?));
    // Ask CoreVideo here, on ITS OWN thread and BEFORE taking the lock.
    // Asking from under draw_lock is the inversion documented on the
    // field: the query waits for this thread, and this thread is about
    // to wait for the lock the caller is holding.
    if (self.display_period_us.load(.monotonic) == 0) {
        const p = CVDisplayLinkGetActualOutputVideoRefreshPeriod(link);
        if (p > 0) self.display_period_us.store(@intFromFloat(@round(p * 1e6)), .monotonic);
    }
    self.drawNow();
    return 0;
}

/// ⌘Q and every other AppKit route out of the app. It used to take
/// rook-host down here; now its job is making sure nothing outlives the
/// app IN-process either — process exit alone leaves any SIGHUP-trapping
/// job running (see hangupAllSessions).
fn terminateCallback(ctx: *const ResizeBlock.Context, _: objc.c.id) callconv(.c) void {
    ctx.app.hangupAllSessions();
}

/// Authorization result. Nothing to do but say so once: a denied
/// notification is the user's decision, and retrying would be nagging.
fn authCallback(_: *const AuthBlock.Context, granted: bool, err: objc.c.id) callconv(.c) void {
    _ = err;
    if (!granted) std.debug.print("rook: notification permission denied (System Settings > Notifications > rook)\n", .{});
}

/// The agent deck's poller. Same contract as the inbox's: fetches only
/// while its panel is open, and dirties the scene only on a digest
/// change, so idle frames stay 0.
extern "c" fn usleep(us: u32) c_int;

extern "c" fn fork() c_int;
extern "c" fn execl(path: [*:0]const u8, arg0: [*:0]const u8, ...) c_int;
extern "c" fn waitpid(pid: c_int, status: *c_int, opts: c_int) c_int;

/// Run a category's own cleanup command through the shell.
///
/// Through `sh -c` because the commands come from `diskscan.categories`
/// — a compiled-in table, not user input and not anything a plugin can
/// reach — and they are written the way their documentation writes them
/// ("go clean -modcache", "brew cleanup --prune=all"). Nothing here
/// interpolates a scanned path into the string; a reclaim that needs a
/// path uses the delete branch instead, which never goes near a shell.
fn runTool(cmd: []const u8) bool {
    var buf: [128]u8 = undefined;
    if (cmd.len >= buf.len) return false;
    @memcpy(buf[0..cmd.len], cmd);
    buf[cmd.len] = 0;
    const z: [*:0]const u8 = @ptrCast(&buf);

    const pid = fork();
    if (pid < 0) return false;
    if (pid == 0) {
        _ = execl("/bin/sh", "sh", "-c", z, @as(?[*:0]const u8, null));
        _exit(127);
    }
    var status: c_int = 0;
    if (waitpid(pid, &status, 0) < 0) return false;
    // WIFEXITED && WEXITSTATUS == 0
    return (status & 0x7f) == 0 and ((status >> 8) & 0xff) == 0;
}

fn inputKick(ctx: *anyopaque, sess: *sessionpkg.Session) void {
    const self: *App = @ptrCast(@alignCast(ctx));
    if (self.focused_session.load(.acquire) != sess) return;
    if (self.input_mark.load(.acquire) > 0) self.drawNow();
}
