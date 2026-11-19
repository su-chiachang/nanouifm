//! One tab: the folder it shows, its back/forward history, its selection, its sort order and its
//! listing. (Tabs, split panes and the column view build on this; slice 1 has one tab in one pane.)
const std = @import("std");
const Allocator = std.mem.Allocator;
const lister = @import("../core/lister.zig");
const History = @import("history.zig").History;
const Selection = @import("selection.zig").Selection;
const Listing = @import("listing.zig").Listing;

pub const Tab = struct {
    gpa: Allocator,
    history: History,
    sort: lister.SortOrder = .{},
    selection: Selection = .{},
    listing: Listing = .{},
    /// The listing replaced last: strings the frame just built may still point into it, so it
    /// is freed only when the next one replaces it.
    retired: ?Listing = null,
    /// The list jumps to the top in the next frame (set by every folder change).
    scroll_reset: bool = true,

    /// Starts in `path`. A folder that can't be listed is not an error here: the tab shows it.
    pub fn init(gpa: Allocator, folder: []const u8, show_hidden: bool) Allocator.Error!Tab {
        var t: Tab = .{ .gpa = gpa, .history = try History.init(gpa, folder) };
        errdefer t.history.deinit();
        try t.load(show_hidden);
        return t;
    }

    pub fn deinit(self: *Tab) void {
        self.selection.deinit(self.gpa);
        self.listing.deinit(self.gpa);
        if (self.retired) |*r| r.deinit(self.gpa);
        self.history.deinit();
        self.* = undefined;
    }

    /// The folder shown: always an absolute path without a trailing slash (except "/").
    pub fn path(self: *const Tab) []const u8 {
        return self.history.current();
    }

    /// The folder's name for a title.
    pub fn title(self: *const Tab) []const u8 {
        const p = self.path();
        const base = std.fs.path.basename(p);
        return if (base.len == 0) p else base;
    }

    pub fn canBack(self: *const Tab) bool {
        return self.history.canBack();
    }

    pub fn canForward(self: *const Tab) bool {
        return self.history.canForward();
    }

    fn swapIn(self: *Tab, fresh: Listing) void {
        if (self.retired) |*r| r.deinit(self.gpa);
        self.retired = self.listing;
        self.listing = fresh;
    }

    /// Lists the current folder into `listing` (an error becomes the listing's `err`).
    fn load(self: *Tab, show_hidden: bool) Allocator.Error!void {
        var fresh: Listing = if (Listing.loadFolder(self.gpa, self.path())) |items|
            Listing.fromItems(items)
        else |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => Listing.failed(e),
        };
        errdefer fresh.deinit(self.gpa);
        try fresh.rebuild(self.gpa, show_hidden, self.sort);
        self.swapIn(fresh);
    }

    /// Goes to a new folder, recording it in the history. If it can't be listed nothing changes
    /// and the lister's error comes back.
    pub fn visit(self: *Tab, folder: []const u8, show_hidden: bool) (lister.ListError || Allocator.Error)!void {
        if (std.mem.eql(u8, folder, self.path())) return self.reload(show_hidden);
        const items = try Listing.loadFolder(self.gpa, folder);
        var fresh = Listing.fromItems(items);
        errdefer fresh.deinit(self.gpa);
        try fresh.rebuild(self.gpa, show_hidden, self.sort);
        try self.history.push(folder);
        self.swapIn(fresh);
        self.selection.clear(self.gpa);
        self.scroll_reset = true;
    }

    /// History moves show the folder even if it has since become unreadable (the list says so).
    pub fn back(self: *Tab, show_hidden: bool) Allocator.Error!bool {
        _ = self.history.back() orelse return false;
        try self.arrived(show_hidden);
        return true;
    }

    pub fn forward(self: *Tab, show_hidden: bool) Allocator.Error!bool {
        _ = self.history.forward() orelse return false;
        try self.arrived(show_hidden);
        return true;
    }

    fn arrived(self: *Tab, show_hidden: bool) Allocator.Error!void {
        self.selection.clear(self.gpa);
        self.scroll_reset = true;
        try self.load(show_hidden);
    }

    /// Reads the folder again, keeping what is still selected.
    pub fn reload(self: *Tab, show_hidden: bool) Allocator.Error!void {
        try self.load(show_hidden);
        try self.selection.prune(self.gpa, self.listing.visible);
    }

    /// Hidden files shown or not: no re-read.
    pub fn refilter(self: *Tab, show_hidden: bool) Allocator.Error!void {
        try self.listing.rebuild(self.gpa, show_hidden, self.sort);
        try self.selection.prune(self.gpa, self.listing.visible);
    }

    /// Clicking a header: the same key flips the direction, another key starts ascending.
    pub fn sortBy(self: *Tab, key: lister.SortKey, show_hidden: bool) Allocator.Error!void {
        if (self.sort.key == key) {
            self.sort.ascending = !self.sort.ascending;
        } else {
            self.sort.key = key;
            self.sort.ascending = true;
        }
        try self.refilter(show_hidden);
    }
};
