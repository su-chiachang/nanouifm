//! The sidebar's data: sections of rows built from the injected `Config` (Home; Favorites;
//! Pinned; Locations). No UI. `itemsOf` turns core state entries (the persisted favorites and
//! pinned folders) into config items.
const std = @import("std");
const Allocator = std.mem.Allocator;
const state_model = @import("../core/state_model.zig");
const Uuid = state_model.Uuid;

/// A folder offered in the sidebar. Strings are borrowed by `Config` and copied by `Sidebar`.
pub const Item = struct {
    path: []const u8,
    /// Shown instead of the folder's name.
    title: ?[]const u8 = null,
    /// The persisted entry's id (favorites and pinned); null: the sidebar makes one.
    id: ?Uuid = null,
    /// A volume that can be ejected (Locations): its row has an eject button.
    ejectable: bool = false,
};

pub const SectionKind = enum { home, favorites, pinned, locations };

pub const Row = struct {
    path: []u8,
    title: []u8,
    /// An SF Symbol.
    icon: []const u8,
    /// Favorites and Pinned rows are persisted entries and carry their id (null: Home, volumes).
    id: ?Uuid = null,
    /// The title was given, not the folder's name (only those are persisted as titles).
    titled: bool = false,
    ejectable: bool = false,
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

/// Where a row is: its section and its index in it.
pub const RowRef = struct { section: usize, row: usize };

pub const Sidebar = struct {
    gpa: Allocator,
    sections: [4]Section = .{ .{ .kind = .home }, .{ .kind = .favorites }, .{ .kind = .pinned }, .{ .kind = .locations } },
    /// Moves whenever a favorite or pin is added or removed: the palette's file index follows the folders.
    revision: u32 = 0,
    /// Makes the ids of new entries (the real random ones); null: a counter (tests).
    io: ?std.Io = null,
    counter: u64 = 0,

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
            self.freeRows(sec);
            sec.rows.deinit(self.gpa);
        }
        self.* = undefined;
    }

    fn freeRows(self: *Sidebar, sec: *Section) void {
        for (sec.rows.items) |r| {
            self.gpa.free(r.path);
            self.gpa.free(r.title);
        }
        sec.rows.clearRetainingCapacity();
    }

    fn freshId(self: *Sidebar) Uuid {
        if (self.io) |io| return Uuid.random(io);
        self.counter += 1;
        var b: [16]u8 = @splat(0);
        std.mem.writeInt(u64, b[0..8], self.counter, .little);
        b[6] = 0x40;
        b[8] = 0x80;
        return .{ .bytes = b };
    }

    fn makeRow(self: *Sidebar, kind: SectionKind, it: Item) Allocator.Error!Row {
        const path = try self.gpa.dupe(u8, it.path);
        errdefer self.gpa.free(path);
        const name = it.title orelse (if (std.fs.path.basename(it.path).len == 0) it.path else std.fs.path.basename(it.path));
        const title = try self.gpa.dupe(u8, name);
        const persisted = kind == .favorites or kind == .pinned;
        return .{
            .path = path,
            .title = title,
            .icon = if (kind == .locations and !it.ejectable) "internaldrive" else iconFor(kind, it.path),
            .id = if (persisted) (it.id orelse self.freshId()) else null,
            .titled = persisted and it.title != null,
            .ejectable = it.ejectable,
        };
    }

    fn addRow(self: *Sidebar, kind: SectionKind, it: Item) Allocator.Error!void {
        try self.insertRow(kind, it, null);
    }

    fn insertRow(self: *Sidebar, kind: SectionKind, it: Item, at: ?usize) Allocator.Error!void {
        const sec = &self.sections[@backingInt(kind)];
        const row = try self.makeRow(kind, it);
        errdefer {
            self.gpa.free(row.path);
            self.gpa.free(row.title);
        }
        try sec.rows.insert(self.gpa, @min(at orelse sec.rows.items.len, sec.rows.items.len), row);
        self.revision +%= 1;
    }

    /// Pin to Sidebar: a Pinned row for `path`, unless Favorites or Pinned already has one.
    pub fn pin(self: *Sidebar, path: []const u8) Allocator.Error!void {
        for ([_]SectionKind{ .favorites, .pinned }) |kind| {
            for (self.sections[@backingInt(kind)].rows.items) |r| if (std.mem.eql(u8, r.path, path)) return;
        }
        try self.addRow(.pinned, .{ .path = path });
    }

    /// A favorite (or pin) for `path` at row `at` of its section (default: the end). One the
    /// section already has is left alone, or moved to `at` when that is given.
    pub fn addEntry(self: *Sidebar, kind: SectionKind, path: []const u8, at: ?usize) Allocator.Error!void {
        std.debug.assert(kind == .favorites or kind == .pinned);
        const sec = &self.sections[@backingInt(kind)];
        for (sec.rows.items) |r| if (std.mem.eql(u8, r.path, path)) {
            const id = r.id.?;
            if (at != null) try self.moveEntry(id, kind, at.?);
            return;
        };
        try self.insertRow(kind, .{ .path = path }, at);
    }

    pub fn find(self: *const Sidebar, id: Uuid) ?RowRef {
        for ([_]SectionKind{ .favorites, .pinned }) |kind| {
            const si = @backingInt(kind);
            for (self.sections[si].rows.items, 0..) |r, i| if (r.id != null and r.id.?.eql(id)) return .{ .section = si, .row = i };
        }
        return null;
    }

    /// Remove from Sidebar: false when no favorite or pin has this id.
    pub fn removeEntry(self: *Sidebar, id: Uuid) bool {
        const at = self.find(id) orelse return false;
        const r = self.sections[at.section].rows.orderedRemove(at.row);
        self.gpa.free(r.path);
        self.gpa.free(r.title);
        self.revision +%= 1;
        return true;
    }

    /// Drag to reorder: the entry goes to row `to` of `kind` (counted before it leaves its old
    /// place, as a drop position is), possibly from Favorites to Pinned or back.
    pub fn moveEntry(self: *Sidebar, id: Uuid, kind: SectionKind, to: usize) Allocator.Error!void {
        const at = self.find(id) orelse return;
        const dst = &self.sections[@backingInt(kind)].rows;
        const src = &self.sections[at.section].rows;
        var target = @min(to, dst.items.len);
        if (at.section == @backingInt(kind) and at.row < target) target -= 1;
        if (at.section == @backingInt(kind) and at.row == target) return;
        try dst.ensureUnusedCapacity(self.gpa, 1);
        const row = src.orderedRemove(at.row);
        dst.insertAssumeCapacity(@min(target, dst.items.len), row);
        if (at.section != @backingInt(kind)) self.revision +%= 1;
    }

    /// Replaces the favorites and pinned folders (a restored state); the ids stay.
    pub fn replaceEntries(self: *Sidebar, favorites: []const Item, pinned: []const Item) Allocator.Error!void {
        var fresh = try Sidebar.init(self.gpa, "/", favorites, pinned, &.{});
        defer fresh.deinit();
        fresh.io = self.io;
        for ([_]SectionKind{ .favorites, .pinned }) |kind| {
            const si = @backingInt(kind);
            std.mem.swap(std.ArrayList(Row), &self.sections[si].rows, &fresh.sections[si].rows);
        }
        self.revision +%= 1;
    }

    /// The Locations rows follow `volumes` (the mounted ones). False when they already did.
    pub fn setLocations(self: *Sidebar, volumes: []const Item) Allocator.Error!bool {
        const sec = &self.sections[@backingInt(SectionKind.locations)];
        if (sec.rows.items.len == volumes.len) {
            const same = for (sec.rows.items, volumes) |r, v| {
                const name = v.title orelse std.fs.path.basename(v.path);
                if (!std.mem.eql(u8, r.path, v.path) or !std.mem.eql(u8, r.title, name) or r.ejectable != v.ejectable) break false;
            } else true;
            if (same) return false;
        }
        var fresh: Section = .{ .kind = .locations };
        errdefer {
            self.freeRows(&fresh);
            fresh.rows.deinit(self.gpa);
        }
        try fresh.rows.ensureTotalCapacityPrecise(self.gpa, volumes.len);
        for (volumes) |v| fresh.rows.appendAssumeCapacity(try self.makeRow(.locations, v));
        self.freeRows(sec);
        sec.rows.deinit(self.gpa);
        sec.rows = fresh.rows;
        return true;
    }

    /// The row to highlight for the folder shown: the first one that is that folder.
    pub fn highlighted(self: *const Sidebar, folder: []const u8) ?RowRef {
        for (self.sections, 0..) |sec, si| {
            for (sec.rows.items, 0..) |r, ri| if (std.mem.eql(u8, r.path, folder)) return .{ .section = si, .row = ri };
        }
        return null;
    }

    /// The persisted entries of `kind` (favorites or pinned), for the state file. Free with
    /// `state_model.deinitEntries`.
    pub fn entries(self: *const Sidebar, kind: SectionKind) Allocator.Error!state_model.EntryList {
        var out: state_model.EntryList = .empty;
        errdefer state_model.deinitEntries(self.gpa, &out);
        for (self.sections[@backingInt(kind)].rows.items) |r| {
            const e = try state_model.SidebarEntry.initWithId(self.gpa, r.id.?, r.path, if (r.titled) r.title else null);
            errdefer {
                var ee = e;
                ee.deinit(self.gpa);
            }
            try out.append(self.gpa, e);
        }
        return out;
    }
};

/// Config items for persisted sidebar entries. Free the slice (the strings stay `entries`').
pub fn itemsOf(gpa: Allocator, entries_: []const state_model.SidebarEntry) Allocator.Error![]Item {
    const out = try gpa.alloc(Item, entries_.len);
    for (entries_, out) |e, *o| o.* = .{ .path = e.path, .title = e.title, .id = e.id };
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

fn titles(s: *const Sidebar, kind: SectionKind, out: *[8][]const u8) []const []const u8 {
    const rows = s.sections[@backingInt(kind)].rows.items;
    for (rows, 0..) |r, i| out[i] = r.title;
    return out[0..rows.len];
}

test "entries are added, moved between sections, reordered and removed, keeping their ids" {
    const gpa = testing.allocator;
    var s = try Sidebar.init(gpa, "/h", &.{ .{ .path = "/a" }, .{ .path = "/b" }, .{ .path = "/c" } }, &.{.{ .path = "/p" }}, &.{});
    defer s.deinit();
    var buf: [8][]const u8 = undefined;
    const id_c = s.sections[1].rows.items[2].id.?;
    try testing.expect(!s.sections[1].rows.items[0].id.?.eql(s.sections[1].rows.items[1].id.?)); // ids are made

    try s.moveEntry(id_c, .favorites, 0); // to the top
    try testing.expectEqualDeep(@as([]const []const u8, &.{ "c", "a", "b" }), titles(&s, .favorites, &buf));
    try s.moveEntry(id_c, .favorites, 3); // after the last (a drop position counts the old place too)
    try testing.expectEqualDeep(@as([]const []const u8, &.{ "a", "b", "c" }), titles(&s, .favorites, &buf));
    try s.moveEntry(id_c, .pinned, 0); // the other section
    try testing.expectEqualDeep(@as([]const []const u8, &.{ "a", "b" }), titles(&s, .favorites, &buf));
    try testing.expectEqualDeep(@as([]const []const u8, &.{ "c", "p" }), titles(&s, .pinned, &buf));
    try testing.expect(s.sections[2].rows.items[0].id.?.eql(id_c));

    // Adding: at the end, at a row, and one the section has is left (or moved when a row is given).
    try s.addEntry(.favorites, "/d", null);
    try s.addEntry(.favorites, "/e", 0);
    try s.addEntry(.favorites, "/d", null);
    try testing.expectEqualDeep(@as([]const []const u8, &.{ "e", "a", "b", "d" }), titles(&s, .favorites, &buf));
    try s.addEntry(.favorites, "/d", 1);
    try testing.expectEqualDeep(@as([]const []const u8, &.{ "e", "d", "a", "b" }), titles(&s, .favorites, &buf));

    const revision = s.revision;
    try testing.expect(s.removeEntry(id_c));
    try testing.expect(!s.removeEntry(id_c));
    try testing.expect(s.revision != revision);
    try testing.expectEqualDeep(@as([]const []const u8, &.{"p"}), titles(&s, .pinned, &buf));
}

test "Locations follow the volumes, and say when nothing changed; titles persist only when given" {
    const gpa = testing.allocator;
    var s = try Sidebar.init(gpa, "/h", &.{ .{ .path = "/a", .title = "Alpha" }, .{ .path = "/b" } }, &.{}, &.{.{ .path = "/", .title = "HD" }});
    defer s.deinit();
    const vols = [_]Item{ .{ .path = "/", .title = "HD" }, .{ .path = "/Volumes/U", .title = "U", .ejectable = true } };
    try testing.expect(try s.setLocations(&vols));
    try testing.expect(!try s.setLocations(&vols));
    const rows = s.sections[3].rows.items;
    try testing.expectEqual(@as(usize, 2), rows.len);
    try testing.expect(rows[1].ejectable and !rows[0].ejectable and rows[0].id == null);
    try testing.expectEqualStrings("internaldrive", rows[0].icon);
    try testing.expectEqualStrings("externaldrive", rows[1].icon);
    try testing.expect(try s.setLocations(&.{}));
    try testing.expectEqual(@as(usize, 0), s.sections[3].rows.items.len);

    var fav = try s.entries(.favorites);
    defer state_model.deinitEntries(gpa, &fav);
    try testing.expectEqualStrings("Alpha", fav.items[0].title.?);
    try testing.expect(fav.items[1].title == null); // the folder's name is not a title
}
