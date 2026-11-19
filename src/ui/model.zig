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
const ViewMode = @import("pane.zig").ViewMode;
const Tab = @import("tab.zig").Tab;
const TabOpts = @import("tab.zig").Opts;
const listing = @import("listing.zig");
const sidebar_model = @import("sidebar_model.zig");
const pane_sizes = @import("pane_sizes.zig");
const layout_ops = @import("layout_ops.zig");
const tab_ops = @import("tab_ops.zig");
const nav_ops = @import("nav_ops.zig");
const NavKey = @import("nav_key.zig").NavKey;
const TypeAhead = @import("typeahead.zig").TypeAhead;
const opener = @import("opener.zig");

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
    /// How a file is opened (double-click, Return). Null: files are not opened. Only main.zig
    /// passes `opener.system`, so no test can launch an app by accident; tests pass a recorder.
    opener: ?opener.OpenFn = null,
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
    /// Cmd+1 (list), Cmd+2 (column) and the toolbar's toggle: the focused pane's view mode.
    set_view_mode: ViewMode,
    /// An arrow key, Home or End in the focused pane (Shift extends the selection).
    nav: struct { key: NavKey, shift: bool },
    /// A typed character in the focused pane: jumps to the first name starting with what was
    /// typed lately. `time` is the frame's clock, in seconds.
    type_select: struct { key: u21, time: f64 },
    /// Return and Cmd+Down: opens what is selected in the focused pane (a folder goes there,
    /// files open in their default apps).
    open_selection,
    /// Double-click on a file (the path is owned by the queue).
    open_file: []const u8,
    /// A disclosure triangle of the list: opens or closes that folder in place (path owned by the queue).
    toggle_expand: struct { pane: u32, path: []const u8 },
    /// A click on row `index` of column `depth` of a pane's column view.
    column_click: struct { pane: u32, depth: u32, index: u32, cmd: bool, shift: bool },
};

/// The path an action owns, if it has one.
fn ownedPath(a: *Action) ?*[]const u8 {
    return switch (a.*) {
        .open => |*p| p,
        .open_in_new_tab => |*p| p,
        .open_file => |*p| p,
        .toggle_expand => |*e| &e.path,
        else => null,
    };
}

/// What the view keeps between frames that is not model data.
pub const ViewState = struct {
    /// The divider under the pointer's drag, and where the pointer last was along it.
    divider: ?struct { split: u32, index: u32, last: f32 } = null,
    /// A tab pressed: it follows the pointer along the strip once the pointer has moved.
    tab_drag: ?struct { tab: TabRef, start_x: f32, moving: bool } = null,
    /// A column's divider pressed: which one, and where the pointer last was.
    col_drag: ?struct { pane: u32, depth: u32, last: f32 } = null,
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
    /// Opens files; see `Config.opener`.
    opener: ?opener.OpenFn = null,
    /// What type-to-select has heard lately.
    typeahead: TypeAhead = .{},

    pub fn init(gpa: Allocator, cfg: Config) Allocator.Error!Model {
        const home = try normalize(gpa, cfg.home_path);
        errdefer gpa.free(home);
        var sb = try sidebar_model.Sidebar.init(gpa, home, cfg.favorites, cfg.pinned, cfg.locations);
        errdefer sb.deinit();
        const start = try normalize(gpa, cfg.start_path);
        defer gpa.free(start);
        var pane = try Pane.init(gpa, start, .{ .show_hidden = cfg.show_hidden }, .{ .pane = 1, .tab = 2 });
        errdefer pane.deinit();
        var m: Model = .{ .gpa = gpa, .home = home, .sidebar = sb, .show_hidden = cfg.show_hidden, .layout = .{ .leaf = pane.id }, .next_id = 3, .opener = cfg.opener };
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
        if (ownedPath(&act)) |p| p.* = try self.gpa.dupe(u8, p.*);
        errdefer if (ownedPath(&act)) |p| self.gpa.free(p.*);
        try self.pending.append(self.gpa, act);
    }

    fn clearPending(self: *Model) void {
        for (self.pending.items) |*a| if (ownedPath(a)) |p| self.gpa.free(p.*);
        self.pending.clearRetainingCapacity();
    }

    /// Runs the queued actions in order; true if there were any.
    pub fn applyPending(self: *Model) Allocator.Error!bool {
        self.freeRetired();
        try nav_ops.syncColumns(self); // the shown tabs of column-view panes match their folders
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
            .set_view_mode => |mode| try nav_ops.setViewMode(self, mode),
            .nav => |n| try nav_ops.key(self, n.key, n.shift),
            .type_select => |t| try nav_ops.typeSelect(self, t.key, t.time),
            .open_selection => try nav_ops.openSelection(self),
            .open_file => |p| try self.openFile(p),
            .toggle_expand => |e| try nav_ops.toggleExpand(self, e.pane, e.path),
            .column_click => |c| try nav_ops.columnClick(self, c.pane, c.depth, c.index, .{ .cmd = c.cmd, .shift = c.shift }),
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

    /// Double-click on row `index` of the focused tab's list: a folder opens, a file opens in
    /// its app.
    pub fn openItem(self: *Model, index: usize) Allocator.Error!void {
        const items = self.focusedTab().exp.items;
        if (index >= items.len) return;
        if (items[index].is_directory) try self.navigate(items[index].path) else try self.openFile(items[index].path);
    }

    /// Opens a file in its default app through the injected opener (none: nothing happens); a
    /// failure raises a notice.
    pub fn openFile(self: *Model, path: []const u8) Allocator.Error!void {
        const f = self.opener orelse return;
        if (f(path)) return;
        const msg = try std.fmt.allocPrint(self.gpa, "Can't open \"{s}\".", .{std.fs.path.basename(path)});
        self.clearNotice();
        self.notice = msg;
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
