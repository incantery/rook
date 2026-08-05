//! rook's LSP client — JSON-RPC 2.0 over a server's stdio, in Zig, in
//! the app.
//!
//! It used to live in the Go host (internal/lsp), one client per
//! (server, root), reached over HTTP. That shape answered `rookctl def`
//! and could never grow past it, because LSP document sync is
//! VERSIONED: didChange carries edits and a version counter, and every
//! later request is answered against a version. The editor owns the
//! rope, the edit stream, and the version. A process boundary between
//! the buffer and the server forces either full text on every request
//! (what the host did) or an edit stream mirrored across HTTP and
//! reconciled on both sides. Diagnostics-as-you-type is unreachable
//! from there. So it moved here, next to the buffer.
//!
//! SANS-IO. `Session` never touches a file descriptor: bytes go in
//! through feed(), bytes come out of outbound(), and everything the app
//! wants comes out of nextEvent(). That is what makes a handshake, a
//! crashed server, an out-of-order response and a hostile payload all
//! testable without spawning anything. `Server` (bottom of this file)
//! is the only part that forks, and it is a pump between a pipe and a
//! Session.
//!
//! FAIL OPEN, everywhere — the host-protocol-skew rule aimed at a
//! process we didn't write. An unparseable message, an unknown method,
//! a field of the wrong type, a server that dies mid-request: the
//! session degrades to "no answers" and the editor keeps tree-sitter
//! highlighting and its buffer-keyword completion. Nothing here may
//! hand the editor an error to handle. A language server is an
//! enhancement, and an enhancement that can break the editor is a
//! defect.

const std = @import("std");
const Allocator = std.mem.Allocator;

// ------------------------------------------------------------------ URIs

/// `/a/b c.go` → `file:///a/b%20c.go`. Servers echo URIs back verbatim
/// in diagnostics and definitions, so the encoding has to round-trip
/// through pathFromUri exactly — see the test.
pub fn uriFromPath(gpa: Allocator, abs: []const u8) ?[]u8 {
    var a: std.Io.Writer.Allocating = .init(gpa);
    errdefer a.deinit();
    const w = &a.writer;
    w.writeAll("file://") catch return null;
    for (abs) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '.' or c == '_' or c == '~' or c == '/') {
            w.writeByte(c) catch return null;
        } else {
            w.print("%{X:0>2}", .{c}) catch return null;
        }
    }
    return a.toOwnedSlice() catch null;
}

/// `file:///a/b%20c.go` → `/a/b c.go`; null for anything that is not a
/// file URI (a server may name an in-memory or jar: resource, and a
/// path we invent for one would point at nothing).
pub fn pathFromUri(gpa: Allocator, uri: []const u8) ?[]u8 {
    if (!std.mem.startsWith(u8, uri, "file://")) return null;
    var rest = uri["file://".len..];
    // file://host/path — rook is local; a remote authority is not ours.
    if (rest.len > 0 and rest[0] != '/') {
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
        rest = rest[slash..];
    }
    var a: std.Io.Writer.Allocating = .init(gpa);
    errdefer a.deinit();
    const w = &a.writer;
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        if (rest[i] == '%' and i + 2 < rest.len) {
            const hi = std.fmt.charToDigit(rest[i + 1], 16) catch {
                w.writeByte(rest[i]) catch return null;
                continue;
            };
            const lo = std.fmt.charToDigit(rest[i + 2], 16) catch {
                w.writeByte(rest[i]) catch return null;
                continue;
            };
            w.writeByte(@as(u8, hi) * 16 + lo) catch return null;
            i += 2;
        } else w.writeByte(rest[i]) catch return null;
    }
    return a.toOwnedSlice() catch null;
}

// --------------------------------------------------------- UTF-16 columns

/// LSP columns are UTF-16 CODE UNITS, not bytes and not codepoints —
/// the protocol's default `positionEncoding`, and the one every server
/// in rook's catalog speaks. The editor counts bytes. These two convert,
/// and they are here rather than in the wiring because getting them
/// wrong is invisible until someone puts an emoji in a comment and every
/// diagnostic on that line lands two columns off.
pub fn utf16FromByteCol(line: []const u8, byte_col: usize) u32 {
    var units: u32 = 0;
    var i: usize = 0;
    while (i < line.len and i < byte_col) {
        const n = std.unicode.utf8ByteSequenceLength(line[i]) catch 1;
        if (i + n > line.len) break;
        // Everything outside the BMP is a surrogate PAIR: one codepoint,
        // two UTF-16 units. That is the whole difference, and it starts
        // at a 4-byte UTF-8 sequence.
        units += if (n == 4) 2 else 1;
        i += n;
    }
    return units;
}

/// The inverse, clamped to the line: a server may name a column past the
/// end (a diagnostic on a line that has since been edited), and a column
/// past the end must read as end-of-line, never as an overrun.
pub fn byteColFromUtf16(line: []const u8, u16_col: u32) usize {
    var units: u32 = 0;
    var i: usize = 0;
    while (i < line.len) {
        if (units >= u16_col) return i;
        const n = std.unicode.utf8ByteSequenceLength(line[i]) catch 1;
        if (i + n > line.len) break;
        units += if (n == 4) 2 else 1;
        i += n;
    }
    return line.len;
}

// ---------------------------------------------------------------- framing

pub const Frame = struct {
    /// The JSON body, borrowed from the buffer handed to parseFrame.
    body: []const u8,
    /// Header + body — how many bytes to consume from the stream.
    total: usize,
};

/// Pull one complete message out of `buf`. null means "need more bytes"
/// — the ordinary case on a stream. error.Malformed means the framing
/// is broken and the stream cannot be resynchronized, which for a pipe
/// means the server is not speaking LSP and the session is over.
pub fn parseFrame(buf: []const u8) error{Malformed}!?Frame {
    var len: ?usize = null;
    var i: usize = 0;
    while (true) {
        const nl = std.mem.indexOfScalarPos(u8, buf, i, '\n') orelse return null;
        const line = std.mem.trimEnd(u8, buf[i..nl], "\r");
        i = nl + 1;
        if (line.len == 0) break; // end of headers
        // Case-insensitive: the spec fixes the spelling, servers are
        // written by people, and being strict here buys nothing.
        if (line.len > 15 and std.ascii.eqlIgnoreCase(line[0..15], "Content-Length:")) {
            len = std.fmt.parseInt(usize, std.mem.trim(u8, line[15..], " \t"), 10) catch
                return error.Malformed;
        }
    }
    const n = len orelse return error.Malformed;
    // A length that would have us allocate the world is a desync, not a
    // big file: LSP bodies are JSON about one document.
    if (n > max_frame_bytes) return error.Malformed;
    if (buf.len < i + n) return null;
    return .{ .body = buf[i .. i + n], .total = i + n };
}

/// 64MB. gopls sends whole-workspace symbol replies; nothing legitimate
/// approaches this, and past it we are reading garbage as a length.
pub const max_frame_bytes = 64 * 1024 * 1024;

// ----------------------------------------------------------- language ids

/// Extension → LSP `languageId`. The server matches its own handlers off
/// this string, so a wrong one reads as "the server ignored my file".
///
/// This table is TEMPORARY in this shape: the language catalog owns it
/// once packages land, and then it comes off a package declaration
/// rather than an extension list compiled in here.
pub fn languageId(path: []const u8) ?[]const u8 {
    const table = [_]struct { ext: []const u8, id: []const u8 }{
        .{ .ext = ".go", .id = "go" },
        .{ .ext = ".zig", .id = "zig" },
        .{ .ext = ".py", .id = "python" },
        .{ .ext = ".pyi", .id = "python" },
        .{ .ext = ".ts", .id = "typescript" },
        .{ .ext = ".tsx", .id = "typescriptreact" },
        .{ .ext = ".mts", .id = "typescript" },
        .{ .ext = ".cts", .id = "typescript" },
        .{ .ext = ".js", .id = "javascript" },
        .{ .ext = ".jsx", .id = "javascriptreact" },
        .{ .ext = ".mjs", .id = "javascript" },
        .{ .ext = ".cjs", .id = "javascript" },
        .{ .ext = ".json", .id = "json" },
        .{ .ext = ".md", .id = "markdown" },
        .{ .ext = ".rs", .id = "rust" },
        .{ .ext = ".c", .id = "c" },
        .{ .ext = ".h", .id = "c" },
        .{ .ext = ".sh", .id = "shellscript" },
        .{ .ext = ".yaml", .id = "yaml" },
        .{ .ext = ".yml", .id = "yaml" },
        .{ .ext = ".toml", .id = "toml" },
    };
    for (table) |e| {
        if (std.mem.endsWith(u8, path, e.ext)) return e.id;
    }
    return null;
}

// ------------------------------------------------------------------ types

pub const Position = struct {
    /// 0-based, as the protocol has it — the editor's 1-based lines are
    /// the wiring's problem, converted at exactly one boundary.
    line: u32 = 0,
    /// UTF-16 code units. See utf16FromByteCol.
    col: u32 = 0,
};

pub const Range = struct {
    start: Position = .{},
    end: Position = .{},
};

pub const Severity = enum(u8) {
    err = 1,
    warn = 2,
    info = 3,
    hint = 4,

    fn fromInt(v: i64) Severity {
        return switch (v) {
            1 => .err,
            2 => .warn,
            3 => .info,
            4 => .hint,
            // The protocol says severity is OPTIONAL and an absent one
            // means "the client decides". Every editor decides error,
            // because a server that bothered to publish it means it.
            else => .err,
        };
    }
};

pub const Diagnostic = struct {
    range: Range = .{},
    severity: Severity = .err,
    /// Owned.
    message: []const u8 = "",
    /// Owned; "" when the server didn't say. gopls says "compiler",
    /// basedpyright says "basedpyright" — worth showing, since it is
    /// how you tell a type error from a lint.
    source: []const u8 = "",
};

pub const Location = struct {
    /// Absolute path, owned. A location whose URI wasn't a file URI is
    /// dropped before it gets here.
    path: []const u8 = "",
    range: Range = .{},
};

pub const Event = union(enum) {
    /// initialize came back; the session is usable and the legend (if
    /// any) is readable.
    ready,
    diagnostics: Diagnostics,
    hover: Hover,
    definition: Locations,
    /// Every use of the symbol. Same payload as a definition — a list of
    /// places — and deliberately a SEPARATE tag: "go here" and "here is
    /// where they all are" are different answers, and a caller that
    /// could not tell them apart would jump on a references reply.
    references: Locations,
    /// A request we sent is answered and has nothing to show: a null
    /// result, an error reply, or a server that died holding it. The
    /// caller MUST be released either way, or whatever it put on screen
    /// to say "asking…" stays there forever.
    empty: struct { id: u32 },
    /// The session is over. Reason is owned and is for a status line,
    /// not for control flow.
    failed: struct { reason: []const u8 },

    pub const Diagnostics = struct {
        /// Absolute path, owned.
        path: []const u8,
        /// Owned, with every message/source inside it.
        items: []Diagnostic,
        /// The document version these were computed against, when the
        /// server said. Diagnostics for a version older than the buffer
        /// are stale and the wiring will want to know.
        version: ?i64 = null,
    };

    pub const Hover = struct {
        id: u32,
        /// Owned, markdown as the server wrote it.
        text: []const u8,
        range: ?Range = null,
    };

    pub const Locations = struct {
        id: u32,
        /// Owned, with every path inside it.
        locs: []Location,
    };

    pub fn deinit(self: *Event, gpa: Allocator) void {
        switch (self.*) {
            .diagnostics => |*d| {
                gpa.free(d.path);
                for (d.items) |it| {
                    gpa.free(it.message);
                    gpa.free(it.source);
                }
                gpa.free(d.items);
            },
            .hover => |*h| gpa.free(h.text),
            .definition, .references => |*d| {
                for (d.locs) |l| gpa.free(l.path);
                gpa.free(d.locs);
            },
            .failed => |*f| gpa.free(f.reason),
            .ready, .empty => {},
        }
        self.* = .{ .empty = .{ .id = 0 } };
    }
};

pub const State = enum {
    /// Constructed; initialize not sent.
    new,
    /// initialize sent, reply outstanding. Requests queue here.
    initializing,
    ready,
    /// shutdown sent.
    stopping,
    /// The server is gone, expectedly or not. Terminal.
    failed,
};

const Kind = enum { initialize, hover, definition, references, shutdown };

const Pending = struct { id: u32, kind: Kind };

const Doc = struct {
    /// Absolute path, owned.
    path: []const u8,
    version: i32 = 1,
};

/// In flight at once. A UI can only be waiting on so many things, and
/// past this the oldest is released as `.empty` rather than growing a
/// list nobody drains.
const max_pending = 64;
/// Queued events. A server that floods diagnostics faster than the frame
/// loop drains them must not grow memory without bound; past this the
/// oldest DIAGNOSTIC is dropped (never a reply — replies release
/// callers).
const max_events = 256;
/// Locations kept from one reply. references on a popular symbol is the
/// only request whose answer is naturally this big; search.zig caps its
/// own hits at the same order for the same reason.
const max_locations = 2000;

// ---------------------------------------------------------------- Session

pub const Session = struct {
    gpa: Allocator,
    /// Absolute workspace root, owned.
    root: []const u8,
    state: State = .new,

    /// Bytes read off the server, awaiting a complete frame.
    in: std.ArrayListUnmanaged(u8) = .empty,
    /// Bytes to write to the server.
    out: std.ArrayListUnmanaged(u8) = .empty,
    /// Frames built before the handshake finished. LSP forbids sending
    /// anything but initialize until the reply lands, and a didOpen
    /// dropped on the floor is a file the server never sees.
    queued: std.ArrayListUnmanaged(u8) = .empty,

    next_id: u32 = 1,
    pending: std.ArrayListUnmanaged(Pending) = .empty,
    events: std.ArrayListUnmanaged(Event) = .empty,
    docs: std.ArrayListUnmanaged(Doc) = .empty,

    /// The server's semantic-token vocabulary, owned. Empty means it
    /// doesn't do semantic tokens — token data is integer indices into
    /// these, so without the legend there is nothing to read.
    legend_types: [][]const u8 = &.{},
    legend_mods: [][]const u8 = &.{},

    /// Verbatim JSON object of server settings, owned; "" for none. Sent
    /// on initialized and handed back for workspace/configuration, which
    /// is how gopls and basedpyright pull their config.
    settings: []const u8 = "",

    pub fn init(gpa: Allocator, root_abs: []const u8, settings_json: []const u8) ?Session {
        const root = gpa.dupe(u8, root_abs) catch return null;
        const set = gpa.dupe(u8, settings_json) catch {
            gpa.free(root);
            return null;
        };
        return .{ .gpa = gpa, .root = root, .settings = set };
    }

    pub fn deinit(self: *Session) void {
        const gpa = self.gpa;
        self.in.deinit(gpa);
        self.out.deinit(gpa);
        self.queued.deinit(gpa);
        self.pending.deinit(gpa);
        for (self.events.items) |*e| e.deinit(gpa);
        self.events.deinit(gpa);
        for (self.docs.items) |d| gpa.free(d.path);
        self.docs.deinit(gpa);
        self.freeLegend();
        gpa.free(self.root);
        gpa.free(self.settings);
        self.* = undefined;
    }

    fn freeLegend(self: *Session) void {
        for (self.legend_types) |t| self.gpa.free(t);
        self.gpa.free(self.legend_types);
        for (self.legend_mods) |m| self.gpa.free(m);
        self.gpa.free(self.legend_mods);
        self.legend_types = &.{};
        self.legend_mods = &.{};
    }

    /// The token types this server publishes, in legend order. Borrowed.
    pub fn legendTypes(self: *const Session) []const []const u8 {
        return self.legend_types;
    }

    // -------------------------------------------------------- outbound

    /// Bytes waiting to go to the server. Borrowed — write them, then
    /// say how many landed with consumeOutbound.
    pub fn outbound(self: *const Session) []const u8 {
        return self.out.items;
    }

    pub fn consumeOutbound(self: *Session, n: usize) void {
        if (n >= self.out.items.len) {
            self.out.clearRetainingCapacity();
            return;
        }
        std.mem.copyForwards(u8, self.out.items[0 .. self.out.items.len - n], self.out.items[n..]);
        self.out.shrinkRetainingCapacity(self.out.items.len - n);
    }

    fn frame(self: *Session, into: *std.ArrayListUnmanaged(u8), body: []const u8) void {
        var hdr: [48]u8 = undefined;
        const h = std.fmt.bufPrint(&hdr, "Content-Length: {d}\r\n\r\n", .{body.len}) catch return;
        into.appendSlice(self.gpa, h) catch return;
        into.appendSlice(self.gpa, body) catch return;
    }

    /// Route a built body: straight out once the handshake is done,
    /// parked until then.
    fn post(self: *Session, body: []const u8) void {
        if (self.state == .ready or self.state == .stopping) {
            self.frame(&self.out, body);
        } else {
            self.frame(&self.queued, body);
        }
    }

    fn notify(self: *Session, method: []const u8, params_json: []const u8) void {
        var a: std.Io.Writer.Allocating = .init(self.gpa);
        defer a.deinit();
        const w = &a.writer;
        w.writeAll("{\"jsonrpc\":\"2.0\",\"method\":") catch return;
        writeJsonString(w, method);
        w.writeAll(",\"params\":") catch return;
        w.writeAll(params_json) catch return;
        w.writeByte('}') catch return;
        self.post(a.written());
    }

    fn request(self: *Session, kind: Kind, method: []const u8, params_json: []const u8) ?u32 {
        if (self.state == .failed) return null;
        const id = self.next_id;
        self.next_id += 1;

        var a: std.Io.Writer.Allocating = .init(self.gpa);
        defer a.deinit();
        const w = &a.writer;
        w.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":", .{id}) catch return null;
        writeJsonString(w, method);
        w.writeAll(",\"params\":") catch return null;
        w.writeAll(params_json) catch return null;
        w.writeByte('}') catch return null;

        if (self.pending.items.len >= max_pending) {
            const old = self.pending.orderedRemove(0);
            self.push(.{ .empty = .{ .id = old.id } });
        }
        self.pending.append(self.gpa, .{ .id = id, .kind = kind }) catch return null;
        self.post(a.written());
        return id;
    }

    fn respond(self: *Session, id_json: []const u8, result_json: []const u8) void {
        var a: std.Io.Writer.Allocating = .init(self.gpa);
        defer a.deinit();
        const w = &a.writer;
        w.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{s}}}", .{ id_json, result_json }) catch return;
        // A response is never queued: the server is BLOCKED on it, and a
        // server blocked on us during the handshake is a deadlock.
        self.frame(&self.out, a.written());
    }

    fn respondError(self: *Session, id_json: []const u8, code: i32, message: []const u8) void {
        var a: std.Io.Writer.Allocating = .init(self.gpa);
        defer a.deinit();
        const w = &a.writer;
        w.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"error\":{{\"code\":{d},\"message\":", .{ id_json, code }) catch return;
        writeJsonString(w, message);
        w.writeAll("}}") catch return;
        self.frame(&self.out, a.written());
    }

    // --------------------------------------------------------- lifecycle

    /// Send initialize. Everything the app asks for before the reply
    /// lands is parked and flushed in order.
    pub fn start(self: *Session) void {
        if (self.state != .new) return;
        const uri = uriFromPath(self.gpa, self.root) orelse {
            self.fail("workspace root is not a usable path");
            return;
        };
        defer self.gpa.free(uri);

        var a: std.Io.Writer.Allocating = .init(self.gpa);
        defer a.deinit();
        const w = &a.writer;
        w.writeAll("{\"processId\":null,\"rootUri\":") catch return;
        writeJsonString(w, uri);
        w.writeAll(",\"workspaceFolders\":[{\"uri\":") catch return;
        writeJsonString(w, uri);
        w.writeAll(",\"name\":") catch return;
        writeJsonString(w, std.fs.path.basename(self.root));
        w.writeAll("}],\"capabilities\":{\"textDocument\":{" ++
            "\"definition\":{\"linkSupport\":true}," ++
            "\"references\":{}," ++
            "\"hover\":{\"contentFormat\":[\"markdown\",\"plaintext\"]}," ++
            "\"publishDiagnostics\":{\"versionSupport\":true}," ++
            "\"synchronization\":{\"didSave\":true}," ++
            // gopls refuses the semanticTokens capability outright when
            // `requests` is absent — learned the hard way in the Go
            // client, and the cost of getting it wrong is silence.
            "\"semanticTokens\":{\"requests\":{\"full\":true}," ++
            "\"tokenTypes\":[],\"tokenModifiers\":[],\"formats\":[\"relative\"]}}," ++
            "\"workspace\":{\"configuration\":true,\"workspaceFolders\":true}}}") catch return;

        // state is still .new, so post() would park it — initialize is
        // the one message that must go out now.
        const body = a.written();
        self.state = .initializing;
        const id = self.next_id;
        self.next_id += 1;
        var m: std.Io.Writer.Allocating = .init(self.gpa);
        defer m.deinit();
        m.writer.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"initialize\",\"params\":{s}}}", .{ id, body }) catch {
            self.fail("could not build initialize");
            return;
        };
        self.pending.append(self.gpa, .{ .id = id, .kind = .initialize }) catch {};
        self.frame(&self.out, m.written());
    }

    fn onInitialized(self: *Session, result: std.json.Value) void {
        const caps = jGet(result, "capabilities");
        const sem = jGet(caps, "semanticTokensProvider");
        if (sem != .null) {
            const legend = jGet(sem, "legend");
            self.legend_types = dupStrings(self.gpa, jGet(legend, "tokenTypes"));
            self.legend_mods = dupStrings(self.gpa, jGet(legend, "tokenModifiers"));
        }
        self.state = .ready;
        self.notify("initialized", "{}");
        if (self.settings.len > 0) {
            var a: std.Io.Writer.Allocating = .init(self.gpa);
            defer a.deinit();
            a.writer.print("{{\"settings\":{s}}}", .{self.settings}) catch return;
            self.notify("workspace/didChangeConfiguration", a.written());
        }
        // Flush what was parked, in the order it was asked for.
        self.out.appendSlice(self.gpa, self.queued.items) catch {};
        self.queued.clearRetainingCapacity();
        self.push(.ready);
    }

    /// Ask the server to stop. The caller still has to reap the process
    /// — a server that ignores shutdown is a server you kill.
    pub fn shutdown(self: *Session) void {
        if (self.state != .ready) return;
        self.state = .stopping;
        _ = self.request(.shutdown, "shutdown", "null");
        self.notify("exit", "null");
    }

    /// The server is gone. Releases every waiting caller — the part that
    /// matters, because a spinner outliving its server is the one
    /// failure the user cannot clear.
    pub fn serverGone(self: *Session, reason: []const u8) void {
        for (self.pending.items) |p| self.push(.{ .empty = .{ .id = p.id } });
        self.pending.clearRetainingCapacity();
        // A shutdown we asked for is not a failure to report.
        if (self.state == .stopping) {
            self.state = .failed;
            return;
        }
        self.fail(reason);
    }

    fn fail(self: *Session, reason: []const u8) void {
        if (self.state == .failed) return;
        self.state = .failed;
        const owned = self.gpa.dupe(u8, reason) catch return;
        self.push(.{ .failed = .{ .reason = owned } });
    }

    // ----------------------------------------------------------- events

    fn push(self: *Session, ev: Event) void {
        if (self.events.items.len >= max_events) {
            // Drop the oldest DIAGNOSTIC, never a reply: a dropped reply
            // strands a caller, a dropped diagnostic is superseded by
            // the next publish for that file anyway.
            var i: usize = 0;
            const dropped = while (i < self.events.items.len) : (i += 1) {
                if (self.events.items[i] == .diagnostics) break true;
            } else false;
            if (dropped) {
                var old = self.events.orderedRemove(i);
                old.deinit(self.gpa);
            } else {
                var ev_mut = ev;
                ev_mut.deinit(self.gpa);
                return;
            }
        }
        self.events.append(self.gpa, ev) catch {
            var ev_mut = ev;
            ev_mut.deinit(self.gpa);
        };
    }

    /// Oldest first. The caller owns what comes out — `ev.deinit(gpa)`.
    pub fn nextEvent(self: *Session) ?Event {
        if (self.events.items.len == 0) return null;
        return self.events.orderedRemove(0);
    }

    fn takePending(self: *Session, id: u32) ?Kind {
        for (self.pending.items, 0..) |p, i| {
            if (p.id == id) {
                _ = self.pending.orderedRemove(i);
                return p.kind;
            }
        }
        return null;
    }

    // -------------------------------------------------------- documents

    fn doc(self: *Session, path: []const u8) ?*Doc {
        for (self.docs.items) |*d| {
            if (std.mem.eql(u8, d.path, path)) return d;
        }
        return null;
    }

    pub fn isOpen(self: *Session, path: []const u8) bool {
        return self.doc(path) != null;
    }

    pub fn didOpen(self: *Session, path: []const u8, text: []const u8) void {
        if (self.state == .failed) return;
        if (self.doc(path) != null) return;
        const lang = languageId(path) orelse return;
        const uri = uriFromPath(self.gpa, path) orelse return;
        defer self.gpa.free(uri);
        const owned = self.gpa.dupe(u8, path) catch return;
        self.docs.append(self.gpa, .{ .path = owned, .version = 1 }) catch {
            self.gpa.free(owned);
            return;
        };

        var a: std.Io.Writer.Allocating = .init(self.gpa);
        defer a.deinit();
        const w = &a.writer;
        w.writeAll("{\"textDocument\":{\"uri\":") catch return;
        writeJsonString(w, uri);
        w.writeAll(",\"languageId\":") catch return;
        writeJsonString(w, lang);
        w.writeAll(",\"version\":1,\"text\":") catch return;
        writeJsonString(w, text);
        w.writeAll("}}") catch return;
        self.notify("textDocument/didOpen", a.written());
    }

    /// Full-text sync. Incremental sync is the next step and it is worth
    /// taking — it is the reason this client lives next to the rope —
    /// but full text first means the version counter and the ordering
    /// are proven before edit ranges are added on top.
    pub fn didChange(self: *Session, path: []const u8, text: []const u8) void {
        if (self.state == .failed) return;
        const d = self.doc(path) orelse return;
        d.version += 1;
        const uri = uriFromPath(self.gpa, path) orelse return;
        defer self.gpa.free(uri);

        var a: std.Io.Writer.Allocating = .init(self.gpa);
        defer a.deinit();
        const w = &a.writer;
        w.writeAll("{\"textDocument\":{\"uri\":") catch return;
        writeJsonString(w, uri);
        w.print(",\"version\":{d}}},\"contentChanges\":[{{\"text\":", .{d.version}) catch return;
        writeJsonString(w, text);
        w.writeAll("}]}") catch return;
        self.notify("textDocument/didChange", a.written());
    }

    pub fn didSave(self: *Session, path: []const u8) void {
        if (self.state == .failed) return;
        if (self.doc(path) == null) return;
        const uri = uriFromPath(self.gpa, path) orelse return;
        defer self.gpa.free(uri);
        var a: std.Io.Writer.Allocating = .init(self.gpa);
        defer a.deinit();
        a.writer.writeAll("{\"textDocument\":{\"uri\":") catch return;
        writeJsonString(&a.writer, uri);
        a.writer.writeAll("}}") catch return;
        self.notify("textDocument/didSave", a.written());
    }

    pub fn didClose(self: *Session, path: []const u8) void {
        if (self.state == .failed) return;
        var idx: ?usize = null;
        for (self.docs.items, 0..) |d, i| {
            if (std.mem.eql(u8, d.path, path)) idx = i;
        }
        const i = idx orelse return;
        self.gpa.free(self.docs.items[i].path);
        _ = self.docs.orderedRemove(i);

        const uri = uriFromPath(self.gpa, path) orelse return;
        defer self.gpa.free(uri);
        var a: std.Io.Writer.Allocating = .init(self.gpa);
        defer a.deinit();
        a.writer.writeAll("{\"textDocument\":{\"uri\":") catch return;
        writeJsonString(&a.writer, uri);
        a.writer.writeAll("}}") catch return;
        self.notify("textDocument/didClose", a.written());
    }

    /// The version the server has been told about, for deciding whether
    /// a diagnostic payload is stale.
    pub fn version(self: *Session, path: []const u8) ?i32 {
        const d = self.doc(path) orelse return null;
        return d.version;
    }

    // --------------------------------------------------------- requests

    /// TextDocumentPositionParams, plus whatever the method adds.
    ///
    /// `extra` is spliced in before the closing brace and must start
    /// with its own comma (`,\"context\":{…}`) — every position request
    /// in the protocol is this object with fields bolted on, and a
    /// second builder per method would drift from this one.
    fn posParamsExtra(self: *Session, path: []const u8, pos: Position, extra: []const u8) ?[]u8 {
        const uri = uriFromPath(self.gpa, path) orelse return null;
        defer self.gpa.free(uri);
        var a: std.Io.Writer.Allocating = .init(self.gpa);
        errdefer a.deinit();
        const w = &a.writer;
        w.writeAll("{\"textDocument\":{\"uri\":") catch return null;
        writeJsonString(w, uri);
        w.print("}},\"position\":{{\"line\":{d},\"character\":{d}}}", .{ pos.line, pos.col }) catch return null;
        w.writeAll(extra) catch return null;
        w.writeByte('}') catch return null;
        return a.toOwnedSlice() catch null;
    }

    fn posParams(self: *Session, path: []const u8, pos: Position) ?[]u8 {
        return self.posParamsExtra(path, pos, "");
    }

    /// Returns the request id; the answer arrives as a `.hover` or an
    /// `.empty` carrying the same id. null means it could not be sent at
    /// all, and then no event is coming.
    pub fn hover(self: *Session, path: []const u8, pos: Position) ?u32 {
        const params = self.posParams(path, pos) orelse return null;
        defer self.gpa.free(params);
        return self.request(.hover, "textDocument/hover", params);
    }

    pub fn definition(self: *Session, path: []const u8, pos: Position) ?u32 {
        const params = self.posParams(path, pos) orelse return null;
        defer self.gpa.free(params);
        return self.request(.definition, "textDocument/definition", params);
    }

    /// Every use of the symbol under `pos`, answered as a `.references`
    /// event carrying the same id.
    ///
    /// `include_decl` is in the protocol because some callers want only
    /// the uses. rook always says true: "where is this used" asked from
    /// the declaration itself would otherwise answer nothing, which
    /// reads as a broken key rather than as a precise one.
    pub fn references(self: *Session, path: []const u8, pos: Position, include_decl: bool) ?u32 {
        const params = self.posParamsExtra(path, pos, if (include_decl)
            ",\"context\":{\"includeDeclaration\":true}"
        else
            ",\"context\":{\"includeDeclaration\":false}") orelse return null;
        defer self.gpa.free(params);
        return self.request(.references, "textDocument/references", params);
    }

    // ---------------------------------------------------------- inbound

    /// Feed bytes read off the server. Complete frames are dispatched;
    /// a partial tail is kept for next time.
    pub fn feed(self: *Session, bytes: []const u8) void {
        if (self.state == .failed) return;
        self.in.appendSlice(self.gpa, bytes) catch {
            self.fail("out of memory reading the server");
            return;
        };
        while (true) {
            const f = parseFrame(self.in.items) catch {
                self.serverGone("the server is not speaking LSP");
                return;
            } orelse return;
            self.dispatch(f.body);
            const consumed = f.total;
            if (consumed >= self.in.items.len) {
                self.in.clearRetainingCapacity();
            } else {
                std.mem.copyForwards(u8, self.in.items[0 .. self.in.items.len - consumed], self.in.items[consumed..]);
                self.in.shrinkRetainingCapacity(self.in.items.len - consumed);
            }
            if (self.state == .failed) return;
        }
    }

    fn dispatch(self: *Session, body: []const u8) void {
        const parsed = std.json.parseFromSlice(std.json.Value, self.gpa, body, .{}) catch {
            // One bad message is not a dead session: skip it. A stream
            // that is truly broken fails at the framing layer instead.
            return;
        };
        defer parsed.deinit();
        const msg = parsed.value;
        if (msg != .object) return;

        const method = jStr(jGet(msg, "method"));
        const id = jGet(msg, "id");

        if (method != null and id != .null) {
            self.serverRequest(method.?, jGet(msg, "params"), id);
            return;
        }
        if (method) |m| {
            self.serverNotify(m, jGet(msg, "params"));
            return;
        }
        if (id == .integer) {
            self.serverReply(@intCast(id.integer), msg);
        }
    }

    /// Server→client requests. Everything a session needs to stay
    /// healthy is answered; everything else gets MethodNotFound, which
    /// servers survive — but it must be ANSWERED, because a server
    /// waiting on a request we ignored stops answering ours.
    fn serverRequest(self: *Session, method: []const u8, params: std.json.Value, id: std.json.Value) void {
        var idbuf: [40]u8 = undefined;
        const id_json = switch (id) {
            .integer => |i| std.fmt.bufPrint(&idbuf, "{d}", .{i}) catch return,
            .string => |s| blk: {
                var a: std.Io.Writer.Allocating = .init(self.gpa);
                defer a.deinit();
                writeJsonString(&a.writer, s);
                // Short-lived: respond copies it before we free.
                const owned = self.gpa.dupe(u8, a.written()) catch return;
                break :blk owned;
            },
            else => return,
        };
        defer if (id == .string) self.gpa.free(id_json);

        if (std.mem.eql(u8, method, "workspace/configuration")) {
            // Each item wants its named section out of our settings;
            // null for one we don't have, which servers treat as
            // "defaults" rather than as an error.
            var a: std.Io.Writer.Allocating = .init(self.gpa);
            defer a.deinit();
            const w = &a.writer;
            w.writeByte('[') catch return;
            const items = jGet(params, "items");
            var n: usize = 0;
            if (items == .array) {
                for (items.array.items) |item| {
                    if (n > 0) w.writeByte(',') catch return;
                    n += 1;
                    const section = jStr(jGet(item, "section")) orelse {
                        w.writeAll("null") catch return;
                        continue;
                    };
                    if (self.settingsSection(section)) |raw| {
                        w.writeAll(raw) catch return;
                        self.gpa.free(raw);
                    } else w.writeAll("null") catch return;
                }
            }
            w.writeByte(']') catch return;
            self.respond(id_json, a.written());
            return;
        }
        if (std.mem.eql(u8, method, "workspace/workspaceFolders")) {
            const uri = uriFromPath(self.gpa, self.root) orelse {
                self.respond(id_json, "null");
                return;
            };
            defer self.gpa.free(uri);
            var a: std.Io.Writer.Allocating = .init(self.gpa);
            defer a.deinit();
            a.writer.writeAll("[{\"uri\":") catch return;
            writeJsonString(&a.writer, uri);
            a.writer.writeAll(",\"name\":") catch return;
            writeJsonString(&a.writer, std.fs.path.basename(self.root));
            a.writer.writeAll("}]") catch return;
            self.respond(id_json, a.written());
            return;
        }
        // Registration, progress and message requests: acknowledged with
        // null. We don't act on dynamic registration — we asked for what
        // we want statically — but refusing it makes gopls noisy.
        if (std.mem.eql(u8, method, "client/registerCapability") or
            std.mem.eql(u8, method, "client/unregisterCapability") or
            std.mem.eql(u8, method, "window/workDoneProgress/create") or
            std.mem.eql(u8, method, "window/showMessageRequest") or
            std.mem.eql(u8, method, "workspace/applyEdit"))
        {
            self.respond(id_json, "null");
            return;
        }
        self.respondError(id_json, -32601, "method not found");
    }

    /// A section of the settings object, re-rendered. Returned owned
    /// because std.json owns the parse tree it came out of.
    ///
    /// A section name is a DOTTED PATH, not a key: pyright asks for
    /// "python.analysis" and expects the nested object, and answering
    /// null because there is no top-level key of that name reads to the
    /// server as "the client has no opinion", which silently discards
    /// settings the user did set.
    fn settingsSection(self: *Session, section: []const u8) ?[]u8 {
        if (self.settings.len == 0) return null;
        const parsed = std.json.parseFromSlice(std.json.Value, self.gpa, self.settings, .{}) catch return null;
        defer parsed.deinit();
        var v = parsed.value;
        var it = std.mem.splitScalar(u8, section, '.');
        while (it.next()) |part| {
            if (part.len == 0) continue;
            v = jGet(v, part);
            if (v == .null) return null;
        }
        return std.json.Stringify.valueAlloc(self.gpa, v, .{}) catch null;
    }

    fn serverNotify(self: *Session, method: []const u8, params: std.json.Value) void {
        if (!std.mem.eql(u8, method, "textDocument/publishDiagnostics")) return;
        // $/progress, window/logMessage, telemetry: deliberately dropped.
        const uri = jStr(jGet(params, "uri")) orelse return;
        const path = pathFromUri(self.gpa, uri) orelse return;
        errdefer self.gpa.free(path);

        const arr = jGet(params, "diagnostics");
        var items: std.ArrayListUnmanaged(Diagnostic) = .empty;
        errdefer {
            for (items.items) |it| {
                self.gpa.free(it.message);
                self.gpa.free(it.source);
            }
            items.deinit(self.gpa);
        }
        if (arr == .array) {
            for (arr.array.items) |d| {
                const msg = jStr(jGet(d, "message")) orelse continue;
                const message = self.gpa.dupe(u8, msg) catch continue;
                const src = self.gpa.dupe(u8, jStr(jGet(d, "source")) orelse "") catch {
                    self.gpa.free(message);
                    continue;
                };
                const sev = switch (jGet(d, "severity")) {
                    .integer => |i| Severity.fromInt(i),
                    else => Severity.err,
                };
                items.append(self.gpa, .{
                    .range = jRange(jGet(d, "range")),
                    .severity = sev,
                    .message = message,
                    .source = src,
                }) catch {
                    self.gpa.free(message);
                    self.gpa.free(src);
                    continue;
                };
            }
        }
        const owned = items.toOwnedSlice(self.gpa) catch {
            self.gpa.free(path);
            return;
        };
        const ver: ?i64 = switch (jGet(params, "version")) {
            .integer => |i| i,
            else => null,
        };
        self.push(.{ .diagnostics = .{ .path = path, .items = owned, .version = ver } });
    }

    fn serverReply(self: *Session, id: u32, msg: std.json.Value) void {
        const kind = self.takePending(id) orelse return;
        const err = jGet(msg, "error");
        const result = jGet(msg, "result");

        if (err != .null) {
            // An error reply to initialize is fatal; to a query it is
            // just "no answer" — servers error on positions they don't
            // understand all the time.
            if (kind == .initialize) {
                self.fail(jStr(jGet(err, "message")) orelse "the server refused to initialize");
            } else if (kind != .shutdown) {
                self.push(.{ .empty = .{ .id = id } });
            }
            return;
        }

        switch (kind) {
            .initialize => self.onInitialized(result),
            .shutdown => {},
            .hover => self.onHover(id, result),
            .definition => self.onLocations(id, result, false),
            .references => self.onLocations(id, result, true),
        }
    }

    fn onHover(self: *Session, id: u32, result: std.json.Value) void {
        if (result == .null) {
            self.push(.{ .empty = .{ .id = id } });
            return;
        }
        var a: std.Io.Writer.Allocating = .init(self.gpa);
        defer a.deinit();
        appendHoverText(&a.writer, jGet(result, "contents"));
        const text = a.written();
        if (text.len == 0) {
            self.push(.{ .empty = .{ .id = id } });
            return;
        }
        const owned = self.gpa.dupe(u8, text) catch return;
        const rng = jGet(result, "range");
        self.push(.{ .hover = .{
            .id = id,
            .text = owned,
            .range = if (rng == .null) null else jRange(rng),
        } });
    }

    /// definition and references answer the same shape — a Location, an
    /// array of them, or null — so they read the same. `many` picks the
    /// tag the caller is waiting on.
    fn onLocations(self: *Session, id: u32, result: std.json.Value, many: bool) void {
        var locs: std.ArrayListUnmanaged(Location) = .empty;
        defer locs.deinit(self.gpa);

        switch (result) {
            // A single Location object.
            .object => if (self.readLocation(result)) |l| {
                locs.append(self.gpa, l) catch {};
            },
            // Location[] or LocationLink[] — gopls answers with
            // LocationLinks whenever the client says linkSupport, which
            // ours does, so BOTH shapes have to be read or "go to
            // definition does nothing" is the symptom.
            .array => |arr| for (arr.items) |item| {
                // References to a common symbol run to thousands, and
                // the list is the SERVER's to decide. Past the cap the
                // rest are dropped rather than allocated — nobody reads
                // hit 2001, and an unbounded reply is the one input this
                // client cannot refuse.
                if (locs.items.len >= max_locations) break;
                if (self.readLocation(item)) |l| locs.append(self.gpa, l) catch {};
            },
            else => {},
        }

        if (locs.items.len == 0) {
            self.push(.{ .empty = .{ .id = id } });
            return;
        }
        const owned = locs.toOwnedSlice(self.gpa) catch {
            for (locs.items) |l| self.gpa.free(l.path);
            return;
        };
        const payload: Event.Locations = .{ .id = id, .locs = owned };
        self.push(if (many) .{ .references = payload } else .{ .definition = payload });
    }

    fn readLocation(self: *Session, v: std.json.Value) ?Location {
        if (jStr(jGet(v, "uri"))) |uri| {
            const path = pathFromUri(self.gpa, uri) orelse return null;
            return .{ .path = path, .range = jRange(jGet(v, "range")) };
        }
        // LocationLink: targetSelectionRange is the identifier itself,
        // targetRange the whole declaration. Jumping to the identifier
        // is what every editor does.
        if (jStr(jGet(v, "targetUri"))) |uri| {
            const path = pathFromUri(self.gpa, uri) orelse return null;
            const sel = jGet(v, "targetSelectionRange");
            return .{
                .path = path,
                .range = jRange(if (sel == .null) jGet(v, "targetRange") else sel),
            };
        }
        return null;
    }
};

// ------------------------------------------------------------- json bits

fn jGet(v: std.json.Value, key: []const u8) std.json.Value {
    return switch (v) {
        .object => |o| o.get(key) orelse .null,
        else => .null,
    };
}

fn jStr(v: std.json.Value) ?[]const u8 {
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

fn jU32(v: std.json.Value) u32 {
    return switch (v) {
        .integer => |i| if (i < 0) 0 else @intCast(i),
        // A float where an integer belongs is a JSON encoder being
        // liberal, not a protocol violation worth dropping a position
        // over.
        .float => |f| if (f < 0) 0 else @intFromFloat(f),
        else => 0,
    };
}

fn jPos(v: std.json.Value) Position {
    return .{ .line = jU32(jGet(v, "line")), .col = jU32(jGet(v, "character")) };
}

fn jRange(v: std.json.Value) Range {
    return .{ .start = jPos(jGet(v, "start")), .end = jPos(jGet(v, "end")) };
}

fn dupStrings(gpa: Allocator, v: std.json.Value) [][]const u8 {
    const arr = switch (v) {
        .array => |a| a.items,
        else => return &.{},
    };
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    for (arr) |item| {
        const s = jStr(item) orelse continue;
        const owned = gpa.dupe(u8, s) catch continue;
        out.append(gpa, owned) catch {
            gpa.free(owned);
            continue;
        };
    }
    return out.toOwnedSlice(gpa) catch &.{};
}

/// Hover contents come in three shapes across server generations:
/// MarkupContent `{kind,value}`, a bare string, a `{language,value}`
/// MarkedString, or an array of those. Reading only the modern one
/// means older servers hover blank.
fn appendHoverText(w: *std.Io.Writer, contents: std.json.Value) void {
    switch (contents) {
        .string => |s| w.writeAll(s) catch return,
        .object => {
            if (jStr(jGet(contents, "value"))) |v| w.writeAll(v) catch return;
        },
        .array => |arr| for (arr.items, 0..) |item, i| {
            if (i > 0) w.writeAll("\n\n") catch return;
            appendHoverText(w, item);
        },
        else => {},
    }
}

/// JSON-escape into a writer. Same rules as threaddoc.zig's — kept local so
/// this module has no dependency beyond std, since it is also the module
/// most likely to be lifted into a test harness on its own.
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

// ----------------------------------------------------------------- Server

// libc directly, as pty.zig does and for the same reason: Zig 0.16's
// std.posix no longer wraps process control, and this is the C
// incantation either way.
extern "c" fn pipe(fds: *[2]c_int) c_int;
extern "c" fn fork() c_int;
extern "c" fn execvp(path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn dup2(old: c_int, new: c_int) c_int;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn read(fd: c_int, buf: [*]u8, n: usize) isize;
extern "c" fn write(fd: c_int, buf: [*]const u8, n: usize) isize;
extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
extern "c" fn chdir(path: [*:0]const u8) c_int;
extern "c" fn kill(pid: c_int, sig: c_int) c_int;
extern "c" fn waitpid(pid: c_int, status: ?*c_int, options: c_int) c_int;
extern "c" fn poll(fds: [*]PollFd, n: c_uint, timeout: c_int) c_int;
extern "c" fn getdtablesize() c_int;
extern "c" fn _exit(code: c_int) noreturn;

extern "c" fn usleep(us: u32) c_int;
extern "c" fn os_unfair_lock_lock(lock: *u32) void;
extern "c" fn os_unfair_lock_unlock(lock: *u32) void;

/// The same tiny lock session.zig uses, redeclared rather than imported:
/// session.zig pulls ghostty-vt, and this module's headless test root
/// gets its value from depending on nothing but std and libc.
const Lock = struct {
    raw: u32 = 0,
    fn lock(self: *Lock) void {
        os_unfair_lock_lock(&self.raw);
    }
    fn unlock(self: *Lock) void {
        os_unfair_lock_unlock(&self.raw);
    }
};

const PollFd = extern struct {
    fd: c_int,
    events: i16,
    revents: i16 = 0,
};
const POLLIN: i16 = 1;
const O_WRONLY = 1;
const SIGTERM = 15;
const SIGKILL = 9;

/// A live language server: the process, the pump thread, and the Session
/// they share. Every method locks — callers on the frame loop should
/// treat all of them as cheap and none of them as blocking on the
/// server, because the pump owns the pipe and the frame loop never
/// touches it.
///
/// Writes never happen on the caller's thread. That is deliberate: a
/// didOpen of a megabyte file is a megabyte write, and a server busy
/// parsing is a server not reading, so a "quick" write from the frame
/// loop is a dropped frame waiting to happen.
pub const Server = struct {
    gpa: Allocator,
    sess: Session,
    mu: Lock = .{},
    thread: ?std.Thread = null,

    pid: c_int = -1,
    to_child: c_int = -1,
    from_child: c_int = -1,
    /// The pump sleeps in poll(); this is how a caller wakes it to say
    /// "there is outbound waiting" without ever writing to the pipe.
    wake_r: c_int = -1,
    wake_w: c_int = -1,
    quit: std.atomic.Value(bool) = .init(false),

    /// Spawn `argv` with `root` as its working directory. null when the
    /// process could not be started at all — the caller carries on
    /// without a server, which is the whole fail-open contract.
    pub fn start(gpa: Allocator, argv: []const []const u8, root: []const u8, settings_json: []const u8) ?*Server {
        if (argv.len == 0) return null;
        const self = gpa.create(Server) catch return null;
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .sess = Session.init(gpa, root, settings_json) orelse {
                gpa.destroy(self);
                return null;
            },
        };
        errdefer self.sess.deinit();

        var in_fds: [2]c_int = undefined;
        var out_fds: [2]c_int = undefined;
        var wake_fds: [2]c_int = undefined;
        if (pipe(&in_fds) != 0) return null;
        if (pipe(&out_fds) != 0) {
            _ = close(in_fds[0]);
            _ = close(in_fds[1]);
            return null;
        }
        if (pipe(&wake_fds) != 0) {
            _ = close(in_fds[0]);
            _ = close(in_fds[1]);
            _ = close(out_fds[0]);
            _ = close(out_fds[1]);
            return null;
        }

        // argv and root must be NUL-terminated BEFORE the fork: after
        // it, in the child, allocating is not safe.
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const a = arena.allocator();
        var cargv = a.allocSentinel(?[*:0]const u8, argv.len, null) catch return null;
        for (argv, 0..) |arg, i| {
            cargv[i] = (a.dupeZ(u8, arg) catch return null).ptr;
        }
        const croot = a.dupeZ(u8, root) catch return null;

        const child = fork();
        if (child < 0) {
            _ = close(in_fds[0]);
            _ = close(in_fds[1]);
            _ = close(out_fds[0]);
            _ = close(out_fds[1]);
            _ = close(wake_fds[0]);
            _ = close(wake_fds[1]);
            return null;
        }
        if (child == 0) {
            _ = dup2(in_fds[0], 0);
            _ = dup2(out_fds[1], 1);
            // Servers chatter on stderr — gopls logs, vtsls logs a lot.
            // Inheriting ours would print it over rook's own window.
            const devnull = open("/dev/null", O_WRONLY);
            if (devnull >= 0) _ = dup2(devnull, 2);
            // EVERYTHING above stdio dies here, not just our own pipes.
            // pty.zig learned this the hard way and its comment says it
            // best: a ctl CONNECTION held open by a child keeps the
            // client from ever seeing EOF. A language server is a child
            // like any other, and it outlives a lot of ctl connections.
            var cfd: c_int = 3;
            const maxfd = getdtablesize();
            while (cfd < maxfd) : (cfd += 1) _ = close(cfd);
            _ = chdir(croot);
            _ = execvp(cargv[0].?, cargv.ptr);
            _exit(127);
        }

        _ = close(in_fds[0]);
        _ = close(out_fds[1]);
        self.pid = child;
        self.to_child = in_fds[1];
        self.from_child = out_fds[0];
        self.wake_r = wake_fds[0];
        self.wake_w = wake_fds[1];

        self.sess.start();
        self.thread = std.Thread.spawn(.{}, pump, .{self}) catch {
            self.stop();
            self.sess.deinit();
            gpa.destroy(self);
            return null;
        };
        return self;
    }

    fn pump(self: *Server) void {
        var buf: [64 * 1024]u8 = undefined;
        // Anything the handshake already produced.
        self.flush();
        while (!self.quit.load(.acquire)) {
            var fds = [_]PollFd{
                .{ .fd = self.from_child, .events = POLLIN },
                .{ .fd = self.wake_r, .events = POLLIN },
            };
            const n = poll(&fds, 2, 1000);
            if (n < 0) break;
            if (fds[1].revents & POLLIN != 0) {
                var drain: [64]u8 = undefined;
                _ = read(self.wake_r, &drain, drain.len);
                self.flush();
            }
            if (fds[0].revents & POLLIN != 0) {
                const got = read(self.from_child, &buf, buf.len);
                if (got <= 0) {
                    self.mu.lock();
                    self.sess.serverGone("the language server exited");
                    self.mu.unlock();
                    return;
                }
                self.mu.lock();
                self.sess.feed(buf[0..@intCast(got)]);
                self.mu.unlock();
                // feed() can produce outbound of its own — responses to
                // server→client requests, and the queue flushed by the
                // initialize reply.
                self.flush();
            }
            // revents may report the far end closed without POLLIN.
            if (fds[0].revents != 0 and fds[0].revents & POLLIN == 0) {
                self.mu.lock();
                self.sess.serverGone("the language server exited");
                self.mu.unlock();
                return;
            }
        }
    }

    /// Copy pending outbound out from under the lock, then write it
    /// unlocked — a blocking write must never hold the session while the
    /// frame loop wants it.
    fn flush(self: *Server) void {
        while (true) {
            self.mu.lock();
            const pending = self.sess.outbound();
            if (pending.len == 0) {
                self.mu.unlock();
                return;
            }
            const chunk = self.gpa.dupe(u8, pending) catch {
                self.mu.unlock();
                return;
            };
            self.sess.consumeOutbound(chunk.len);
            self.mu.unlock();
            defer self.gpa.free(chunk);

            var off: usize = 0;
            while (off < chunk.len) {
                const wrote = write(self.to_child, chunk.ptr + off, chunk.len - off);
                if (wrote <= 0) return; // the child is gone; poll will see it
                off += @intCast(wrote);
            }
        }
    }

    fn poke(self: *Server) void {
        const byte = [_]u8{1};
        _ = write(self.wake_w, &byte, 1);
    }

    // ------------------------------------------------ locked passthrough

    pub fn state(self: *Server) State {
        self.mu.lock();
        defer self.mu.unlock();
        return self.sess.state;
    }

    pub fn didOpen(self: *Server, path: []const u8, text: []const u8) void {
        self.mu.lock();
        self.sess.didOpen(path, text);
        self.mu.unlock();
        self.poke();
    }

    pub fn didChange(self: *Server, path: []const u8, text: []const u8) void {
        self.mu.lock();
        self.sess.didChange(path, text);
        self.mu.unlock();
        self.poke();
    }

    pub fn didSave(self: *Server, path: []const u8) void {
        self.mu.lock();
        self.sess.didSave(path);
        self.mu.unlock();
        self.poke();
    }

    pub fn didClose(self: *Server, path: []const u8) void {
        self.mu.lock();
        self.sess.didClose(path);
        self.mu.unlock();
        self.poke();
    }

    pub fn hover(self: *Server, path: []const u8, pos: Position) ?u32 {
        self.mu.lock();
        const id = self.sess.hover(path, pos);
        self.mu.unlock();
        self.poke();
        return id;
    }

    pub fn definition(self: *Server, path: []const u8, pos: Position) ?u32 {
        self.mu.lock();
        const id = self.sess.definition(path, pos);
        self.mu.unlock();
        self.poke();
        return id;
    }

    pub fn references(self: *Server, path: []const u8, pos: Position, include_decl: bool) ?u32 {
        self.mu.lock();
        const id = self.sess.references(path, pos, include_decl);
        self.mu.unlock();
        self.poke();
        return id;
    }

    /// Drain one event. The caller owns it — `ev.deinit(gpa)`.
    pub fn nextEvent(self: *Server) ?Event {
        self.mu.lock();
        defer self.mu.unlock();
        return self.sess.nextEvent();
    }

    /// Ask the server to stop, then make sure it did. Idempotent.
    pub fn stop(self: *Server) void {
        if (self.quit.swap(true, .acq_rel)) return;
        self.mu.lock();
        self.sess.shutdown();
        self.mu.unlock();
        self.flush();
        // Closing stdin is what most servers actually exit on; SIGTERM
        // covers the ones that don't. Neither is trusted to be enough —
        // waitpid below is, because the pump has stopped reading.
        if (self.to_child >= 0) {
            _ = close(self.to_child);
            self.to_child = -1;
        }
        if (self.pid > 0) _ = kill(self.pid, SIGTERM);
        self.poke();
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
        if (self.pid > 0) {
            var status: c_int = 0;
            if (waitpid(self.pid, &status, 0) < 0) {
                _ = kill(self.pid, SIGKILL);
                _ = waitpid(self.pid, &status, 0);
            }
            self.pid = -1;
        }
        if (self.from_child >= 0) {
            _ = close(self.from_child);
            self.from_child = -1;
        }
        if (self.wake_r >= 0) {
            _ = close(self.wake_r);
            self.wake_r = -1;
        }
        if (self.wake_w >= 0) {
            _ = close(self.wake_w);
            self.wake_w = -1;
        }
    }

    pub fn deinit(self: *Server) void {
        self.stop();
        self.sess.deinit();
        const gpa = self.gpa;
        gpa.destroy(self);
    }
};

// ------------------------------------------------------------------ tests

const testing = std.testing;

fn framed(gpa: Allocator, body: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "Content-Length: {d}\r\n\r\n{s}", .{ body.len, body });
}

/// Drive a session to ready with a canned initialize reply, so the tests
/// past the handshake don't each re-do it.
fn readySession(sess: *Session, legend: bool) !void {
    sess.start();
    const reply = if (legend)
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"capabilities\":{\"semanticTokensProvider\":" ++
            "{\"legend\":{\"tokenTypes\":[\"namespace\",\"type\"],\"tokenModifiers\":[\"static\"]}}}}}"
    else
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"capabilities\":{}}}";
    const f = try framed(testing.allocator, reply);
    defer testing.allocator.free(f);
    sess.feed(f);
}

test "uri round trip survives spaces, unicode and reserved bytes" {
    const gpa = testing.allocator;
    const cases = [_][]const u8{
        "/Users/seth/go/src/main.go",
        "/tmp/a b/c.go",
        "/tmp/héllo/wörld.py",
        "/tmp/a#b?c/d.ts",
        "/tmp/100%/x.js",
    };
    for (cases) |p| {
        const uri = uriFromPath(gpa, p).?;
        defer gpa.free(uri);
        try testing.expect(std.mem.startsWith(u8, uri, "file:///"));
        const back = pathFromUri(gpa, uri).?;
        defer gpa.free(back);
        try testing.expectEqualStrings(p, back);
    }
}

test "pathFromUri refuses what isn't a local file" {
    const gpa = testing.allocator;
    try testing.expect(pathFromUri(gpa, "untitled:Untitled-1") == null);
    try testing.expect(pathFromUri(gpa, "jdt://contents/rt.jar") == null);
    // A host authority is somebody else's filesystem; the path after it
    // is still parsed, but only because dropping the authority is the
    // documented normalization for file://localhost/...
    const local = pathFromUri(gpa, "file://localhost/tmp/x.go").?;
    defer gpa.free(local);
    try testing.expectEqualStrings("/tmp/x.go", local);
}

test "utf16 columns: ascii, accents, CJK and astral planes" {
    // "aé中🙂b": 1 + 2 + 3 + 4 + 1 bytes; 1 + 1 + 1 + 2 + 1 UTF-16 units.
    const line = "a\u{e9}\u{4e2d}\u{1f642}b";
    try testing.expectEqual(@as(u32, 0), utf16FromByteCol(line, 0));
    try testing.expectEqual(@as(u32, 1), utf16FromByteCol(line, 1));
    try testing.expectEqual(@as(u32, 2), utf16FromByteCol(line, 3));
    try testing.expectEqual(@as(u32, 3), utf16FromByteCol(line, 6));
    try testing.expectEqual(@as(u32, 5), utf16FromByteCol(line, 10));
    try testing.expectEqual(@as(u32, 6), utf16FromByteCol(line, 11));

    try testing.expectEqual(@as(usize, 0), byteColFromUtf16(line, 0));
    try testing.expectEqual(@as(usize, 1), byteColFromUtf16(line, 1));
    try testing.expectEqual(@as(usize, 3), byteColFromUtf16(line, 2));
    try testing.expectEqual(@as(usize, 6), byteColFromUtf16(line, 3));
    try testing.expectEqual(@as(usize, 10), byteColFromUtf16(line, 5));
    // Past the end clamps to the end rather than overrunning — a stale
    // diagnostic names a column the line no longer has.
    try testing.expectEqual(@as(usize, 11), byteColFromUtf16(line, 99));
}

test "parseFrame: partial, exact, trailing, and the shapes that are broken" {
    try testing.expect(try parseFrame("Content-Length: 2\r\n\r\n{") == null);
    try testing.expect(try parseFrame("Content-Len") == null);

    const one = (try parseFrame("Content-Length: 2\r\n\r\n{}")).?;
    try testing.expectEqualStrings("{}", one.body);
    try testing.expectEqual(@as(usize, 23), one.total);

    // A second message in the same read must not be swallowed.
    const two = (try parseFrame("Content-Length: 2\r\n\r\n{}Content-Length: 4\r\n\r\nnull")).?;
    try testing.expectEqualStrings("{}", two.body);

    // Extra headers, and the casing servers actually send.
    const withct = (try parseFrame("content-length: 2\r\nContent-Type: application/vscode-jsonrpc\r\n\r\n{}")).?;
    try testing.expectEqualStrings("{}", withct.body);

    // LF-only line endings: out of spec, and cheap to survive.
    const lf = (try parseFrame("Content-Length: 2\n\n{}")).?;
    try testing.expectEqualStrings("{}", lf.body);

    try testing.expectError(error.Malformed, parseFrame("Content-Length: banana\r\n\r\n{}"));
    try testing.expectError(error.Malformed, parseFrame("X-Nothing: 1\r\n\r\n{}"));
    try testing.expectError(error.Malformed, parseFrame("Content-Length: 999999999999\r\n\r\n{}"));
}

test "languageId maps what the catalog will need" {
    try testing.expectEqualStrings("go", languageId("/x/main.go").?);
    try testing.expectEqualStrings("python", languageId("/x/main.py").?);
    try testing.expectEqualStrings("typescript", languageId("/x/a.ts").?);
    try testing.expectEqualStrings("typescriptreact", languageId("/x/a.tsx").?);
    try testing.expectEqualStrings("javascript", languageId("/x/a.mjs").?);
    try testing.expect(languageId("/x/README") == null);
}

test "handshake: initialize goes out alone, the legend is read, ready fires" {
    const gpa = testing.allocator;
    var sess = Session.init(gpa, "/tmp/work", "").?;
    defer sess.deinit();

    sess.start();
    try testing.expectEqual(State.initializing, sess.state);
    const out = sess.outbound();
    try testing.expect(std.mem.indexOf(u8, out, "\"method\":\"initialize\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "file:///tmp/work") != null);
    // The capability gopls insists on.
    try testing.expect(std.mem.indexOf(u8, out, "\"requests\":{\"full\":true}") != null);
    sess.consumeOutbound(out.len);

    const reply = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"capabilities\":{\"semanticTokensProvider\":" ++
        "{\"legend\":{\"tokenTypes\":[\"namespace\",\"type\"],\"tokenModifiers\":[\"static\"]}}}}}";
    const f = try framed(gpa, reply);
    defer gpa.free(f);
    sess.feed(f);

    try testing.expectEqual(State.ready, sess.state);
    try testing.expectEqual(@as(usize, 2), sess.legendTypes().len);
    try testing.expectEqualStrings("type", sess.legendTypes()[1]);
    try testing.expect(std.mem.indexOf(u8, sess.outbound(), "\"method\":\"initialized\"") != null);

    var ev = sess.nextEvent().?;
    defer ev.deinit(gpa);
    try testing.expect(ev == .ready);
}

test "work asked for before the handshake lands is parked, not dropped" {
    const gpa = testing.allocator;
    var sess = Session.init(gpa, "/tmp/work", "").?;
    defer sess.deinit();

    sess.start();
    sess.consumeOutbound(sess.outbound().len);

    // The protocol forbids these before the reply; the app doesn't know
    // that and shouldn't have to.
    sess.didOpen("/tmp/work/a.go", "package main\n");
    const hid = sess.hover("/tmp/work/a.go", .{ .line = 0, .col = 3 });
    try testing.expect(hid != null);
    try testing.expectEqual(@as(usize, 0), sess.outbound().len);

    try readySession(&sess, false);

    const out = sess.outbound();
    const i_init = std.mem.indexOf(u8, out, "\"method\":\"initialized\"").?;
    const i_open = std.mem.indexOf(u8, out, "textDocument/didOpen").?;
    const i_hover = std.mem.indexOf(u8, out, "textDocument/hover").?;
    // Order is the contract: initialized first, then the parked work as
    // it was asked for. A hover that overtakes its didOpen is a hover on
    // a file the server has never seen.
    try testing.expect(i_init < i_open);
    try testing.expect(i_open < i_hover);
}

test "document versions increment, and close forgets the file" {
    const gpa = testing.allocator;
    var sess = Session.init(gpa, "/tmp/work", "").?;
    defer sess.deinit();
    try readySession(&sess, false);
    sess.consumeOutbound(sess.outbound().len);

    sess.didOpen("/tmp/work/a.go", "package main\n");
    try testing.expectEqual(@as(i32, 1), sess.version("/tmp/work/a.go").?);
    sess.didChange("/tmp/work/a.go", "package main\n\n");
    sess.didChange("/tmp/work/a.go", "package main\n\n\n");
    try testing.expectEqual(@as(i32, 3), sess.version("/tmp/work/a.go").?);
    try testing.expect(std.mem.indexOf(u8, sess.outbound(), "\"version\":3") != null);

    // A change to a file we never opened is not a change with version 1
    // — it is nothing. Inventing one desynchronizes the server's copy.
    sess.didChange("/tmp/work/never.go", "x");
    try testing.expect(std.mem.indexOf(u8, sess.outbound(), "never.go") == null);

    sess.didClose("/tmp/work/a.go");
    try testing.expect(!sess.isOpen("/tmp/work/a.go"));
    try testing.expect(sess.version("/tmp/work/a.go") == null);
}

test "didOpen of a language we have no id for is skipped, not guessed" {
    const gpa = testing.allocator;
    var sess = Session.init(gpa, "/tmp/work", "").?;
    defer sess.deinit();
    try readySession(&sess, false);
    sess.consumeOutbound(sess.outbound().len);

    sess.didOpen("/tmp/work/NOTES", "hello");
    try testing.expectEqual(@as(usize, 0), sess.outbound().len);
    try testing.expect(!sess.isOpen("/tmp/work/NOTES"));
}

test "publishDiagnostics becomes an event with a decoded path" {
    const gpa = testing.allocator;
    var sess = Session.init(gpa, "/tmp/work", "").?;
    defer sess.deinit();
    try readySession(&sess, false);
    var ready = sess.nextEvent().?;
    ready.deinit(gpa);

    const note =
        "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\"params\":{" ++
        "\"uri\":\"file:///tmp/work/a%20b.go\",\"version\":7,\"diagnostics\":[" ++
        "{\"range\":{\"start\":{\"line\":3,\"character\":8},\"end\":{\"line\":3,\"character\":12}}," ++
        "\"severity\":1,\"source\":\"compiler\",\"message\":\"undefined: foo\"}," ++
        "{\"range\":{\"start\":{\"line\":9,\"character\":0},\"end\":{\"line\":9,\"character\":1}}," ++
        "\"severity\":2,\"message\":\"unused\"}]}}";
    const f = try framed(gpa, note);
    defer gpa.free(f);
    sess.feed(f);

    var ev = sess.nextEvent().?;
    defer ev.deinit(gpa);
    try testing.expect(ev == .diagnostics);
    try testing.expectEqualStrings("/tmp/work/a b.go", ev.diagnostics.path);
    try testing.expectEqual(@as(i64, 7), ev.diagnostics.version.?);
    try testing.expectEqual(@as(usize, 2), ev.diagnostics.items.len);
    try testing.expectEqual(Severity.err, ev.diagnostics.items[0].severity);
    try testing.expectEqualStrings("compiler", ev.diagnostics.items[0].source);
    try testing.expectEqualStrings("undefined: foo", ev.diagnostics.items[0].message);
    try testing.expectEqual(@as(u32, 3), ev.diagnostics.items[0].range.start.line);
    try testing.expectEqual(@as(u32, 8), ev.diagnostics.items[0].range.start.col);
    try testing.expectEqual(Severity.warn, ev.diagnostics.items[1].severity);
    // Absent source is "", not a missing diagnostic.
    try testing.expectEqualStrings("", ev.diagnostics.items[1].source);
}

test "diagnostics for a file outside our world are dropped, not crashed on" {
    const gpa = testing.allocator;
    var sess = Session.init(gpa, "/tmp/work", "").?;
    defer sess.deinit();
    try readySession(&sess, false);
    var ready = sess.nextEvent().?;
    ready.deinit(gpa);

    const note =
        "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\"params\":{" ++
        "\"uri\":\"untitled:Untitled-1\",\"diagnostics\":[]}}";
    const f = try framed(gpa, note);
    defer gpa.free(f);
    sess.feed(f);
    try testing.expect(sess.nextEvent() == null);
}

test "hover: markup, the legacy shapes, and a null that still releases" {
    const gpa = testing.allocator;
    var sess = Session.init(gpa, "/tmp/work", "").?;
    defer sess.deinit();
    try readySession(&sess, false);
    var ready = sess.nextEvent().?;
    ready.deinit(gpa);
    sess.didOpen("/tmp/work/a.go", "package main\n");

    const id = sess.hover("/tmp/work/a.go", .{ .line = 0, .col = 3 }).?;
    const r1 = try std.fmt.allocPrint(gpa,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"contents\":{{\"kind\":\"markdown\",\"value\":\"func main()\"}}," ++
        "\"range\":{{\"start\":{{\"line\":0,\"character\":5}},\"end\":{{\"line\":0,\"character\":9}}}}}}}}", .{id});
    defer gpa.free(r1);
    const f1 = try framed(gpa, r1);
    defer gpa.free(f1);
    sess.feed(f1);

    var ev = sess.nextEvent().?;
    defer ev.deinit(gpa);
    try testing.expect(ev == .hover);
    try testing.expectEqual(id, ev.hover.id);
    try testing.expectEqualStrings("func main()", ev.hover.text);
    try testing.expectEqual(@as(u32, 5), ev.hover.range.?.start.col);

    // An older server answering with MarkedString[].
    const id2 = sess.hover("/tmp/work/a.go", .{ .line = 1, .col = 0 }).?;
    const r2 = try std.fmt.allocPrint(gpa,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"contents\":[{{\"language\":\"go\",\"value\":\"var x int\"}},\"docs\"]}}}}", .{id2});
    defer gpa.free(r2);
    const f2 = try framed(gpa, r2);
    defer gpa.free(f2);
    sess.feed(f2);
    var ev2 = sess.nextEvent().?;
    defer ev2.deinit(gpa);
    try testing.expectEqualStrings("var x int\n\ndocs", ev2.hover.text);

    // Nothing to say still has to answer: the caller is holding a
    // spinner keyed to this id.
    const id3 = sess.hover("/tmp/work/a.go", .{ .line = 2, .col = 0 }).?;
    const r3 = try std.fmt.allocPrint(gpa, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":null}}", .{id3});
    defer gpa.free(r3);
    const f3 = try framed(gpa, r3);
    defer gpa.free(f3);
    sess.feed(f3);
    var ev3 = sess.nextEvent().?;
    defer ev3.deinit(gpa);
    try testing.expect(ev3 == .empty);
    try testing.expectEqual(id3, ev3.empty.id);
}

test "definition reads Location, Location[] and gopls's LocationLink[]" {
    const gpa = testing.allocator;
    var sess = Session.init(gpa, "/tmp/work", "").?;
    defer sess.deinit();
    try readySession(&sess, false);
    var ready = sess.nextEvent().?;
    ready.deinit(gpa);
    sess.didOpen("/tmp/work/a.go", "package main\n");

    const id1 = sess.definition("/tmp/work/a.go", .{}).?;
    const r1 = try std.fmt.allocPrint(gpa,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"uri\":\"file:///tmp/work/b.go\"," ++
        "\"range\":{{\"start\":{{\"line\":2,\"character\":5}},\"end\":{{\"line\":2,\"character\":9}}}}}}}}", .{id1});
    defer gpa.free(r1);
    const f1 = try framed(gpa, r1);
    defer gpa.free(f1);
    sess.feed(f1);
    var e1 = sess.nextEvent().?;
    defer e1.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), e1.definition.locs.len);
    try testing.expectEqualStrings("/tmp/work/b.go", e1.definition.locs[0].path);
    try testing.expectEqual(@as(u32, 2), e1.definition.locs[0].range.start.line);

    // linkSupport is on, so this is what gopls actually sends. Reading
    // only the Location shape would make "go to definition" silently do
    // nothing.
    const id2 = sess.definition("/tmp/work/a.go", .{}).?;
    const r2 = try std.fmt.allocPrint(gpa,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":[{{\"targetUri\":\"file:///tmp/work/c.go\"," ++
        "\"targetRange\":{{\"start\":{{\"line\":10,\"character\":0}},\"end\":{{\"line\":14,\"character\":1}}}}," ++
        "\"targetSelectionRange\":{{\"start\":{{\"line\":10,\"character\":5}},\"end\":{{\"line\":10,\"character\":8}}}}}}]}}", .{id2});
    defer gpa.free(r2);
    const f2 = try framed(gpa, r2);
    defer gpa.free(f2);
    sess.feed(f2);
    var e2 = sess.nextEvent().?;
    defer e2.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), e2.definition.locs.len);
    try testing.expectEqualStrings("/tmp/work/c.go", e2.definition.locs[0].path);
    // The identifier, not the whole declaration.
    try testing.expectEqual(@as(u32, 5), e2.definition.locs[0].range.start.col);

    // An empty array is "no definition here", and it must release.
    const id3 = sess.definition("/tmp/work/a.go", .{}).?;
    const r3 = try std.fmt.allocPrint(gpa, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":[]}}", .{id3});
    defer gpa.free(r3);
    const f3 = try framed(gpa, r3);
    defer gpa.free(f3);
    sess.feed(f3);
    var e3 = sess.nextEvent().?;
    defer e3.deinit(gpa);
    try testing.expect(e3 == .empty);
}

test "references asks with a context and answers as its own tag" {
    const gpa = testing.allocator;
    var sess = Session.init(gpa, "/tmp/work", "").?;
    defer sess.deinit();
    try readySession(&sess, false);
    var ready = sess.nextEvent().?;
    ready.deinit(gpa);
    sess.didOpen("/tmp/work/a.go", "package main\n");
    sess.consumeOutbound(sess.outbound().len);

    const id1 = sess.references("/tmp/work/a.go", .{ .line = 3, .col = 7 }, true).?;
    // The CONTEXT is the whole difference between this request and
    // definition's, and a server given params without one answers an
    // error — so the bytes are asserted, not just the reply handling.
    const sent = sess.outbound();
    try testing.expect(std.mem.indexOf(u8, sent, "\"method\":\"textDocument/references\"") != null);
    try testing.expect(std.mem.indexOf(u8, sent, "\"context\":{\"includeDeclaration\":true}") != null);
    try testing.expect(std.mem.indexOf(u8, sent, "\"line\":3,\"character\":7") != null);

    const r1 = try std.fmt.allocPrint(gpa,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":[" ++
        "{{\"uri\":\"file:///tmp/work/a.go\",\"range\":{{\"start\":{{\"line\":3,\"character\":7}}," ++
        "\"end\":{{\"line\":3,\"character\":10}}}}}}," ++
        "{{\"uri\":\"file:///tmp/work/b.go\",\"range\":{{\"start\":{{\"line\":9,\"character\":2}}," ++
        "\"end\":{{\"line\":9,\"character\":5}}}}}}]}}", .{id1});
    defer gpa.free(r1);
    const f1 = try framed(gpa, r1);
    defer gpa.free(f1);
    sess.feed(f1);
    var e1 = sess.nextEvent().?;
    defer e1.deinit(gpa);
    // A `.definition` here would make the wiring JUMP to the first use
    // instead of listing them, which is the failure this tag prevents.
    try testing.expect(e1 == .references);
    try testing.expectEqual(@as(usize, 2), e1.references.locs.len);
    try testing.expectEqualStrings("/tmp/work/b.go", e1.references.locs[1].path);
    try testing.expectEqual(@as(u32, 9), e1.references.locs[1].range.start.line);

    // A symbol nobody uses answers null, and the caller still has to be
    // released or the panel says "asking…" forever.
    const id2 = sess.references("/tmp/work/a.go", .{}, false).?;
    try testing.expect(std.mem.indexOf(u8, sess.outbound(), "\"includeDeclaration\":false") != null);
    const r2 = try std.fmt.allocPrint(gpa, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":null}}", .{id2});
    defer gpa.free(r2);
    const f2 = try framed(gpa, r2);
    defer gpa.free(f2);
    sess.feed(f2);
    var e2 = sess.nextEvent().?;
    defer e2.deinit(gpa);
    try testing.expect(e2 == .empty);
}

test "a reply longer than the cap is truncated, not allocated whole" {
    const gpa = testing.allocator;
    var sess = Session.init(gpa, "/tmp/work", "").?;
    defer sess.deinit();
    try readySession(&sess, false);
    var ready = sess.nextEvent().?;
    ready.deinit(gpa);
    sess.didOpen("/tmp/work/a.go", "package main\n");

    const id = sess.references("/tmp/work/a.go", .{}, true).?;
    var body: std.Io.Writer.Allocating = .init(gpa);
    defer body.deinit();
    const w = &body.writer;
    try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":[", .{id});
    var i: usize = 0;
    while (i < max_locations + 100) : (i += 1) {
        if (i > 0) try w.writeByte(',');
        try w.print(
            "{{\"uri\":\"file:///tmp/work/b.go\",\"range\":{{\"start\":{{\"line\":{d},\"character\":0}}," ++
            "\"end\":{{\"line\":{d},\"character\":1}}}}}}", .{ i, i });
    }
    try w.writeAll("]}");
    const f = try framed(gpa, body.written());
    defer gpa.free(f);
    sess.feed(f);
    var e = sess.nextEvent().?;
    defer e.deinit(gpa);
    try testing.expectEqual(@as(usize, max_locations), e.references.locs.len);
}

test "an error reply releases the caller instead of stranding it" {
    const gpa = testing.allocator;
    var sess = Session.init(gpa, "/tmp/work", "").?;
    defer sess.deinit();
    try readySession(&sess, false);
    var ready = sess.nextEvent().?;
    ready.deinit(gpa);
    sess.didOpen("/tmp/work/a.go", "package main\n");

    const id = sess.hover("/tmp/work/a.go", .{}).?;
    const r = try std.fmt.allocPrint(gpa,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"error\":{{\"code\":-32602,\"message\":\"no position\"}}}}", .{id});
    defer gpa.free(r);
    const f = try framed(gpa, r);
    defer gpa.free(f);
    sess.feed(f);

    var ev = sess.nextEvent().?;
    defer ev.deinit(gpa);
    try testing.expect(ev == .empty);
    try testing.expectEqual(id, ev.empty.id);
    // Still usable: one bad position is not a dead server.
    try testing.expectEqual(State.ready, sess.state);
}

test "server→client requests are answered — including the ones we refuse" {
    const gpa = testing.allocator;
    var sess = Session.init(gpa, "/tmp/work",
        "{\"gopls\":{\"usePlaceholders\":true},\"other\":1}").?;
    defer sess.deinit();
    try readySession(&sess, false);
    sess.consumeOutbound(sess.outbound().len);

    const req = "{\"jsonrpc\":\"2.0\",\"id\":41,\"method\":\"workspace/configuration\"," ++
        "\"params\":{\"items\":[{\"section\":\"gopls\"},{\"section\":\"nope\"}]}}";
    const f = try framed(gpa, req);
    defer gpa.free(f);
    sess.feed(f);
    const out = sess.outbound();
    try testing.expect(std.mem.indexOf(u8, out, "\"id\":41") != null);
    try testing.expect(std.mem.indexOf(u8, out, "usePlaceholders") != null);
    // A section we don't carry is null — servers read that as
    // "defaults", where an error would read as a broken client.
    try testing.expect(std.mem.indexOf(u8, out, "null") != null);
    sess.consumeOutbound(out.len);

    // Registration is acknowledged...
    const reg = "{\"jsonrpc\":\"2.0\",\"id\":42,\"method\":\"client/registerCapability\",\"params\":{}}";
    const f2 = try framed(gpa, reg);
    defer gpa.free(f2);
    sess.feed(f2);
    try testing.expect(std.mem.indexOf(u8, sess.outbound(), "\"id\":42,\"result\":null") != null);
    sess.consumeOutbound(sess.outbound().len);

    // ...and something we don't implement gets an ERROR rather than
    // silence: a server blocked on an unanswered request stops
    // answering ours, which presents as the whole session hanging.
    const unknown = "{\"jsonrpc\":\"2.0\",\"id\":43,\"method\":\"window/showDocument\",\"params\":{}}";
    const f3 = try framed(gpa, unknown);
    defer gpa.free(f3);
    sess.feed(f3);
    const out3 = sess.outbound();
    try testing.expect(std.mem.indexOf(u8, out3, "\"id\":43") != null);
    try testing.expect(std.mem.indexOf(u8, out3, "-32601") != null);
}

test "workspace/configuration answers a DOTTED section, not just a key" {
    const gpa = testing.allocator;
    var sess = Session.init(gpa, "/tmp/work",
        "{\"python\":{\"pythonPath\":\"/tmp/work/.venv/bin/python\",\"analysis\":{\"typeCheckingMode\":\"basic\"}}}").?;
    defer sess.deinit();
    try readySession(&sess, false);
    sess.consumeOutbound(sess.outbound().len);

    // pyright asks for exactly these two. Answering null to the second
    // because there is no top-level "python.analysis" KEY would read as
    // "the client has no opinion" and quietly drop the setting.
    const req = "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"workspace/configuration\"," ++
        "\"params\":{\"items\":[{\"section\":\"python\"},{\"section\":\"python.analysis\"}," ++
        "{\"section\":\"python.nope\"}]}}";
    const f = try framed(gpa, req);
    defer gpa.free(f);
    sess.feed(f);
    const out = sess.outbound();
    try testing.expect(std.mem.indexOf(u8, out, "typeCheckingMode") != null);
    try testing.expect(std.mem.indexOf(u8, out, "/tmp/work/.venv/bin/python") != null);
    // A path that goes nowhere is null, not an error.
    try testing.expect(std.mem.indexOf(u8, out, "null") != null);
}

test "a dying server releases everyone waiting on it" {
    const gpa = testing.allocator;
    var sess = Session.init(gpa, "/tmp/work", "").?;
    defer sess.deinit();
    try readySession(&sess, false);
    var ready = sess.nextEvent().?;
    ready.deinit(gpa);
    sess.didOpen("/tmp/work/a.go", "package main\n");

    const a = sess.hover("/tmp/work/a.go", .{}).?;
    const b = sess.definition("/tmp/work/a.go", .{}).?;
    sess.serverGone("the language server exited");

    var seen_a = false;
    var seen_b = false;
    var failed = false;
    while (sess.nextEvent()) |e| {
        var ev = e;
        defer ev.deinit(gpa);
        switch (ev) {
            .empty => |x| {
                if (x.id == a) seen_a = true;
                if (x.id == b) seen_b = true;
            },
            .failed => failed = true,
            else => {},
        }
    }
    try testing.expect(seen_a);
    try testing.expect(seen_b);
    try testing.expect(failed);
    try testing.expectEqual(State.failed, sess.state);
}

test "garbage on the wire: one bad message is survivable, bad framing is not" {
    const gpa = testing.allocator;
    var sess = Session.init(gpa, "/tmp/work", "").?;
    defer sess.deinit();
    try readySession(&sess, false);
    var ready = sess.nextEvent().?;
    ready.deinit(gpa);

    // Well-framed nonsense: skipped, session lives.
    const bad = try framed(gpa, "{not json");
    defer gpa.free(bad);
    sess.feed(bad);
    try testing.expectEqual(State.ready, sess.state);

    // A reply to an id we never sent: ignored rather than dispatched.
    const stray = try framed(gpa, "{\"jsonrpc\":\"2.0\",\"id\":9999,\"result\":{}}");
    defer gpa.free(stray);
    sess.feed(stray);
    try testing.expect(sess.nextEvent() == null);
    try testing.expectEqual(State.ready, sess.state);

    // Framing that cannot be resynchronized ends it.
    sess.feed("Content-Length: nope\r\n\r\n{}");
    try testing.expectEqual(State.failed, sess.state);
}

test "a frame split across reads is reassembled" {
    const gpa = testing.allocator;
    var sess = Session.init(gpa, "/tmp/work", "").?;
    defer sess.deinit();
    sess.start();

    const reply = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"capabilities\":{}}}";
    const f = try framed(gpa, reply);
    defer gpa.free(f);
    // One byte at a time — the worst case a pipe can hand us.
    for (f) |c| sess.feed(&[_]u8{c});
    try testing.expectEqual(State.ready, sess.state);
}

test "two messages arriving in one read are both dispatched" {
    const gpa = testing.allocator;
    var sess = Session.init(gpa, "/tmp/work", "").?;
    defer sess.deinit();
    sess.start();

    const init_reply = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"capabilities\":{}}}";
    const diag = "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\"params\":" ++
        "{\"uri\":\"file:///tmp/work/a.go\",\"diagnostics\":[]}}";
    const f1 = try framed(gpa, init_reply);
    defer gpa.free(f1);
    const f2 = try framed(gpa, diag);
    defer gpa.free(f2);
    const both = try std.mem.concat(gpa, u8, &.{ f1, f2 });
    defer gpa.free(both);
    sess.feed(both);

    var saw_ready = false;
    var saw_diag = false;
    while (sess.nextEvent()) |e| {
        var ev = e;
        defer ev.deinit(gpa);
        if (ev == .ready) saw_ready = true;
        if (ev == .diagnostics) saw_diag = true;
    }
    try testing.expect(saw_ready);
    try testing.expect(saw_diag);
}

test "Server: a real process, a real handshake, real diagnostics" {
    const gpa = testing.allocator;
    // A server made of /bin/sh. It answers the one request whose id is
    // deterministic (initialize is always 1 from a fresh session), then
    // publishes a diagnostic, then holds stdin open so it stays alive.
    // Enough to prove the fork, the pipes, the pump and the teardown —
    // the protocol itself is proven above without any of them.
    const script =
        \\I='{"jsonrpc":"2.0","id":1,"result":{"capabilities":{"semanticTokensProvider":{"legend":{"tokenTypes":["type"],"tokenModifiers":[]}}}}}'
        \\D='{"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///tmp/rooklsp/a.go","diagnostics":[{"range":{"start":{"line":1,"character":2},"end":{"line":1,"character":3}},"severity":2,"message":"from a real pipe"}]}}'
        \\printf 'Content-Length: %s\r\n\r\n%s' "${#I}" "$I"
        \\printf 'Content-Length: %s\r\n\r\n%s' "${#D}" "$D"
        \\cat > /dev/null
    ;
    const argv = [_][]const u8{ "/bin/sh", "-c", script };
    const srv = Server.start(gpa, &argv, "/tmp", "") orelse {
        return error.SkipZigTest; // no /bin/sh: not a failure of ours
    };
    defer srv.deinit();

    var saw_ready = false;
    var saw_diag = false;
    // The pump is a thread and the server is a fork+exec of /bin/sh, so
    // this waits on a real process coming up — a spin of yield() is
    // microseconds and would time out before sh had exec'd.
    var spins: usize = 0;
    while (spins < 1000 and !(saw_ready and saw_diag)) : (spins += 1) {
        while (srv.nextEvent()) |e| {
            var ev = e;
            defer ev.deinit(gpa);
            switch (ev) {
                .ready => saw_ready = true,
                .diagnostics => |d| {
                    try testing.expectEqualStrings("/tmp/rooklsp/a.go", d.path);
                    try testing.expectEqual(@as(usize, 1), d.items.len);
                    try testing.expectEqualStrings("from a real pipe", d.items[0].message);
                    try testing.expectEqual(Severity.warn, d.items[0].severity);
                    saw_diag = true;
                },
                else => {},
            }
        }
        _ = usleep(2000);
    }
    try testing.expect(saw_ready);
    try testing.expect(saw_diag);
    try testing.expectEqual(State.ready, srv.state());
}

test "Server: a command that does not exist fails open" {
    const gpa = testing.allocator;
    const argv = [_][]const u8{"/nonexistent/rook-not-a-server"};
    const srv = Server.start(gpa, &argv, "/tmp", "") orelse return;
    defer srv.deinit();

    // fork+execvp cannot report the failure synchronously — the child is
    // already gone by then — so it arrives as the pipe closing. What
    // matters is that it arrives at all, and as an event rather than a
    // hang.
    var spins: usize = 0;
    var failed = false;
    while (spins < 1000 and !failed) : (spins += 1) {
        while (srv.nextEvent()) |e| {
            var ev = e;
            defer ev.deinit(gpa);
            if (ev == .failed) failed = true;
        }
        _ = usleep(2000);
    }
    try testing.expect(failed);
}
