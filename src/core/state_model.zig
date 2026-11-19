//! The persisted state's data types (port of the model half of StateStore.swift): sidebar entries,
//! persisted panes, and the whole PersistedState. Pure data with owned memory: every type that
//! owns allocations has `deinit(gpa)` and `clone(gpa)`. JSON lives in state_json.zig, the file
//! in state_store.zig.
const std = @import("std");
const Allocator = std.mem.Allocator;
const layout_tree = @import("layout_tree.zig");
const LayoutPreset = @import("layout_preset.zig").LayoutPreset;
const LayoutTree = layout_tree.LayoutTree;
const SplitAxis = layout_tree.SplitAxis;

// ---- file URLs <-> paths (Swift encodes URLs as "file:///path" strings) ----

fn isUnreserved(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '.' or c == '_' or c == '~' or c == '/';
}

/// "/Users/me/My Docs" -> "file:///Users/me/My%20Docs". Caller frees.
pub fn urlFromPath(gpa: Allocator, path: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "file://");
    const hex = "0123456789ABCDEF";
    for (path) |c| {
        if (isUnreserved(c)) {
            try out.append(gpa, c);
        } else {
            try out.appendSlice(gpa, &.{ '%', hex[c >> 4], hex[c & 15] });
        }
    }
    return out.toOwnedSlice(gpa);
}

/// Accepts "file:///a/b%20c/" (trailing slash dropped) or a plain path. Caller frees.
pub fn pathFromUrl(gpa: Allocator, url: []const u8) Allocator.Error![]u8 {
    var rest = url;
    const is_url = std.mem.startsWith(u8, url, "file://");
    if (is_url) {
        rest = url["file://".len..];
        // Skip an authority ("localhost"): the path starts at the next slash.
        if (rest.len > 0 and rest[0] != '/') rest = if (std.mem.indexOfScalar(u8, rest, '/')) |i| rest[i..] else "/";
    }
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        if (is_url and rest[i] == '%' and i + 2 < rest.len) {
            if (std.fmt.parseInt(u8, rest[i + 1 ..][0..2], 16)) |b| {
                try out.append(gpa, b);
                i += 2;
                continue;
            } else |_| {}
        }
        try out.append(gpa, rest[i]);
    }
    while (out.items.len > 1 and out.items[out.items.len - 1] == '/') _ = out.pop();
    return out.toOwnedSlice(gpa);
}

// ---- Uuid ----

/// A UUID, written like Swift's `UUID` Codable: 36 uppercase characters.
pub const Uuid = struct {
    bytes: [16]u8,

    pub fn random(io: std.Io) Uuid {
        var b: [16]u8 = undefined;
        io.random(&b);
        b[6] = (b[6] & 0x0f) | 0x40;
        b[8] = (b[8] & 0x3f) | 0x80;
        return .{ .bytes = b };
    }

    pub fn format(self: Uuid) [36]u8 {
        const hex = "0123456789ABCDEF";
        var out: [36]u8 = undefined;
        var o: usize = 0;
        for (self.bytes, 0..) |b, i| {
            if (i == 4 or i == 6 or i == 8 or i == 10) {
                out[o] = '-';
                o += 1;
            }
            out[o] = hex[b >> 4];
            out[o + 1] = hex[b & 15];
            o += 2;
        }
        return out;
    }

    pub fn parse(s: []const u8) ?Uuid {
        if (s.len != 36) return null;
        var bytes: [16]u8 = undefined;
        var n: usize = 0;
        var i: usize = 0;
        while (i < 36) {
            if (i == 8 or i == 13 or i == 18 or i == 23) {
                if (s[i] != '-') return null;
                i += 1;
                continue;
            }
            bytes[n] = std.fmt.parseInt(u8, s[i..][0..2], 16) catch return null;
            n += 1;
            i += 2;
        }
        return .{ .bytes = bytes };
    }

    pub fn eql(a: Uuid, b: Uuid) bool {
        return std.mem.eql(u8, &a.bytes, &b.bytes);
    }
};

// ---- SidebarEntry ----

pub const SidebarEntry = struct {
    id: Uuid,
    /// Absolute folder path (owned).
    path: []u8,
    title: ?[]u8 = null,

    /// Copies `path` and `title`; the id is freshly generated.
    pub fn init(gpa: Allocator, io: std.Io, path: []const u8, title: ?[]const u8) Allocator.Error!SidebarEntry {
        return initWithId(gpa, Uuid.random(io), path, title);
    }

    pub fn initWithId(gpa: Allocator, id: Uuid, path: []const u8, title: ?[]const u8) Allocator.Error!SidebarEntry {
        const p = try gpa.dupe(u8, path);
        errdefer gpa.free(p);
        const t = if (title) |t| try gpa.dupe(u8, t) else null;
        return .{ .id = id, .path = p, .title = t };
    }

    pub fn deinit(self: *SidebarEntry, gpa: Allocator) void {
        gpa.free(self.path);
        if (self.title) |t| gpa.free(t);
        self.* = undefined;
    }

    pub fn clone(self: *const SidebarEntry, gpa: Allocator) Allocator.Error!SidebarEntry {
        return initWithId(gpa, self.id, self.path, self.title);
    }

    pub fn eql(a: *const SidebarEntry, b: *const SidebarEntry) bool {
        if (!a.id.eql(b.id) or !std.mem.eql(u8, a.path, b.path)) return false;
        if (a.title == null or b.title == null) return a.title == null and b.title == null;
        return std.mem.eql(u8, a.title.?, b.title.?);
    }

    /// Title if set, else the last path component.
    pub fn displayName(self: *const SidebarEntry) []const u8 {
        if (self.title) |t| return t;
        const base = std.fs.path.basename(self.path);
        return if (base.len == 0) self.path else base;
    }
};

pub const EntryList = std.ArrayList(SidebarEntry);

pub fn deinitEntries(gpa: Allocator, list: *EntryList) void {
    for (list.items) |*e| e.deinit(gpa);
    list.deinit(gpa);
}

fn cloneEntries(gpa: Allocator, src: []const SidebarEntry) Allocator.Error!EntryList {
    var out: EntryList = .empty;
    errdefer deinitEntries(gpa, &out);
    try out.ensureTotalCapacityPrecise(gpa, src.len);
    for (src) |*e| out.appendAssumeCapacity(try e.clone(gpa));
    return out;
}

fn entriesEql(a: []const SidebarEntry, b: []const SidebarEntry) bool {
    if (a.len != b.len) return false;
    for (a, b) |*x, *y| if (!x.eql(y)) return false;
    return true;
}

// ---- PersistedPane ----

pub const ViewMode = enum {
    list,
    column,

    pub fn fromName(s: []const u8) ?ViewMode {
        return std.meta.stringToEnum(ViewMode, s);
    }
};

pub const PersistedPane = struct {
    /// Folder paths, one per tab (each owned).
    tabs: std.ArrayList([]u8) = .empty,
    selected_tab: usize = 0,
    view_mode: ViewMode = .list,

    /// Copies `tab_paths`.
    pub fn init(gpa: Allocator, tab_paths: []const []const u8, selected_tab: usize, view_mode: ViewMode) Allocator.Error!PersistedPane {
        var p: PersistedPane = .{ .selected_tab = selected_tab, .view_mode = view_mode };
        errdefer p.deinit(gpa);
        try p.tabs.ensureTotalCapacityPrecise(gpa, tab_paths.len);
        for (tab_paths) |t| p.tabs.appendAssumeCapacity(try gpa.dupe(u8, t));
        return p;
    }

    pub fn addTab(self: *PersistedPane, gpa: Allocator, path: []const u8) Allocator.Error!void {
        const p = try gpa.dupe(u8, path);
        errdefer gpa.free(p);
        try self.tabs.append(gpa, p);
    }

    pub fn deinit(self: *PersistedPane, gpa: Allocator) void {
        for (self.tabs.items) |t| gpa.free(t);
        self.tabs.deinit(gpa);
        self.* = undefined;
    }

    pub fn clone(self: *const PersistedPane, gpa: Allocator) Allocator.Error!PersistedPane {
        return init(gpa, @ptrCast(self.tabs.items), self.selected_tab, self.view_mode);
    }

    pub fn eql(a: *const PersistedPane, b: *const PersistedPane) bool {
        if (a.selected_tab != b.selected_tab or a.view_mode != b.view_mode or a.tabs.items.len != b.tabs.items.len) return false;
        for (a.tabs.items, b.tabs.items) |x, y| if (!std.mem.eql(u8, x, y)) return false;
        return true;
    }
};

pub const PaneTree = LayoutTree(PersistedPane);

// ---- PersistedState ----

pub const PersistedState = struct {
    /// Sidebar "Favorites" (defaults: Desktop, Documents, Downloads, Home).
    favorites: EntryList = .empty,
    /// Sidebar "Pinned" group.
    pinned: EntryList = .empty,
    /// Pane split tree.
    layout: PaneTree,
    show_hidden: bool = false,
    sidebar_visible: bool = true,

    pub fn deinit(self: *PersistedState, gpa: Allocator) void {
        deinitEntries(gpa, &self.favorites);
        deinitEntries(gpa, &self.pinned);
        self.layout.deinit(gpa);
        self.* = undefined;
    }

    pub fn clone(self: *const PersistedState, gpa: Allocator) Allocator.Error!PersistedState {
        var fav = try cloneEntries(gpa, self.favorites.items);
        errdefer deinitEntries(gpa, &fav);
        var pin = try cloneEntries(gpa, self.pinned.items);
        errdefer deinitEntries(gpa, &pin);
        const lay = try self.layout.clone(gpa);
        return .{ .favorites = fav, .pinned = pin, .layout = lay, .show_hidden = self.show_hidden, .sidebar_visible = self.sidebar_visible };
    }

    pub fn eql(a: *const PersistedState, b: *const PersistedState) bool {
        return a.show_hidden == b.show_hidden and a.sidebar_visible == b.sidebar_visible and
            entriesEql(a.favorites.items, b.favorites.items) and entriesEql(a.pinned.items, b.pinned.items) and
            a.layout.eql(&b.layout);
    }

    /// The panes in reading order, borrowed from `layout`. Free the slice with `gpa.free`.
    pub fn panes(self: *const PersistedState, gpa: Allocator) Allocator.Error![]PersistedPane {
        return self.layout.leaves(gpa);
    }

    /// A flat split of (clones of) `panes`, normalized; a single pane becomes a lone leaf.
    /// null when `panes` is empty.
    pub fn flatLayout(gpa: Allocator, panes_in: []const PersistedPane, stacked: bool) Allocator.Error!?PaneTree {
        const kids = try gpa.alloc(PaneTree, panes_in.len);
        var done: usize = 0;
        errdefer {
            for (kids[0..done]) |*k| k.deinit(gpa);
            gpa.free(kids);
        }
        while (done < kids.len) : (done += 1) kids[done] = .{ .leaf = try panes_in[done].clone(gpa) };
        var split = PaneTree.splitOf(if (stacked) SplitAxis.stacked else .side_by_side, kids);
        defer split.deinit(gpa);
        return split.normalized(gpa);
    }

    /// The first-launch state: favorites Desktop, Documents, Downloads, Home; a 2x2 grid of panes
    /// showing them, list view; hidden files off, sidebar visible. `home` is the user's home folder.
    pub fn defaults(gpa: Allocator, io: std.Io, home: []const u8) Allocator.Error!PersistedState {
        var home_dir = home;
        while (home_dir.len > 1 and home_dir[home_dir.len - 1] == '/') home_dir = home_dir[0 .. home_dir.len - 1];
        const paths: [4][]u8 = blk: {
            var p: [4][]u8 = undefined;
            var n: usize = 0;
            errdefer for (p[0..n]) |x| gpa.free(x);
            for ([_][]const u8{ "Desktop", "Documents", "Downloads" }) |name| {
                p[n] = try std.fs.path.join(gpa, &.{ home_dir, name });
                n += 1;
            }
            p[3] = try gpa.dupe(u8, home_dir);
            break :blk p;
        };
        defer for (paths) |x| gpa.free(x);

        var fav: EntryList = .empty;
        errdefer deinitEntries(gpa, &fav);
        try fav.ensureTotalCapacityPrecise(gpa, 4);
        for (paths) |p| fav.appendAssumeCapacity(try SidebarEntry.init(gpa, io, p, null));

        var cells: [4]PersistedPane = undefined;
        var made: usize = 0;
        defer for (cells[0..made]) |*c| c.deinit(gpa);
        for (paths) |p| {
            cells[made] = try PersistedPane.init(gpa, &.{p}, 0, .list);
            made += 1;
        }
        const lay = LayoutPreset.grid_2x2.arranged(gpa, PersistedPane, &cells) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.WrongPaneCount => unreachable,
        };
        return .{ .favorites = fav, .layout = lay };
    }
};
