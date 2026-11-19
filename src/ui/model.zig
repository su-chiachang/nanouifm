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
const nanoui = @import("nanoui");
const file_ops = @import("../core/file_ops.zig");
const Clipboard = @import("clipboard.zig").Clipboard;
const Hooks = @import("hooks.zig").Hooks;
const rename = @import("rename.zig");
const watch = @import("watch.zig");
const goto = @import("goto.zig");
const context_menu = @import("context_menu.zig");
const commands = @import("commands.zig");
const file_actions = @import("file_actions.zig");
const CommandId = @import("command_id.zig").Id;
const palette_model = @import("palette_model.zig");
const palette_index = @import("palette_index.zig");
const palette_exec = @import("palette_exec.zig");
const palette_ops = @import("palette_ops.zig");
const filter_ops = @import("filter_ops.zig");
const toolbar_menu = @import("toolbar_menu.zig");
const persist = @import("persist.zig");
const volumes = @import("volumes.zig");
const sidebar_ops = @import("sidebar_ops.zig");
const menu_link = @import("menu_link.zig");
const state_model = @import("../core/state_model.zig");
const sidebar_menu = @import("sidebar_menu.zig");
const preview_state = @import("preview_state.zig");

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
    /// Clipboard mirror, Reveal in Finder, Option state: see `hooks.zig`. Empty in tests.
    hooks: Hooks = .{},
    /// Live refresh: `.off` (default), `.manual` (tests fire changes), `.system` (main.zig).
    watch: watch.Mode = .off,
    /// The command palette's file index: null (default, tests) builds none; main.zig passes the
    /// roots and a thread, tests their temp folders and a runner of their own.
    index: ?palette_index.Config = null,
    /// Where favorites, pinned, the layout and the settings are kept (`persist.zig`); null: nothing
    /// is read or written. main.zig passes the real one, tests a store over a temp folder.
    store: ?*persist.Store = null,
    /// The mounted volumes (`volumes.zig`): the Locations follow it. Null: `locations` stay as given.
    volumes: ?volumes.Provider = null,
};

/// Files to move or copy into a folder (a drop from Finder or another pane).
pub const DropJob = struct {
    paths: []const []const u8,
    dest: []const u8,
    /// Option held: copy instead of move.
    copy: bool = false,
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
    /// A command of the registry (`commands.zig`): shortcuts, menus and the palette all queue this.
    run_command: CommandId,
    /// Return, or the keyboard leaving the field, in the inline rename.
    commit_rename,
    /// Escape in the inline rename.
    cancel_rename,
    /// Files dropped on a folder (the paths and the folder are owned by the queue).
    drop_files: DropJob,
    /// The toolbar's filter field of this pane changed: its tabs are listed again by name.
    apply_filter: u32,
    /// The palette chose a folder or a file (the path is owned by the queue).
    palette_open: palette_model.Open,
    /// Open in Split from the sidebar: a pane docked beside the focused one (path owned by the queue).
    open_in_split: []const u8,
    /// Remove from Sidebar: the favorite or pin with this id.
    sidebar_remove: state_model.Uuid,
    /// A folder dropped on Favorites or Pinned (path owned by the queue), at a row or the end.
    sidebar_add: SidebarAdd,
    /// Drag to reorder: the entry goes to this row of the section (possibly the other one).
    sidebar_move: struct { id: state_model.Uuid, kind: sidebar_model.SectionKind, to: u32 },
    /// The eject button of a volume (path owned by the queue).
    eject: []const u8,
};

pub const SidebarAdd = struct { path: []const u8, kind: sidebar_model.SectionKind, at: ?u32 = null };

/// A copy of `a` that owns its strings (what `Model.queue` keeps), and the matching free.
fn dupeOwned(gpa: Allocator, a: Action) Allocator.Error!Action {
    var act = a;
    switch (act) {
        .open, .open_in_new_tab, .open_file, .open_in_split, .eject => |*p| p.* = try gpa.dupe(u8, p.*),
        .sidebar_add => |*sa| sa.path = try gpa.dupe(u8, sa.path),
        .toggle_expand => |*e| e.path = try gpa.dupe(u8, e.path),
        .palette_open => |*o| o.path = try gpa.dupe(u8, o.path),
        .drop_files => |*d| {
            const dest = try gpa.dupe(u8, d.dest);
            errdefer gpa.free(dest);
            const paths = try gpa.alloc([]const u8, d.paths.len);
            var made: usize = 0;
            errdefer {
                for (paths[0..made]) |p| gpa.free(p);
                gpa.free(paths);
            }
            for (d.paths, paths) |src, *dst| {
                dst.* = try gpa.dupe(u8, src);
                made += 1;
            }
            d.* = .{ .paths = paths, .dest = dest, .copy = d.copy };
        },
        else => {},
    }
    return act;
}

fn freeOwned(gpa: Allocator, a: Action) void {
    switch (a) {
        .open, .open_in_new_tab, .open_file, .open_in_split, .eject => |p| gpa.free(p),
        .sidebar_add => |sa| gpa.free(sa.path),
        .toggle_expand => |e| gpa.free(e.path),
        .palette_open => |o| gpa.free(o.path),
        .drop_files => |d| {
            for (d.paths) |p| gpa.free(p);
            gpa.free(d.paths);
            gpa.free(d.dest);
        },
        else => {},
    }
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
    /// The context menu: open, where (window points), which pane, and what was right-clicked.
    ctx_menu: context_menu.State = .{},
    /// A drag of files from a pane's rows (pane-to-pane): the pane they come from.
    file_drag: ?u32 = null,
    /// The layout button's rectangle (window points), where its popover hangs.
    layout_anchor: ?pane_sizes.Rect = null,
    /// The toolbar's Sort and "..." menus (one open at a time, in one pane).
    toolbar_menu: toolbar_menu.State = .{},
    /// Cmd+F: the pane whose filter field takes the keyboard in the next frame.
    focus_filter: ?u32 = null,
    /// The command palette (Cmd+K).
    palette: palette_model.State = .{},
    /// The sidebar's context menu.
    sidebar_menu: sidebar_menu.State = .{},
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
    /// The sidebar is shown (Ctrl+Cmd+S); persisted.
    sidebar_visible: bool = true,
    /// A message for the banner above the list (a folder that couldn't be opened).
    notice: ?[]u8 = null,
    pending: std.ArrayList(Action) = .empty,
    /// Opens files; see `Config.opener`.
    opener: ?opener.OpenFn = null,
    /// What type-to-select has heard lately.
    typeahead: TypeAhead = .{},
    /// Every undoable file operation goes through this (undo/redo stacks, failure detail).
    ops: file_ops.FileOperationService,
    /// Copy's files; Paste reads this (see `clipboard.zig`).
    clip: Clipboard,
    hooks: Hooks = .{},
    /// The inline rename in progress, if any.
    rename: ?rename.Session = null,
    /// Live refresh's watchers (`watch.zig`).
    watch: watch.Watchers,
    /// Go to Folder's dialog.
    goto: goto.State = .{},
    /// How a watcher callback wakes a frame; copied from the context each pass.
    waker: ?watch.Waker = null,
    /// The frame clock (seconds), copied from the context each pass: the palette's index ages by it.
    clock: f64 = 0,
    /// The state file (`persist.zig`).
    persist: persist.State = .{},
    /// The mounted volumes, and what tells us they changed (`volumes.zig`; on the heap for the
    /// system's notification callbacks).
    volumes: ?volumes.Provider = null,
    vol_signal: *volumes.Signal,
    /// The native menu bar's link to the model (`menu_link.zig`): null callbacks in tests.
    menu: menu_link.State = .{},
    /// A text field had the keyboard in the last frame: file commands from the menu wait.
    text_focus: bool = false,
    /// Thumbnails, picture sizes and Quick Look's bookkeeping (`preview_state.zig`).
    preview: preview_state.State,

    pub fn init(gpa: Allocator, cfg: Config) Allocator.Error!Model {
        const home = try normalize(gpa, cfg.home_path);
        errdefer gpa.free(home);
        var sb = try sidebar_model.Sidebar.init(gpa, home, cfg.favorites, cfg.pinned, cfg.locations);
        errdefer sb.deinit();
        const signal = try gpa.create(volumes.Signal);
        signal.* = .{};
        errdefer gpa.destroy(signal);
        const start = try normalize(gpa, cfg.start_path);
        defer gpa.free(start);
        var pane = try Pane.init(gpa, start, .{ .show_hidden = cfg.show_hidden }, .{ .pane = 1, .tab = 2 });
        errdefer pane.deinit();
        var pv = try preview_state.State.init(gpa);
        errdefer pv.deinit(gpa);
        var m: Model = .{ .preview = pv, .gpa = gpa, .home = home, .sidebar = sb, .show_hidden = cfg.show_hidden, .layout = .{ .leaf = pane.id }, .next_id = 3, .opener = cfg.opener, .ops = file_ops.FileOperationService.init(gpa), .clip = Clipboard.init(gpa), .hooks = cfg.hooks, .watch = watch.Watchers.init(gpa, cfg.watch), .volumes = cfg.volumes, .vol_signal = signal };
        errdefer m.ops.deinit();
        errdefer m.clip.deinit();
        errdefer m.watch.deinit();
        errdefer m.sizes.deinit(gpa);
        try m.sizes.reset(gpa, &m.layout);
        try m.panes.append(gpa, pane);
        errdefer m.panes.deinit(gpa);
        try m.view_state.palette.index.configure(gpa, cfg.index);
        try sidebar_ops.refreshVolumes(&m);
        m.persist.store = cfg.store;
        errdefer m.persist.deinit(gpa);
        if (cfg.store) |store| {
            m.sidebar.io = store.io;
            try persist.restore(&m);
        }
        return m;
    }

    pub fn deinit(self: *Model) void {
        self.clearPending();
        self.pending.deinit(self.gpa);
        self.freeRetired();
        self.retired_panes.deinit(self.gpa);
        self.retired_tabs.deinit(self.gpa);
        if (self.notice) |n| self.gpa.free(n);
        if (self.rename) |*r| r.deinit(self.gpa);
        self.goto.deinit();
        self.view_state.palette.deinit(self.gpa);
        self.watch.deinit();
        self.clip.deinit();
        self.ops.deinit();
        for (self.panes.items) |*p| p.deinit();
        self.panes.deinit(self.gpa);
        self.layout.deinit(self.gpa);
        self.sizes.deinit(self.gpa);
        self.persist.deinit(self.gpa);
        self.preview.deinit(self.gpa);
        self.gpa.destroy(self.vol_signal);
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
        const act = try dupeOwned(self.gpa, a);
        errdefer freeOwned(self.gpa, act);
        try self.pending.append(self.gpa, act);
    }

    fn clearPending(self: *Model) void {
        for (self.pending.items) |a| freeOwned(self.gpa, a);
        self.pending.clearRetainingCapacity();
    }

    /// Runs the queued actions in order; true if there were any.
    pub fn applyPending(self: *Model) Allocator.Error!bool {
        self.freeRetired();
        self.view_state.palette.freeRetired();
        _ = self.preview.thumbs.merge(); // thumbnails that arrived since the last pass
        if (self.vol_signal.take()) try sidebar_ops.refreshVolumes(self); // a mount, an unmount, a rename
        try nav_ops.syncColumns(self); // the shown tabs of column-view panes match their folders
        var changed = try self.watch.refreshDirty(self); // folders that changed on disk
        defer self.watch.reconcile(self) catch {}; // watch what is drawn after this pass
        defer filter_ops.syncNavigation(self) catch {}; // a folder left behind takes its filter along
        defer palette_ops.sync(self); // the palette's file index follows the sidebar's folders
        if (self.pending.items.len == 0) return changed;
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
            .run_command => |id| try commands.run(self, id),
            .commit_rename => try rename.commit(self),
            .cancel_rename => rename.cancel(self),
            .drop_files => |d| try file_actions.drop(self, d),
            .apply_filter => |id| try filter_ops.apply(self, id),
            .palette_open => |o| try palette_exec.open(self, o),
            .open_in_split => |p| try sidebar_ops.openInSplit(self, p),
            .sidebar_remove => |id| sidebar_ops.remove(self, id),
            .sidebar_add => |sa| try sidebar_ops.add(self, sa),
            .sidebar_move => |mv| try self.sidebar.moveEntry(mv.id, mv.kind, mv.to),
            .eject => |p| try sidebar_ops.eject(self, p),
        };
        rename.validate(self);
        changed = true;
        persist.noteChange(self);
        return changed;
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

    /// Puts `text` in the banner (copied).
    pub fn raise(self: *Model, text: []const u8) Allocator.Error!void {
        const msg = try self.gpa.dupe(u8, text);
        self.clearNotice();
        self.notice = msg;
    }

    /// Whether there is something to paste: Copy's files, or (the real app) files another app put
    /// on the system pasteboard since.
    pub fn canPaste(self: *const Model) bool {
        if (!self.clip.isEmpty()) return true;
        const cc = self.hooks.change_count orelse return false;
        return self.hooks.read_files != null and cc() != self.clip.mirrored;
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

    /// Writes the state file now if it differs (the app quitting).
    pub fn flushState(self: *Model) void {
        persist.flush(self);
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
