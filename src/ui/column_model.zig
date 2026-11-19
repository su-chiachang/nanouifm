//! A tab's column view state: the stack of Miller columns (each one a folder's listing with its
//! own selection), which column the keyboard is in, the leftmost column's folder (`root`), the
//! columns' widths and the horizontal scroll. Like a tab's listing, columns that go away are
//! retired and freed at the next call to `freeRetired`, because the frame just built may still
//! point into their strings. Pure data, no UI; `column_ops.zig` changes it.
const std = @import("std");
const Allocator = std.mem.Allocator;
const lister = @import("../core/lister.zig");
const FileItem = lister.FileItem;
const Listing = @import("listing.zig").Listing;
const Selection = @import("selection.zig").Selection;

/// What listings are built with (the pane's order and the hidden-files setting).
pub const Options = @import("expansion.zig").Options;

pub const default_width: f32 = 230;
pub const min_width: f32 = 140;
pub const max_width: f32 = 800;
/// The trailing preview column of a selected file.
pub const preview_width: f32 = 260;

pub fn clampWidth(w: f32) f32 {
    return std.math.clamp(w, min_width, max_width);
}

pub const Column = struct {
    /// The folder listed (owned).
    path: []u8,
    listing: Listing,
    selection: Selection = .{},
    /// The row the keyboard just moved to: the view scrolls it into sight, once.
    reveal: ?usize = null,

    pub fn deinit(self: *Column, gpa: Allocator) void {
        self.selection.deinit(gpa);
        self.listing.deinit(gpa);
        gpa.free(self.path);
        self.* = undefined;
    }

    pub fn items(self: *const Column) []const FileItem {
        return self.listing.visible;
    }

    /// The row of the selected item when exactly one is selected.
    pub fn singleIndex(self: *const Column) ?usize {
        if (self.selection.count() != 1) return null;
        var it = self.selection.set.keyIterator();
        const k = it.next() orelse return null;
        return self.listing.indexOf(k.*);
    }

    pub fn single(self: *const Column) ?FileItem {
        const i = self.singleIndex() orelse return null;
        return self.listing.visible[i];
    }
};

pub const ColumnState = struct {
    columns: std.ArrayList(Column) = .empty,
    /// Columns taken off the stack, freed by the next `freeRetired`; so are replaced listings.
    retired: std.ArrayList(Column) = .empty,
    retired_listings: std.ArrayList(Listing) = .empty,
    /// The leftmost column's folder (owned), remembered while the tab drills; null: the folder
    /// above the tab's own.
    root: ?[]u8 = null,
    /// The column the keyboard is in (an index of `columns`).
    active: usize = 0,
    /// The horizontal scroll as the view last laid it out.
    scroll_x: f32 = 0,
    /// The view scrolls just far enough to show the last column (and the preview) next frame.
    reveal: bool = true,
    /// Each depth's width; depths past the end have the default.
    widths: std.ArrayList(f32) = .empty,
    /// The one column the toolbar's name filter applies to: the active one when the filter began
    /// (Swift's `filterIndex`); null while there is no filter.
    filter_col: ?usize = null,

    pub fn deinit(self: *ColumnState, gpa: Allocator) void {
        self.freeRetired(gpa);
        self.retired.deinit(gpa);
        self.retired_listings.deinit(gpa);
        for (self.columns.items) |*c| c.deinit(gpa);
        self.columns.deinit(gpa);
        if (self.root) |r| gpa.free(r);
        self.widths.deinit(gpa);
        self.* = undefined;
    }

    pub fn freeRetired(self: *ColumnState, gpa: Allocator) void {
        for (self.retired.items) |*c| c.deinit(gpa);
        self.retired.clearRetainingCapacity();
        for (self.retired_listings.items) |*l| l.deinit(gpa);
        self.retired_listings.clearRetainingCapacity();
    }

    /// The filter text column `i` is listed with: `o.filter` for the filtered column only.
    fn filterOf(self: *ColumnState, o: Options, i: usize) []const u8 {
        if (o.filter.len == 0) {
            self.filter_col = null;
            return "";
        }
        if (self.filter_col == null) self.filter_col = self.active;
        return if (self.filter_col.? == i) o.filter else "";
    }

    /// Hidden files, the order or the filter changed: every column's rows again, no disk read.
    pub fn refilter(self: *ColumnState, gpa: Allocator, o: Options) Allocator.Error!void {
        for (self.columns.items, 0..) |*c, i| {
            try c.listing.rebuild(gpa, o.show_hidden, o.sort, self.filterOf(o, i));
            try c.selection.prune(gpa, c.listing.visible);
        }
        self.validate(gpa);
    }

    /// Every column read from disk again, keeping what is still selected; a column whose folder
    /// is no longer the selected one of the column before it goes.
    pub fn reread(self: *ColumnState, gpa: Allocator, o: Options) Allocator.Error!void {
        for (self.columns.items, 0..) |*c, i| {
            var fresh = try Listing.readVia(gpa, c.path, o.pre);
            errdefer fresh.deinit(gpa);
            try fresh.rebuild(gpa, o.show_hidden, o.sort, self.filterOf(o, i));
            try self.retired_listings.append(gpa, c.listing);
            c.listing = fresh;
            try c.selection.prune(gpa, c.listing.visible);
        }
        self.validate(gpa);
    }

    /// Drops the columns after the first one that is not what the column before it selected.
    pub fn validate(self: *ColumnState, gpa: Allocator) void {
        const cols = self.columns.items;
        for (cols, 0..) |*c, i| {
            if (i + 1 >= cols.len) break;
            const sel = c.single();
            if (sel == null or !std.mem.eql(u8, sel.?.path, cols[i + 1].path)) return self.truncate(gpa, i + 1);
        }
    }

    /// Takes the last column off the stack (freed later).
    fn retireLast(self: *ColumnState, gpa: Allocator) void {
        var c = self.columns.pop().?;
        self.retired.append(gpa, c) catch c.deinit(gpa);
    }

    /// Keeps columns 0..`n`, retires the rest.
    pub fn truncate(self: *ColumnState, gpa: Allocator, n: usize) void {
        while (self.columns.items.len > n) self.retireLast(gpa);
        if (self.active >= n) self.active = n -| 1;
    }

    /// Back to nothing shown (the tab went elsewhere): the stack is built again from the tab's
    /// folder, with the default root and no scroll. Widths stay.
    pub fn reset(self: *ColumnState, gpa: Allocator) void {
        self.truncate(gpa, 0);
        if (self.root) |r| gpa.free(r);
        self.root = null;
        self.scroll_x = 0;
        self.reveal = true;
    }

    pub fn setRoot(self: *ColumnState, gpa: Allocator, path: []const u8) Allocator.Error!void {
        const copy = try gpa.dupe(u8, path);
        if (self.root) |r| gpa.free(r);
        self.root = copy;
    }

    pub fn last(self: *ColumnState) ?*Column {
        if (self.columns.items.len == 0) return null;
        return &self.columns.items[self.columns.items.len - 1];
    }

    pub fn activeColumn(self: *ColumnState) ?*Column {
        if (self.columns.items.len == 0) return null;
        return &self.columns.items[@min(self.active, self.columns.items.len - 1)];
    }

    pub fn width(self: *const ColumnState, depth: usize) f32 {
        return if (depth < self.widths.items.len) self.widths.items[depth] else default_width;
    }

    /// Sets column `depth`'s width, clamped to the limits; returns what it became.
    pub fn setWidth(self: *ColumnState, gpa: Allocator, depth: usize, w: f32) Allocator.Error!f32 {
        const v = clampWidth(w);
        while (self.widths.items.len <= depth) try self.widths.append(gpa, default_width);
        self.widths.items[depth] = v;
        return v;
    }

    /// The width the strip of columns (and a preview, if `with_preview`) needs.
    pub fn contentWidth(self: *const ColumnState, with_preview: bool) f32 {
        var x: f32 = 0;
        for (0..self.columns.items.len) |i| x += self.width(i);
        return if (with_preview) x + preview_width else x;
    }
};

const testing = std.testing;

test "widths default, clamp and are remembered per depth" {
    const gpa = testing.allocator;
    var s: ColumnState = .{};
    defer s.deinit(gpa);
    try testing.expectEqual(default_width, s.width(3));
    try testing.expectEqual(min_width, try s.setWidth(gpa, 2, 10));
    try testing.expectEqual(max_width, try s.setWidth(gpa, 0, 5000));
    try testing.expectEqual(@as(f32, 300), try s.setWidth(gpa, 1, 300));
    try testing.expectEqual(max_width, s.width(0));
    try testing.expectEqual(@as(f32, 300), s.width(1));
    try testing.expectEqual(min_width, s.width(2));
    try testing.expectEqual(default_width, s.width(5));
}
