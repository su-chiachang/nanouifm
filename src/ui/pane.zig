//! A pane: a strip of tabs with one shown, plus the state the tabs share: the sort order and
//! the view mode. The index rules mirror the Swift `PaneModel` (addTab, closeTab, selectTab,
//! cycleTab, moveTab). A pane never has zero tabs: `closeTab` refuses the last one and the
//! model decides what that means (close the pane, or nothing).
const std = @import("std");
const Allocator = std.mem.Allocator;
const lister = @import("../core/lister.zig");
const tab_mod = @import("tab.zig");
const Tab = tab_mod.Tab;
const Opts = tab_mod.Opts;
const Filter = @import("filter.zig").Filter;

pub const ViewMode = enum { list, column };

pub const Pane = struct {
    gpa: Allocator,
    /// Unique in the model and stable while panes are docked, closed and reordered.
    id: u32 = 0,
    tabs: std.ArrayList(Tab) = .empty,
    active: usize = 0,
    sort: lister.SortOrder = .{},
    view_mode: ViewMode = .list,
    /// The toolbar's name filter: its field's text, and where it was applied (see `filter.zig`).
    filter: Filter = .{},
    /// The inspector (the preview and details of the selection) is shown beside the list (Opt+Cmd+I).
    /// Column view always has its trailing preview column; the flag is kept for when it goes back to a list.
    inspector: bool = false,

    /// A pane with one tab in `folder`; `ids` are the pane's and its tab's.
    pub fn init(gpa: Allocator, folder: []const u8, o: Opts, ids: struct { pane: u32 = 0, tab: u32 = 0 }) Allocator.Error!Pane {
        var p: Pane = .{ .gpa = gpa, .id = ids.pane, .sort = o.sort };
        errdefer p.deinit();
        var t = try Tab.init(gpa, folder, o);
        errdefer t.deinit();
        t.id = ids.tab;
        try p.tabs.append(gpa, t);
        return p;
    }

    pub fn deinit(self: *Pane) void {
        for (self.tabs.items) |*t| t.deinit();
        self.tabs.deinit(self.gpa);
        self.filter.deinit(self.gpa);
        self.* = undefined;
    }

    pub fn tab(self: *Pane) *Tab {
        return &self.tabs.items[self.active];
    }

    /// What the tabs' listings are built with.
    pub fn opts(self: *const Pane, show_hidden: bool) Opts {
        return .{ .show_hidden = show_hidden, .sort = self.sort, .filter = self.filter.text() };
    }

    pub fn indexOfTab(self: *const Pane, tab_id: u32) ?usize {
        for (self.tabs.items, 0..) |t, i| if (t.id == tab_id) return i;
        return null;
    }

    /// Inserts `t` (taking ownership) right after tab `after` (default: the shown one). `select`
    /// shows it; otherwise the shown tab stays shown even if it moved right.
    pub fn insertTab(self: *Pane, t: Tab, after: ?usize, select: bool) Allocator.Error!*Tab {
        const at = @min((after orelse self.active) + 1, self.tabs.items.len);
        try self.tabs.insert(self.gpa, at, t);
        if (select) {
            self.active = at;
        } else if (at <= self.active) {
            self.active += 1;
        }
        return &self.tabs.items[at];
    }

    /// A new tab in `folder`, listed with this pane's order.
    pub fn addTab(self: *Pane, folder: []const u8, tab_id: u32, show_hidden: bool, after: ?usize, select: bool) Allocator.Error!*Tab {
        var t = try Tab.init(self.gpa, folder, self.opts(show_hidden));
        errdefer t.deinit();
        t.id = tab_id;
        return self.insertTab(t, after, select);
    }

    /// Removes tab `index` and hands it over (the caller frees it, later); null for the last tab
    /// or a bad index.
    pub fn closeTab(self: *Pane, index: usize) ?Tab {
        if (self.tabs.items.len <= 1 or index >= self.tabs.items.len) return null;
        const t = self.tabs.orderedRemove(index);
        if (self.active > index or self.active >= self.tabs.items.len) self.active = self.active -| 1;
        return t;
    }

    pub fn selectTab(self: *Pane, index: usize) void {
        if (index < self.tabs.items.len) self.active = index;
    }

    pub fn cycleTab(self: *Pane, delta: isize) void {
        const n: isize = @intCast(self.tabs.items.len);
        if (n < 2) return;
        self.active = @intCast(@mod(@as(isize, @intCast(self.active)) + delta, n));
    }

    /// Moves a tab; the shown tab stays the shown tab.
    pub fn moveTab(self: *Pane, from: usize, to: usize) void {
        const n = self.tabs.items.len;
        if (from >= n or to >= n or from == to) return;
        const t = self.tabs.orderedRemove(from);
        self.tabs.insertAssumeCapacity(to, t);
        if (self.active == from) {
            self.active = to;
        } else if (from < self.active and to >= self.active) {
            self.active -= 1;
        } else if (from > self.active and to <= self.active) {
            self.active += 1;
        }
    }

    /// Clicking a header: the same key flips the direction, another key starts ascending. Every
    /// tab is listed again in the new order.
    pub fn sortBy(self: *Pane, key: lister.SortKey, show_hidden: bool) Allocator.Error!void {
        if (self.sort.key == key) {
            self.sort.ascending = !self.sort.ascending;
        } else {
            self.sort.key = key;
            self.sort.ascending = true;
        }
        try self.refilter(show_hidden);
    }

    /// The sort menu's Ascending and Descending.
    pub fn setAscending(self: *Pane, ascending: bool, show_hidden: bool) Allocator.Error!void {
        self.sort.ascending = ascending;
        try self.refilter(show_hidden);
    }

    /// The sort menu's Folders First.
    pub fn toggleFoldersFirst(self: *Pane, show_hidden: bool) Allocator.Error!void {
        self.sort.folders_first = !self.sort.folders_first;
        try self.refilter(show_hidden);
    }

    /// Every tab's rows again (the order, the hidden files or the name filter changed).
    pub fn refilter(self: *Pane, show_hidden: bool) Allocator.Error!void {
        for (self.tabs.items) |*t| try t.refilter(self.opts(show_hidden));
    }
};
