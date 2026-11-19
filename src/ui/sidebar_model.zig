//! The sidebar's data: sections of rows built from the injected `Config` (Home; Favorites;
//! Pinned; Locations). No UI. `itemsOf` turns core state entries (the persisted favorites and
//! pinned folders) into config items.
const std = @import("std");
const Allocator = std.mem.Allocator;
const state_model = @import("../core/state_model.zig");

/// A folder offered in the sidebar. Strings are borrowed by `Config` and copied by `Sidebar`.
pub const Item = struct {
    path: []const u8,
    /// Shown instead of the folder's name.
    title: ?[]const u8 = null,
};

pub const SectionKind = enum { home, favorites, pinned, locations };

pub const Row = struct {
    path: []u8,
    title: []u8,
    /// An SF Symbol.
    icon: []const u8,
};

pub const Section = struct {
    kind: SectionKind,
    rows: std.ArrayList(Row) = .empty,

    /// The header ("" for the Home row's own section).
    pub fn title(self: *const Section) []const u8 {
        return switch (self.kind) {
            .home => "",
            .favorites => "Favorites",
            .pinned => "Pinned",
            .locations => "Locations",
        };
    }
};

/// The icon of a favorite: the well-known folders have their own, like Finder's sidebar.
pub fn iconFor(kind: SectionKind, path: []const u8) []const u8 {
    switch (kind) {
        .home => return "house",
        .locations => return "externaldrive",
        .favorites, .pinned => {},
    }
    const name = std.fs.path.basename(path);
    if (std.mem.eql(u8, name, "Desktop")) return "menubar.dock.rectangle";
    if (std.mem.eql(u8, name, "Documents")) return "doc";
    if (std.mem.eql(u8, name, "Downloads")) return "arrow.down.circle";
    if (std.mem.eql(u8, name, "Applications")) return "square.grid.2x2";
    return "folder";
}

pub const Sidebar = struct {
    gpa: Allocator,
    sections: [4]Section = .{ .{ .kind = .home }, .{ .kind = .favorites }, .{ .kind = .pinned }, .{ .kind = .locations } },

    pub fn init(gpa: Allocator, home: []const u8, favorites: []const Item, pinned: []const Item, locations: []const Item) Allocator.Error!Sidebar {
        var s: Sidebar = .{ .gpa = gpa };
        errdefer s.deinit();
        try s.addRow(.home, .{ .path = home, .title = "Home" });
        for (favorites) |it| try s.addRow(.favorites, it);
        for (pinned) |it| try s.addRow(.pinned, it);
        for (locations) |it| try s.addRow(.locations, it);
        return s;
    }

    pub fn deinit(self: *Sidebar) void {
        for (&self.sections) |*sec| {
            for (sec.rows.items) |r| {
                self.gpa.free(r.path);
                self.gpa.free(r.title);
            }
            sec.rows.deinit(self.gpa);
        }
        self.* = undefined;
    }

    fn addRow(self: *Sidebar, kind: SectionKind, it: Item) Allocator.Error!void {
        const sec = &self.sections[@backingInt(kind)];
        const path = try self.gpa.dupe(u8, it.path);
        errdefer self.gpa.free(path);
        const name = it.title orelse (if (std.fs.path.basename(it.path).len == 0) it.path else std.fs.path.basename(it.path));
        const title = try self.gpa.dupe(u8, name);
        errdefer self.gpa.free(title);
        try sec.rows.append(self.gpa, .{ .path = path, .title = title, .icon = iconFor(kind, it.path) });
    }

    /// Pin to Sidebar: a Pinned row for `path`, unless Favorites or Pinned already has one.
    pub fn pin(self: *Sidebar, path: []const u8) Allocator.Error!void {
        for ([_]SectionKind{ .favorites, .pinned }) |kind| {
            for (self.sections[@backingInt(kind)].rows.items) |r| if (std.mem.eql(u8, r.path, path)) return;
        }
        try self.addRow(.pinned, .{ .path = path });
    }

    /// The row to highlight for the folder shown: the first one that is that folder.
    pub fn highlighted(self: *const Sidebar, folder: []const u8) ?struct { section: usize, row: usize } {
        for (self.sections, 0..) |sec, si| {
            for (sec.rows.items, 0..) |r, ri| if (std.mem.eql(u8, r.path, folder)) return .{ .section = si, .row = ri };
        }
        return null;
    }
};

/// Config items for persisted sidebar entries. Free the slice (the strings stay `entries`').
pub fn itemsOf(gpa: Allocator, entries: []const state_model.SidebarEntry) Allocator.Error![]Item {
    const out = try gpa.alloc(Item, entries.len);
    for (entries, out) |e, *o| o.* = .{ .path = e.path, .title = e.title };
    return out;
}

const testing = std.testing;

test "rows from the core state's defaults" {
    const gpa = testing.allocator;
    var st = try state_model.PersistedState.defaults(gpa, testing.io, "/Users/tester");
    defer st.deinit(gpa);
    const fav = try itemsOf(gpa, st.favorites.items);
    defer gpa.free(fav);
    var sb = try Sidebar.init(gpa, "/Users/tester", fav, &.{}, &.{.{ .path = "/", .title = "Macintosh HD" }});
    defer sb.deinit();
    try testing.expectEqual(@as(usize, 1), sb.sections[0].rows.items.len);
    try testing.expectEqualStrings("Home", sb.sections[0].rows.items[0].title);
    const rows = sb.sections[1].rows.items;
    try testing.expectEqual(@as(usize, 4), rows.len);
    try testing.expectEqualStrings("Desktop", rows[0].title);
    try testing.expectEqualStrings("/Users/tester/Documents", rows[1].path);
    try testing.expectEqualStrings("Downloads", rows[2].title);
    try testing.expectEqualStrings("tester", rows[3].title); // the home folder, by its name
    try testing.expectEqual(@as(usize, 0), sb.sections[2].rows.items.len);
    try testing.expectEqualStrings("Macintosh HD", sb.sections[3].rows.items[0].title);
    const h = sb.highlighted("/Users/tester").?;
    try testing.expectEqual(@as(usize, 0), h.section); // the Home row comes first
}
