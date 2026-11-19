//! What an off-main read brings back: one `Entry` per folder asked for (its items, or the lister's
//! error), and `Preloaded`, the bundle a landing request hands to the ordinary synchronous code
//! (`Tab.visit`, `Expansion.rebuild`, the column operations) so that code finds its folders
//! already read instead of reading them on the main thread. Pure data; the strings are owned.
const std = @import("std");
const Allocator = std.mem.Allocator;
const lister = @import("../core/lister.zig");
const FileItem = lister.FileItem;

pub const Result = union(enum) {
    /// Everything the lister found, hidden items included (owned; `lister.freeItems`).
    items: []FileItem,
    err: lister.ListError,
};

pub const Entry = struct {
    /// The folder (owned).
    path: []u8,
    result: Result,
    /// Taken by a read already: the entry is spent (its items belong to the listing built from it).
    spent: bool = false,
};

/// The folders one request read, owned. `take` hands each entry out once, so a folder asked for
/// twice is listed twice (`Tab.reload` reads its own folder once for the rows and once for the
/// column that shows it, as the synchronous code always did).
pub const Preloaded = struct {
    entries: []Entry = &.{},
    /// Reads that found nothing here and went to the disk on the calling thread (a folder the
    /// request did not foresee). Tests assert it stays 0 for what the loader covers.
    misses: u32 = 0,

    pub fn take(self: *Preloaded, path: []const u8) ?Result {
        for (self.entries) |*e| {
            if (e.spent or !std.mem.eql(u8, e.path, path)) continue;
            e.spent = true;
            return e.result;
        }
        return null;
    }

    /// Frees the entries nobody took (and the list itself).
    pub fn deinit(self: *Preloaded, gpa: Allocator) void {
        freeEntries(gpa, self.entries);
        self.* = .{};
    }
};

/// Frees every entry that has not been taken, then the slice.
pub fn freeEntries(gpa: Allocator, entries: []Entry) void {
    for (entries) |e| {
        gpa.free(e.path);
        if (!e.spent and e.result == .items) lister.freeItems(gpa, e.result.items);
    }
    gpa.free(entries);
}

const testing = std.testing;

test "take hands an entry out once and deinit frees only what was not taken" {
    const gpa = testing.allocator;
    const entries = try gpa.alloc(Entry, 2);
    entries[0] = .{ .path = try gpa.dupe(u8, "/a"), .result = .{ .items = try gpa.alloc(FileItem, 0) } };
    entries[1] = .{ .path = try gpa.dupe(u8, "/b"), .result = .{ .err = error.FileNotFound } };
    var pre: Preloaded = .{ .entries = entries };
    defer pre.deinit(gpa);
    const got = pre.take("/a").?;
    gpa.free(got.items); // the caller owns what it took
    try testing.expect(pre.take("/a") == null);
    try testing.expect(pre.take("/b").?.err == error.FileNotFound);
    try testing.expect(pre.take("/c") == null);
}
