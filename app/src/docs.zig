//! The open-document table: which files are open, and who is holding
//! them.
//!
//! rook has always said a file is a DOCUMENT and a pane is a window
//! onto it (see editor.zig's buffer-list note). Until this existed it
//! was only a saying: every pane that opened a file loaded its own copy,
//! so one file in two panes was two ropes, two undo histories and two
//! dirty flags. Typing in one left the other showing stale text, and
//! `:w` from the second refused — correctly, since the file HAD changed
//! underneath it — which is a confusing way to be told you opened
//! something twice.
//!
//! Emacs is the model, and its split is the one worth naming: the
//! buffer holds the text, the undo history and the modified flag; the
//! window holds the point and the scroll. This table is the buffer
//! half. Sublime calls the same thing "New View into File", which is a
//! better name for what a user is doing.
//!
//! Deliberately not a cache. An entry lives exactly as long as some
//! view holds it: the last pane to close a file frees it, so nothing
//! here can hand back a document whose text is older than the disk.
//! Reopening re-reads, which is what you want after a `git checkout`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const bufferpkg = @import("buffer.zig");

/// A generous ceiling on files open AT ONCE across every pane and tab.
/// Past it, a view keeps its own private copy — degraded (that pane
/// stops sharing) rather than refused (the file will not open).
pub const max_docs = 512;

const Entry = struct {
    /// The path as the view asked for it, owned. Comparison is
    /// case-insensitive for the same reason lspmgr's is: macOS
    /// filesystems are, and two panes that asked with different case
    /// are looking at one file.
    key: []u8,
    doc: *bufferpkg.Buffer,
    refs: u32,
};

pub const Registry = struct {
    gpa: Allocator,
    entries: std.ArrayListUnmanaged(Entry) = .empty,

    pub fn init(gpa: Allocator) Registry {
        return .{ .gpa = gpa };
    }

    /// Frees nothing but its own table. A non-empty registry at
    /// shutdown means views still hold documents, and those views free
    /// them on their way out — tearing them down here would be freeing
    /// somebody else's pointer first.
    pub fn deinit(self: *Registry) void {
        for (self.entries.items) |e| self.gpa.free(e.key);
        self.entries.deinit(self.gpa);
        self.* = undefined;
    }

    fn find(self: *Registry, path: []const u8) ?*Entry {
        for (self.entries.items) |*e| {
            if (e.key.len == path.len and std.ascii.eqlIgnoreCase(e.key, path)) return e;
        }
        return null;
    }

    /// The document already open at `path`, with a reference taken for
    /// the caller — or null, and the caller loads it and publishes.
    pub fn acquire(self: *Registry, path: []const u8) ?*bufferpkg.Buffer {
        const e = self.find(path) orelse return null;
        e.refs += 1;
        return e.doc;
    }

    /// Offer a freshly loaded document. True means the registry owns it
    /// now (and the caller holds one reference); false means there was
    /// no room and the caller keeps owning it outright.
    ///
    /// A document with no path is never registered: a scratch buffer
    /// and a synthetic view have no identity to share by.
    pub fn publish(self: *Registry, doc: *bufferpkg.Buffer) bool {
        const path = doc.path orelse return false;
        // Already there: two views raced to load the same file. The
        // caller's copy is the loser and it keeps it — refusing here is
        // the honest answer, since handing back the OTHER document
        // would leave the caller's own pointer dangling.
        if (self.find(path) != null) return false;
        if (self.entries.items.len >= max_docs) return false;
        const key = self.gpa.dupe(u8, path) catch return false;
        self.entries.append(self.gpa, .{ .key = key, .doc = doc, .refs = 1 }) catch {
            self.gpa.free(key);
            return false;
        };
        return true;
    }

    /// Give up one reference. The last one out frees the document.
    pub fn release(self: *Registry, doc: *bufferpkg.Buffer) void {
        for (self.entries.items, 0..) |*e, i| {
            if (e.doc != doc) continue;
            e.refs -= 1;
            if (e.refs > 0) return;
            self.gpa.free(e.key);
            _ = self.entries.orderedRemove(i);
            doc.deinit(self.gpa);
            self.gpa.destroy(doc);
            return;
        }
        // Not ours: a view that owned its document privately. Freeing
        // it is still the right thing — the caller has given it up.
        doc.deinit(self.gpa);
        self.gpa.destroy(doc);
    }

    /// How many views hold `path`, for `ctl docs` and the e2e.
    pub fn refsFor(self: *Registry, path: []const u8) u32 {
        const e = self.find(path) orelse return 0;
        return e.refs;
    }

    pub fn count(self: *Registry) usize {
        return self.entries.items.len;
    }

    /// One line per open document: how many views hold it, whether it
    /// has unsaved changes, and its path.
    pub fn describe(self: *Registry, w: *std.Io.Writer) void {
        for (self.entries.items) |e| {
            w.print("doc views:{d} modified:{s} version:{d} {s}\n", .{
                e.refs,
                if (e.doc.isModified()) "yes" else "no",
                e.doc.version,
                e.key,
            }) catch return;
        }
    }
};

// ------------------------------------------------------------------ tests

const testing = std.testing;

fn fakeDoc(gpa: Allocator, path: []const u8) !*bufferpkg.Buffer {
    const doc = try gpa.create(bufferpkg.Buffer);
    doc.* = try bufferpkg.Buffer.initEmpty(gpa);
    doc.path = try gpa.dupe(u8, path);
    return doc;
}

test "one path, one document, counted by its holders" {
    var r = Registry.init(testing.allocator);
    defer r.deinit();

    // Nobody has it yet.
    try testing.expect(r.acquire("/tmp/a.txt") == null);

    const doc = try fakeDoc(testing.allocator, "/tmp/a.txt");
    try testing.expect(r.publish(doc));
    try testing.expectEqual(@as(u32, 1), r.refsFor("/tmp/a.txt"));

    // A second view gets the SAME pointer, not a copy — which is the
    // whole reason this exists.
    const again = r.acquire("/tmp/a.txt").?;
    try testing.expectEqual(doc, again);
    try testing.expectEqual(@as(u32, 2), r.refsFor("/tmp/a.txt"));

    // One view closing does not take the document with it.
    r.release(doc);
    try testing.expectEqual(@as(u32, 1), r.refsFor("/tmp/a.txt"));
    try testing.expectEqual(@as(usize, 1), r.count());

    // The last one does.
    r.release(doc);
    try testing.expectEqual(@as(u32, 0), r.refsFor("/tmp/a.txt"));
    try testing.expectEqual(@as(usize, 0), r.count());
}

test "case-insensitive, like the filesystem underneath it" {
    var r = Registry.init(testing.allocator);
    defer r.deinit();
    const doc = try fakeDoc(testing.allocator, "/tmp/Notes.md");
    try testing.expect(r.publish(doc));
    // Two panes that asked with different case are looking at one file,
    // and giving them two documents would be the bug this table exists
    // to remove.
    try testing.expectEqual(doc, r.acquire("/tmp/notes.md").?);
    r.release(doc);
    r.release(doc);
}

test "a document with no path is nobody's to share" {
    var r = Registry.init(testing.allocator);
    defer r.deinit();
    const doc = try testing.allocator.create(bufferpkg.Buffer);
    doc.* = try bufferpkg.Buffer.initEmpty(testing.allocator);
    // A scratch buffer and a synthetic view have no identity to share
    // by; publishing them by display name would make two unrelated
    // transcripts one document.
    try testing.expect(!r.publish(doc));
    try testing.expectEqual(@as(usize, 0), r.count());
    doc.deinit(testing.allocator);
    testing.allocator.destroy(doc);
}

test "a second load of the same path is refused, not swapped" {
    var r = Registry.init(testing.allocator);
    defer r.deinit();
    const first = try fakeDoc(testing.allocator, "/tmp/race.txt");
    try testing.expect(r.publish(first));

    // Two views raced to load one file. Accepting the second would
    // leave the first entry's holders pointing at a document the table
    // no longer knows about.
    const second = try fakeDoc(testing.allocator, "/tmp/race.txt");
    try testing.expect(!r.publish(second));
    try testing.expectEqual(@as(usize, 1), r.count());
    try testing.expectEqual(first, r.acquire("/tmp/race.txt").?);

    r.release(second); // not ours: freed outright
    r.release(first);
    r.release(first);
}

test "releasing a document the table never had still frees it" {
    // The private-ownership path: a view past max_docs, or one holding
    // a scratch buffer. It has given the document up either way.
    var r = Registry.init(testing.allocator);
    defer r.deinit();
    const doc = try fakeDoc(testing.allocator, "/tmp/private.txt");
    r.release(doc);
    try testing.expectEqual(@as(usize, 0), r.count());
}
