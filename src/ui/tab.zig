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
const Loader = @import("listing_loader.zig").Loader;
const Preloaded = @import("listing_inbox.zig").Preloaded;

/// What a listing is built with: the pane's order and the app's hidden-files setting.
pub const Opts = struct {
    show_hidden: bool = false,
    sort: lister.SortOrder = .{},
    /// The pane's name filter (borrowed from its toolbar field; "" shows everything).
    filter: []const u8 = "",
    /// Asynchronous listing (`listing_loader.zig`): the operations that read a folder ask this
    /// loader for it and return; the tab keeps what it shows until the answer lands. Null (the
    /// default, tests): they read inline, as always.
    loader: ?*Loader = null,
    /// Set only while a landed request runs the operation again: its folders are in here.
    pre: ?*Preloaded = null,

    /// The loader to ask, when this call should ask rather than read.
    pub fn later(self: Opts) ?*Loader {
        return if (self.pre == null) self.loader else null;
    }
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
    /// A listing has been built (or failed) at least once: false for a tab still waiting for its first.
    listed: bool = false,
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
    /// With a loader (`opts.loader`) the tab starts empty and the caller asks for its first
    /// listing with `reload` once it has its id (`Pane.init`, `Pane.addTabWith`).
    pub fn init(gpa: Allocator, folder: []const u8, opts: Opts) Allocator.Error!Tab {
        var t: Tab = .{ .gpa = gpa, .history = try History.init(gpa, folder) };
        errdefer t.deinit();
        if (opts.later() == null) try t.load(opts);
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
        self.listed = true;
    }

    /// Lists the current folder into `listing` (an error becomes the listing's `err`).
    fn load(self: *Tab, opts: Opts) Allocator.Error!void {
        var fresh = try Listing.readVia(self.gpa, self.path(), opts.pre);
        errdefer fresh.deinit(self.gpa);
        try fresh.rebuild(self.gpa, opts.show_hidden, opts.sort, opts.filter);
        self.swapIn(fresh);
        try self.rebuildRows(opts, true);
    }

    /// The rows of the list again from the listing (and the open folders').
    fn rebuildRows(self: *Tab, opts: Opts, reread: bool) Allocator.Error!void {
        try self.exp.rebuild(self.gpa, self.listing.visible, .{ .show_hidden = opts.show_hidden, .sort = opts.sort, .pre = opts.pre }, reread);
    }

    /// The folders a `reload` reads: this one, the folders opened in the list and, with
    /// `columns`, those of the column stack. Borrowed from the tab; free the slice.
    fn reloadNeeds(self: *const Tab, columns: bool) Allocator.Error![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        errdefer out.deinit(self.gpa);
        try out.append(self.gpa, self.path());
        var it = self.exp.set.keyIterator();
        while (it.next()) |k| try out.append(self.gpa, k.*);
        if (columns) for (self.col.columns.items) |c| try out.append(self.gpa, c.path);
        return out.toOwnedSlice(self.gpa);
    }

    /// Opens (or closes) folder `folder` in place in the list.
    pub fn setExpanded(self: *Tab, folder: []const u8, on: bool, opts: Opts) Allocator.Error!void {
        if (on and !self.exp.isExpanded(folder)) if (opts.later()) |ld| {
            return ld.request(self.id, self.path(), .{ .expand = folder }, &.{folder});
        };
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
        if (opts.later()) |ld| { // the listing lands later (`listing_apply`), which says if it failed
            const same = std.mem.eql(u8, folder, self.path());
            const need = if (same) try self.reloadNeeds(false) else try self.gpa.dupe([]const u8, &.{folder});
            defer self.gpa.free(need);
            return ld.request(self.id, self.path(), .{ .visit = folder }, need);
        }
        if (std.mem.eql(u8, folder, self.path())) {
            self.col.reset(self.gpa); // a column view re-roots here
            return self.reload(opts);
        }
        const items = try Listing.fetch(self.gpa, folder, opts.pre);
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
        if (opts.later()) |ld| {
            const target = self.history.peekBack() orelse return false;
            try ld.request(self.id, self.path(), .back, &.{target});
            return true;
        }
        _ = self.history.back() orelse return false;
        try self.arrived(opts);
        return true;
    }

    pub fn forward(self: *Tab, opts: Opts) Allocator.Error!bool {
        if (opts.later()) |ld| {
            const target = self.history.peekForward() orelse return false;
            try ld.request(self.id, self.path(), .forward, &.{target});
            return true;
        }
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
        if (opts.later()) |ld| {
            const need = try self.reloadNeeds(true);
            defer self.gpa.free(need);
            return ld.request(self.id, self.path(), .reload, need);
        }
        try self.load(opts);
        try self.col.reread(self.gpa, .{ .show_hidden = opts.show_hidden, .sort = opts.sort, .filter = opts.filter, .pre = opts.pre });
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
