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
    // The moment the outside world can reach us — the e2e `startup`
    // bench's "app is up" line. create() stamped the other phases.
    if (macos.boot_times.start != 0)
        macos.boot_times.ctl_ready_us = macos.usSince(macos.boot_times.start);
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
    const ok = blk: {
        app.draw_lock.lock();
        defer app.draw_lock.unlock();
        // Untargeted input goes through the SAME routing rule the real
        // key path uses — see routeChromeKeyLocked.
        if (pane_id == null) {
            app.markInput(CACurrentMediaTime());
            if (app.routeChromeKeyLocked(bytes)) break :blk true;
        }
        const p = findPane(app, pane_id) orelse break :blk false;
        if (p == app.activeTab().focused) app.markInput(CACurrentMediaTime());
        app.paneInput(p, bytes);
        break :blk true;
    };
    // Outside the locked block: an Enter in the COMMAND palette queues a
    // command, and every dispatch target takes draw_lock again.
    app.drainPendingCmd();
    return ok;
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
                    // What the pane HOLDS, appended last so the existing
                    // "… grid 80x24" parsers are unaffected. Without it
                    // `panes` cannot distinguish an editor from a shell,
                    // which makes any assertion about editor panes — :qa's
                    // reach, a takeover, a retarget — silently vacuous.
                    var whatbuf: [128]u8 = undefined;
                    const what: []const u8 = if (p.editor()) |ed|
                        std.fmt.bufPrint(&whatbuf, " edit:{s}", .{ed.displayName()}) catch " edit"
                    else
                        " term";
                    w.print("{s}{s} t{d} {s}{d} rect {d}x{d}+{d}+{d} grid {d}x{d}{s}{s}\n", .{
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
                        @as([]const u8, if (t.zoomed == p) " zoomed" else ""),
                        what,
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
        } else if (app.pal_mode == .files) {
            // The index size comes along: "no matches" with 0 files
            // indexed is a walk that found nothing, which is a
            // different bug from a filter that matched nothing.
            w.print("mode:files\nfilter:{s}\nroot:{s}\nindexed:{d}{s}\n", .{
                app.pal_input[0..app.pal_input_len],
                app.pal_files.root,
                app.pal_files.paths.len,
                @as([]const u8, if (app.pal_files.truncated) " truncated" else ""),
            }) catch {};
            for (app.pal_filtered[0..app.pal_nfiltered], 0..) |ii, vi| {
                w.print("{s}{s}\n", .{
                    @as([]const u8, if (vi == app.pal_sel) "*" else " "),
                    app.pal_files.paths[ii],
                }) catch break;
            }
        } else if (app.pal_mode == .commands) {
            w.print("mode:commands\nfilter:{s}\n", .{app.pal_input[0..app.pal_input_len]}) catch {};
            const reg = @import("registry.zig");
            for (app.pal_filtered[0..app.pal_nfiltered], 0..) |ii, vi| {
                const c = reg.commands[ii];
                w.print("{s}{s}\t{s}: {s}\n", .{
                    @as([]const u8, if (vi == app.pal_sel) "*" else " "),
                    c.id,
                    c.category,
                    c.title,
                }) catch break;
            }
        } else {
            w.print("mode:workspaces\nfilter:{s}\n", .{app.pal_input[0..app.pal_input_len]}) catch {};
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
    } else if (std.mem.eql(u8, verb, "statusbar") and rest.len == 0) {
        // The bar's where-you-are zone, blind: workspace, branch (as
        // polled off the focused pane's cwd), the cwd label, and each
        // drawn segment's click point.
        var buf: [1024]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        app.draw_lock.lock();
        w.print("workspace {s}\nbranch {s}\ncwd {s}\n", .{
            app.activeSpace().label(),
            if (app.bar_branch_len > 0) app.bar_branch[0..app.bar_branch_len] else "-",
            app.hud_left[0..app.hud_left_len],
        }) catch {};
        const seg_y: u32 = @intFromFloat(app.px_h - app.bar_h / 2);
        if (app.seg_ws_x[1] > 0) w.print("seg-workspace {d},{d}\n", .{
            @as(u32, @intFromFloat((app.seg_ws_x[0] + app.seg_ws_x[1]) / 2)),
            seg_y,
        }) catch {};
        if (app.seg_branch_x[1] > 0) w.print("seg-branch {d},{d}\n", .{
            @as(u32, @intFromFloat((app.seg_branch_x[0] + app.seg_branch_x[1]) / 2)),
            seg_y,
        }) catch {};
        // The arrangement itself, blind: which lists drive each bar
        // (the presetparity scenario diffs two instances on exactly
        // these lines), plus a click point per drawn tabs chip.
        w.print("topbar", .{}) catch {};
        for (app.cfg_top_bar.slice()) |s| w.print(" {s}", .{@tagName(s)}) catch {};
        w.print("\nleft", .{}) catch {};
        for (app.cfg_status_left.slice()) |s| w.print(" {s}", .{@tagName(s)}) catch {};
        w.print("\nright", .{}) catch {};
        for (app.cfg_status_right.slice()) |s| w.print(" {s}", .{@tagName(s)}) catch {};
        w.print("\nactivitybar {s}", .{if (app.cfg_activity_bar) "on" else "off"}) catch {};
        w.print("\ntabstyle {s}\n", .{@tagName(app.cfg_tab_style)}) catch {};
        for (app.bar_tab_x[0..app.bar_tab_n], 0..) |zx, i| {
            w.print("seg-tab{d} {d},{d}\n", .{
                i + 1,
                @as(u32, @intFromFloat((zx[0] + zx[1]) / 2)),
                seg_y,
            }) catch {};
        }
        // The icon rail's click points, by name — the vscodefeel
        // scenario drives the rail blind through these.
        for (0..app.rail_n) |i| {
            w.print("rail-{s} {d},{d}\n", .{
                @import("macos.zig").App.rail_items[i].title,
                @as(u32, @intFromFloat(app.railWidth() / 2)),
                @as(u32, @intFromFloat((app.rail_y[i][0] + app.rail_y[i][1]) / 2)),
            }) catch {};
        }
        app.draw_lock.unlock();
        reply(fd, buf[0..w.end]);
    } else if (std.mem.eql(u8, verb, "whichkey") and rest.len == 0) {
        // The leader's teaching sheet, blind: armed/visible state, the
        // rows the sheet shows (LIVE bindings, the same list drawWhichKey
        // lays out), each row's click point once the sheet has drawn,
        // and the status-bar hint zones — everything a test needs to
        // drive the mouse route without pixels.
        var buf: [4096]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        app.draw_lock.lock();
        if (!app.leader_pending.load(.acquire)) {
            _ = w.write("closed\n") catch 0;
        } else {
            w.print("armed {s}\n", .{@as([]const u8, if (app.wk_visible) "visible" else "pending")}) catch {};
            var items: [33]macos.WkItem = undefined;
            const n = app.wkItemsLocked(&items);
            for (items[0..n], 0..) |it, i| {
                var kb: [1]u8 = undefined;
                const keyname: []const u8 = if (!it.click)
                    "1-9"
                else switch (it.ch) {
                    ' ' => "SPACE",
                    '\t' => "TAB",
                    0x1b => "ESC",
                    else => blk: {
                        kb[0] = it.ch;
                        break :blk kb[0..1];
                    },
                };
                // Click point only after a frame has laid the rows out;
                // "-" before that, so a test that reads coordinates too
                // early fails loudly instead of clicking (0,0).
                if (app.wk_visible and app.wk_n == n) {
                    const hit = app.wk_hits[i];
                    w.print("{s}\t{s}\t{d},{d}\n", .{
                        keyname,
                        it.title,
                        @as(u32, @intFromFloat(hit.x + hit.w / 2)),
                        @as(u32, @intFromFloat(hit.y + hit.h / 2)),
                    }) catch break;
                } else {
                    w.print("{s}\t{s}\t-\n", .{ keyname, it.title }) catch break;
                }
            }
        }
        const hint_y: u32 = @intFromFloat(app.px_h - app.bar_h / 2);
        if (app.hint_menu_x[1] > 0) w.print("hint-menu {d},{d}\n", .{
            @as(u32, @intFromFloat((app.hint_menu_x[0] + app.hint_menu_x[1]) / 2)),
            hint_y,
        }) catch {};
        if (app.hint_cmd_x[1] > 0) w.print("hint-commands {d},{d}\n", .{
            @as(u32, @intFromFloat((app.hint_cmd_x[0] + app.hint_cmd_x[1]) / 2)),
            hint_y,
        }) catch {};
        app.draw_lock.unlock();
        reply(fd, buf[0..w.end]);
    } else if (std.mem.eql(u8, verb, "commands") and rest.len == 0) {
        // The agent's tool surface, and the same table the palette and
        // the keybinds read. `run` below takes any id printed here.
        const reg = @import("registry.zig");
        var buf: [4096]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        for (reg.commands) |c| {
            var ex: [64]u8 = undefined;
            w.print("{s}\t{s}: {s}\t{s}\t:{s}\n", .{
                c.id,
                c.category,
                c.title,
                if (c.keys.len > 0) c.keys else "-",
                reg.exName(c.id, &ex),
            }) catch break;
        }
        reply(fd, buf[0..w.end]);
    } else if (std.mem.eql(u8, verb, "run") and rest.len > 0) {
        // By NAME, so an agent never has to know rook's internals — and
        // aliases resolve, so a config written in tmux's vocabulary and
        // an agent using the canonical id reach the same code.
        const reg = @import("registry.zig");
        if (reg.specFromName(rest)) |spec| {
            app.dispatch(spec);
            reply(fd, "ok\n");
        } else {
            reply(fd, "err unknown command (see `commands`)\n");
        }
    } else if (std.mem.eql(u8, verb, "ask") and rest.len > 0) {
        // Put a question on screen without a host — the same role `paste
        // <text>` plays for the pasteboard. Takes {"questions":[…]} or a
        // bare […], through the SAME parse the poller uses, so the form
        // is never exercised by a second code path.
        const asks = @import("asks.zig");
        if (asks.parsePayload(app.gpa, "ctl", "", rest)) |a| {
            app.presentAsk(a);
            reply(fd, "ok\n");
        } else reply(fd, "err bad questions JSON\n");
    } else if (std.mem.eql(u8, verb, "transcript") and rest.len > 0) {
        // Open an agent's transcript as a buffer. Async by design: the
        // fetch is a document-sized blocking read, so this only queues.
        app.draw_lock.lock();
        app.requestTranscriptLocked(rest);
        app.draw_lock.unlock();
        reply(fd, "ok\n");
    } else if (std.mem.eql(u8, verb, "ask-answer") and rest.len == 0) {
        // What the form last decided, verbatim. This is the body that
        // unblocks the asker, so it is the thing worth asserting on.
        app.draw_lock.lock();
        const n = app.ask_last_len;
        var buf: [4096]u8 = undefined;
        @memcpy(buf[0..n], app.ask_last[0..n]);
        app.draw_lock.unlock();
        if (n == 0) {
            reply(fd, "none\n");
        } else {
            reply(fd, buf[0..n]);
            reply(fd, "\n");
        }
    } else if (std.mem.eql(u8, verb, "sidepane") and rest.len == 0) {
        // Container state + the tenant's rows, so the whole panel is
        // verifiable without a screenshot.
        var buf: [4096]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        app.draw_lock.lock();
        if (!app.side_open) {
            _ = w.write("closed\n") catch 0;
        } else {
            w.print("open side:{s} panel:{s}\n", .{
                @tagName(app.side),
                @tagName(app.side_panel),
            }) catch {};
            switch (app.side_panel) {
                .attention => {
                    if (!app.attention.live) {
                        _ = w.write("host unreachable\n") catch 0;
                    } else if (app.attention.n == 0) {
                        _ = w.write("nothing waiting\n") catch 0;
                    } else for (app.attention.slice()) |*it| {
                        w.print("{s}\t{s}{s}\n", .{
                            it.workspace(),
                            it.text(),
                            @as([]const u8, if (it.interactive) "\t(picker)" else ""),
                        }) catch break;
                    }
                    if (app.attention.more > 0)
                        w.print("+{d} more\n", .{app.attention.more}) catch {};
                },
                .review => {
                    if (!app.rev.live) {
                        _ = w.write("host unreachable\n") catch 0;
                    } else if (!app.rev.any) {
                        _ = w.write("no review in this workspace\n") catch 0;
                    } else {
                        w.print("gate {s} {s} blocking={d} total={d}\n{s}\n", .{
                            app.rev.verb.get(),
                            @as([]const u8, if (app.rev.ready) "READY" else "blocked"),
                            app.rev.blocking,
                            app.rev.total,
                            app.rev.label.get(),
                        }) catch {};
                        for (app.rev.slice(), 0..) |*f, i| {
                            w.print("{s}{d}\t{s}\t{s}:{d}\t{s}\n", .{
                                @as([]const u8, if (i == app.rev_sel) "*" else " "),
                                f.id,
                                @tagName(f.state),
                                f.path.get(),
                                f.line,
                                f.what.get(),
                            }) catch break;
                        }
                        if (app.rev.more > 0) w.print("+{d} more\n", .{app.rev.more}) catch {};
                    }
                },
                .threads => {
                    if (!app.thr.live) {
                        _ = w.write("host unreachable\n") catch 0;
                    } else if (app.thr.n == 0) {
                        _ = w.write("no open threads\n") catch 0;
                    } else for (app.thr.slice(), 0..) |*t, i| {
                        w.print("{s}{d}\t{s}:{d}\t{s}{s}\n", .{
                            @as([]const u8, if (i == app.thr_sel) "*" else " "),
                            t.id,
                            t.path.get(),
                            t.line,
                            t.anchor.get(),
                            @as([]const u8, if (t.undelivered) "\t(undelivered)" else if (t.has_draft) "\t(draft)" else ""),
                        }) catch break;
                    }
                    if (app.thr.more > 0) w.print("+{d} more\n", .{app.thr.more}) catch {};
                },
                .deck => {
                    if (!app.deck.live) {
                        _ = w.write("host unreachable\n") catch 0;
                    } else if (app.deck.n == 0) {
                        _ = w.write("no agents running\n") catch 0;
                    } else for (app.deck.slice(), 0..) |*a, i| {
                        w.print("{s}{s}\t{s}\t{s}\n", .{
                            @as([]const u8, if (i == app.deck_sel) "*" else " "),
                            @tagName(a.state),
                            a.cwd.get(),
                            a.what.get(),
                        }) catch break;
                    }
                    if (app.deck.more > 0) w.print("+{d} more\n", .{app.deck.more}) catch {};
                },
                .ask => {
                    if (app.ask) |a| {
                        const q = a.questions[app.ask_qi];
                        w.print("ask:{s} q:{d}/{d}{s}\n", .{
                            a.id.get(),
                            app.ask_qi + 1,
                            a.n,
                            @as([]const u8, if (q.multi) " multi" else ""),
                        }) catch {};
                        if (a.cwd.len > 0) {
                            var srcbuf: [96]u8 = undefined;
                            w.print("{s} ({s})\n", .{ app.askSourceLabel(&srcbuf), a.cwd.get() }) catch {};
                        }
                        w.print("{s}\n", .{q.text.get()}) catch {};
                        for (q.options[0..q.n], 0..) |o, i| {
                            w.print("{s}{s} {s}\n", .{
                                @as([]const u8, if (i == app.ask_sel) "*" else " "),
                                @as([]const u8, if (q.multi and app.ask_picked[i]) "[x]" else if (q.multi) "[ ]" else "( )"),
                                o.label.get(),
                            }) catch break;
                        }
                        w.print("{s}other: {s}\n", .{
                            @as([]const u8, if (app.ask_sel == q.n) "*" else " "),
                            app.ask_text[0..app.ask_text_len],
                        }) catch {};
                    } else _ = w.write("no question\n") catch 0;
                },
            }
        }
        app.draw_lock.unlock();
        reply(fd, buf[0..w.end]);
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
    } else if (std.mem.eql(u8, verb, "boottime") and rest.len == 0) {
        // Startup phase timings (µs), stamped in create() and at the
        // ctl bind above. No lock: written once before any client can
        // connect, immutable after.
        const b = macos.boot_times;
        var buf: [256]u8 = undefined;
        const s = std.fmt.bufPrint(
            &buf,
            "config_us={d} keybinds_us={d} appkit_us={d} renderer_us={d} session_us={d} create_us={d} ctl_ready_us={d}\n",
            .{ b.config_us, b.keybinds_us, b.appkit_us, b.renderer_us, b.session_us, b.create_us, b.ctl_ready_us },
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
    } else if (std.mem.eql(u8, verb, "search")) {
        // State only — the search is DRIVEN through `press`, so the
        // real copy-mode key path is what gets tested, not a shortcut
        // into the session that no keystroke can reach.
        app.draw_lock.lock();
        defer app.draw_lock.unlock();
        var buf: [256]u8 = undefined;
        const tm = app.activeTab().focused.term() orelse return reply(fd, "err not a terminal\n");
        const s2 = std.fmt.bufPrint(&buf, "copy={s} prompt={s} needle=\"{s}\" match={d}/{d}\n", .{
            @as([]const u8, if (tm.copy_mode) "yes" else "no"),
            @as([]const u8, if (tm.search_input) "open" else "closed"),
            tm.search_buf[0..tm.search_len],
            tm.search_i,
            tm.search_n,
        }) catch return;
        reply(fd, s2);
    } else if (std.mem.eql(u8, verb, "zoom")) {
        reply(fd, if (app.toggleZoom()) "ok\n" else "err nothing to zoom (single pane)\n");
    } else if (std.mem.eql(u8, verb, "clipboard")) {
        // The REAL pasteboard, read back — so an OSC 52 test proves the
        // bytes reached the system, not just that rook noticed them.
        // `last` distinguishes "rook wrote this" from "⌘C did".
        app.draw_lock.lock();
        defer app.draw_lock.unlock();
        var buf: [2048]u8 = undefined;
        var pbbuf: [512]u8 = undefined;
        const s2 = std.fmt.bufPrint(&buf, "pasteboard=\"{s}\" last=\"{s}\" allow={s}\n", .{
            app.pasteboardText(&pbbuf),
            app.clip_last[0..@min(app.clip_last_len, 512)],
            if (app.cfg_clip_allow) "yes" else "no",
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
        else if (std.mem.eql(u8, rest, "RET"))
            '\r'
        else if (std.mem.eql(u8, rest, "BS"))
            0x7f
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
            if (app.shotPending()) {
                // Disarm: a shot left armed makes every later one answer
                // "err busy", so one timeout would wedge the surface for
                // the life of the process.
                app.cancelShot();
                reply(fd, "err timeout\n");
            } else reply(fd, "ok\n");
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
