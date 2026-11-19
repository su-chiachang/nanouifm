//! The selected rows of a list, by path (so a selection survives a re-sort or a refresh), with
//! Finder's click rules: click selects one, cmd-click toggles, shift-click extends from the anchor.
//! Pure data, no UI.
const std = @import("std");
const Allocator = std.mem.Allocator;
const FileItem = @import("../core/file_item.zig").FileItem;

pub const Mods = struct {
    cmd: bool = false,
    shift: bool = false,
};

pub const Selection = struct {
    set: std.StringHashMapUnmanaged(void) = .empty,
    /// The row a shift-click extends from (owned path).
    anchor: ?[]u8 = null,
    /// The row the keyboard moves from: the one last clicked or arrowed to (owned path). Shift+arrow
    /// grows the range between the anchor and it.
    lead: ?[]u8 = null,

    pub fn deinit(self: *Selection, gpa: Allocator) void {
        self.clear(gpa);
        self.set.deinit(gpa);
        self.* = undefined;
    }

    pub fn count(self: *const Selection) usize {
        return self.set.count();
    }

    pub fn contains(self: *const Selection, path: []const u8) bool {
        return self.set.contains(path);
    }

    pub fn clear(self: *Selection, gpa: Allocator) void {
        var it = self.set.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
        self.set.clearRetainingCapacity();
        if (self.anchor) |a| gpa.free(a);
        self.anchor = null;
        if (self.lead) |l| gpa.free(l);
        self.lead = null;
    }

    fn add(self: *Selection, gpa: Allocator, path: []const u8) Allocator.Error!void {
        if (self.set.contains(path)) return;
        const copy = try gpa.dupe(u8, path);
        errdefer gpa.free(copy);
        try self.set.put(gpa, copy, {});
    }

    fn remove(self: *Selection, gpa: Allocator, path: []const u8) void {
        if (self.set.fetchRemove(path)) |kv| gpa.free(kv.key);
    }

    fn setAnchor(self: *Selection, gpa: Allocator, path: []const u8) Allocator.Error!void {
        const copy = try gpa.dupe(u8, path);
        if (self.anchor) |a| gpa.free(a);
        self.anchor = copy;
    }

    fn setLead(self: *Selection, gpa: Allocator, path: []const u8) Allocator.Error!void {
        const copy = try gpa.dupe(u8, path);
        if (self.lead) |l| gpa.free(l);
        self.lead = copy;
    }

    /// The row the keyboard moves from (the lead, else the anchor).
    pub fn leadIndex(self: *const Selection, items: []const FileItem) ?usize {
        if (self.lead) |l| for (items, 0..) |it, i| if (std.mem.eql(u8, it.path, l)) return i;
        return self.anchorIndex(items);
    }

    /// Selects just `path` (it need not be in a listing), as a plain click does.
    pub fn selectOnly(self: *Selection, gpa: Allocator, path: []const u8) Allocator.Error!void {
        self.clearSet(gpa);
        try self.add(gpa, path);
        try self.setAnchor(gpa, path);
        try self.setLead(gpa, path);
    }

    /// Becomes a copy of `other`.
    pub fn copyFrom(self: *Selection, gpa: Allocator, other: *const Selection) Allocator.Error!void {
        self.clear(gpa);
        var it = other.set.keyIterator();
        while (it.next()) |k| try self.add(gpa, k.*);
        if (other.anchor) |a| try self.setAnchor(gpa, a);
        if (other.lead) |l| try self.setLead(gpa, l);
    }

    /// The keyboard moved to row `index` (arrows, Home, End): `extend` (Shift) grows the range
    /// from the anchor, otherwise that row alone is selected.
    pub fn moveTo(self: *Selection, gpa: Allocator, items: []const FileItem, index: usize, extend: bool) Allocator.Error!void {
        try self.click(gpa, items, index, .{ .shift = extend });
    }

    fn anchorIndex(self: *const Selection, items: []const FileItem) ?usize {
        const a = self.anchor orelse return null;
        for (items, 0..) |it, i| if (std.mem.eql(u8, it.path, a)) return i;
        return null;
    }

    /// A click on row `index` of `items` (the rows as shown).
    pub fn click(self: *Selection, gpa: Allocator, items: []const FileItem, index: usize, mods: Mods) Allocator.Error!void {
        if (index >= items.len) return;
        const path = items[index].path;
        if (mods.shift) if (self.anchorIndex(items)) |from| {
            if (!mods.cmd) self.clearSet(gpa);
            const lo = @min(from, index);
            const hi = @max(from, index);
            for (items[lo .. hi + 1]) |it| try self.add(gpa, it.path);
            try self.setLead(gpa, path);
            return; // the anchor stays where it was
        };
        if (mods.cmd) {
            if (self.contains(path)) self.remove(gpa, path) else try self.add(gpa, path);
        } else {
            self.clearSet(gpa);
            try self.add(gpa, path);
        }
        try self.setAnchor(gpa, path);
        try self.setLead(gpa, path);
    }

    fn clearSet(self: *Selection, gpa: Allocator) void {
        var it = self.set.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
        self.set.clearRetainingCapacity();
    }

    /// Drops what is no longer in `items` (after a refresh or hiding hidden files).
    pub fn prune(self: *Selection, gpa: Allocator, items: []const FileItem) Allocator.Error!void {
        var present: std.StringHashMapUnmanaged(void) = .empty;
        defer present.deinit(gpa);
        for (items) |it| try present.put(gpa, it.path, {});
        var gone: std.ArrayList([]const u8) = .empty;
        defer gone.deinit(gpa);
        var keys = self.set.keyIterator();
        while (keys.next()) |k| if (!present.contains(k.*)) try gone.append(gpa, k.*);
        for (gone.items) |k| self.remove(gpa, k);
        if (self.anchor) |a| if (!present.contains(a)) {
            gpa.free(a);
            self.anchor = null;
        };
        if (self.lead) |l| if (!present.contains(l)) {
            gpa.free(l);
            self.lead = null;
        };
    }
};

const testing = std.testing;

fn fake(path: []const u8) FileItem {
    return .{ .path = path, .name = path, .is_directory = false, .is_package = false, .is_hidden = false, .is_symlink = false, .size = 1, .modified = null, .created = null, .kind = "Document" };
}

test "click, cmd-click and shift-click" {
    const gpa = testing.allocator;
    const items = [_]FileItem{ fake("/a"), fake("/b"), fake("/c"), fake("/d"), fake("/e") };
    var s: Selection = .{};
    defer s.deinit(gpa);
    try s.click(gpa, &items, 1, .{});
    try testing.expect(s.contains("/b") and s.count() == 1);
    try s.click(gpa, &items, 3, .{ .cmd = true });
    try testing.expect(s.contains("/b") and s.contains("/d") and s.count() == 2);
    try s.click(gpa, &items, 1, .{ .cmd = true }); // toggles off
    try testing.expect(!s.contains("/b") and s.count() == 1);
    // The anchor is /b's row (the last plain/cmd click): shift extends from it.
    try s.click(gpa, &items, 4, .{ .shift = true });
    try testing.expectEqual(@as(usize, 4), s.count()); // b..e
    try testing.expect(!s.contains("/a") and s.contains("/c") and s.contains("/e"));
    try s.click(gpa, &items, 0, .{});
    try testing.expect(s.count() == 1 and s.contains("/a"));
}

test "keyboard moves: plain selects one, shift extends from the anchor" {
    const gpa = testing.allocator;
    const items = [_]FileItem{ fake("/a"), fake("/b"), fake("/c"), fake("/d") };
    var s: Selection = .{};
    defer s.deinit(gpa);
    try s.moveTo(gpa, &items, 1, false);
    try s.moveTo(gpa, &items, 2, true);
    try s.moveTo(gpa, &items, 3, true);
    try testing.expectEqual(@as(usize, 3), s.count()); // b..d
    try testing.expectEqual(@as(?usize, 3), s.leadIndex(&items));
    try s.moveTo(gpa, &items, 2, true); // shrinks back toward the anchor
    try testing.expect(s.count() == 2 and !s.contains("/d"));
    try s.moveTo(gpa, &items, 0, false);
    try testing.expect(s.count() == 1 and s.contains("/a"));
    var copy: Selection = .{};
    defer copy.deinit(gpa);
    try copy.copyFrom(gpa, &s);
    try testing.expect(copy.contains("/a") and copy.leadIndex(&items) == 0);
}

test "prune drops vanished paths" {
    const gpa = testing.allocator;
    const items = [_]FileItem{ fake("/a"), fake("/b") };
    var s: Selection = .{};
    defer s.deinit(gpa);
    try s.click(gpa, &items, 0, .{});
    try s.click(gpa, &items, 1, .{ .cmd = true });
    try s.prune(gpa, items[1..]);
    try testing.expect(s.count() == 1 and s.contains("/b"));
    try testing.expect(s.anchor != null);
}
