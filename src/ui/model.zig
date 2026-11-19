//! The app's state, testable without a window: the sidebar, the panes (each with tabs), the
//! hidden-files setting, and the queue of actions the view raises. The view (`app.zig`) only
//! reads this and queues `Action`s; `applyPending` runs them at the start of the next pass, so
//! nothing a frame is still drawing is freed under it.
//!
//! Everything about where the app starts is injected through `Config`: only main.zig knows the
//! real home folder.
const std = @import("std");
const Allocator = std.mem.Allocator;
const lister = @import("../core/lister.zig");
const Pane = @import("pane.zig").Pane;
const Tab = @import("tab.zig").Tab;
const listing = @import("listing.zig");
const sidebar_model = @import("sidebar_model.zig");

pub const Item = sidebar_model.Item;

pub const Config = struct {
    /// The folder the first tab opens (absolute).
    start_path: []const u8,
    /// The Home row, and where breadcrumbs start when the folder is inside it.
    home_path: []const u8,
    favorites: []const Item = &.{},
    pinned: []const Item = &.{},
    locations: []const Item = &.{},
    show_hidden: bool = false,
};

/// What the view asks for. Applied by `Model.applyPending`.
pub const Action = union(enum) {
    /// Navigate to a folder (the path is owned by the queue).
    open: []const u8,
    back,
    forward,
    up,
    sort: lister.SortKey,
    toggle_hidden,
    reload,
    clear_notice,
};

pub const Model = struct {
    gpa: Allocator,
    /// Owned copy of `Config.home_path`.
    home: []u8,
    sidebar: sidebar_model.Sidebar,
    panes: std.ArrayList(Pane) = .empty,
    /// The pane sidebar clicks, shortcuts and the toolbar act on.
    focused: usize = 0,
    /// Global for now; the persisted state keeps it with the layout.
    show_hidden: bool,
    /// A message for the banner above the list (a folder that couldn't be opened).
    notice: ?[]u8 = null,
    pending: std.ArrayList(Action) = .empty,

    pub fn init(gpa: Allocator, cfg: Config) Allocator.Error!Model {
        const home = try normalize(gpa, cfg.home_path);
        errdefer gpa.free(home);
        var sb = try sidebar_model.Sidebar.init(gpa, home, cfg.favorites, cfg.pinned, cfg.locations);
        errdefer sb.deinit();
        var m: Model = .{ .gpa = gpa, .home = home, .sidebar = sb, .show_hidden = cfg.show_hidden };
        errdefer m.panes.deinit(gpa);
        const start = try normalize(gpa, cfg.start_path);
        defer gpa.free(start);
        var pane = try Pane.init(gpa, start, cfg.show_hidden);
        errdefer pane.deinit();
        try m.panes.append(gpa, pane);
        return m;
    }

    pub fn deinit(self: *Model) void {
        self.clearPending();
        self.pending.deinit(self.gpa);
        if (self.notice) |n| self.gpa.free(n);
        for (self.panes.items) |*p| p.deinit();
        self.panes.deinit(self.gpa);
        self.sidebar.deinit();
        self.gpa.free(self.home);
        self.* = undefined;
    }

    pub fn focusedTab(self: *Model) *Tab {
        return self.panes.items[self.focused].tab();
    }

    // ---- actions ----

    pub fn queue(self: *Model, a: Action) Allocator.Error!void {
        var act = a;
        if (act == .open) act.open = try self.gpa.dupe(u8, a.open);
        errdefer if (act == .open) self.gpa.free(act.open);
        try self.pending.append(self.gpa, act);
    }

    fn clearPending(self: *Model) void {
        for (self.pending.items) |a| if (a == .open) self.gpa.free(a.open);
        self.pending.clearRetainingCapacity();
    }

    /// Runs the queued actions in order; true if there were any.
    pub fn applyPending(self: *Model) Allocator.Error!bool {
        if (self.pending.items.len == 0) return false;
        defer self.clearPending();
        // Actions don't queue more, but copy so the loop is safe if one ever does.
        const todo = try self.gpa.dupe(Action, self.pending.items);
        defer self.gpa.free(todo);
        for (todo) |a| switch (a) {
            .open => |p| try self.navigate(p),
            .back => try self.back(),
            .forward => try self.forward(),
            .up => try self.up(),
            .sort => |k| try self.focusedTab().sortBy(k, self.show_hidden),
            .toggle_hidden => try self.setShowHidden(!self.show_hidden),
            .reload => try self.focusedTab().reload(self.show_hidden),
            .clear_notice => self.clearNotice(),
        };
        return true;
    }

    // ---- navigation ----

    /// Opens a folder in the focused tab. One that can't be listed leaves the tab and its
    /// history alone and raises a notice instead.
    pub fn navigate(self: *Model, path: []const u8) Allocator.Error!void {
        const p = try normalize(self.gpa, path);
        defer self.gpa.free(p);
        self.focusedTab().visit(p, self.show_hidden) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => |le| return self.setNotice(p, le),
        };
        self.clearNotice();
    }

    fn setNotice(self: *Model, path: []const u8, e: lister.ListError) Allocator.Error!void {
        const name = std.fs.path.basename(path);
        const msg = try std.fmt.allocPrint(self.gpa, "Can't open \"{s}\". {s}", .{ if (name.len == 0) path else name, listing.errorText(e) });
        self.clearNotice();
        self.notice = msg;
    }

    pub fn clearNotice(self: *Model) void {
        if (self.notice) |n| self.gpa.free(n);
        self.notice = null;
    }

    pub fn back(self: *Model) Allocator.Error!void {
        if (try self.focusedTab().back(self.show_hidden)) self.clearNotice();
    }

    pub fn forward(self: *Model) Allocator.Error!void {
        if (try self.focusedTab().forward(self.show_hidden)) self.clearNotice();
    }

    pub fn canUp(self: *Model) bool {
        return std.fs.path.dirname(self.focusedTab().path()) != null;
    }

    /// To the enclosing folder.
    pub fn up(self: *Model) Allocator.Error!void {
        const parent = std.fs.path.dirname(self.focusedTab().path()) orelse return;
        try self.navigate(parent);
    }

    /// Double-click or Return on row `index` of the focused tab: folders open (files don't, yet).
    pub fn openItem(self: *Model, index: usize) Allocator.Error!void {
        const items = self.focusedTab().listing.visible;
        if (index >= items.len) return;
        if (items[index].is_directory) try self.navigate(items[index].path);
    }

    pub fn setShowHidden(self: *Model, on: bool) Allocator.Error!void {
        self.show_hidden = on;
        for (self.panes.items) |*p| for (p.tabs.items) |*t| try t.refilter(on);
    }
};

/// An absolute path without trailing slashes ("/" stays "/").
pub fn normalize(gpa: Allocator, path: []const u8) Allocator.Error![]u8 {
    const trimmed = std.mem.trimEnd(u8, path, "/");
    return gpa.dupe(u8, if (trimmed.len == 0) "/" else trimmed);
}
