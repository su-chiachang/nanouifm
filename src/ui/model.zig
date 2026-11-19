//! The app's state, testable without a window: the sidebar, the panes (each with tabs) and how
//! they are laid out, the hidden-files setting, and the queue of actions the view raises. The
//! view (`app.zig`) only reads this and queues `Action`s; `applyPending` runs them at the start
//! of the next pass, so nothing a frame is still drawing is freed under it.
//!
//! `panes` is always the leaves of `layout` in reading order (left to right, top to bottom), and
//! `focused` indexes it. Pane and tab ids are stable, so queued actions name them rather than
//! indices: an action that arrives twice, or after its target is gone, does nothing. Pane and tab
//! operations live in `layout_ops.zig` and `tab_ops.zig`.
//!
//! Everything about where the app starts is injected through `Config`: only main.zig knows the
//! real home folder.
const std = @import("std");
const Allocator = std.mem.Allocator;
const lister = @import("../core/lister.zig");
const pane_layout = @import("../core/pane_layout.zig");
const Pane = @import("pane.zig").Pane;
const Tab = @import("tab.zig").Tab;
const TabOpts = @import("tab.zig").Opts;
const listing = @import("listing.zig");
const sidebar_model = @import("sidebar_model.zig");
const pane_sizes = @import("pane_sizes.zig");
const layout_ops = @import("layout_ops.zig");
const tab_ops = @import("tab_ops.zig");

pub const Item = sidebar_model.Item;
pub const LayoutTree = pane_sizes.Tree;
pub const SplitAxis = pane_layout.SplitAxis;
pub const LayoutPreset = pane_layout.LayoutPreset;

/// A tab, by the ids that survive reordering.
pub const TabRef = struct { pane: u32, tab: u32 };

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
    /// Cmd-click in the sidebar: a folder in a new tab of the focused pane (path owned by the queue).
    open_in_new_tab: []const u8,
    /// A tab beside the shown one of the focused pane, in the same folder.
    new_tab,
    close_tab: TabRef,
    /// Cmd+W: the focused pane's shown tab.
    close_active_tab,
    select_tab: TabRef,
    /// Ctrl+Tab (+1) and Ctrl+Shift+Tab (-1) in the focused pane.
    cycle_tab: i8,
    move_tab: struct { tab: TabRef, to: u32 },
    focus_pane: u32,
    /// Cmd+Opt+Right (+1) and Left (-1): wraps around.
    focus_move: i8,
    /// Docks a new pane, in the focused pane's folder, beside the focused one: `.side_by_side`
    /// to its right (Cmd+D), `.stacked` below it (Shift+Cmd+D).
    split: SplitAxis,
    close_pane: u32,
    apply_preset: LayoutPreset,
};

/// What the view keeps between frames that is not model data.
pub const ViewState = struct {
    /// The divider under the pointer's drag, and where the pointer last was along it.
    divider: ?struct { split: u32, index: u32, last: f32 } = null,
    /// A tab pressed: it follows the pointer along the strip once the pointer has moved.
    tab_drag: ?struct { tab: TabRef, start_x: f32, moving: bool } = null,
    layout_menu_open: bool = false,
    /// The layout button's rectangle (window points), where its popover hangs.
    layout_anchor: ?pane_sizes.Rect = null,
};

pub const Model = struct {
    gpa: Allocator,
    /// Owned copy of `Config.home_path`.
    home: []u8,
    sidebar: sidebar_model.Sidebar,
    /// In reading order of `layout`.
    panes: std.ArrayList(Pane) = .empty,
    /// Pane ids; how the panes nest, and each split's weights (reset when the shape changes).
    layout: LayoutTree,
    sizes: pane_sizes.Sizes = .{},
    /// The pane (an index of `panes`) that sidebar clicks, shortcuts and the toolbar act on.
    focused: usize = 0,
    next_id: u32 = 1,
    /// Closed panes and tabs, freed at the next `applyPending`: the frame just drawn may still
    /// point into their listings.
    retired_panes: std.ArrayList(Pane) = .empty,
    retired_tabs: std.ArrayList(Tab) = .empty,
    view_state: ViewState = .{},
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
        const start = try normalize(gpa, cfg.start_path);
        defer gpa.free(start);
        var pane = try Pane.init(gpa, start, .{ .show_hidden = cfg.show_hidden }, .{ .pane = 1, .tab = 2 });
        errdefer pane.deinit();
        var m: Model = .{ .gpa = gpa, .home = home, .sidebar = sb, .show_hidden = cfg.show_hidden, .layout = .{ .leaf = pane.id }, .next_id = 3 };
        errdefer m.sizes.deinit(gpa);
        try m.sizes.reset(gpa, &m.layout);
        try m.panes.append(gpa, pane);
        return m;
    }

    pub fn deinit(self: *Model) void {
        self.clearPending();
        self.pending.deinit(self.gpa);
        self.freeRetired();
        self.retired_panes.deinit(self.gpa);
        self.retired_tabs.deinit(self.gpa);
        if (self.notice) |n| self.gpa.free(n);
        for (self.panes.items) |*p| p.deinit();
        self.panes.deinit(self.gpa);
        self.layout.deinit(self.gpa);
        self.sizes.deinit(self.gpa);
        self.sidebar.deinit();
        self.gpa.free(self.home);
        self.* = undefined;
    }

    pub fn nextId(self: *Model) u32 {
        defer self.next_id += 1;
        return self.next_id;
    }

    pub fn focusedPane(self: *Model) *Pane {
        return &self.panes.items[self.focused];
    }

    /// What listings are built with in `pane`.
    pub fn opts(self: *const Model, pane: *const Pane) TabOpts {
        return pane.opts(self.show_hidden);
    }

    pub fn paneIndex(self: *const Model, id: u32) ?usize {
        for (self.panes.items, 0..) |p, i| if (p.id == id) return i;
        return null;
    }

    fn freeRetired(self: *Model) void {
        for (self.retired_tabs.items) |*t| t.deinit();
        self.retired_tabs.clearRetainingCapacity();
        for (self.retired_panes.items) |*p| p.deinit();
        self.retired_panes.clearRetainingCapacity();
    }

    pub fn focusedTab(self: *Model) *Tab {
        return self.focusedPane().tab();
    }

    // ---- actions ----

    pub fn queue(self: *Model, a: Action) Allocator.Error!void {
        var act = a;
        switch (act) {
            .open => |p| act.open = try self.gpa.dupe(u8, p),
            .open_in_new_tab => |p| act.open_in_new_tab = try self.gpa.dupe(u8, p),
            else => {},
        }
        errdefer switch (act) {
            .open => |p| self.gpa.free(p),
            .open_in_new_tab => |p| self.gpa.free(p),
            else => {},
        };
        try self.pending.append(self.gpa, act);
    }

    fn clearPending(self: *Model) void {
        for (self.pending.items) |a| switch (a) {
            .open => |p| self.gpa.free(p),
            .open_in_new_tab => |p| self.gpa.free(p),
            else => {},
        };
        self.pending.clearRetainingCapacity();
    }

    /// Runs the queued actions in order; true if there were any.
    pub fn applyPending(self: *Model) Allocator.Error!bool {
        self.freeRetired();
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
            .sort => |k| try self.focusedPane().sortBy(k, self.show_hidden),
            .toggle_hidden => try self.setShowHidden(!self.show_hidden),
            .reload => try self.focusedTab().reload(self.opts(self.focusedPane())),
            .clear_notice => self.clearNotice(),
            .open_in_new_tab => |p| try tab_ops.openInNewTab(self, p),
            .new_tab => try tab_ops.newTab(self),
            .close_tab => |r| try tab_ops.closeTab(self, r),
            .close_active_tab => try tab_ops.closeActiveTab(self),
            .select_tab => |r| tab_ops.selectTab(self, r),
            .cycle_tab => |d| self.focusedPane().cycleTab(d),
            .move_tab => |mv| tab_ops.moveTab(self, mv.tab, mv.to),
            .focus_pane => |id| self.focusPane(id),
            .focus_move => |d| layout_ops.focusMove(self, d),
            .split => |axis| try layout_ops.split(self, axis),
            .close_pane => |id| if (self.paneIndex(id)) |i| try layout_ops.closePane(self, i),
            .apply_preset => |p| try layout_ops.applyPreset(self, p),
        };
        return true;
    }

    // ---- navigation ----

    /// Opens a folder in the focused tab. One that can't be listed leaves the tab and its
    /// history alone and raises a notice instead.
    pub fn navigate(self: *Model, path: []const u8) Allocator.Error!void {
        const p = try normalize(self.gpa, path);
        defer self.gpa.free(p);
        self.focusedTab().visit(p, self.opts(self.focusedPane())) catch |e| switch (e) {
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
        if (try self.focusedTab().back(self.opts(self.focusedPane()))) self.clearNotice();
    }

    pub fn forward(self: *Model) Allocator.Error!void {
        if (try self.focusedTab().forward(self.opts(self.focusedPane()))) self.clearNotice();
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
        for (self.panes.items) |*p| for (p.tabs.items) |*t| try t.refilter(p.opts(on));
    }

    /// Focuses the pane with this id (a click in it, a tab chosen in it).
    pub fn focusPane(self: *Model, id: u32) void {
        if (self.paneIndex(id)) |i| self.focused = i;
    }
};

/// An absolute path without trailing slashes ("/" stays "/").
pub fn normalize(gpa: Allocator, path: []const u8) Allocator.Error![]u8 {
    const trimmed = std.mem.trimEnd(u8, path, "/");
    return gpa.dupe(u8, if (trimmed.len == 0) "/" else trimmed);
}
