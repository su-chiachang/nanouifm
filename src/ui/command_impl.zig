//! What the commands do and when they apply: the predicates (`enabled`, `checked`, titles) and the
//! `run` functions the table in `commands.zig` points at. File work is in `file_actions.zig`,
//! pane and tab work in `tab_ops.zig` / `layout_ops.zig` / `nav_ops.zig`.
const std = @import("std");
const Allocator = std.mem.Allocator;
const model_mod = @import("model.zig");
const Model = model_mod.Model;
const pane_layout = @import("../core/pane_layout.zig");
const lister = @import("../core/lister.zig");
const target = @import("file_target.zig");
const file_actions = @import("file_actions.zig");
const rename = @import("rename.zig");
const tab_ops = @import("tab_ops.zig");
const layout_ops = @import("layout_ops.zig");
const nav_ops = @import("nav_ops.zig");
const goto = @import("goto.zig");
const filter_ops = @import("filter_ops.zig");
const palette_ops = @import("palette_ops.zig");
const sidebar_ops = @import("sidebar_ops.zig");
const quick_look = @import("quick_look.zig");
const inspector_ops = @import("inspector_ops.zig");
const open_with = @import("open_with.zig");
const Pred = @import("command.zig").Pred;

// ---- predicates ----

pub fn hasSelection(m: *Model) bool {
    return target.count(m.focusedPane()) > 0;
}

pub fn hasSingle(m: *Model) bool {
    return target.count(m.focusedPane()) == 1;
}

/// Open in New Tab / Split: selected folders, or the folder shown when nothing is selected.
pub fn hasFolderTarget(m: *Model) bool {
    const pane = m.focusedPane();
    if (target.count(pane) == 0) return true;
    var arena = std.heap.ArenaAllocator.init(m.gpa);
    defer arena.deinit();
    const f = target.selectedFolders(arena.allocator(), pane) catch return false;
    return f.len > 0;
}

/// Pin to Sidebar: the folder shown when nothing is selected, else needs a selected folder.
pub fn canPin(m: *Model) bool {
    return target.count(m.focusedPane()) == 0 or hasFolderTarget(m);
}

pub fn canUndo(m: *Model) bool {
    return m.ops.canUndo();
}

pub fn canRedo(m: *Model) bool {
    return m.ops.canRedo();
}

pub fn canPaste(m: *Model) bool {
    return m.canPaste();
}

pub fn canQuickLook(m: *Model) bool {
    return quick_look.canRun(m);
}

pub fn inspectorTitle(m: *Model, _: []u8) []const u8 {
    return if (inspector_ops.isOn(m)) "Hide Inspector" else "Show Inspector";
}

pub fn manyPanes(m: *Model) bool {
    return m.panes.items.len > 1;
}

pub fn canBack(m: *Model) bool {
    return m.focusedTab().canBack();
}

pub fn canForward(m: *Model) bool {
    return m.focusedTab().canForward();
}

pub fn canUp(m: *Model) bool {
    return m.canUp();
}

pub fn isList(m: *Model) bool {
    return m.focusedPane().view_mode == .list;
}

pub fn isColumn(m: *Model) bool {
    return m.focusedPane().view_mode == .column;
}

pub fn showsHidden(m: *Model) bool {
    return m.show_hidden;
}

pub fn sortedBy(comptime key: lister.SortKey) Pred {
    return struct {
        fn f(m: *Model) bool {
            return m.focusedPane().sort.key == key;
        }
    }.f;
}

pub fn isAscending(m: *Model) bool {
    return m.focusedPane().sort.ascending;
}

pub fn isDescending(m: *Model) bool {
    return !m.focusedPane().sort.ascending;
}

pub fn foldersFirst(m: *Model) bool {
    return m.focusedPane().sort.folders_first;
}

pub fn layoutIs(comptime preset: pane_layout.LayoutPreset) Pred {
    return struct {
        fn f(m: *Model) bool {
            var arena = std.heap.ArenaAllocator.init(m.gpa);
            defer arena.deinit();
            const cur = pane_layout.LayoutPreset.matching(arena.allocator(), &m.layout) catch return false;
            return cur != null and cur.? == preset;
        }
    }.f;
}

pub fn sidebarTitle(m: *Model, _: []u8) []const u8 {
    return if (m.sidebar_visible) "Hide Sidebar" else "Show Sidebar";
}

pub fn undoTitle(m: *Model, buf: []u8) []const u8 {
    const t = m.ops.undoTitle() orelse return "Undo";
    return std.fmt.bufPrint(buf, "Undo {s}", .{t}) catch "Undo";
}

pub fn redoTitle(m: *Model, buf: []u8) []const u8 {
    const t = m.ops.redoTitle() orelse return "Redo";
    return std.fmt.bufPrint(buf, "Redo {s}", .{t}) catch "Redo";
}

// ---- actions ----

pub fn newTab(m: *Model) Allocator.Error!void {
    return tab_ops.newTab(m);
}
pub fn closeTab(m: *Model) Allocator.Error!void {
    return tab_ops.closeActiveTab(m);
}
pub fn closePane(m: *Model) Allocator.Error!void {
    if (m.panes.items.len > 1) try layout_ops.closePane(m, m.focused);
}
pub fn newFolder(m: *Model) Allocator.Error!void {
    return file_actions.newFolder(m);
}
pub fn open(m: *Model) Allocator.Error!void {
    return nav_ops.openSelection(m);
}
pub fn openNewTab(m: *Model) Allocator.Error!void {
    return file_actions.openInNewTab(m);
}
pub fn openSplit(m: *Model) Allocator.Error!void {
    return file_actions.openInSplit(m);
}
pub fn beginRename(m: *Model) Allocator.Error!void {
    return rename.begin(m);
}
pub fn duplicate(m: *Model) Allocator.Error!void {
    return file_actions.duplicate(m);
}
pub fn trash(m: *Model) Allocator.Error!void {
    return file_actions.trash(m);
}
pub fn reveal(m: *Model) Allocator.Error!void {
    return file_actions.reveal(m);
}
pub fn copyPath(m: *Model) Allocator.Error!void {
    return file_actions.copyPath(m);
}
pub fn pin(m: *Model) Allocator.Error!void {
    return file_actions.pin(m);
}
pub fn addFavorite(m: *Model) Allocator.Error!void {
    return sidebar_ops.addFavorite(m);
}
pub fn quickLook(m: *Model) Allocator.Error!void {
    return quick_look.toggle(m);
}
pub fn share(m: *Model) Allocator.Error!void {
    return inspector_ops.share(m);
}
pub fn toggleInspector(m: *Model) Allocator.Error!void {
    return inspector_ops.toggle(m);
}
pub fn toggleSidebar(m: *Model) Allocator.Error!void {
    m.sidebar_visible = !m.sidebar_visible;
}
pub fn undo(m: *Model) Allocator.Error!void {
    return file_actions.undo(m);
}
pub fn redo(m: *Model) Allocator.Error!void {
    return file_actions.redo(m);
}
pub fn copy(m: *Model) Allocator.Error!void {
    return file_actions.copy(m);
}
pub fn paste(m: *Model) Allocator.Error!void {
    return file_actions.paste(m, false);
}
pub fn pasteMove(m: *Model) Allocator.Error!void {
    return file_actions.paste(m, true);
}
pub fn selectAll(m: *Model) Allocator.Error!void {
    return file_actions.selectAll(m);
}
pub fn viewList(m: *Model) Allocator.Error!void {
    return nav_ops.setViewMode(m, .list);
}
pub fn viewColumn(m: *Model) Allocator.Error!void {
    return nav_ops.setViewMode(m, .column);
}
pub fn sort(comptime key: lister.SortKey) *const fn (*Model) Allocator.Error!void {
    return struct {
        fn f(m: *Model) Allocator.Error!void {
            try m.focusedPane().sortBy(key, m.show_hidden);
        }
    }.f;
}
pub fn setAscending(comptime ascending: bool) *const fn (*Model) Allocator.Error!void {
    return struct {
        fn f(m: *Model) Allocator.Error!void {
            try m.focusedPane().setAscending(ascending, m.show_hidden);
        }
    }.f;
}
pub fn toggleFoldersFirst(m: *Model) Allocator.Error!void {
    try m.focusedPane().toggleFoldersFirst(m.show_hidden);
}
pub fn focusFilter(m: *Model) Allocator.Error!void {
    filter_ops.focus(m);
}
pub fn togglePalette(m: *Model) Allocator.Error!void {
    try palette_ops.toggle(m);
}
pub fn toggleHidden(m: *Model) Allocator.Error!void {
    return m.setShowHidden(!m.show_hidden);
}
pub fn splitSide(m: *Model) Allocator.Error!void {
    return layout_ops.split(m, .side_by_side);
}
pub fn splitStacked(m: *Model) Allocator.Error!void {
    return layout_ops.split(m, .stacked);
}
pub fn canOpenWith(comptime n: usize) Pred {
    return struct {
        fn f(m: *Model) bool {
            return open_with.canOpen(m, n);
        }
    }.f;
}

pub fn openWith(comptime n: usize) *const fn (*Model) Allocator.Error!void {
    return struct {
        fn f(m: *Model) Allocator.Error!void {
            return open_with.openWith(m, n);
        }
    }.f;
}

pub fn layout(comptime preset: pane_layout.LayoutPreset) *const fn (*Model) Allocator.Error!void {
    return struct {
        fn f(m: *Model) Allocator.Error!void {
            return layout_ops.applyPreset(m, preset);
        }
    }.f;
}
pub fn back(m: *Model) Allocator.Error!void {
    return m.back();
}
pub fn forward(m: *Model) Allocator.Error!void {
    return m.forward();
}
pub fn up(m: *Model) Allocator.Error!void {
    return m.up();
}
pub fn tabNext(m: *Model) Allocator.Error!void {
    m.focusedPane().cycleTab(1);
}
pub fn tabPrev(m: *Model) Allocator.Error!void {
    m.focusedPane().cycleTab(-1);
}
pub fn focusNext(m: *Model) Allocator.Error!void {
    layout_ops.focusMove(m, 1);
}
pub fn focusPrev(m: *Model) Allocator.Error!void {
    layout_ops.focusMove(m, -1);
}
pub fn goToFolder(m: *Model) Allocator.Error!void {
    goto.open(m);
}

/// Go to one of the places under Home (or an absolute one: Applications).
pub fn place(comptime sub: []const u8) *const fn (*Model) Allocator.Error!void {
    return struct {
        fn f(m: *Model) Allocator.Error!void {
            if (sub.len > 0 and sub[0] == '/') return m.navigate(sub);
            if (sub.len == 0) return m.navigate(m.home);
            const p = try std.fs.path.join(m.gpa, &.{ m.home, sub });
            defer m.gpa.free(p);
            try m.navigate(p);
        }
    }.f;
}
