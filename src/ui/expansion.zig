//! List-view folder expansion: which folders of a tab are open in place (a set of paths that
//! survives refreshes and is dropped when the tab goes somewhere else), the listing of each open
//! folder, and the rows the list shows, flattened: a folder's row, then its children one level
//! deeper. The flattened `items` borrow their strings from the listings, so a listing that goes
//! away is retired and freed at the next rebuild, never while the frame that drew it may still be
//! in use. Pure data, no UI.
const std = @import("std");
const Allocator = std.mem.Allocator;
const lister = @import("../core/lister.zig");
const FileItem = lister.FileItem;
const Listing = @import("listing.zig").Listing;

/// A deeper tree than this is not walked (the set is user-driven, this only bounds a runaway).
pub const max_depth: u16 = 24;

pub const Options = struct {
    show_hidden: bool = false,
    sort: lister.SortOrder = .{},
};

const Kids = std.StringHashMapUnmanaged(Listing);

pub const Expansion = struct {
    /// Expanded folders (owned paths).
    set: std.StringHashMapUnmanaged(void) = .empty,
    /// The listing of each expanded folder that is shown (owned keys).
    kids: Kids = .empty,
    /// The rows as shown; `depth[i]` is row i's indent level.
    items: []FileItem = &.{},
    depth: []u16 = &.{},
    /// Listings dropped by the last rebuild, freed by the next one.
    retired: std.ArrayList(Listing) = .empty,

    pub fn deinit(self: *Expansion, gpa: Allocator) void {
        self.clearSet(gpa);
        self.set.deinit(gpa);
        self.dropKids(gpa, &self.kids);
        self.kids.deinit(gpa);
        self.freeRetired(gpa);
        self.retired.deinit(gpa);
        gpa.free(self.items);
        gpa.free(self.depth);
        self.* = undefined;
    }

    pub fn isExpanded(self: *const Expansion, path: []const u8) bool {
        return self.set.contains(path);
    }

    /// Marks `path` open (call `rebuild` after).
    pub fn expand(self: *Expansion, gpa: Allocator, path: []const u8) Allocator.Error!void {
        if (self.set.contains(path)) return;
        const copy = try gpa.dupe(u8, path);
        errdefer gpa.free(copy);
        try self.set.put(gpa, copy, {});
    }

    /// Marks `path` and everything open below it closed (call `rebuild` after).
    pub fn collapse(self: *Expansion, gpa: Allocator, path: []const u8) Allocator.Error!void {
        var gone: std.ArrayList([]const u8) = .empty;
        defer gone.deinit(gpa);
        var it = self.set.keyIterator();
        while (it.next()) |k| if (isSameOrInside(k.*, path)) try gone.append(gpa, k.*);
        for (gone.items) |k| if (self.set.fetchRemove(k)) |kv| gpa.free(kv.key);
    }

    /// Forgets every open folder (the tab went elsewhere); `rebuild` after.
    pub fn clearSet(self: *Expansion, gpa: Allocator) void {
        var it = self.set.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
        self.set.clearRetainingCapacity();
    }

    /// The row of `path`, if it is shown.
    pub fn indexOf(self: *const Expansion, path: []const u8) ?usize {
        for (self.items, 0..) |it, i| if (std.mem.eql(u8, it.path, path)) return i;
        return null;
    }

    fn freeRetired(self: *Expansion, gpa: Allocator) void {
        for (self.retired.items) |*l| l.deinit(gpa);
        self.retired.clearRetainingCapacity();
    }

    fn dropKids(self: *Expansion, gpa: Allocator, kids: *Kids) void {
        _ = self;
        var it = kids.iterator();
        while (it.next()) |e| {
            gpa.free(e.key_ptr.*);
            e.value_ptr.deinit(gpa);
        }
        kids.clearRetainingCapacity();
    }

    /// Recomputes the rows from `top` (the tab's own visible items). `reread` reads every open
    /// folder from disk again; otherwise their listings are only re-filtered and re-sorted. On
    /// failure the rows are emptied, so nothing is left pointing at a listing that goes away.
    pub fn rebuild(self: *Expansion, gpa: Allocator, top: []const FileItem, o: Options, reread: bool) Allocator.Error!void {
        self.freeRetired(gpa);
        var old = self.kids;
        self.kids = .empty;
        var w: Walk = .{ .self = self, .gpa = gpa, .o = o, .reread = reread, .old = &old };
        errdefer {
            w.items.deinit(gpa);
            w.depth.deinit(gpa);
            self.moveAllToRetired(gpa, &self.kids);
            self.moveAllToRetired(gpa, &old);
            old.deinit(gpa);
            gpa.free(self.items);
            gpa.free(self.depth);
            self.items = &.{};
            self.depth = &.{};
        }
        try w.walk(top, 0);
        const items = try w.items.toOwnedSlice(gpa);
        errdefer gpa.free(items);
        const depth = try w.depth.toOwnedSlice(gpa);
        gpa.free(self.items);
        gpa.free(self.depth);
        self.items = items;
        self.depth = depth;
        self.moveAllToRetired(gpa, &old);
        old.deinit(gpa);
    }

    fn moveAllToRetired(self: *Expansion, gpa: Allocator, kids: *Kids) void {
        var it = kids.iterator();
        while (it.next()) |e| {
            gpa.free(e.key_ptr.*);
            self.retired.append(gpa, e.value_ptr.*) catch e.value_ptr.deinit(gpa);
        }
        kids.clearRetainingCapacity();
    }
};

const Walk = struct {
    self: *Expansion,
    gpa: Allocator,
    o: Options,
    reread: bool,
    /// The previous listings, from which the ones still needed are taken.
    old: *Kids,
    items: std.ArrayList(FileItem) = .empty,
    depth: std.ArrayList(u16) = .empty,

    fn walk(w: *Walk, list: []const FileItem, level: u16) Allocator.Error!void {
        for (list) |it| {
            try w.items.append(w.gpa, it);
            try w.depth.append(w.gpa, level);
            if (!it.is_directory or level >= max_depth or !w.self.set.contains(it.path)) continue;
            const kid = try w.kidOf(it.path);
            try w.walk(kid.visible, level + 1);
        }
    }

    /// The listing of the open folder `path`: the old one, re-filtered, or a fresh read.
    fn kidOf(w: *Walk, path: []const u8) Allocator.Error!*const Listing {
        const taken = if (w.reread) null else w.old.fetchRemove(path);
        var key: []u8 = undefined;
        var l: Listing = undefined;
        if (taken) |kv| {
            key = @constCast(kv.key);
            l = kv.value;
        } else {
            key = try w.gpa.dupe(u8, path);
            errdefer w.gpa.free(key);
            l = try Listing.read(w.gpa, path);
        }
        errdefer {
            w.gpa.free(key);
            l.deinit(w.gpa);
        }
        try l.rebuild(w.gpa, w.o.show_hidden, w.o.sort);
        try w.self.kids.put(w.gpa, key, l);
        return w.self.kids.getPtr(path).?;
    }
};

/// `path` is `folder` or inside it.
pub fn isSameOrInside(path: []const u8, folder: []const u8) bool {
    if (!std.mem.startsWith(u8, path, folder)) return false;
    return path.len == folder.len or path[folder.len] == '/' or std.mem.eql(u8, folder, "/");
}
