//! Back/forward history of one tab: a list of visited folders and the one shown now.
//! Pure data (owned strings), no UI. Visiting a new folder drops the forward entries.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const History = struct {
    gpa: Allocator,
    entries: std.ArrayList([]u8) = .empty,
    /// Index of the folder shown now (always valid once `init` succeeded).
    index: usize = 0,

    pub fn init(gpa: Allocator, start: []const u8) Allocator.Error!History {
        var h: History = .{ .gpa = gpa };
        errdefer h.deinit();
        try h.entries.append(gpa, try gpa.dupe(u8, start));
        return h;
    }

    pub fn deinit(self: *History) void {
        for (self.entries.items) |e| self.gpa.free(e);
        self.entries.deinit(self.gpa);
        self.* = undefined;
    }

    pub fn current(self: *const History) []const u8 {
        return self.entries.items[self.index];
    }

    pub fn canBack(self: *const History) bool {
        return self.index > 0;
    }

    pub fn canForward(self: *const History) bool {
        return self.index + 1 < self.entries.items.len;
    }

    /// Visits `path`: the forward entries go, and a repeat of the current folder is not recorded.
    pub fn push(self: *History, path: []const u8) Allocator.Error!void {
        if (std.mem.eql(u8, path, self.current())) return;
        const copy = try self.gpa.dupe(u8, path);
        errdefer self.gpa.free(copy);
        for (self.entries.items[self.index + 1 ..]) |e| self.gpa.free(e);
        self.entries.shrinkRetainingCapacity(self.index + 1);
        try self.entries.append(self.gpa, copy);
        self.index += 1;
    }

    /// Makes `path` the current entry in place, without recording a visit (column view drilling).
    pub fn replaceCurrent(self: *History, path: []const u8) Allocator.Error!void {
        if (std.mem.eql(u8, path, self.current())) return;
        const copy = try self.gpa.dupe(u8, path);
        self.gpa.free(self.entries.items[self.index]);
        self.entries.items[self.index] = copy;
    }

    /// The folder `back` would show, without moving.
    pub fn peekBack(self: *const History) ?[]const u8 {
        return if (self.canBack()) self.entries.items[self.index - 1] else null;
    }

    /// The folder `forward` would show, without moving.
    pub fn peekForward(self: *const History) ?[]const u8 {
        return if (self.canForward()) self.entries.items[self.index + 1] else null;
    }

    /// Steps back; the folder now current, or null at the start.
    pub fn back(self: *History) ?[]const u8 {
        if (!self.canBack()) return null;
        self.index -= 1;
        return self.current();
    }

    /// Steps forward; the folder now current, or null at the end.
    pub fn forward(self: *History) ?[]const u8 {
        if (!self.canForward()) return null;
        self.index += 1;
        return self.current();
    }
};

const testing = std.testing;

test "replaceCurrent swaps the entry in place without a visit" {
    var h = try History.init(testing.allocator, "/a");
    defer h.deinit();
    try h.push("/a/b");
    try h.replaceCurrent("/a/b/c");
    try testing.expectEqualStrings("/a/b/c", h.current());
    try testing.expectEqual(@as(usize, 2), h.entries.items.len);
    try testing.expectEqualStrings("/a", h.back().?);
    try testing.expect(h.canForward());
}

test "push, back, forward" {
    var h = try History.init(testing.allocator, "/a");
    defer h.deinit();
    try testing.expect(!h.canBack() and !h.canForward());
    try h.push("/a/b");
    try h.push("/a/b"); // repeat: ignored
    try h.push("/a/b/c");
    try testing.expectEqualStrings("/a/b/c", h.current());
    try testing.expectEqualStrings("/a/b", h.back().?);
    try testing.expectEqualStrings("/a", h.back().?);
    try testing.expect(h.back() == null);
    try testing.expect(h.canForward());
    try testing.expectEqualStrings("/a/b", h.forward().?);
}

test "a new visit drops the forward entries" {
    var h = try History.init(testing.allocator, "/a");
    defer h.deinit();
    try h.push("/b");
    try h.push("/c");
    _ = h.back();
    _ = h.back();
    try h.push("/d");
    try testing.expect(!h.canForward());
    try testing.expectEqualStrings("/d", h.current());
    try testing.expectEqualStrings("/a", h.back().?);
}
