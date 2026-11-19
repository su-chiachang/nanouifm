//! One tab: the folder it shows, its back/forward history, its selection and its listing. The
//! sort order and the hidden-files setting belong to the pane and the app: every call that
//! (re)builds the listing takes them as `Opts`. Each tab has an `id` that stays with it as tabs
//! are reordered, closed and moved, so the view can key what it keeps per tab (the scroll).
const std = @import("std");
const Allocator = std.mem.Allocator;
const lister = @import("../core/lister.zig");
const History = @import("history.zig").History;
const Selection = @import("selection.zig").Selection;
const Listing = @import("listing.zig").Listing;
const Expansion = @import("expansion.zig").Expansion;
const ColumnState = @import("column_model.zig").ColumnState;

/// What a listing is built with: the pane's order and the app's hidden-files setting.
pub const Opts = struct {
    show_hidden: bool = false,
    sort: lister.SortOrder = .{},
    /// The pane's name filter (borrowed from its toolbar field; "" shows everything).
    filter: []const u8 = "",
};

pub const Tab = struct {
    gpa: Allocator,
    /// Unique in the model; 0 until the model hands one out.
    id: u32 = 0,
    history: History,
    selection: Selection = .{},
    listing: Listing = .{},
    /// The listing replaced last: strings the frame just built may still point into it, so it
    /// is freed only when the next one replaces it.
    retired: ?Listing = null,
    /// The list jumps to the top in the next frame (set by every folder change).
    scroll_reset: bool = true,
    /// List view: the open folders and the rows as shown (`exp.items`, folders opened in place
    /// included). Selection and keyboard moves work on these rows.
    exp: Expansion = .{},
    /// The row the keyboard just moved to: the list scrolls it into sight, once.
    reveal: ?usize = null,
    /// Column view: the stack of columns, widths, scroll.
    col: ColumnState = .{},

    /// Starts in `path`. A folder that can't be listed is not an error here: the tab shows it.
    pub fn init(gpa: Allocator, folder: []const u8, opts: Opts) Allocator.Error!Tab {
        var t: Tab = .{ .gpa = gpa, .history = try History.init(gpa, folder) };
        errdefer t.deinit();
        try t.load(opts);
        return t;
    }

    pub fn deinit(self: *Tab) void {
        self.selection.deinit(self.gpa);
        self.exp.deinit(self.gpa);
        self.col.deinit(self.gpa);
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
    fn load(self: *Tab, opts: Opts) Allocator.Error!void {
        var fresh = try Listing.read(self.gpa, self.path());
        errdefer fresh.deinit(self.gpa);
        try fresh.rebuild(self.gpa, opts.show_hidden, opts.sort, opts.filter);
        self.swapIn(fresh);
        try self.rebuildRows(opts, true);
    }

    /// The rows of the list again from the listing (and the open folders').
    fn rebuildRows(self: *Tab, opts: Opts, reread: bool) Allocator.Error!void {
        try self.exp.rebuild(self.gpa, self.listing.visible, .{ .show_hidden = opts.show_hidden, .sort = opts.sort }, reread);
    }

    /// Opens (or closes) folder `folder` in place in the list.
    pub fn setExpanded(self: *Tab, folder: []const u8, on: bool, opts: Opts) Allocator.Error!void {
        if (on) try self.exp.expand(self.gpa, folder) else try self.exp.collapse(self.gpa, folder);
        try self.rebuildRows(opts, false);
        try self.selection.prune(self.gpa, self.exp.items);
    }

    /// Column view moved into `folder` (a column selected, a column dropped): the tab's folder
    /// follows without a history entry. The listing is read again for it.
    pub fn setColumnLocation(self: *Tab, folder: []const u8, opts: Opts) Allocator.Error!void {
        if (std.mem.eql(u8, folder, self.path())) return;
        try self.history.replaceCurrent(folder);
        self.exp.clearSet(self.gpa);
        try self.load(opts);
    }

    /// Goes to a new folder, recording it in the history. If it can't be listed nothing changes
    /// and the lister's error comes back.
    pub fn visit(self: *Tab, folder: []const u8, opts: Opts) (lister.ListError || Allocator.Error)!void {
        if (std.mem.eql(u8, folder, self.path())) {
            self.col.reset(self.gpa); // a column view re-roots here
            return self.reload(opts);
        }
        const items = try Listing.loadFolder(self.gpa, folder);
        var fresh = Listing.fromItems(items);
        errdefer fresh.deinit(self.gpa);
        try fresh.rebuild(self.gpa, opts.show_hidden, opts.sort, opts.filter);
        try self.history.push(folder);
        self.swapIn(fresh);
        self.selection.clear(self.gpa);
        self.scroll_reset = true;
        self.exp.clearSet(self.gpa);
        self.col.reset(self.gpa);
        try self.rebuildRows(opts, false);
    }

    /// History moves show the folder even if it has since become unreadable (the list says so).
    pub fn back(self: *Tab, opts: Opts) Allocator.Error!bool {
        _ = self.history.back() orelse return false;
        try self.arrived(opts);
        return true;
    }

    pub fn forward(self: *Tab, opts: Opts) Allocator.Error!bool {
        _ = self.history.forward() orelse return false;
        try self.arrived(opts);
        return true;
    }

    fn arrived(self: *Tab, opts: Opts) Allocator.Error!void {
        self.selection.clear(self.gpa);
        self.scroll_reset = true;
        self.exp.clearSet(self.gpa);
        self.col.reset(self.gpa);
        try self.load(opts);
    }

    /// Reads the folder again, keeping what is still selected.
    pub fn reload(self: *Tab, opts: Opts) Allocator.Error!void {
        try self.load(opts);
        try self.col.reread(self.gpa, .{ .show_hidden = opts.show_hidden, .sort = opts.sort, .filter = opts.filter });
        try self.selection.prune(self.gpa, self.exp.items);
    }

    /// Hidden files shown or not: no re-read.
    pub fn refilter(self: *Tab, opts: Opts) Allocator.Error!void {
        try self.listing.rebuild(self.gpa, opts.show_hidden, opts.sort, opts.filter);
        try self.rebuildRows(opts, false);
        try self.col.refilter(self.gpa, .{ .show_hidden = opts.show_hidden, .sort = opts.sort, .filter = opts.filter });
        try self.selection.prune(self.gpa, self.exp.items);
    }
};
