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
const renderpkg = @import("render.zig");
const panespkg = @import("panes.zig");
const editorpkg = @import("editor.zig");
const workspacespkg = @import("workspaces.zig");
const registrypkg = @import("registry.zig");
const pastepkg = @import("paste.zig");
const hostc = @import("hostc.zig");
const themepkg = @import("theme.zig");
const cfgpkg = @import("config.zig");
const filelistpkg = @import("filelist.zig");
const uipkg = @import("ui.zig");
const stats = @import("stats.zig");

extern "c" fn CACurrentMediaTime() f64;
/// AppKit's system alert sound — the audible half of the bell.
extern "c" fn NSBeep() void;

const NSPoint = extern struct { x: f64, y: f64 };
const NSSize = extern struct { width: f64, height: f64 };
const NSRect = extern struct { origin: NSPoint, size: NSSize };
const MTLClearColor = extern struct { r: f64, g: f64, b: f64, a: f64 };

extern "c" fn MTLCreateSystemDefaultDevice() objc.c.id;
extern "c" fn proc_pidinfo(pid: c_int, flavor: c_int, arg: u64, buffer: *anyopaque, buffersize: c_int) c_int;
extern "c" fn kill(pid: c_int, sig: c_int) c_int;
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

const NSEventMaskKeyDown: u64 = 1 << 10;
const NSEventMaskLeftMouseDown: u64 = 1 << 1;
const NSEventMaskLeftMouseUp: u64 = 1 << 2;
const NSEventMaskLeftMouseDragged: u64 = 1 << 6;
const NSEventMaskScrollWheel: u64 = 1 << 22;
const flag_shift: u64 = 1 << 17;
const flag_ctrl: u64 = 1 << 18;
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
pub const PalMode = enum { workspaces, commands, files };

/// Which side pane a panel is slotted into. Panels are placement-
/// agnostic: the tenant draws into a rect and does not know which edge
/// it came from.
pub const Side = enum { left, right };

/// The side pane's tenants. One today; the switch in drawSidePane is
/// where §2's inbox/deck/threads/review join it, the same way pal_mode
/// grew a second list. Deliberately an enum rather than a vtable — a
/// tenant interface designed against ONE tenant is a guess.
pub const Panel = enum { attention, ask, deck, threads, review };

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

/// A queued "open this path outside the asking editor" — the tree's
/// beside-open and :sp/:vsp. Queued because the ask fires on the key
/// path under draw_lock and pane surgery takes it again.
const PendingOpen = struct {
    len: usize,
    line: usize,
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
    cfg_top_bar: cfgpkg.SegList = cfgpkg.segs(.{ .tabs, .title, .usage }),
    cfg_status_left: cfgpkg.SegList = cfgpkg.segs(.{ .workspace, .branch, .cwd }),
    cfg_status_right: cfgpkg.SegList = cfgpkg.segs(.{ .hints, .hud }),
    cfg_tab_style: cfgpkg.TabStyle = .chips,
    /// Per-tab hit zones for a `tabs` segment living in the STATUS
    /// bar (the top strip's chips keep chip_x). current-style records
    /// one zone; a click there cycles.
    bar_tab_x: [12][2]f32 = undefined,
    bar_tab_n: usize = 0,

    // ---- cursor blink ----
    /// config `cursor-blink`: the focused pane's cursor blinks on the
    /// mark every terminal shares (1.1s period, ~55% on).
    cursor_blink: bool = true,
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
    pal_scores: [64]i32 = undefined,
    // ---- side pane: the container every §2 panel lands in ----
    /// Closed by default. An empty container costs nothing but a branch,
    /// and the inbox is only worth screen space once something is in it.
    side_open: bool = false,
    side: Side = .right,
    side_panel: Panel = .attention,
    /// Columns, not pixels: the pane beside it is a character grid, and
    /// a width in px makes the split land mid-cell at some font sizes.
    side_cols: f32 = 34,
    /// The inbox, refreshed by attentionThread ONLY while open — a
    /// closed panel must cost nothing, including no host traffic.
    attention: @import("attention.zig").Snapshot = .{},
    attention_digest: u64 = 0,
    /// The agent deck, refreshed by deckThread while its panel is open.
    deck: @import("agents.zig").Snapshot = .{},
    deck_digest: u64 = 0,
    deck_sel: usize = 0,
    /// Set when the panel opens so the poller fetches immediately
    /// instead of after its next sleep.
    attention_wake: std.atomic.Value(bool) = .init(false),
    /// Set when an answer is queued, so the poster posts it now.
    ask_wake: std.atomic.Value(bool) = .init(false),
    deck_wake: std.atomic.Value(bool) = .init(false),
    /// An agent id whose transcript has been requested. The fetch is
    /// blocking HTTP over a document-sized body, so the key path only
    /// ever queues — transcriptThread does the work and opens the pane.
    tx_req: [64]u8 = @splat(0),
    tx_req_len: usize = 0,
    tx_wake: std.atomic.Value(bool) = .init(false),

    // ---- threads ----
    /// The workspace thread list, polled while its panel is open.
    thr: @import("threaddoc.zig").Snapshot = .{},
    thr_digest: u64 = 0,
    thr_sel: usize = 0,
    thr_wake: std.atomic.Value(bool) = .init(false),
    /// A thread id whose doc has been requested (open), and one whose
    /// doc is queued to save. Both are network work, so the key path
    /// only ever queues.
    thr_open_req: i64 = 0,
    thr_save_id: i64 = 0,
    thr_save_len: usize = 0,
    thr_save_body: [256 * 1024]u8 = undefined,
    /// A verb (note|ask|resolve) queued against a thread.
    thr_verb_id: i64 = 0,
    thr_verb: [16]u8 = @splat(0),
    thr_verb_len: usize = 0,
    /// The immutable prefix of the doc currently open, as handed out.
    /// Saving splits the buffer on exactly this — never by scanning for
    /// the scissors line, which a comment body could legally contain.
    thr_prefix: []u8 = &.{},
    thr_prefix_id: i64 = 0,

    // ---- review ----
    rev: @import("review.zig").Snapshot = .{},
    rev_digest: u64 = 0,
    rev_sel: usize = 0,
    rev_wake: std.atomic.Value(bool) = .init(false),
    /// A verdict queued against a finding: id + state name.
    rev_set_id: i64 = 0,
    rev_set: [12]u8 = @splat(0),
    rev_set_len: usize = 0,
    /// A finding's location queued to open — the fetch/open happens off
    /// the key path like every other network-adjacent action.
    rev_open_path: [128]u8 = @splat(0),
    rev_open_path_len: usize = 0,
    rev_open_line: i64 = 0,
    /// A diff view queued to build. Off the key path for the same reason
    /// everything else here is, only more so: one diff is a `git diff`
    /// per changed file, so building it on the UI thread would stall the
    /// frame for as long as the repo is large.
    ///
    /// When `diff_path_len` is non-zero it is ONE file's diff; otherwise
    /// the whole changes list.
    diff_req: bool = false,
    diff_path: [256]u8 = @splat(0),
    diff_path_len: usize = 0,
    /// The modified-side line to land on, or 0 for the top. A finding
    /// names a line, and a diff that opened at row one would make you
    /// hunt for it — the same rule openEditorAtLine follows.
    diff_line: i64 = 0,

    /// The side pane takes the key path. Needed the moment a tenant is
    /// INTERACTIVE — the inbox is read-only, the ask form is not. Modal
    /// like the palette, but it owns a region rather than the screen, so
    /// it yields back to the panes instead of closing.
    side_focus: bool = false,

    // ---- the ask form (asks.zig) ----
    ask: ?@import("asks.zig").Ask = null,
    /// Which question of the ask we are on.
    ask_qi: usize = 0,
    /// Cursor row within the current question.
    ask_sel: usize = 0,
    /// Ticks for the current question (multi-select), and the answers
    /// already decided for earlier questions.
    ask_picked: [@import("asks.zig").max_options]bool = @splat(false),
    ask_answers: [@import("asks.zig").max_questions][@import("asks.zig").max_options]bool = @splat(@splat(false)),
    /// Free-text input, and the "Other…" row's text.
    ask_text: [240]u8 = @splat(0),
    ask_text_len: usize = 0,
    /// A body queued for the poster thread: answering must not block the
    /// key path on an HTTP round trip.
    ask_post_id: [24]u8 = @splat(0),
    ask_post_id_len: usize = 0,
    ask_post_body: [4096]u8 = @splat(0),
    ask_post_len: usize = 0,
    /// The last answer body the form produced, RETAINED after the poster
    /// consumes it. Observability: a malformed body loses the answer and
    /// leaves the asker blocked, and "what exactly did we send" is the
    /// first question when that happens. ctl `ask-answer` reads it.
    ask_last: [4096]u8 = @splat(0),
    ask_last_len: usize = 0,

    /// A command the palette picked, waiting for draw_lock to be RELEASED.
    /// The palette's key path runs under the lock and every dispatch
    /// target takes it again (newTab, selectTab, splitFocused, …), so
    /// running one inline is a self-deadlock. Drained by drainPendingCmd
    /// at each of the three places that let go of the lock.
    pending_cmd: ?registrypkg.Spec = null,
    /// A queued open-outside-the-editor; see PendingOpen.
    pending_open: ?PendingOpen = null,
    pending_open_path: [1024]u8 = undefined,
    /// A queued `:qa`-family request. See editorQuitAll for why it cannot
    /// run where it is asked for.
    pending_quit_all: ?struct { write: bool, quit: bool, force: bool } = null,

    /// Subscription usage cluster (host-cached windows), refreshed by
    /// a background thread every 30s; shown right-aligned in the title
    /// zone. Guarded by draw_lock.
    usage: @import("usage.zig").Snapshot = .{},

    /// rook-host: the daemon we spawned (or adopted) at launch, and the
    /// port+token every host-backed panel will reach it through. Filled
    /// by hostThread, read under host_lock — `host_up` is the only safe
    /// gate on `host` being meaningful.
    host: hostc.Handle = .{},
    host_up: bool = false,
    host_lock: sessionpkg.Lock = .{},

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
        self.draw_lock.lock();
        defer self.draw_lock.unlock();
        self.drawFrame();
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
        const session = try sessionpkg.Session.start(gpa, init.io, shell, null, termColors(), @intCast(cols), @intCast(rows), @intCast(renderer.cellw_px), @intCast(renderer.cellh_px), cfg.scrollback);
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
            .cfg_ed_insert = cfg.editor_insert,
            .cfg_activity_bar = cfg.activity_bar,
            .cursor_blink = cfg.cursor_blink,
            .cfg_scrollback = cfg.scrollback,
            .bg_alpha = @intFromFloat(@round(cfg.background_opacity * 255.0)),
            .ime_view = view,
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
        self.pal_items = workspacespkg.load(gpa);
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
        boot_times.create_us = usSince(boot_times.start);
        return self;
    }

    pub fn run(self: *App) void {
        self.window.msgSend(void, "makeKeyAndOrderFront:", .{@as(objc.c.id, null)});
        // --no-activate: probe/tooling launches must not steal focus.
        if (self.activate) self.app.msgSend(void, "activateIgnoringOtherApps:", .{true});

        @import("ctl.zig").start(self) catch |err| {
            std.debug.print("rook ctl: failed to start: {}\n", .{err});
        };

        // rook-host: spawn (or adopt) the daemon. Off-thread because a
        // cold start costs a health-poll of up to 5s, and the first
        // frame owes nothing to the host — the terminal opens either way.
        if (std.Thread.spawn(.{}, hostThread, .{self})) |t| t.detach() else |err| {
            std.debug.print("rook host: thread failed: {}\n", .{err});
        }

        // …and take it down with us. Nothing runs while rook is closed:
        // this notification is the app's last word before AppKit exits,
        // and the ONLY path out of `NSApp run` we get to observe (a
        // crash or SIGKILL skips it — see hostc.zig's known gap).
        var term_ctx = ResizeBlock.init(.{ .app = self }, &terminateCallback);
        const nc = objc.getClass("NSNotificationCenter").?
            .msgSend(objc.Object, "defaultCenter", .{});
        _ = nc.msgSend(objc.Object, "addObserverForName:object:queue:usingBlock:", .{
            nsString("NSApplicationWillTerminateNotification").value,
            @as(objc.c.id, null),
            @as(objc.c.id, null),
            &term_ctx,
        });

        // Usage cluster: poll the host's cached snapshot off-thread.
        if (std.Thread.spawn(.{}, usageThread, .{self})) |t| t.detach() else |err| {
            std.debug.print("rook usage: thread failed: {}\n", .{err});
        }

        // The attention inbox. Spawned always, but it only FETCHES while
        // its panel is open — a closed panel owes the host nothing.
        if (std.Thread.spawn(.{}, attentionThread, .{self})) |t| t.detach() else |err| {
            std.debug.print("rook attention: thread failed: {}\n", .{err});
        }

        // Review: gate, verdicts, jumps.
        if (std.Thread.spawn(.{}, reviewThread, .{self})) |t| t.detach() else |err| {
            std.debug.print("rook review: thread failed: {}\n", .{err});
        }

        // Threads: list, open, save, verbs.
        if (std.Thread.spawn(.{}, threadsThread, .{self})) |t| t.detach() else |err| {
            std.debug.print("rook threads: thread failed: {}\n", .{err});
        }

        // Transcript fetches, on demand.
        if (std.Thread.spawn(.{}, transcriptThread, .{self})) |t| t.detach() else |err| {
            std.debug.print("rook transcript: thread failed: {}\n", .{err});
        }

        // The agent deck, gated on its panel like the inbox.
        if (std.Thread.spawn(.{}, deckThread, .{self})) |t| t.detach() else |err| {
            std.debug.print("rook deck: thread failed: {}\n", .{err});
        }

        // The asks loop. Polls unconditionally: a question is the app's
        // reason to interrupt, so it cannot wait for a panel to be open.
        if (std.Thread.spawn(.{}, asksThread, .{self})) |t| t.detach() else |err| {
            std.debug.print("rook asks: thread failed: {}\n", .{err});
        }

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

        // Frame clock off the main thread.
        var link: CVDisplayLinkRef = null;
        _ = CVDisplayLinkCreateWithActiveCGDisplays(&link);
        _ = CVDisplayLinkSetOutputCallback(link, &displayLinkCallback, self);
        _ = CVDisplayLinkStart(link);
        self.link = link;

        self.app.msgSend(void, "run", .{});
    }

    /// Take rook-host down. Idempotent, callable from any thread, and a
    /// no-op unless the daemon is one our own spawn became — the whole
    /// "nothing runs while rook is closed" rule lives in hostc.shutdown.
    pub fn shutdownHost(self: *App) void {
        self.host_lock.lock();
        defer self.host_lock.unlock();
        if (!self.host_up) return;
        hostc.shutdown(&self.host);
        self.host_up = false;
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
    fn sideArea(self: *App) panespkg.Rect {
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
            } else if (x >= self.seg_branch_x[0] and x < self.seg_branch_x[1]) {
                self.pending_cmd = .{ .action = .diff_open };
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
        const session = try sessionpkg.Session.start(self.gpa, self.io, self.shell, cwd, termColors(), 80, 24, @intCast(self.renderer.cellw_px), @intCast(self.renderer.cellh_px), self.cfg_scrollback);
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
        if (!self.openEditor(path)) return false;
        self.draw_lock.lock();
        defer self.draw_lock.unlock();
        const ed = self.activeTab().focused.editor() orelse return true;
        const n = ed.lineCountB();
        ed.cline = @min(@as(usize, @intCast(@max(line, 1))) - 1, n -| 1);
        ed.ccol = 0;
        self.scene_dirty = true;
        return true;
    }

    pub fn openEditor(self: *App, path: []const u8) bool {
        self.draw_lock.lock();
        defer self.draw_lock.unlock();
        const t = self.activeTab();
        const p = t.focused;
        if (p.editor()) |ed| {
            ed.open(path, false) catch return false;
            self.scene_dirty = true;
            return true;
        }
        const ed = editorpkg.Editor.create(self.gpa, self.io, path) catch return false;
        @import("syntax.zig").attach(ed, self.gpa);
        self.attachCommands(ed);
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
    pub fn writeFocused(self: *App, bytes: []const u8, ts: f64) void {
        {
            self.draw_lock.lock();
            defer self.draw_lock.unlock();
            self.markInput(ts);
            if (!self.routeChromeKeyLocked(bytes))
                self.paneInput(self.activeTab().focused, bytes);
        }
        // Outside the block on purpose — see pending_cmd.
        self.drainPendingCmd();
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
        if (self.pal_open) {
            self.palKeyLocked(bytes);
            return true;
        }
        if (!self.side_focus) return false;
        switch (self.side_panel) {
            .ask => self.askKeyLocked(bytes),
            .deck => self.deckKeyLocked(bytes),
            .threads => self.threadsKeyLocked(bytes),
            .review => self.reviewKeyLocked(bytes),
            // Read-only tenant: it never takes the keys.
            .attention => return false,
        }
        return true;
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
        }
    }

    /// Close the focused pane (⌘W): a terminal gets SIGHUP (the
    /// shell exits and the normal reap collapses the pane); an editor
    /// takes :q semantics — unsaved changes refuse with a status
    /// message (:q! or :wq inside the editor to force).
    pub fn closeFocused(self: *App) void {
        self.draw_lock.lock();
        defer self.draw_lock.unlock();
        switch (self.activeTab().focused.content) {
            .term => |*tm| _ = kill(tm.session.pid, 1), // SIGHUP
            .edit => |ed| {
                if (ed.buf.isModified()) {
                    ed.setStatusUnsaved();
                } else ed.closed = true;
                ed.render_dirty = true;
            },
        }
        self.scene_dirty = true;
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

    /// Open the workspace picker with a fresh read of rook.db. Any thread.
    pub fn openPalette(self: *App) void {
        self.draw_lock.lock();
        defer self.draw_lock.unlock();
        workspacespkg.free(self.gpa, self.pal_items);
        self.pal_items = workspacespkg.load(self.gpa);
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
    fn liveChordHint(self: *App, action: registrypkg.Action, arg: u8, buf: []u8) ?[]const u8 {
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
        var hi: usize = 0;
        for (needle) |nc| {
            const n = std.ascii.toLower(nc);
            while (hi < hay.len and std.ascii.toLower(hay[hi]) != n) hi += 1;
            if (hi == hay.len) return false;
            hi += 1;
        }
        return true;
    }

    /// Subsequence match with a SCORE, for the one list long enough to
    /// need ranking. A file picker that returns matches in walk order
    /// is a file picker you scroll, which is the thing ⌘P exists not
    /// to do. Higher is better; null is no match.
    ///
    /// What it rewards, in the order it matters: matching in the
    /// BASENAME (you type "main" for main.zig, not for
    /// src/domain/x.zig), CONTIGUOUS runs, a match at a word boundary
    /// (start, or after / _ - .), and a short path. These four are
    /// what separate "the file I meant is first" from "it is somewhere
    /// in the list".
    fn fuzzyScore(hay: []const u8, needle: []const u8) ?i32 {
        if (needle.len == 0) return 0;
        const base_at = if (std.mem.lastIndexOfScalar(u8, hay, '/')) |i| i + 1 else 0;
        var score: i32 = 0;
        var hi: usize = 0;
        var prev_end: usize = std.math.maxInt(usize);
        for (needle) |nc| {
            const n = std.ascii.toLower(nc);
            while (hi < hay.len and std.ascii.toLower(hay[hi]) != n) hi += 1;
            if (hi == hay.len) return null;
            if (hi >= base_at) score += 12;
            if (prev_end == hi) score += 10; // contiguous with the last hit
            if (hi == 0 or hi == base_at) {
                score += 8;
            } else switch (hay[hi - 1]) {
                '/', '_', '-', '.' => score += 6,
                else => {},
            }
            prev_end = hi + 1;
            hi += 1;
        }
        // Shorter paths win ties: "src/x.zig" over "a/b/c/d/src/x.zig".
        score -= @intCast(@min(hay.len / 4, 40));
        return score;
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
            .app_fullscreen => self.requestFullscreen(),
            .panel_attention => self.toggleSidePane(.attention),
            .panel_deck => self.toggleDeck(),
            .panel_threads => self.toggleThreads(),
            .panel_review => self.toggleReview(),
            .thread_note => self.threadVerb("note"),
            .thread_ask => self.threadVerb("ask"),
            .thread_resolve => self.threadVerb("resolve"),
            .panel_ask => self.showPendingAsk(),
            .panel_flip => self.flipSidePane(),
            .diff_open => self.requestDiff("", 0),
            .tree_toggle => self.treeCommand(false),
            .tree_reveal => self.treeCommand(true),
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
        const start: []const u8 = blk: {
            if (p.editor()) |ed| {
                if (!ed.synthetic) if (ed.buf.path) |bp| {
                    if (ed.is_dir) break :blk bp; // in-pane tree: same root
                    break :blk std.fs.path.dirname(bp) orelse bp;
                };
            }
            const cwd = self.paneCwd(p) orelse return null;
            break :blk std.mem.span(cwd);
        };
        return @import("git.zig").repoRootFs(self.io, self.gpa, start, buf) orelse start;
    }

    fn openTreePaneLocked(self: *App) ?*panespkg.Pane {
        const t = self.activeTab();
        const p = t.focused;
        var root_buf: [1024]u8 = undefined;
        const root = self.paneRootLocked(p, &root_buf) orelse return null;

        const ed = editorpkg.Editor.create(self.gpa, self.io, root) catch return null;
        if (!ed.is_dir) {
            ed.destroy();
            return null;
        }
        ed.tree_pinned = true;
        @import("syntax.zig").attach(ed, self.gpa);
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

    /// Toggle the side pane. Opening with a DIFFERENT panel than the one
    /// showing switches tenants instead of closing — the VS Code rule,
    /// and the one that makes a second tenant behave sensibly the day it
    /// arrives.
    pub fn toggleSidePane(self: *App, panel: Panel) void {
        {
            self.draw_lock.lock();
            defer self.draw_lock.unlock();
            if (self.side_open and self.side_panel == panel) {
                self.side_open = false;
            } else {
                self.side_panel = panel;
                self.side_open = true;
            }
            // The panes beside it must retile: their COLUMN COUNT
            // changes, which means a pty resize, not just a redraw.
            self.relayoutLocked();
            self.scene_dirty = true;
        }
        // Wake the poller so an opened panel fills in now rather than at
        // the next tick. Cheap: it only ever skips ahead one sleep.
        self.attention_wake.store(true, .release);
    }

    /// Rows the current question offers: its options, plus the "Other…"
    /// row that lets a human answer in their own words. A free-text
    /// question is that row alone.
    fn askRowCount(self: *App) usize {
        const a = self.ask orelse return 0;
        const q = a.questions[self.ask_qi];
        return q.n + 1;
    }

    fn askOtherRow(self: *App) usize {
        const a = self.ask orelse return 0;
        return a.questions[self.ask_qi].n;
    }

    /// Seed the cursor and ticks for a question. `recommended` is
    /// load-bearing: pre-ticked in multi, under the cursor in single, so
    /// Enter alone is a complete answer to a well-formed ask.
    fn askSeedLocked(self: *App) void {
        const a = self.ask orelse return;
        const q = a.questions[self.ask_qi];
        self.ask_picked = @splat(false);
        self.ask_sel = 0;
        self.ask_text_len = 0;
        for (q.options[0..q.n], 0..) |o, i| {
            if (!o.recommended) continue;
            if (q.multi) self.ask_picked[i] = true else if (self.ask_sel == 0) self.ask_sel = i;
        }
        if (q.free_text) self.ask_sel = 0;
    }

    /// Take an ask and put it on screen. Opens the panel and TAKES FOCUS:
    /// a question nobody notices is the failure mode this whole loop
    /// exists to fix.
    fn presentAskLocked(self: *App, a: @import("asks.zig").Ask) void {
        self.ask = a;
        self.ask_qi = 0;
        self.ask_answers = @splat(@splat(false));
        self.askSeedLocked();
        self.side_panel = .ask;
        self.side_open = true;
        self.side_focus = true;
        self.relayoutLocked();
        self.scene_dirty = true;
    }

    /// Build the answer JSON and hand it to the poster thread.
    /// {"answers":[{question, header?, selected:[…], other?}]} — the
    /// shape the MCP `answers` tool and the blocked rookctl both read.
    fn askSubmitLocked(self: *App) void {
        const a = self.ask orelse return;
        const asks = @import("asks.zig");
        var w: std.Io.Writer = .fixed(&self.ask_post_body);
        _ = w.write("{\"answers\":[") catch {};
        for (a.questions[0..a.n], 0..) |q, qi| {
            if (qi > 0) _ = w.write(",") catch {};
            _ = w.write("{\"question\":") catch {};
            asks.writeJsonString(&w, q.text.get());
            if (q.header.len > 0) {
                _ = w.write(",\"header\":") catch {};
                asks.writeJsonString(&w, q.header.get());
            }
            _ = w.write(",\"selected\":[") catch {};
            var first = true;
            for (q.options[0..q.n], 0..) |o, oi| {
                if (!self.ask_answers[qi][oi]) continue;
                if (!first) _ = w.write(",") catch {};
                first = false;
                asks.writeJsonString(&w, o.label.get());
            }
            _ = w.write("]") catch {};
            // `other` is the human's own words, and the tool description
            // tells the agent to treat it as such. Only the LAST question
            // can carry one — it is whatever is in the text buffer when
            // they submit.
            if (qi + 1 == a.n and self.ask_text_len > 0) {
                _ = w.write(",\"other\":") catch {};
                asks.writeJsonString(&w, self.ask_text[0..self.ask_text_len]);
            }
            _ = w.write("}") catch {};
        }
        _ = w.write("]}") catch {};
        self.queueAskPostLocked(a.id.get(), self.ask_post_body[0..w.end]);
        self.dismissAskLocked();
    }

    /// Jump to where an ask came from (⌃G).
    ///
    /// There is no session to jump TO — the app owns its ptys and the
    /// queue is session-less — so the link back is the asker's cwd
    /// against each pane's shell cwd, read from the kernel. Best match
    /// wins: an exact directory beats a parent, and a deeper parent
    /// beats a shallower one, so the pane the agent is actually running
    /// in outranks the shell that happens to sit at the repo root.
    ///
    /// Deliberately does NOT dismiss the question. You jump to look at
    /// what is being asked about, and the form has to still be there
    /// when you look back.
    fn askJumpLocked(self: *App) bool {
        const a = self.ask orelse return false;
        if (!self.jumpToCwdLocked(a.cwd.get())) return false;
        // The panes own the keys now — you asked to go look at something.
        self.side_focus = false;
        return true;
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

    /// ESC: the asker sees {"canceled":true} and exits 1. Deliberately a
    /// real answer rather than silence — a dismissal has to unblock the
    /// asker, or `rookctl ask` hangs until someone kills it.
    fn askCancelLocked(self: *App) void {
        const a = self.ask orelse return;
        const body = "{\"canceled\":true}";
        @memcpy(self.ask_post_body[0..body.len], body);
        self.queueAskPostLocked(a.id.get(), self.ask_post_body[0..body.len]);
        self.dismissAskLocked();
    }

    fn queueAskPostLocked(self: *App, id: []const u8, body: []const u8) void {
        const n = @min(id.len, self.ask_post_id.len);
        @memcpy(self.ask_post_id[0..n], id[0..n]);
        self.ask_post_id_len = n;
        // body already lives in ask_post_body; record how much of it.
        self.ask_post_len = @min(body.len, self.ask_post_body.len);
        // Keep a copy the poster does not consume — see ask_last.
        @memcpy(self.ask_last[0..self.ask_post_len], self.ask_post_body[0..self.ask_post_len]);
        self.ask_last_len = self.ask_post_len;
        self.ask_wake.store(true, .release);
    }

    /// Put a question on screen directly. ctl's `ask` verb — the same
    /// role `paste <text>` plays for the pasteboard: drive the real form
    /// without needing the thing that normally feeds it.
    pub fn presentAsk(self: *App, a: @import("asks.zig").Ask) void {
        self.draw_lock.lock();
        defer self.draw_lock.unlock();
        self.presentAskLocked(a);
    }

    fn dismissAskLocked(self: *App) void {
        self.ask = null;
        self.ask_text_len = 0;
        self.side_focus = false;
        // Leave the panel open on the inbox rather than yanking the whole
        // container away: the answer usually is not the last thing you
        // wanted to see.
        self.side_panel = .attention;
        self.relayoutLocked();
        self.scene_dirty = true;
    }

    /// The ask form's key path. Same stream contract as the palette and
    /// the editor: NSEvents deliver chars and whole CSI arrows, ctl
    /// delivers strings. Caller holds draw_lock.
    pub fn askKeyLocked(self: *App, bytes: []const u8) void {
        if (self.ask == null) return;
        const rows = self.askRowCount();
        const other = self.askOtherRow();
        var i: usize = 0;
        while (i < bytes.len) {
            const b = bytes[i];
            if (b == 0x1b and i + 2 < bytes.len and bytes[i + 1] == '[') {
                switch (bytes[i + 2]) {
                    'A' => self.ask_sel -|= 1,
                    'B' => self.ask_sel = @min(self.ask_sel + 1, rows -| 1),
                    else => {},
                }
                i += 3;
                continue;
            }
            switch (b) {
                0x1b => {
                    self.askCancelLocked();
                    return;
                },
                '\r', '\n' => {
                    self.askAdvanceLocked();
                    return;
                },
                0x10 => self.ask_sel -|= 1, // ⌃P
                0x0e => self.ask_sel = @min(self.ask_sel + 1, rows -| 1), // ⌃N
                0x07 => { // ⌃G — go to where the ask came from
                    _ = self.askJumpLocked();
                    return;
                },
                0x7f, 0x08 => {
                    if (self.ask_text_len > 0) self.ask_text_len -= 1;
                },
                ' ' => {
                    // Space toggles a tick in multi-select; on the Other
                    // row it is just a space in the text.
                    const q = self.ask.?.questions[self.ask_qi];
                    if (q.multi and self.ask_sel < q.n) {
                        self.ask_picked[self.ask_sel] = !self.ask_picked[self.ask_sel];
                    } else if (self.ask_sel == other and self.ask_text_len < self.ask_text.len) {
                        self.ask_text[self.ask_text_len] = ' ';
                        self.ask_text_len += 1;
                    }
                },
                else => {
                    // Typing anywhere jumps to Other and starts writing:
                    // the row exists so a human never has to pick from
                    // options that miss the point.
                    if (b >= 0x20 and b < 0x7f and self.ask_text_len < self.ask_text.len) {
                        self.ask_sel = other;
                        self.ask_text[self.ask_text_len] = b;
                        self.ask_text_len += 1;
                    }
                },
            }
            i += 1;
        }
        self.scene_dirty = true;
    }

    /// Enter: record this question's picks, then move on or submit.
    fn askAdvanceLocked(self: *App) void {
        const a = self.ask orelse return;
        const q = a.questions[self.ask_qi];
        if (q.multi) {
            self.ask_answers[self.ask_qi] = self.ask_picked;
        } else if (self.ask_sel < q.n) {
            self.ask_answers[self.ask_qi][self.ask_sel] = true;
        }
        // Nothing chosen and nothing typed on a question that HAS options
        // is not an answer — hold rather than sending an empty decision
        // the agent would have to interpret.
        const picked_any = blk: {
            for (self.ask_answers[self.ask_qi][0..q.n]) |p| {
                if (p) break :blk true;
            }
            break :blk false;
        };
        if (!picked_any and self.ask_text_len == 0 and !q.free_text) return;

        if (self.ask_qi + 1 < a.n) {
            self.ask_qi += 1;
            self.askSeedLocked();
            self.scene_dirty = true;
            return;
        }
        self.askSubmitLocked();
    }

    /// The deck's key path — vim keys over the list, Enter to go there.
    /// Caller holds draw_lock.
    pub fn deckKeyLocked(self: *App, bytes: []const u8) void {
        const n = self.deck.slice().len;
        var i: usize = 0;
        while (i < bytes.len) {
            const b = bytes[i];
            if (b == 0x1b and i + 2 < bytes.len and bytes[i + 1] == '[') {
                switch (bytes[i + 2]) {
                    'A' => self.deck_sel -|= 1,
                    'B' => self.deck_sel = @min(self.deck_sel + 1, n -| 1),
                    else => {},
                }
                i += 3;
                continue;
            }
            switch (b) {
                0x1b => { // ESC yields the keys back to the panes
                    self.side_focus = false;
                    self.scene_dirty = true;
                    return;
                },
                'k', 0x10 => self.deck_sel -|= 1,
                'j', 0x0e => self.deck_sel = @min(self.deck_sel + 1, n -| 1),
                'g' => self.deck_sel = 0,
                'G' => self.deck_sel = n -| 1,
                '\r', '\n' => {
                    // Enter OPENS the agent — its transcript. That is what
                    // "open this row" means in a deck, and it is the
                    // question the deck could not answer before: what did
                    // it actually say.
                    if (self.deck_sel < n)
                        self.requestTranscriptLocked(self.deck.slice()[self.deck_sel].id.get());
                    self.scene_dirty = true;
                    return;
                },
                0x07 => { // ⌃G — go to its pane, same meaning as in the ask form
                    if (self.deck_sel < n) {
                        const a = self.deck.slice()[self.deck_sel];
                        if (self.jumpToCwdLocked(a.cwd.get())) self.side_focus = false;
                    }
                    self.scene_dirty = true;
                    return;
                },
                else => {},
            }
            i += 1;
        }
        self.scene_dirty = true;
    }

    /// Ask for an agent's transcript. Returns immediately — the fetch is
    /// a document-sized blocking HTTP read and must not sit on the key
    /// path. Caller holds draw_lock.
    pub fn requestTranscriptLocked(self: *App, id: []const u8) void {
        const n = @min(id.len, self.tx_req.len);
        if (n == 0) return;
        @memcpy(self.tx_req[0..n], id[0..n]);
        self.tx_req_len = n;
        self.tx_wake.store(true, .release);
    }

    /// The editor's save seam for projected buffers. Queues; never
    /// blocks the key path on the network.
    ///
    /// The buffer NAME carries the identity (`thread:42`), the same
    /// trick the transcript pane uses — so which thread a save belongs
    /// to is a property of the pane, not of some "currently open thread"
    /// on the App that a second pane would fight over.
    fn editorSave(ctx: *anyopaque, name: []const u8, content: []const u8) bool {
        const self: *App = @ptrCast(@alignCast(ctx));
        const id = threadIdOf(name) orelse return false;
        if (content.len > self.thr_save_body.len) return false;
        @memcpy(self.thr_save_body[0..content.len], content);
        self.thr_save_len = content.len;
        self.thr_save_id = id;
        self.thr_wake.store(true, .release);
        return true;
    }

    /// Remember the immutable prefix we were handed, so a later save can
    /// split the buffer on it EXACTLY rather than by scanning for the
    /// scissors line — which a comment body could legally contain.
    pub fn rememberThreadPrefix(self: *App, id: i64, prefix: []const u8) void {
        self.draw_lock.lock();
        defer self.draw_lock.unlock();
        if (self.thr_prefix.len > 0) self.gpa.free(self.thr_prefix);
        self.thr_prefix = self.gpa.dupe(u8, prefix) catch &.{};
        self.thr_prefix_id = id;
    }

    /// Put a fresh doc into whichever pane holds this thread, keeping
    /// the pane and the cursor's line where they were.
    pub fn replaceThreadDoc(self: *App, id: i64, content: []const u8, prefix: []const u8, note: ?[]const u8) void {
        self.rememberThreadPrefix(id, prefix);
        var name: [32]u8 = undefined;
        const label = std.fmt.bufPrint(&name, "thread:{d}", .{id}) catch return;
        self.draw_lock.lock();
        defer self.draw_lock.unlock();
        for (self.spaces.items) |s| {
            for (s.tabs.items) |t| {
                for (t.panes.items) |p| {
                    const ed = p.editor() orelse continue;
                    if (!std.mem.eql(u8, ed.buf.path orelse "", label)) continue;
                    const line = ed.cline;
                    ed.openText(label, content) catch continue;
                    ed.cline = @min(line, ed.lineCountB() -| 1);
                    if (note) |n| ed.setStatus("{s}", .{n}, false);
                    self.scene_dirty = true;
                }
            }
        }
    }

    /// Report a save/verb outcome on the thread's own pane.
    pub fn setThreadStatus(self: *App, id: i64, msg: []const u8) void {
        var name: [32]u8 = undefined;
        const label = std.fmt.bufPrint(&name, "thread:{d}", .{id}) catch return;
        self.draw_lock.lock();
        defer self.draw_lock.unlock();
        for (self.spaces.items) |s| {
            for (s.tabs.items) |t| {
                for (t.panes.items) |p| {
                    const ed = p.editor() orelse continue;
                    if (!std.mem.eql(u8, ed.buf.path orelse "", label)) continue;
                    ed.setStatus("{s}", .{msg}, false);
                    self.scene_dirty = true;
                }
            }
        }
    }

    /// `thread:42` → 42. Any other buffer name is not a thread.
    fn threadIdOf(name: []const u8) ?i64 {
        if (!std.mem.startsWith(u8, name, "thread:")) return null;
        return std.fmt.parseInt(i64, name["thread:".len..], 10) catch null;
    }

    /// The thread under the deck-style cursor, if the focused pane holds
    /// one. Used by :ThreadNote / :ThreadAsk / :ThreadResolve.
    fn focusedThreadId(self: *App) ?i64 {
        const ed = self.activeTab().focused.editor() orelse return null;
        return threadIdOf(ed.buf.path orelse "");
    }

    fn queueThreadVerbLocked(self: *App, id: i64, name: []const u8) void {
        const n = @min(name.len, self.thr_verb.len);
        @memcpy(self.thr_verb[0..n], name[0..n]);
        self.thr_verb_len = n;
        self.thr_verb_id = id;
        self.thr_wake.store(true, .release);
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
        const ed = editorpkg.Editor.create(self.gpa, self.io, null) catch return;
        @import("syntax.zig").attach(ed, self.gpa);
        self.attachCommands(ed);
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

    /// Queue a diff view. Empty `path` means every changed file.
    ///
    /// Queued rather than built, because building forks git once per file
    /// and this is called from the key path — including from the review
    /// panel, where the alternative is the whole window freezing on the
    /// keystroke that was supposed to show you the code.
    pub fn requestDiff(self: *App, path: []const u8, line: i64) void {
        self.draw_lock.lock();
        self.diff_path_len = @min(path.len, self.diff_path.len);
        @memcpy(self.diff_path[0..self.diff_path_len], path[0..self.diff_path_len]);
        self.diff_line = line;
        self.diff_req = true;
        self.draw_lock.unlock();
        self.rev_wake.store(true, .release);
    }

    /// Put a built diff document into a pane, decorated and locked.
    ///
    /// The three arrays travel together and are indexed by the same line,
    /// which is the invariant diffdoc.zig exists to hold — so they are
    /// handed over in one call rather than assembled here.
    pub fn showDiff(self: *App, name: []const u8, doc: *const @import("diffdoc.zig").Doc, row: usize) void {
        self.openTextPane(name, doc.text);
        self.draw_lock.lock();
        defer self.draw_lock.unlock();
        const ed = self.activeTab().focused.editor() orelse return;

        var styles = self.gpa.alloc(editorpkg.Style, doc.rows.len) catch return;
        defer self.gpa.free(styles);
        var nums = self.gpa.alloc(u32, doc.rows.len) catch return;
        defer self.gpa.free(nums);
        for (doc.rows, 0..) |r, i| {
            styles[i] = switch (r.kind) {
                .add => .diff_add,
                .del => .diff_del,
                .hunk => .diff_hunk,
                .meta => .diff_meta,
                .context => .text,
            };
            // ONE number, and which side it is depends on the row: a
            // deletion belongs to the original, everything else to the
            // modified side. The +/- prefix already says which file the
            // number is in, so a second column would be spending four
            // columns of a terminal to repeat it.
            nums[i] = if (r.kind == .del) r.old_line else r.new_line;
        }
        ed.setDecor(styles, nums) catch return;
        ed.cline = @min(row, doc.rows.len -| 1);
        ed.ccol = 0;
        ed.top = row -| 3; // a little context above where you landed
        self.scene_dirty = true;
    }

    /// Bring a pending question back to the front.
    ///
    /// Needed because the form HOLDS the ask while it is open, so the
    /// poller will not offer another one — switching panels (or jumping
    /// to source) without this leaves the question alive but unreachable,
    /// and the asker blocked with no way to answer it. Found by writing
    /// the e2e for the jump.
    pub fn showPendingAsk(self: *App) void {
        self.draw_lock.lock();
        defer self.draw_lock.unlock();
        if (self.ask == null) return;
        self.side_panel = .ask;
        self.side_open = true;
        self.side_focus = true;
        self.relayoutLocked();
        self.scene_dirty = true;
    }

    /// Toggle the deck. Unlike the inbox it opens FOCUSED: it is a
    /// navigable list whose whole point is that you move through it and
    /// pick one, so handing it the keys is the action you wanted.
    pub fn toggleDeck(self: *App) void {
        {
            self.draw_lock.lock();
            defer self.draw_lock.unlock();
            if (self.side_open and self.side_panel == .deck) {
                self.side_open = false;
                self.side_focus = false;
            } else {
                self.side_panel = .deck;
                self.side_open = true;
                self.side_focus = true;
                self.deck_sel = 0;
            }
            self.relayoutLocked();
            self.scene_dirty = true;
        }
        self.deck_wake.store(true, .release);
    }

    pub fn toggleThreads(self: *App) void {
        {
            self.draw_lock.lock();
            defer self.draw_lock.unlock();
            if (self.side_open and self.side_panel == .threads) {
                self.side_open = false;
                self.side_focus = false;
            } else {
                self.side_panel = .threads;
                self.side_open = true;
                self.side_focus = true;
                self.thr_sel = 0;
            }
            self.relayoutLocked();
            self.scene_dirty = true;
        }
        self.thr_wake.store(true, .release);
    }

    /// A thread verb against whatever thread the focused pane holds.
    /// Says so when the pane is not a thread, rather than doing nothing —
    /// a silent no-op on `:ThreadNote` is indistinguishable from a bug.
    pub fn threadVerb(self: *App, name: []const u8) void {
        self.draw_lock.lock();
        defer self.draw_lock.unlock();
        const id = self.focusedThreadId() orelse {
            if (self.activeTab().focused.editor()) |ed|
                ed.setStatus("not a thread buffer", .{}, true);
            self.scene_dirty = true;
            return;
        };
        self.queueThreadVerbLocked(id, name);
    }

    /// The threads panel's key path: vim keys, Enter opens the doc.
    pub fn threadsKeyLocked(self: *App, bytes: []const u8) void {
        const n = self.thr.slice().len;
        var i: usize = 0;
        while (i < bytes.len) {
            const b = bytes[i];
            if (b == 0x1b and i + 2 < bytes.len and bytes[i + 1] == '[') {
                switch (bytes[i + 2]) {
                    'A' => self.thr_sel -|= 1,
                    'B' => self.thr_sel = @min(self.thr_sel + 1, n -| 1),
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
                'k', 0x10 => self.thr_sel -|= 1,
                'j', 0x0e => self.thr_sel = @min(self.thr_sel + 1, n -| 1),
                'g' => self.thr_sel = 0,
                'G' => self.thr_sel = n -| 1,
                '\r', '\n' => {
                    if (self.thr_sel < n) {
                        self.thr_open_req = self.thr.slice()[self.thr_sel].id;
                        self.thr_wake.store(true, .release);
                        self.side_focus = false;
                    }
                    self.scene_dirty = true;
                    return;
                },
                else => {},
            }
            i += 1;
        }
        self.scene_dirty = true;
    }

    pub fn toggleReview(self: *App) void {
        {
            self.draw_lock.lock();
            defer self.draw_lock.unlock();
            if (self.side_open and self.side_panel == .review) {
                self.side_open = false;
                self.side_focus = false;
            } else {
                self.side_panel = .review;
                self.side_open = true;
                self.side_focus = true;
                self.rev_sel = 0;
            }
            self.relayoutLocked();
            self.scene_dirty = true;
        }
        self.rev_wake.store(true, .release);
    }

    /// The review panel's keys: move, open, and the three verdicts.
    /// a/r/d rather than a menu, because triaging 52 findings is the
    /// actual workload and every extra keystroke is paid 52 times.
    pub fn reviewKeyLocked(self: *App, bytes: []const u8) void {
        const n = self.rev.slice().len;
        var i: usize = 0;
        while (i < bytes.len) {
            const b = bytes[i];
            if (b == 0x1b and i + 2 < bytes.len and bytes[i + 1] == '[') {
                switch (bytes[i + 2]) {
                    'A' => self.rev_sel -|= 1,
                    'B' => self.rev_sel = @min(self.rev_sel + 1, n -| 1),
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
                'k', 0x10 => self.rev_sel -|= 1,
                'j', 0x0e => self.rev_sel = @min(self.rev_sel + 1, n -| 1),
                'g' => self.rev_sel = 0,
                'G' => self.rev_sel = n -| 1,
                'a' => self.queueVerdictLocked("approved"),
                'r' => self.queueVerdictLocked("rejected"),
                'd' => self.queueVerdictLocked("deferred"),
                // The CHANGE this finding is about, rather than the file
                // it lives in. Additive: Enter still opens the file at
                // the line, because that is the motion already in
                // people's hands and a verdict often needs the
                // surrounding code rather than the patch.
                //
                // Set inline instead of through requestDiff: the caller
                // holds draw_lock, and taking it again would deadlock on
                // the keystroke.
                'D' => {
                    if (self.rev_sel < n) {
                        const f = self.rev.slice()[self.rev_sel];
                        const p = f.path.get();
                        self.diff_path_len = @min(p.len, self.diff_path.len);
                        @memcpy(self.diff_path[0..self.diff_path_len], p[0..self.diff_path_len]);
                        self.diff_line = f.line;
                        self.diff_req = true;
                        self.rev_wake.store(true, .release);
                        self.side_focus = false;
                    }
                    self.scene_dirty = true;
                    return;
                },
                '\r', '\n' => {
                    if (self.rev_sel < n) {
                        const f = self.rev.slice()[self.rev_sel];
                        self.rev_open_path_len = @min(f.path.get().len, self.rev_open_path.len);
                        @memcpy(self.rev_open_path[0..self.rev_open_path_len], f.path.get()[0..self.rev_open_path_len]);
                        self.rev_open_line = f.line;
                        self.side_focus = false;
                    }
                    self.scene_dirty = true;
                    return;
                },
                else => {},
            }
            i += 1;
        }
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
        ed.app_save = &editorSave;
        ed.app_quit_all = &editorQuitAll;
        ed.app_open = &editorOpenRequest;
        ed.leader = self.keybinds.ed_leader;
        ed.bufline_mode = switch (self.cfg_bufline) {
            .off => .off,
            .multiple => .multiple,
            .always => .always,
        };
        ed.default_insert = self.cfg_ed_insert;
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
                if (req.line > 0) {
                    _ = self.openEditorAtLine(path, @intCast(req.line + 1));
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
        const ed = editorpkg.Editor.create(self.gpa, self.io, path) catch {
            self.draw_lock.unlock();
            return;
        };
        @import("syntax.zig").attach(ed, self.gpa);
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
                self.writeFocused(&[1]u8{ch}, ts);
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
    /// only — that is the pane the blink telegraphs — and a terminal
    /// that hid its cursor (DECTCEM) has nothing to blink. Reads the
    /// last snapshot's cursor state, which is exactly what fillPane
    /// will draw. Caller holds draw_lock.
    fn focusedCursorShowing(self: *App) bool {
        return switch (self.activeTab().focused.content) {
            .term => |*tm| tm.rs.cursor.visible and tm.rs.cursor.viewport != null,
            .edit => true,
        };
    }

    fn drawFrame(self: *App) void {
        const pool = objc.AutoreleasePool.init();
        defer pool.deinit();

        const tick = self.frame_count.fetchAdd(1, .monotonic);
        const t_start = CACurrentMediaTime();

        self.reapExitedLocked();
        self.drainClipboardLocked();

        // HUD refresh at ~2Hz. Runs on skipped ticks too, so the bar
        // stays live during idle — but only a text CHANGE causes a draw.
        if (tick % 60 == 0) self.refreshHudLocked(t_start);

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
        const shot_wanted = self.shot_state.load(.acquire) == 2;
        if (!any_dirty and !shot_wanted) {
            _ = stats.global.frames_skipped.fetchAdd(1, .monotonic);
            return;
        }
        self.scene_dirty = false;
        stats.global.frame_update.recordSeconds(t_update - t_start);

        // Fill the shared GPU cell buffer: each pane bump-allocates a
        // slot. The snapshot is the authority on grid dims; during a
        // resize it may briefly disagree with the rect, which is fine.
        const cells = self.renderer.cells();
        var off: usize = 0;
        for (atab.panes.items) |p| {
            p.drawn_cols = 0;
            p.drawn_rows = 0;
            if (p.rect.w == 0) continue;
            const cols: usize = switch (p.content) {
                .term => |*tm| tm.rs.cols,
                .edit => p.cols,
            };
            var rows: usize = switch (p.content) {
                .term => |*tm| tm.rs.rows,
                .edit => p.rows,
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
            .edit => rgb4(th.ed_bg),
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
                .edit => rgb4(th.ed_bg),
            };
            self.renderer.drawRect(enc, vp_w, vp_h, p.rect.x, p.rect.y, p.rect.w, p.rect.h, .{ bg.r, bg.g, bg.b, self.bg_alpha });
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
                        .term => continue,
                    };
                    if (ed.synthetic or ed.is_dir) continue;
                    if (!ed.buf.changedOnDisk(self.io)) {
                        if (ed.disk_changed) {
                            ed.disk_changed = false;
                            ed.render_dirty = true;
                            self.scene_dirty = true;
                        }
                        continue;
                    }
                    if (ed.buf.isModified()) {
                        if (!ed.disk_changed) {
                            ed.disk_changed = true;
                            ed.render_dirty = true;
                            self.scene_dirty = true;
                        }
                        continue;
                    }
                    // A reload that fails leaves the buffer exactly as it
                    // was, which is the right outcome for a transient
                    // read error — we try again next tick.
                    ed.reload() catch continue;
                    self.scene_dirty = true;
                }
            }
        }
    }

    fn pollConfigLocked(self: *App) void {
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
        self.cursor_blink = cfg.cursor_blink;

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
                    ed.bufline_mode = switch (self.cfg_bufline) {
                        .off => .off,
                        .multiple => .multiple,
                        .always => .always,
                    };
                    // The default applies to the NEXT open; a live
                    // editor's current mode is the user's, not ours.
                    ed.default_insert = self.cfg_ed_insert;
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
            .usage => if (self.usage.len > 0) @as(f32, @floatFromInt(self.usage.len)) * cw + 2 * cw else 0,
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
            .usage => {
                if (self.usage.len > 0) {
                    const ufg = if (self.usage.worst >= 90)
                        th.ed_err
                    else if (self.usage.worst >= 70)
                        statusAccent()
                    else
                        statusFg();
                    x.* += ui.text(x.*, ty, self.usage.slice(), ufg, bg);
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
        var items: [33]WkItem = undefined;
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
        // VS Code's magnifier is find-in-files, which rook does not
        // have yet; of the two things it could mean today, "find a
        // file" is the closer read of the glyph than "run a command"
        // — and the command palette has ⌘K plus a bar hint already.
        .{ .glyph = "\u{f002}", .title = "search", .action = .palette_files },
        .{ .glyph = "\u{f126}", .title = "scm", .action = .diff_open },
        .{ .glyph = "\u{f085}", .title = "agents", .action = .panel_deck },
        .{ .glyph = "\u{f00c}", .title = "review", .action = .panel_review },
    };

    /// Is a rail item's surface currently up? Only the side-pane
    /// tenants can answer honestly (the tree is per-pane, the palette
    /// is modal) — the rest never light.
    fn railActive(self: *App, action: cfgpkg.Action) bool {
        return switch (action) {
            .panel_deck => self.side_open and self.side_panel == .deck,
            .panel_review => self.side_open and self.side_panel == .review,
            else => false,
        };
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
        if (self.cfg_top_bar.has(.usage) and self.usage.len > 0) {
            const ufg = if (self.usage.worst >= 90)
                th.ed_err
            else if (self.usage.worst >= 70)
                th.accent
            else
                th.bar_fg;
            _ = ui.textRight(self.px_w - self.m.gutter, zone_ty, self.usage.slice(), ufg, self.glassBg(th.bar_bg));
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
            .attention => "ATTENTION",
            .ask => "QUESTION",
            .deck => "AGENTS",
            .threads => "THREADS",
            .review => "REVIEW",
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
            .attention => self.drawAttention(ui, r, y),
            .ask => self.drawAsk(ui, r, y),
            .deck => self.drawDeck(ui, r, y),
            .threads => self.drawThreads(ui, r, y),
            .review => self.drawReview(ui, r, y),
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

    fn drawReview(self: *App, ui: *@import("ui.zig").Ui, r: panespkg.Rect, top: f32) void {
        const cw = self.renderer.cell_w;
        const ch = self.renderer.cell_h;
        const row_h = self.bar_h;
        const bg = self.glassBg(th.bar_bg);
        const tx = r.x + self.m.gutter;
        var y = top;
        var clipbuf: [256]u8 = undefined;

        if (!self.rev.live) {
            _ = ui.text(tx, y + (row_h - ch) / 2, "host unreachable", th.bar_fg, bg);
            return;
        }
        if (!self.rev.any) {
            _ = ui.text(tx, y + (row_h - ch) / 2, "no review in this workspace", th.bar_fg, bg);
            return;
        }

        const cols: usize = @intFromFloat(@max(1, @divFloor(r.w - self.m.gutter * 2, cw)));
        // THE GATE, first and unmissable: it is the answer to the only
        // question this panel exists for — can I ship this yet.
        var gbuf: [96]u8 = undefined;
        const g = if (self.rev.ready)
            std.fmt.bufPrint(&gbuf, "{s} READY · {d} reviewed", .{ self.rev.verb.get(), self.rev.total }) catch ""
        else
            std.fmt.bufPrint(&gbuf, "{s} blocked · {d} of {d} left", .{ self.rev.verb.get(), self.rev.blocking, self.rev.total }) catch "";
        _ = ui.text(tx, y + (row_h - ch) / 2, uipkg.clip(&clipbuf, g, cols), if (self.rev.ready) th.accent else th.ed_err, bg);
        y += row_h;
        const lbl = self.rev.label.get();
        _ = ui.text(tx, y + (row_h - ch) / 2, uipkg.clip(&clipbuf, lbl, cols), th.bar_fg, bg);
        y += row_h;

        const avail = r.y + r.h - y - row_h;
        const fits: usize = @intFromFloat(@max(0, @divFloor(avail, row_h * 2)));
        const shown = @min(self.rev.slice().len, fits);

        for (self.rev.slice()[0..shown], 0..) |*f, i| {
            const selected = i == self.rev_sel;
            if (selected) self.drawRowSelection(ui, r, y, row_h * 2);
            const mfg = switch (f.state) {
                .approved, .deferred => th.bar_fg,
                .rejected => th.ed_err,
                else => th.accent,
            };
            var mx = tx;
            mx += ui.textOver(mx, y + (row_h - ch) / 2, f.state.mark(), mfg);
            var loc: [140]u8 = undefined;
            const base = f.path.get();
            const file = if (std.mem.lastIndexOfScalar(u8, base, '/')) |sl| base[sl + 1 ..] else base;
            const s2 = std.fmt.bufPrint(&loc, "{s}:{d}", .{ file, f.line }) catch file;
            _ = ui.textOver(mx, y + (row_h - ch) / 2, uipkg.clip(&clipbuf, s2, cols -| 2), if (selected) th.bar_value else th.bar_fg);
            if (f.risk >= 7)
                _ = ui.textOverRight(r.x + r.w - self.m.gutter, y + (row_h - ch) / 2, "risk", th.ed_err);
            y += row_h;
            const wtxt = f.what.get();
            _ = ui.textOver(tx + cw * 2, y + (row_h - ch) / 2, uipkg.clip(&clipbuf, wtxt, cols -| 2), th.bar_fg);
            y += row_h;
        }
        const hidden = self.rev.slice().len - shown + self.rev.more;
        if (hidden > 0) {
            var buf: [32]u8 = undefined;
            const s3 = std.fmt.bufPrint(&buf, "+{d} more", .{hidden}) catch "+more";
            _ = ui.text(tx, y + (row_h - ch) / 2, s3, th.bar_fg, bg);
            y += row_h;
        }
        if (self.side_focus)
            _ = ui.text(tx, y + (row_h - ch) / 2, "a/r/d verdict · enter file · D diff", th.bar_fg, bg);
    }

    fn drawThreads(self: *App, ui: *@import("ui.zig").Ui, r: panespkg.Rect, top: f32) void {
        const cw = self.renderer.cell_w;
        const ch = self.renderer.cell_h;
        const row_h = self.bar_h;
        const bg = self.glassBg(th.bar_bg);
        const tx = r.x + self.m.gutter;
        var y = top;
        var clipbuf: [256]u8 = undefined;

        if (!self.thr.live) {
            _ = ui.text(tx, y + (row_h - ch) / 2, "host unreachable", th.bar_fg, bg);
            return;
        }
        if (self.thr.n == 0) {
            _ = ui.text(tx, y + (row_h - ch) / 2, "no open threads", th.bar_fg, bg);
            return;
        }
        const cols: usize = @intFromFloat(@max(1, @divFloor(r.w - self.m.gutter * 2, cw)));
        const avail = r.y + r.h - top - row_h;
        const fits: usize = @intFromFloat(@max(0, @divFloor(avail, row_h * 2)));
        const shown = @min(self.thr.slice().len, fits);

        for (self.thr.slice()[0..shown], 0..) |*t, i| {
            const selected = i == self.thr_sel;
            if (selected) self.drawRowSelection(ui, r, y, row_h * 2);
            // An UNDELIVERED thread is the one failure the old model
            // rendered as a normal wait: submitted, and nobody was told.
            const mark: []const u8 = if (t.undelivered) "! " else if (t.has_draft) "✎ " else "· ";
            const mfg = if (t.undelivered) th.ed_err else if (t.has_draft) th.accent else th.bar_fg;
            var mx = tx;
            mx += ui.textOver(mx, y + (row_h - ch) / 2, mark, mfg);
            var loc: [140]u8 = undefined;
            const base = t.path.get();
            const file = if (std.mem.lastIndexOfScalar(u8, base, '/')) |sl| base[sl + 1 ..] else base;
            const s2 = std.fmt.bufPrint(&loc, "{s}:{d}", .{ file, t.line }) catch file;
            _ = ui.textOver(mx, y + (row_h - ch) / 2, uipkg.clip(&clipbuf, s2, cols -| 2), if (selected) th.bar_value else th.bar_fg);
            y += row_h;
            const a = t.anchor.get();
            _ = ui.textOver(tx + cw * 2, y + (row_h - ch) / 2, uipkg.clip(&clipbuf, a, cols -| 2), th.bar_fg);
            y += row_h;
        }
        const hidden = self.thr.slice().len - shown + self.thr.more;
        if (hidden > 0) {
            var buf: [32]u8 = undefined;
            const s3 = std.fmt.bufPrint(&buf, "+{d} more", .{hidden}) catch "+more";
            _ = ui.text(tx, y + (row_h - ch) / 2, s3, th.bar_fg, bg);
            y += row_h;
        }
        if (self.side_focus)
            _ = ui.text(tx, y + (row_h - ch) / 2, "j/k · enter opens", th.bar_fg, bg);
    }

    fn drawDeck(self: *App, ui: *@import("ui.zig").Ui, r: panespkg.Rect, top: f32) void {
        const cw = self.renderer.cell_w;
        const ch = self.renderer.cell_h;
        const row_h = self.bar_h;
        const bg = self.glassBg(th.bar_bg);
        const tx = r.x + self.m.gutter;
        var y = top;
        var clipbuf: [256]u8 = undefined;

        if (!self.deck.live) {
            _ = ui.text(tx, y + (row_h - ch) / 2, "host unreachable", th.bar_fg, bg);
            return;
        }
        if (self.deck.n == 0) {
            _ = ui.text(tx, y + (row_h - ch) / 2, "no agents running", th.bar_fg, bg);
            return;
        }

        const cols: usize = @intFromFloat(@max(1, @divFloor(r.w - self.m.gutter * 2, cw)));
        const avail = r.y + r.h - top - row_h; // keep a line for the hint
        const fits: usize = @intFromFloat(@max(0, @divFloor(avail, row_h * 2)));
        const shown = @min(self.deck.slice().len, fits);

        for (self.deck.slice()[0..shown], 0..) |*a, i| {
            const selected = i == self.deck_sel;
            if (selected) self.drawRowSelection(ui, r, y, row_h * 2);
            // The state dot carries the whole triage: what needs you is
            // the accent, what is moving is normal, what is idle recedes.
            const dot: []const u8 = switch (a.state) {
                .needs_input => "● ",
                .working => "◐ ",
                .quiet => "○ ",
            };
            const dotfg = switch (a.state) {
                .needs_input => th.accent,
                .working => th.bar_value,
                .quiet => th.bar_fg,
            };
            var mx = tx;
            mx += ui.textOver(mx, y + (row_h - ch) / 2, dot, dotfg);
            // Workspace-relative, not the last path segment: an agent in
            // rook/app must not read as "app", which every repo has.
            var lblbuf: [96]u8 = undefined;
            const name = self.cwdLabel(a.cwd.get(), &lblbuf);
            _ = ui.textOver(mx, y + (row_h - ch) / 2, uipkg.clip(&clipbuf, name, cols -| 2), if (selected) th.bar_value else th.bar_fg);
            if (a.interactive)
                _ = ui.textOverRight(r.x + r.w - self.m.gutter, y + (row_h - ch) / 2, "picker", th.bar_fg);
            y += row_h;
            const what = a.what.get();
            _ = ui.textOver(tx + cw * 2, y + (row_h - ch) / 2, uipkg.clip(&clipbuf, what, cols -| 2), th.bar_fg);
            y += row_h;
        }

        const hidden = self.deck.slice().len - shown + self.deck.more;
        if (hidden > 0) {
            var buf: [32]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "+{d} more", .{hidden}) catch "+more";
            _ = ui.text(tx, y + (row_h - ch) / 2, s, th.bar_fg, bg);
            y += row_h;
        }
        if (self.side_focus)
            _ = ui.text(tx, y + (row_h - ch) / 2, "j/k · enter opens · ^G goes there", th.bar_fg, bg);
    }

    fn drawAsk(self: *App, ui: *@import("ui.zig").Ui, r: panespkg.Rect, top: f32) void {
        const cw = self.renderer.cell_w;
        const ch = self.renderer.cell_h;
        const row_h = self.bar_h;
        const bg = self.glassBg(th.bar_bg);
        const tx = r.x + self.m.gutter;
        var y = top;
        var clipbuf: [256]u8 = undefined;
        const a = self.ask orelse {
            _ = ui.text(tx, y + (row_h - ch) / 2, "no question", th.bar_fg, bg);
            return;
        };
        const q = a.questions[self.ask_qi];
        const cols: usize = @intFromFloat(@max(1, @divFloor(r.w - self.m.gutter * 2, cw)));

        // WHO is asking. Without it a question is a demand from nowhere,
        // and with several agents running it is unanswerable — you cannot
        // judge "ship it?" without knowing which repo is shipping.
        if (a.cwd.len > 0) {
            var srcbuf: [96]u8 = undefined;
            const src = self.askSourceLabel(&srcbuf);
            _ = ui.text(tx, y + (row_h - ch) / 2, uipkg.clip(&clipbuf, src, cols), th.accent, bg);
            y += row_h;
        }

        // "2/3" when an ask has several questions — a form that hides how
        // much is left is a form people abandon.
        if (a.n > 1) {
            var buf: [16]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "{d}/{d}", .{ self.ask_qi + 1, a.n }) catch "";
            _ = ui.textRight(r.x + r.w - self.m.gutter, y + (row_h - ch) / 2 - row_h, s, th.bar_fg, bg);
        }

        // The question, wrapped by hand — ui.text does not wrap and an
        // ask is a sentence, not a label.
        y = self.wrapText(ui, q.text.get(), tx, y, cols, row_h, ch, th.bar_value, bg);
        y += self.sep * 2;

        for (q.options[0..q.n], 0..) |o, i| {
            const selected = i == self.ask_sel;
            if (selected) self.drawRowSelection(ui, r, y, row_h);
            // ● / ○ for single, [x] / [ ] for multi — the mark says which
            // KIND of question this is without a word of explanation.
            const mark: []const u8 = if (q.multi)
                (if (self.ask_picked[i]) "[x] " else "[ ] ")
            else
                (if (selected) "(*) " else "( ) ");
            var mx = tx;
            mx += ui.textOver(mx, y + (row_h - ch) / 2, mark, if (selected) th.accent else th.bar_fg);
            const lbl = o.label.get();
            _ = ui.textOver(mx, y + (row_h - ch) / 2, uipkg.clip(&clipbuf, lbl, cols -| 4), if (selected) th.bar_value else th.bar_fg);
            y += row_h;
            // The description only for the row under the cursor: all of
            // them at once is a wall, none of them loses the tradeoff.
            if (selected and o.desc.len > 0)
                y = self.wrapText(ui, o.desc.get(), tx + cw * 4, y, cols -| 4, row_h, ch, th.bar_fg, bg);
        }

        // The Other row — always present, so a human is never forced to
        // pick from options that miss the point.
        const other = self.askOtherRow();
        const osel = self.ask_sel == other;
        if (osel) self.drawRowSelection(ui, r, y, row_h);
        var ox = tx;
        ox += ui.textOver(ox, y + (row_h - ch) / 2, if (q.free_text) "> " else "(+) ", if (osel) th.accent else th.bar_fg);
        if (self.ask_text_len > 0) {
            const t = self.ask_text[0..self.ask_text_len];
            _ = ui.textOver(ox, y + (row_h - ch) / 2, t[t.len -| (cols -| 4) ..], th.bar_value);
        } else {
            _ = ui.textOver(ox, y + (row_h - ch) / 2, if (q.free_text) "type an answer" else "Other…", th.bar_fg);
        }
        if (osel) {
            const used: f32 = @floatFromInt(@min(self.ask_text_len, cols -| 4) + 4);
            ui.rect(tx + used * cw, y + (row_h - ch) / 2, cw / 4, ch, th.accent);
        }
        y += row_h * 2;

        var hint: [96]u8 = undefined;
        const h = std.fmt.bufPrint(&hint, "{s}enter sends · esc dismisses{s}", .{
            @as([]const u8, if (q.multi) "space ticks · " else ""),
            @as([]const u8, if (a.cwd.len > 0) " · ^G goes there" else ""),
        }) catch "enter sends · esc dismisses";
        _ = ui.text(tx, y + (row_h - ch) / 2, uipkg.clip(&clipbuf, h, cols), th.bar_fg, bg);
    }

    /// How to name where an ask came from. A workspace name if the cwd is
    /// inside one — that is the word a human thinks in — else the tail of
    /// the path, which is still more use than the whole thing truncated
    /// at the wrong end. Caller holds draw_lock.
    pub fn askSourceLabel(self: *App, buf: []u8) []const u8 {
        const a = self.ask orelse return "";
        if (a.cwd.len == 0) return "";
        var inner: [96]u8 = undefined;
        const lbl = self.cwdLabel(a.cwd.get(), &inner);
        return std.fmt.bufPrint(buf, "from {s}", .{lbl}) catch lbl;
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

    fn drawAttention(self: *App, ui: *@import("ui.zig").Ui, r: panespkg.Rect, top: f32) void {
        const cw = self.renderer.cell_w;
        const ch = self.renderer.cell_h;
        const row_h = self.bar_h;
        const bg = self.glassBg(th.bar_bg);
        const tx = r.x + self.m.gutter;
        var y = top;
        var clipbuf: [256]u8 = undefined;

        // "Nothing needs you" and "we can't reach the host" are
        // different facts and must not render the same.
        if (!self.attention.live) {
            _ = ui.text(tx, y + (row_h - ch) / 2, "host unreachable", th.bar_fg, bg);
            return;
        }
        if (self.attention.n == 0) {
            _ = ui.text(tx, y + (row_h - ch) / 2, "nothing waiting", th.bar_fg, bg);
            return;
        }

        // Room for the rows, less one line kept back for the overflow
        // note when there is one.
        const avail = r.y + r.h - top - (if (self.attention.more > 0) row_h else 0);
        const fits: usize = @intFromFloat(@max(0, @divFloor(avail, row_h * 2)));
        const shown = @min(self.attention.slice().len, fits);

        for (self.attention.slice()[0..shown]) |*it| {
            // Two lines per item: workspace, then what it wants. An ask
            // is a sentence — one line would truncate all of them.
            ui.rect(r.x, y + self.sep, self.sep * 2, row_h * 2 - self.sep * 2, th.accent);
            _ = ui.text(tx, y + (row_h - ch) / 2, it.workspace(), th.bar_value, bg);
            if (it.interactive)
                _ = ui.textRight(r.x + r.w - self.m.gutter, y + (row_h - ch) / 2, "picker", th.bar_fg, bg);
            y += row_h;
            const room: usize = @intFromFloat(@max(0, @divFloor(r.w - self.m.gutter * 2, cw)));
            _ = ui.text(tx, y + (row_h - ch) / 2, uipkg.clip(&clipbuf, it.text(), room), th.bar_fg, bg);
            y += row_h;
        }

        // NEVER a silent cap: rows dropped for want of space and rows
        // dropped by the fetch cap both say so.
        const hidden = self.attention.slice().len - shown + self.attention.more;
        if (hidden > 0) {
            var buf: [32]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "+{d} more", .{hidden}) catch "+more";
            _ = ui.text(tx, y + (row_h - ch) / 2, s, th.bar_fg, bg);
        }
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
                .commands => blk: {
                    const c = registrypkg.commands[item_i];
                    const l = std.fmt.bufPrint(&lbl, "{s}: {s}", .{ c.category, c.title }) catch c.title;
                    // The LIVE chord first (config's truth), then the
                    // hand-written hint (⌘ chords live outside the
                    // binding table), then the id — an unbound command
                    // still shows the name an agent or a config file
                    // would call it by.
                    const live = self.liveChordHint(c.action, c.arg, &kbuf);
                    break :blk .{ l, live orelse if (c.keys.len > 0) c.keys else c.id };
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
                const eff_bg = if (inv) fg else bg;
                const eff_fg = if (styled and st.flags.invisible) eff_bg else if (inv) bg else fg;

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
        const g = ed.fillGrid(cols, rows);
        const cellw_px: u16 = @intCast(self.renderer.cellw_px);
        var prev_wide: ?renderpkg.GlyphLoc = null;
        for (g, 0..) |rc, i| {
            // The grid is walked flat, so the carry has to be dropped at
            // every row start — a tail in column zero (its left half
            // scrolled off) must not pick up the previous row's glyph.
            if (cols != 0 and i % cols == 0) prev_wide = null;
            const status_row = rows >= 1 and i >= (rows - 1) * cols;
            // Blink's off-phase draws the cursor cell as plain text —
            // the same terminal-cursor gate, in the editor's vocabulary.
            // Focused pane only: it is the blink that telegraphs where
            // the keys go, and an unfocused editor's cursor stays a
            // solid location marker.
            const st = if (rc.st == .cursor and focused and !self.blink_phase_on)
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
                if (self.renderer.glyphCluster(ed.clusterText(rc), w)) |loc| {
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

fn monitorCallback(context: *const MonitorBlock.Context, event_id: objc.c.id) callconv(.c) objc.c.id {
    const app: *App = context.app;
    const event = objc.Object.fromId(event_id);

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

    // ⌃HJKL pane nav — yielding to alternate-screen apps (vim owns its
    // own splits). rook reads alt-screen truth straight from the
    // emulator; the webview app needed a 3s-stale `fg` heuristic here.
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
                        app.draw_lock.lock();
                        const alt = switch (app.activeTab().focused.content) {
                            .term => |*tm| tm.session.term.screens.active_key == .alternate,
                            .edit => false,
                        };
                        app.draw_lock.unlock();
                        if (!alt and app.focusMove(d)) return null;
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

    // Arrows by keyCode; everything else via the cooked characters, which
    // already encode control (^C = 0x03), Enter (\r), Backspace (0x7f).
    // Throwaway: vt.input.encodeKey is the real path once modes matter.
    const keycode = event.msgSend(u16, "keyCode", .{});
    const arrow: ?[]const u8 = switch (keycode) {
        123 => "\x1b[D",
        124 => "\x1b[C",
        125 => "\x1b[B",
        126 => "\x1b[A",
        else => null,
    };
    const chars = event.msgSend(objc.Object, "characters", .{});
    const bytes: []const u8 = ime_bytes orelse arrow orelse blk: {
        if (chars.value == null) break :blk "";
        const s = chars.msgSend(?[*:0]const u8, "UTF8String", .{}) orelse break :blk "";
        break :blk std.mem.span(s);
    };
    if (bytes.len > 0) {
        const ts = event.msgSend(f64, "timestamp", .{});
        // Leader chords see plain single-byte keys only — modified or
        // multi-byte input can never arm or resolve a chord.
        if (bytes.len == 1 and flags & (flag_ctrl | (1 << 19)) == 0) {
            if (app.handleCharKey(bytes[0], ts)) return null;
        }
        // The kernel's receipt time, same clock as presentedTime: this
        // makes key_present a true key-to-photon number. Writes go to
        // the focused pane, under the scene lock so reap can't free the
        // session mid-write.
        app.writeFocused(bytes, ts);
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

/// Reader thread, after a parsed chunk: render immediately if a
/// keystroke is waiting on its echo IN THE FOCUSED PANE — a background
/// pane's firehose must not burn the latency path. Pointer compare
/// only; the session may not be dereferenced here.
/// Background poll of the host's usage snapshot. 30s cadence — the
/// host itself probes cost-weighted, this just mirrors its cache. A
/// text change dirties the scene; an unreachable host clears the
/// cluster (fail-open, nothing drawn).
/// Bring rook-host up once at launch. Not a poll: the daemon is ours for
/// the app's lifetime, and if it dies the panels that need it fail open
/// the way usage.zig already does.
fn hostThread(app: *App) void {
    const h = hostc.ensure(app.gpa, app.io) orelse {
        std.debug.print("rook host: no rook-host (panels that need it stay empty)\n", .{});
        return;
    };
    app.host_lock.lock();
    app.host = h;
    app.host_up = true;
    app.host_lock.unlock();
}

/// ⌘Q and every other AppKit route out of the app. ctl `quit` calls
/// App.shutdownHost directly instead: it `_exit`s, which no notification
/// survives, and a lever that leaked a daemon on every use would be a
/// bad lever to verify this with.
fn terminateCallback(context: *const ResizeBlock.Context, notification: objc.c.id) callconv(.c) void {
    _ = notification;
    context.app.shutdownHost();
}

/// Authorization result. Nothing to do but say so once: a denied
/// notification is the user's decision, and retrying would be nagging.
fn authCallback(_: *const AuthBlock.Context, granted: bool, err: objc.c.id) callconv(.c) void {
    _ = err;
    if (!granted) std.debug.print("rook: notification permission denied (System Settings > Notifications > rook)\n", .{});
}

/// Background poll of the attention inbox, 2s, and ONLY while the panel
/// is open — a closed panel costs no host traffic, no wakeups, and no
/// frames. Two properties this must not break:
///
///  - idle frames stay 0. A poll that repainted unconditionally would
///    cost 30 frames/minute forever, so a fetch only dirties the scene
///    when the DIGEST changes.
///  - the fetch is blocking (3s socket timeouts) and happens off the
///    render path; only the assignment takes draw_lock.
fn attentionThread(app: *App) void {
    const att = @import("attention.zig");
    while (true) {
        const open = blk: {
            app.draw_lock.lock();
            defer app.draw_lock.unlock();
            break :blk app.side_open and app.side_panel == .attention;
        };
        if (open) {
            const snap = att.fetch(app.gpa, app.io);
            const d = snap.digest();
            app.draw_lock.lock();
            if (d != app.attention_digest) {
                app.attention = snap;
                app.attention_digest = d;
                app.scene_dirty = true;
            }
            app.draw_lock.unlock();
        }
        // 100ms slices so an open-toggle is picked up promptly without
        // a condvar; the loop is a null check when the panel is closed.
        var slept: u32 = 0;
        while (slept < 2000) : (slept += 100) {
            if (app.attention_wake.swap(false, .acq_rel)) break;
            _ = usleep(100 * 1000);
        }
    }
}

/// The asks loop's client half: poll for a pending question, and post
/// whatever the form decided.
///
/// Polls ALWAYS, unlike the inbox — an ask is the app's reason to
/// interrupt you, so it cannot be gated on a panel already being open.
/// 1s, and only while nothing is on screen: a second question would have
/// nowhere to go until the first is answered.
fn asksThread(app: *App) void {
    const asks = @import("asks.zig");
    while (true) {
        // Post first: an answer the human already gave outranks looking
        // for the next question.
        var post_id: [24]u8 = undefined;
        var post_body: [4096]u8 = undefined;
        var id_len: usize = 0;
        var body_len: usize = 0;
        app.draw_lock.lock();
        if (app.ask_post_len > 0) {
            id_len = app.ask_post_id_len;
            body_len = app.ask_post_len;
            @memcpy(post_id[0..id_len], app.ask_post_id[0..id_len]);
            @memcpy(post_body[0..body_len], app.ask_post_body[0..body_len]);
            app.ask_post_len = 0;
        }
        const busy = app.ask != null;
        app.draw_lock.unlock();

        if (body_len > 0)
            _ = asks.answer(app.gpa, app.io, post_id[0..id_len], post_body[0..body_len]);

        if (!busy) {
            if (asks.poll(app.gpa, app.io)) |a| {
                app.draw_lock.lock();
                // Re-check under the lock: the form may have taken one
                // while we were on the wire.
                const took = app.ask == null;
                if (took) app.presentAskLocked(a);
                app.draw_lock.unlock();
                // Ack OUTSIDE the lock, and only if we actually took it.
                // rookctl gives up after 5s without one, so a question
                // the human is still reading would kill its asker.
                if (took) asks.ack(app.gpa, app.io, a.id.get());
            }
        }

        var slept: u32 = 0;
        while (slept < 1000) : (slept += 100) {
            if (app.ask_wake.swap(false, .acq_rel)) break;
            _ = usleep(100 * 1000);
        }
    }
}

/// Review: poll the workspace's review, apply verdicts, open findings.
fn reviewThread(app: *App) void {
    const sub = @import("substrate.zig");
    while (true) {
        var set_id: i64 = 0;
        var set_name: [12]u8 = undefined;
        var set_len: usize = 0;
        var open_path: [128]u8 = undefined;
        var open_len: usize = 0;
        var open_line: i64 = 0;
        var ws_buf: [64]u8 = undefined;
        var ws_len: usize = 0;
        var want_diff = false;
        var diff_path: [256]u8 = undefined;
        var diff_len: usize = 0;
        var diff_line: i64 = 0;
        const open_panel = blk: {
            app.draw_lock.lock();
            defer app.draw_lock.unlock();
            set_id = app.rev_set_id;
            set_len = app.rev_set_len;
            if (set_id != 0) {
                @memcpy(set_name[0..set_len], app.rev_set[0..set_len]);
                app.rev_set_id = 0;
                app.rev_set_len = 0;
            }
            open_len = app.rev_open_path_len;
            if (open_len > 0) {
                @memcpy(open_path[0..open_len], app.rev_open_path[0..open_len]);
                open_line = app.rev_open_line;
                app.rev_open_path_len = 0;
            }
            want_diff = app.diff_req;
            if (want_diff) {
                diff_len = app.diff_path_len;
                @memcpy(diff_path[0..diff_len], app.diff_path[0..diff_len]);
                diff_line = app.diff_line;
                app.diff_req = false;
            }
            const label = app.activeSpace().label();
            ws_len = @min(label.len, ws_buf.len);
            @memcpy(ws_buf[0..ws_len], label[0..ws_len]);
            break :blk app.side_open and app.side_panel == .review;
        };

        // A verdict outranks polling: it is what the human just did.
        var forced = false;
        if (set_id != 0) {
            _ = sub.Substrate.select(app.gpa, app.io).setReviewState(set_id, set_name[0..set_len]);
            forced = true; // re-fetch so the gate reflects it immediately
        }

        if (open_len > 0) {
            // Paths are workspace-relative; resolve against the space's
            // root by way of the focused pane's cwd.
            var full: [512]u8 = undefined;
            const p = open_path[0..open_len];
            const resolved = if (p.len > 0 and p[0] == '/')
                p
            else if (app.spaceRoot(&full, p)) |r| r else p;
            _ = app.openEditorAtLine(resolved, open_line);
        }

        if (want_diff) buildDiff(app, ws_buf[0..ws_len], diff_path[0..diff_len], diff_line);

        if (open_panel or forced) {
            const snap = sub.Substrate.select(app.gpa, app.io).reviewSnapshot(ws_buf[0..ws_len]);
            const d = snap.digest();
            app.draw_lock.lock();
            if (d != app.rev_digest) {
                app.rev = snap;
                app.rev_digest = d;
                if (app.rev_sel >= app.rev.n) app.rev_sel = app.rev.n -| 1;
                app.scene_dirty = true;
            }
            app.draw_lock.unlock();
        }

        var slept: u32 = 0;
        while (slept < 2000) : (slept += 50) {
            if (app.rev_wake.swap(false, .acq_rel)) break;
            _ = usleep(50 * 1000);
        }
    }
}

/// Build a diff view and hand it to a pane.
///
/// Runs on the review thread, off the key path — one diff is a `git diff`
/// per changed file, and a big repo would otherwise stall the frame for
/// the duration.
///
/// `path` empty means every changed file in one document. The empty
/// answer is still a document ("no changes"), because a keystroke that
/// appears to do nothing is indistinguishable from a broken one.
fn buildDiff(app: *App, workspace: []const u8, path: []const u8, line: i64) void {
    const ds = @import("diffsource.zig");
    const dd = @import("diffdoc.zig");
    const sub = @import("substrate.zig");
    if (workspace.len == 0) return;
    const s = sub.Substrate.select(app.gpa, app.io);

    // Base "": let the source decide — a worktree diffs its whole task,
    // everything else its uncommitted work. Overriding here would make
    // the view disagree with the review panel above it.
    if (path.len > 0) {
        var sides = s.diffSides(workspace, path, "");
        defer sides.deinit();
        var doc = dd.one(app.gpa, app.io, path, &sides, .{});
        defer doc.deinit();
        const row = if (line > 0) doc.rowForLine(0, @intCast(line)) else 0;
        var name: [288]u8 = undefined;
        const label = std.fmt.bufPrint(&name, "diff:{s}", .{path}) catch "diff";
        app.showDiff(label, &doc, row);
        return;
    }

    var changes = s.changes(workspace, "");
    defer changes.deinit();

    // The fetch closure, so diffdoc never needs to know what a substrate
    // is — it takes two texts per file and nothing else.
    const Fetch = struct {
        sb: sub.Substrate,
        ws: []const u8,
        fn get(self: @This(), p: []const u8) ds.Sides {
            return self.sb.diffSides(self.ws, p, "");
        }
    };
    var doc = dd.all(app.gpa, app.io, &changes, Fetch{ .sb = s, .ws = workspace }, Fetch.get, .{});
    defer doc.deinit();
    app.showDiff("diff:changes", &doc, 0);
}

/// Threads: list, open, save, and the verbs.
///
/// One thread because they are all network work against the same
/// resource and must not interleave — a save racing its own re-open
/// would splice the wrong tail.
fn threadsThread(app: *App) void {
    const thr = @import("threaddoc.zig");
    const sub = @import("substrate.zig");
    while (true) {
        // --- save first: what the human already typed outranks polling
        var save_id: i64 = 0;
        var save_len: usize = 0;
        var save_body: []u8 = &.{};
        var verb_id: i64 = 0;
        var verb_name: [16]u8 = undefined;
        var verb_len: usize = 0;
        var open_id: i64 = 0;
        var ws_buf: [64]u8 = undefined;
        var ws_len: usize = 0;
        const want_list = blk: {
            app.draw_lock.lock();
            defer app.draw_lock.unlock();
            save_id = app.thr_save_id;
            save_len = app.thr_save_len;
            if (save_id != 0) {
                save_body = app.gpa.dupe(u8, app.thr_save_body[0..save_len]) catch &.{};
                app.thr_save_id = 0;
                app.thr_save_len = 0;
            }
            verb_id = app.thr_verb_id;
            verb_len = app.thr_verb_len;
            if (verb_id != 0) {
                @memcpy(verb_name[0..verb_len], app.thr_verb[0..verb_len]);
                app.thr_verb_id = 0;
                app.thr_verb_len = 0;
            }
            open_id = app.thr_open_req;
            app.thr_open_req = 0;
            const label = app.activeSpace().label();
            ws_len = @min(label.len, ws_buf.len);
            @memcpy(ws_buf[0..ws_len], label[0..ws_len]);
            break :blk app.side_open and app.side_panel == .threads;
        };

        if (save_id != 0 and save_body.len > 0) {
            defer app.gpa.free(save_body);
            switch (sub.Substrate.select(app.gpa, app.io).saveThreadDoc(save_id, save_body)) {
                .ok => app.setThreadStatus(save_id, "saved"),
                .failed => app.setThreadStatus(save_id, "save failed"),
                .stale => |fresh| {
                    // A concurrent agent reply. History is append-only,
                    // so this always merges: take our tail and put it
                    // under the grown prefix.
                    var f = fresh;
                    defer f.deinit(app.gpa);
                    app.draw_lock.lock();
                    const our_prefix = app.thr_prefix;
                    const tail: []const u8 = if (app.thr_prefix_id == save_id)
                        thr.tailOf(save_body, our_prefix) orelse ""
                    else
                        "";
                    app.draw_lock.unlock();
                    if (thr.splice(app.gpa, &f, tail)) |merged| {
                        defer app.gpa.free(merged);
                        _ = sub.Substrate.select(app.gpa, app.io).saveThreadDoc(save_id, merged);
                        app.replaceThreadDoc(save_id, merged, f.prefix(), "merged a reply");
                    }
                },
            }
        }

        if (verb_id != 0) {
            const ok = sub.Substrate.select(app.gpa, app.io).threadVerb(verb_id, verb_name[0..verb_len]);
            app.setThreadStatus(verb_id, if (ok) "done" else "refused");
            // The doc changed underneath us (a note becomes a comment).
            if (ok) {
                if (sub.Substrate.select(app.gpa, app.io).threadDoc(verb_id)) |d| {
                    var doc = d;
                    defer doc.deinit(app.gpa);
                    app.replaceThreadDoc(verb_id, doc.content, doc.prefix(), null);
                }
            }
        }

        if (open_id != 0) {
            if (sub.Substrate.select(app.gpa, app.io).threadDoc(open_id)) |d| {
                var doc = d;
                defer doc.deinit(app.gpa);
                var name: [32]u8 = undefined;
                const label = std.fmt.bufPrint(&name, "thread:{d}", .{open_id}) catch "thread";
                app.rememberThreadPrefix(open_id, doc.prefix());
                app.openTextPane(label, doc.content);
            }
        }

        if (want_list) {
            const snap = sub.Substrate.select(app.gpa, app.io).threadList(ws_buf[0..ws_len]);
            const d = snap.digest();
            app.draw_lock.lock();
            if (d != app.thr_digest) {
                app.thr = snap;
                app.thr_digest = d;
                if (app.thr_sel >= app.thr.n) app.thr_sel = app.thr.n -| 1;
                app.scene_dirty = true;
            }
            app.draw_lock.unlock();
        }

        var slept: u32 = 0;
        while (slept < 2000) : (slept += 50) {
            if (app.thr_wake.swap(false, .acq_rel)) break;
            _ = usleep(50 * 1000);
        }
    }
}

/// Fetch a requested transcript and open it as a buffer.
///
/// Its own thread because the body is document-sized (the host's own
/// note: 200 records of a real transcript is ~485KB) and the fetch is
/// blocking. Rendering allocates, unlike every other panel — a timeline
/// IS a document — and the editor takes ownership of the text.
fn transcriptThread(app: *App) void {
    const tx = @import("transcript.zig");
    while (true) {
        var id: [64]u8 = undefined;
        var n: usize = 0;
        app.draw_lock.lock();
        if (app.tx_req_len > 0) {
            n = app.tx_req_len;
            @memcpy(id[0..n], app.tx_req[0..n]);
            app.tx_req_len = 0;
        }
        app.draw_lock.unlock();

        if (n > 0) {
            if (tx.fetchRendered(app.gpa, app.io, id[0..n])) |text| {
                defer app.gpa.free(text);
                var name: [80]u8 = undefined;
                // Short id: a uuid is 36 characters of nothing a human
                // reads, and the pane's name is chrome.
                const short = id[0..@min(n, 8)];
                const label = std.fmt.bufPrint(&name, "agent:{s}", .{short}) catch "agent";
                app.openTextPane(label, text);
            } else {
                std.debug.print("rook: transcript fetch failed for {s}\n", .{id[0..n]});
            }
        }

        var slept: u32 = 0;
        while (slept < 1000) : (slept += 50) {
            if (app.tx_wake.swap(false, .acq_rel)) break;
            _ = usleep(50 * 1000);
        }
    }
}

/// The agent deck's poller. Same contract as the inbox's: fetches only
/// while its panel is open, and dirties the scene only on a digest
/// change, so idle frames stay 0.
fn deckThread(app: *App) void {
    const agents = @import("agents.zig");
    while (true) {
        const open = blk: {
            app.draw_lock.lock();
            defer app.draw_lock.unlock();
            break :blk app.side_open and app.side_panel == .deck;
        };
        if (open) {
            const snap = agents.fetch(app.gpa, app.io);
            const d = snap.digest();
            app.draw_lock.lock();
            if (d != app.deck_digest) {
                app.deck = snap;
                app.deck_digest = d;
                // Keep the cursor in range when the list shrinks under
                // it — an agent can exit while you are looking at it.
                if (app.deck_sel >= app.deck.n) app.deck_sel = app.deck.n -| 1;
                app.scene_dirty = true;
            }
            app.draw_lock.unlock();
        }
        var slept: u32 = 0;
        while (slept < 2000) : (slept += 100) {
            if (app.deck_wake.swap(false, .acq_rel)) break;
            _ = usleep(100 * 1000);
        }
    }
}

fn usageThread(app: *App) void {
    while (true) {
        const snap = @import("usage.zig").fetch(app.gpa, app.io);
        app.draw_lock.lock();
        if (!std.mem.eql(u8, snap.slice(), app.usage.slice())) {
            app.usage = snap;
            app.scene_dirty = true;
        }
        app.draw_lock.unlock();
        _ = usleep(30 * 1000 * 1000);
    }
}

extern "c" fn usleep(us: u32) c_int;

fn inputKick(ctx: *anyopaque, sess: *sessionpkg.Session) void {
    const self: *App = @ptrCast(@alignCast(ctx));
    if (self.focused_session.load(.acquire) != sess) return;
    if (self.input_mark.load(.acquire) > 0) self.drawNow();
}
