//! Dev control socket — playwright-grade visibility for a native app.
//! A unix socket (default /tmp/rook.sock, override ROOK_SOCK) speaks a
//! line protocol drivable with plain `nc -U`:
//!
//!   printf 'dump\n'            | nc -U /tmp/rook.sock   # screen text
//!   printf 'type ls\n'         | nc -U /tmp/rook.sock   # keystrokes → pty
//!   printf 'enter\n'           | nc -U /tmp/rook.sock
//!   printf 'shot /tmp/s.png\n' | nc -U /tmp/rook.sock   # own-pixels PNG
//!   printf 'quit\n'            | nc -U /tmp/rook.sock
//!
//! Panes: `panes` lists them; `split right|down` splits the focused
//! pane; `focus <id|left|right|up|down>` moves focus; dump/type/enter/
//! ctrlc/key default to the focused pane and take an `@<id>` suffix to
//! target another (`dump@2`, `type@3 ls`).
//!
//! `shot` reads back our own CAMetalLayer drawable — no screen-recording
//! permission, works occluded or on another Space.

const std = @import("std");
const macos = @import("macos.zig");
const panespkg = @import("panes.zig");
const stats = @import("stats.zig");

extern "c" fn CACurrentMediaTime() f64;

const sockaddr_un = extern struct {
    sun_len: u8 = 0,
    sun_family: u8 = 1, // AF_UNIX
    sun_path: [104]u8 = @splat(0),
};

extern "c" fn socket(domain: c_int, tp: c_int, protocol: c_int) c_int;
extern "c" fn bind(fd: c_int, addr: *const sockaddr_un, len: u32) c_int;
extern "c" fn connect(fd: c_int, addr: *const sockaddr_un, len: u32) c_int;
extern "c" fn listen(fd: c_int, backlog: c_int) c_int;
extern "c" fn accept(fd: c_int, addr: ?*anyopaque, len: ?*u32) c_int;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn unlink(path: [*:0]const u8) c_int;
extern "c" fn read(fd: c_int, buf: [*]u8, n: usize) isize;
extern "c" fn write(fd: c_int, buf: [*]const u8, n: usize) isize;
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
extern "c" fn usleep(us: u32) c_int;
extern "c" fn _exit(code: c_int) noreturn;

pub fn start(app: *macos.App) !void {
    const thread = try std.Thread.spawn(.{}, serve, .{app});
    thread.detach();
}

fn sockPath() [*:0]const u8 {
    return getenv("ROOK_SOCK") orelse "/tmp/rook.sock";
}

/// Is something already serving at this path? A live listener answers
/// connect(); a leftover file from a crashed instance refuses.
fn socketIsLive(path: [*:0]const u8) bool {
    const span = std.mem.span(path);
    var addr: sockaddr_un = .{};
    if (span.len >= addr.sun_path.len) return false;
    @memcpy(addr.sun_path[0..span.len], span);
    const fd = socket(1, 1, 0);
    if (fd < 0) return false;
    defer _ = close(fd);
    return connect(fd, &addr, @sizeOf(sockaddr_un)) == 0;
}

fn serve(app: *macos.App) void {
    const path = sockPath();

    // NEVER STEAL A LIVE SOCKET. unlink-then-bind unconditionally is how
    // a second launch silently hijacks the first instance's automation
    // surface — and worse, when that second instance exits it leaves its
    // dead inode at the path while the FIRST is still listening on the
    // one it bound, now unlinked. The app looks healthy, `lsof` shows it
    // holding the socket, and every connect gets ECONNREFUSED. Seen in
    // the wild within an hour of the cutover.
    //
    // A stale file from a crashed instance refuses connect, so unlinking
    // that one is still right — which is the case this ever existed for.
    if (socketIsLive(path)) {
        std.debug.print("rook ctl: {s} is already served by another instance — not stealing it\n", .{path});
        std.debug.print("rook ctl: set ROOK_SOCK to give this instance its own\n", .{});
        return;
    }
    _ = unlink(path);

    const fd = socket(1, 1, 0); // AF_UNIX, SOCK_STREAM
    if (fd < 0) return;
    var addr: sockaddr_un = .{};
    const span = std.mem.span(path);
    if (span.len >= addr.sun_path.len) return;
    @memcpy(addr.sun_path[0..span.len], span);
    if (bind(fd, &addr, @sizeOf(sockaddr_un)) != 0) {
        std.debug.print("rook ctl: bind failed on {s}\n", .{path});
        return;
    }
    if (listen(fd, 4) != 0) return;
    std.debug.print("rook ctl: listening on {s}\n", .{path});

    while (true) {
        const conn = accept(fd, null, null);
        if (conn < 0) continue;
        handleConn(app, conn);
        _ = close(conn);
    }
}

fn handleConn(app: *macos.App, fd: c_int) void {
    var buf: [4096]u8 = undefined;
    var len: usize = 0;
    // Read lines until EOF; execute each as a command.
    while (true) {
        const n = read(fd, buf[len..].ptr, buf.len - len);
        if (n <= 0) break;
        len += @intCast(n);
        while (std.mem.indexOfScalar(u8, buf[0..len], '\n')) |nl| {
            handleLine(app, fd, std.mem.trimEnd(u8, buf[0..nl], "\r"));
            std.mem.copyForwards(u8, &buf, buf[nl + 1 .. len]);
            len -= nl + 1;
        }
        if (len == buf.len) break; // oversized line, drop conn
    }
}

fn reply(fd: c_int, bytes: []const u8) void {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = write(fd, bytes.ptr + off, bytes.len - off);
        if (n <= 0) return;
        off += @intCast(n);
    }
}

/// Resolve a pane by id (searching every tab), or the active tab's
/// focused pane when id is null. Caller holds app.draw_lock.
fn findPane(app: *macos.App, pane_id: ?u32) ?*panespkg.Pane {
    const id = pane_id orelse return app.activeTab().focused;
    for (app.spaces.items) |s| {
        for (s.tabs.items) |t| {
            for (t.panes.items) |p| {
                if (p.id == id) return p;
            }
        }
    }
    return null;
}

/// Write input bytes to a pane's pty under the scene lock. Only writes
/// to the FOCUSED pane arm the key-to-photon mark — a background pane's
/// echo must not be measured as input latency.
fn writeTarget(app: *macos.App, pane_id: ?u32, bytes: []const u8) bool {
    app.draw_lock.lock();
    defer app.draw_lock.unlock();
    // An open palette owns untargeted input, same as the real key path.
    if (app.pal_open and pane_id == null) {
        app.markInput(CACurrentMediaTime());
        app.palKeyLocked(bytes);
        return true;
    }
    const p = findPane(app, pane_id) orelse return false;
    if (p == app.activeTab().focused) app.markInput(CACurrentMediaTime());
    app.paneInput(p, bytes);
    return true;
}

fn handleLine(app: *macos.App, fd: c_int, line: []const u8) void {
    // Split off the verb and an optional @<id> pane suffix.
    const sp = std.mem.indexOfScalar(u8, line, ' ');
    const verb_full = if (sp) |i| line[0..i] else line;
    const rest = if (sp) |i| line[i + 1 ..] else "";
    var verb = verb_full;
    var pane_id: ?u32 = null;
    if (std.mem.indexOfScalar(u8, verb_full, '@')) |at| {
        verb = verb_full[0..at];
        pane_id = std.fmt.parseInt(u32, verb_full[at + 1 ..], 10) catch {
            reply(fd, "err pane id\n");
            return;
        };
    }

    if (std.mem.eql(u8, verb, "dump") and rest.len == 0) {
        app.draw_lock.lock();
        const p = findPane(app, pane_id) orelse {
            app.draw_lock.unlock();
            reply(fd, "err no pane\n");
            return;
        };
        const str = switch (p.content) {
            .term => |*tm| blk: {
                tm.session.mutex.lock();
                defer tm.session.mutex.unlock();
                break :blk tm.session.term.plainString(app.gpa) catch null;
            },
            .edit => |ed| ed.dumpText(app.gpa, p.cols, p.rows) catch null,
        } orelse {
            app.draw_lock.unlock();
            reply(fd, "err dump\n");
            return;
        };
        var head: [64]u8 = undefined;
        const h = std.fmt.bufPrint(&head, "pane {d} grid {d}x{d}\n", .{ p.id, p.cols, p.rows }) catch {
            app.draw_lock.unlock();
            app.gpa.free(str);
            return;
        };
        app.draw_lock.unlock();
        defer app.gpa.free(str);
        reply(fd, h);
        reply(fd, str);
        reply(fd, "\n");
    } else if (std.mem.eql(u8, verb, "panes") and rest.len == 0) {
        var buf: [4096]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        app.draw_lock.lock();
        for (app.spaces.items, 0..) |s, si| {
            for (s.tabs.items, 0..) |t, ti| {
                for (t.panes.items) |p| {
                    w.print("{s}{s} t{d} {s}{d} rect {d}x{d}+{d}+{d} grid {d}x{d}\n", .{
                        @as([]const u8, if (si == app.active_space and ti == s.active_tab) "*" else " "),
                        s.label(),
                        ti + 1,
                        @as([]const u8, if (p == t.focused) "*" else " "),
                        p.id,
                        @as(u32, @intFromFloat(p.rect.w)),
                        @as(u32, @intFromFloat(p.rect.h)),
                        @as(u32, @intFromFloat(p.rect.x)),
                        @as(u32, @intFromFloat(p.rect.y)),
                        p.cols,
                        p.rows,
                    }) catch break;
                }
            }
        }
        app.draw_lock.unlock();
        reply(fd, buf[0..w.end]);
    } else if (std.mem.eql(u8, verb, "tabs") and rest.len == 0) {
        var buf: [1024]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        app.draw_lock.lock();
        for (app.spaces.items, 0..) |s, si| {
            for (s.tabs.items, 0..) |t, ti| {
                w.print("{s}[{s}] {d} ({d} pane{s}){s}\n", .{
                    @as([]const u8, if (si == app.active_space and ti == s.active_tab) "*" else " "),
                    s.label(),
                    ti + 1,
                    t.panes.items.len,
                    @as([]const u8, if (t.panes.items.len == 1) "" else "s"),
                    // The chip's bell dot, in text — `shot` can see the
                    // dot, but a blind test shouldn't have to.
                    @as([]const u8, if (t.bell) " bell" else ""),
                }) catch break;
            }
        }
        app.draw_lock.unlock();
        reply(fd, buf[0..w.end]);
    } else if (std.mem.eql(u8, verb, "workspaces") and rest.len == 0) {
        // Fresh read of rook.db — proves the sqlite path blind.
        const list = @import("workspaces.zig").load(app.gpa);
        defer @import("workspaces.zig").free(app.gpa, list);
        var buf: [4096]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        for (list) |e| {
            if (e.parent.len > 0) {
                w.print("{s}/{s}\t{s}\n", .{ e.parent, e.name, e.root }) catch break;
            } else w.print("{s}\t{s}\n", .{ e.name, e.root }) catch break;
        }
        if (list.len == 0) _ = w.write("none\n") catch 0;
        reply(fd, buf[0..w.end]);
    } else if (std.mem.eql(u8, verb, "palette") and rest.len == 0) {
        // Palette state: closed, or the filter + rows (* = selected).
        var buf: [4096]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        app.draw_lock.lock();
        if (!app.pal_open) {
            _ = w.write("closed\n") catch 0;
        } else {
            w.print("filter:{s}\n", .{app.pal_input[0..app.pal_input_len]}) catch {};
            for (app.pal_filtered[0..app.pal_nfiltered], 0..) |ii, vi| {
                const e = app.pal_items[ii];
                w.print("{s}{s}\t{s}\n", .{
                    @as([]const u8, if (vi == app.pal_sel) "*" else " "),
                    e.name,
                    e.root,
                }) catch break;
            }
        }
        app.draw_lock.unlock();
        reply(fd, buf[0..w.end]);
    } else if (std.mem.eql(u8, verb, "palette-open") and rest.len == 0) {
        app.openPalette();
        reply(fd, "ok\n");
    } else if (std.mem.eql(u8, verb, "usage") and rest.len == 0) {
        // The cluster as drawn (host-cached; empty = host unreachable).
        var buf: [128]u8 = undefined;
        app.draw_lock.lock();
        const n = @min(app.usage.len, buf.len - 1);
        @memcpy(buf[0..n], app.usage.slice()[0..n]);
        app.draw_lock.unlock();
        buf[n] = '\n';
        reply(fd, if (n == 0) "none\n" else buf[0 .. n + 1]);
    } else if (std.mem.eql(u8, verb, "tab")) {
        if (std.mem.eql(u8, rest, "new")) {
            app.newTab();
            reply(fd, "ok\n");
        } else if (std.mem.eql(u8, rest, "next")) {
            app.cycleTab(1);
            reply(fd, "ok\n");
        } else if (std.mem.eql(u8, rest, "prev")) {
            app.cycleTab(-1);
            reply(fd, "ok\n");
        } else if (std.fmt.parseInt(usize, rest, 10) catch null) |n| {
            reply(fd, if (n >= 1 and app.selectTab(n - 1)) "ok\n" else "err no tab\n");
        } else reply(fd, "err tab new|next|prev|<n>\n");
    } else if (std.mem.eql(u8, verb, "edit") and rest.len > 0) {
        // Open a file in an editor pane: a focused editor retargets in
        // place, else one splits off to the right. Paths resolve
        // against the APP's cwd — send absolute paths (rook edit does).
        reply(fd, if (app.openEditor(rest)) "ok\n" else "err open\n");
    } else if (std.mem.eql(u8, verb, "click")) {
        var it = std.mem.tokenizeScalar(u8, rest, ' ');
        const x = std.fmt.parseFloat(f32, it.next() orelse "") catch -1;
        const y = std.fmt.parseFloat(f32, it.next() orelse "") catch -1;
        if (x < 0 or y < 0) {
            reply(fd, "err click <x_px> <y_px>\n");
            return;
        }
        app.clickAt(x, y, false);
        reply(fd, "ok\n");
    } else if (std.mem.eql(u8, verb, "close") and rest.len == 0) {
        app.closeFocused(); // \u2318W's path
        reply(fd, "ok\n");
    } else if (std.mem.eql(u8, verb, "drag")) {
        // Full gesture: down at (x1,y1), drag to (x2,y2), up.
        var it = std.mem.tokenizeScalar(u8, rest, ' ');
        const x1 = std.fmt.parseFloat(f32, it.next() orelse "") catch -1;
        const y1 = std.fmt.parseFloat(f32, it.next() orelse "") catch -1;
        const x2 = std.fmt.parseFloat(f32, it.next() orelse "") catch -1;
        const y2 = std.fmt.parseFloat(f32, it.next() orelse "") catch -1;
        if (x1 < 0 or y1 < 0 or x2 < 0 or y2 < 0) {
            reply(fd, "err drag <x1> <y1> <x2> <y2>\n");
            return;
        }
        app.clickAt(x1, y1, true); // local: the blind selection tool
        app.dragTo(x2, y2);
        app.dragEnd();
        reply(fd, "ok\n");
    } else if (std.mem.eql(u8, verb, "copy") and rest.len == 0) {
        if (app.copyFocused()) |t| {
            defer app.gpa.free(t);
            reply(fd, t);
            reply(fd, "\n");
        } else reply(fd, "err nothing selected\n");
    } else if (std.mem.eql(u8, verb, "nskey")) {
        // nskey <keycode> <modmask-hex> <characters>
        var it = std.mem.tokenizeScalar(u8, rest, ' ');
        const code = std.fmt.parseInt(u16, it.next() orelse "", 10) catch {
            reply(fd, "err nskey <keycode> <mods-hex> <chars>\n");
            return;
        };
        const mods = std.fmt.parseInt(u64, it.next() orelse "0", 16) catch 0;
        // \r and \n spell themselves — a real Return event carries a CR
        // in its characters, and the line protocol can't hold one.
        const raw = it.rest();
        var chars: [16]u8 = undefined;
        var n: usize = 0;
        var i: usize = 0;
        while (i < raw.len and n < chars.len) : (i += 1) {
            if (raw[i] == '\\' and i + 1 < raw.len) {
                const esc: ?u8 = switch (raw[i + 1]) {
                    'r' => '\r',
                    'n' => '\n',
                    't' => '\t',
                    'e' => 0x1b,
                    else => null,
                };
                if (esc) |e| {
                    chars[n] = e;
                    n += 1;
                    i += 1;
                    continue;
                }
            }
            chars[n] = raw[i];
            n += 1;
        }
        app.postKey(code, mods, chars[0..n]);
        reply(fd, "ok\n");
    } else if (std.mem.eql(u8, verb, "version")) {
        // Build identity + what happened to rook-host. `owned` is the
        // load-bearing bit: it decides whether quitting takes the daemon
        // down, so a blind test needs to see it (hostc.zig).
        app.host_lock.lock();
        defer app.host_lock.unlock();
        var buf: [768]u8 = undefined;
        const s = std.fmt.bufPrint(
            &buf,
            "rook {s} build={s}\nhost={s} port={d} pid={d} build={s} release={s} owned={s}\nhost-binary={s}\n",
            .{
                @import("build_options").version,
                @import("build_options").id,
                if (app.host_up) "up" else "down",
                app.host.info.port,
                app.host.info.pid,
                app.host.info.build(),
                app.host.info.release(),
                if (app.host.owned) "yes" else "no",
                app.host.binary(),
            },
        ) catch return;
        reply(fd, s);
    } else if (std.mem.eql(u8, verb, "notify")) {
        // The banner itself is the OS's; this is the last thing we
        // handed it, which is the part a blind test can check.
        app.draw_lock.lock();
        defer app.draw_lock.unlock();
        var buf: [512]u8 = undefined;
        const s2 = std.fmt.bufPrint(&buf, "last=\"{s}\" asked={s} bundled={s}\n", .{
            app.notify_last[0..app.notify_last_len],
            if (app.notify_asked) "yes" else "no",
            if (app.notify_warned) "no" else "yes",
        }) catch return;
        reply(fd, s2);
    } else if (std.mem.eql(u8, verb, "ime")) {
        // Is the input-method plumbing actually live? inputContext is
        // AppKit's verdict on our NSTextInputClient conformance — nil
        // means no dead keys and no CJK, however good the code looks.
        const ctx = if (app.ime_view.value != null)
            app.ime_view.msgSend(@import("objc").Object, "inputContext", .{})
        else
            @import("objc").Object{ .value = null };
        const first = if (app.ime_view.value != null)
            app.window.msgSend(@import("objc").Object, "firstResponder", .{}).value == app.ime_view.value
        else
            false;
        var buf: [256]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "view={s} context={s} first_responder={s} marked=\"{s}\"\n", .{
            if (app.ime_view.value != null) "yes" else "no",
            if (ctx.value != null) "yes" else "nil",
            if (first) "yes" else "no",
            app.ime_marked[0..app.ime_marked_len],
        }) catch return;
        reply(fd, s);
    } else if (std.mem.eql(u8, verb, "paste")) {
        // Bare `paste` is ⌘V exactly — the real pasteboard, the real
        // routing. `paste <text>` skips the pasteboard so a test can
        // control the payload (and \n spells a newline, since the line
        // protocol can't carry a raw one).
        if (rest.len == 0) {
            if (app.pasteFocused()) |t| {
                defer app.gpa.free(t);
                reply(fd, "ok ");
                reply(fd, t);
                reply(fd, "\n");
            } else reply(fd, "err pasteboard empty\n");
            return;
        }
        var text: std.ArrayListUnmanaged(u8) = .empty;
        defer text.deinit(app.gpa);
        var i: usize = 0;
        while (i < rest.len) : (i += 1) {
            if (rest[i] == '\\' and i + 1 < rest.len and rest[i + 1] == 'n') {
                text.append(app.gpa, '\n') catch return;
                i += 1;
            } else text.append(app.gpa, rest[i]) catch return;
        }
        app.pasteText(text.items);
        reply(fd, "ok\n");
    } else if (std.mem.eql(u8, verb, "wheel")) {
        var it = std.mem.tokenizeScalar(u8, rest, ' ');
        const x = std.fmt.parseFloat(f32, it.next() orelse "") catch -1;
        const y = std.fmt.parseFloat(f32, it.next() orelse "") catch -1;
        const lines = std.fmt.parseInt(i64, it.next() orelse "", 10) catch 0;
        if (x < 0 or y < 0 or lines == 0) {
            reply(fd, "err wheel <x_px> <y_px> <±lines>\n");
            return;
        }
        app.wheelAt(x, y, lines);
        reply(fd, "ok\n");
    } else if (std.mem.eql(u8, verb, "split")) {
        if (std.mem.eql(u8, rest, "right")) {
            app.splitFocused(true);
            reply(fd, "ok\n");
        } else if (std.mem.eql(u8, rest, "down")) {
            app.splitFocused(false);
            reply(fd, "ok\n");
        } else reply(fd, "err split right|down\n");
    } else if (std.mem.eql(u8, verb, "focus")) {
        const dir: ?panespkg.NavDir = if (std.mem.eql(u8, rest, "left"))
            .left
        else if (std.mem.eql(u8, rest, "right"))
            .right
        else if (std.mem.eql(u8, rest, "up"))
            .up
        else if (std.mem.eql(u8, rest, "down"))
            .down
        else
            null;
        if (dir) |d| {
            reply(fd, if (app.focusMove(d)) "ok\n" else "err edge\n");
        } else if (std.fmt.parseInt(u32, rest, 10) catch null) |id| {
            reply(fd, if (app.focusById(id)) "ok\n" else "err no pane\n");
        } else reply(fd, "err focus <id|left|right|up|down>\n");
    } else if (std.mem.eql(u8, verb, "press") and rest.len > 0) {
        // Drive the REAL key path (leader state machine included) with
        // one character — chords are testable blind. `press SPACE`,
        // `press TAB`, `press ESC` for named keys.
        const ch: ?u8 = if (rest.len == 1)
            rest[0]
        else if (std.mem.eql(u8, rest, "TAB"))
            '\t'
        else if (std.mem.eql(u8, rest, "SPACE"))
            ' '
        else if (std.mem.eql(u8, rest, "ESC"))
            0x1b
        else
            null;
        if (ch) |c| {
            if (app.handleCharKey(c, CACurrentMediaTime())) {
                reply(fd, "consumed\n");
            } else {
                app.writeFocused(&[1]u8{c}, CACurrentMediaTime());
                reply(fd, "typed\n");
            }
        } else reply(fd, "err press <char|TAB|SPACE|ESC>\n");
    } else if (std.mem.eql(u8, verb, "type") and rest.len > 0) {
        reply(fd, if (writeTarget(app, pane_id, rest)) "ok\n" else "err no pane\n");
    } else if (std.mem.eql(u8, verb, "enter") and rest.len == 0) {
        reply(fd, if (writeTarget(app, pane_id, "\r")) "ok\n" else "err no pane\n");
    } else if (std.mem.eql(u8, verb, "ctrlc") and rest.len == 0) {
        reply(fd, if (writeTarget(app, pane_id, "\x03")) "ok\n" else "err no pane\n");
    } else if (std.mem.eql(u8, verb, "key") and rest.len > 0) {
        // Raw escape injection: `key 1b5b41` (hex bytes).
        var bytes: [64]u8 = undefined;
        const hex = rest;
        if (hex.len / 2 > bytes.len or hex.len % 2 != 0) {
            reply(fd, "err hex\n");
            return;
        }
        const out = std.fmt.hexToBytes(bytes[0 .. hex.len / 2], hex) catch {
            reply(fd, "err hex\n");
            return;
        };
        reply(fd, if (writeTarget(app, pane_id, out)) "ok\n" else "err no pane\n");
    } else if (std.mem.startsWith(u8, line, "shot ")) {
        if (app.requestShot(line[5..])) {
            // Wait for the render thread to service it (≤2s).
            var waited: u32 = 0;
            while (app.shotPending() and waited < 2_000_000) : (waited += 10_000) {
                _ = usleep(10_000);
            }
            reply(fd, if (app.shotPending()) "err timeout\n" else "ok\n");
        } else reply(fd, "err busy\n");
    } else if (std.mem.startsWith(u8, line, "winsize ")) {
        var it = std.mem.tokenizeScalar(u8, line[8..], ' ');
        const w = std.fmt.parseFloat(f64, it.next() orelse "") catch 0;
        const h = std.fmt.parseFloat(f64, it.next() orelse "") catch 0;
        if (w < 100 or h < 100) {
            reply(fd, "err winsize <w> <h> (points, >=100)\n");
            return;
        }
        app.requestWinSize(w, h);
        reply(fd, "ok\n");
    } else if (std.mem.eql(u8, line, "fullscreen")) {
        app.requestFullscreen();
        reply(fd, "ok\n");
    } else if (std.mem.eql(u8, line, "hud")) {
        app.draw_lock.lock();
        var buf: [256]u8 = undefined;
        const out = std.fmt.bufPrint(&buf, "{s} | {s}\n", .{
            app.hud_left[0..app.hud_left_len],
            app.hud_right[0..app.hud_right_len],
        }) catch {
            app.draw_lock.unlock();
            return;
        };
        app.draw_lock.unlock();
        reply(fd, out);
    } else if (std.mem.eql(u8, line, "stats")) {
        var buf: [4096]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        stats.writeReport(&w) catch {};
        reply(fd, buf[0..w.end]);
    } else if (std.mem.eql(u8, line, "stats reset")) {
        stats.global.reset();
        reply(fd, "ok\n");
    } else if (std.mem.eql(u8, line, "quit")) {
        // _exit skips AppKit, so the will-terminate observer never runs —
        // do its one job here, or every scripted quit leaks a daemon.
        app.shutdownHost();
        reply(fd, "ok\n");
        _exit(0);
    } else {
        reply(fd, "err unknown (panes|edit <path>|split right|down|focus <id|dir>|dump[@id]|type[@id] <s>|enter[@id]|ctrlc[@id]|key[@id] <hex>|shot <path>|winsize <w> <h>|stats|quit)\n");
    }
}
