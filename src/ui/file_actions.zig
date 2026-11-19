//! File commands on the focused pane, all through `FileOperationService` (the model's `ops`), so
//! every change is undoable and every refusal is a banner (`Model.notice`) in the service's own
//! words. After a change the tabs that show the touched folders are read again, and what the
//! change produced is selected and scrolled into sight. Run by `commands.zig` from
//! `Model.applyPending`. Delete is only ever Trash.
const std = @import("std");
const Allocator = std.mem.Allocator;
const file_ops = @import("../core/file_ops.zig");
const fs = @import("../core/file_ops_fs.zig");
const model_mod = @import("model.zig");
const Model = model_mod.Model;
const DropJob = model_mod.DropJob;
const target = @import("file_target.zig");
const refresh = @import("file_refresh.zig");
const rename = @import("rename.zig");
const tab_ops = @import("tab_ops.zig");
const layout_ops = @import("layout_ops.zig");

/// The banner for a refused operation, from the service's description of it.
pub fn reportFailure(m: *Model, e: file_ops.Error) Allocator.Error!void {
    if (e == error.OutOfMemory) return error.OutOfMemory;
    var buf: [1500]u8 = undefined;
    try m.raise(m.ops.describeFailure(&buf));
}

/// Copies of the selected paths in `arena` (the listings are free to be reread meanwhile).
fn selection(arena: Allocator, m: *Model) Allocator.Error![]const []const u8 {
    const paths = try target.selectedPaths(arena, m.focusedPane());
    for (paths) |*p| p.* = try arena.dupe(u8, p.*);
    return paths;
}

/// The selection, or the folder shown when nothing is selected (Copy Path, Reveal).
fn selectionOrFolder(arena: Allocator, m: *Model) Allocator.Error![]const []const u8 {
    const paths = try selection(arena, m);
    if (paths.len > 0) return paths;
    const one = try arena.alloc([]const u8, 1);
    one[0] = try arena.dupe(u8, target.shown(m.focusedPane()).folder);
    return one;
}

pub fn newFolder(m: *Model) Allocator.Error!void {
    const pane_id = m.focusedPane().id;
    const dir = try m.gpa.dupe(u8, target.shown(m.focusedPane()).folder);
    defer m.gpa.free(dir);
    const created = m.ops.createFolder(dir, file_ops.default_folder_name) catch |e| return reportFailure(m, e);
    defer m.gpa.free(created);
    m.clearNotice();
    try refresh.folders(m, &.{dir});
    try refresh.select(m, m.focused, &.{created});
    try rename.beginAt(m, pane_id, created, true);
}

pub fn duplicate(m: *Model) Allocator.Error!void {
    var arena = std.heap.ArenaAllocator.init(m.gpa);
    defer arena.deinit();
    const paths = try selection(arena.allocator(), m);
    if (paths.len == 0) return;
    const made = m.ops.duplicate(paths) catch |e| return reportFailure(m, e);
    defer file_ops.freePaths(m.gpa, made);
    m.clearNotice();
    try refresh.parents(m, made);
    try refresh.select(m, m.focused, made);
}

/// Move to Trash. The selection goes with the files; the row after them is not selected.
pub fn trash(m: *Model) Allocator.Error!void {
    var arena = std.heap.ArenaAllocator.init(m.gpa);
    defer arena.deinit();
    const paths = try selection(arena.allocator(), m);
    if (paths.len == 0) return;
    m.ops.trash(paths) catch |e| return reportFailure(m, e);
    m.clearNotice();
    try refresh.parents(m, paths);
}

pub fn copy(m: *Model) Allocator.Error!void {
    var arena = std.heap.ArenaAllocator.init(m.gpa);
    defer arena.deinit();
    const paths = try selection(arena.allocator(), m);
    if (paths.len == 0) return;
    try m.clip.set(paths);
    if (m.hooks.copy_files) |f| {
        f(paths);
        if (m.hooks.change_count) |cc| m.clip.mirrored = cc();
    }
}

/// The files to paste: Copy's, unless something else put files on the system pasteboard since
/// (only when the hooks exist: the real app). Owned by `arena`.
fn pasteSources(arena: Allocator, m: *Model) Allocator.Error![]const []const u8 {
    if (m.hooks.change_count) |cc| if (m.hooks.read_files) |read| {
        if (cc() != m.clip.mirrored) if (read(m.gpa)) |sys| {
            defer @import("hooks.zig").Hooks.freePaths(m.gpa, sys);
            const out = try arena.alloc([]const u8, sys.len);
            for (sys, out) |p, *o| o.* = try arena.dupe(u8, p);
            return out;
        };
    };
    const out = try arena.alloc([]const u8, m.clip.paths.items.len);
    for (m.clip.paths.items, out) |p, *o| o.* = try arena.dupe(u8, p);
    return out;
}

fn allIn(paths: []const []const u8, folder: []const u8) bool {
    for (paths) |p| {
        const d = std.fs.path.dirname(p) orelse return false;
        if (!std.mem.eql(u8, d, folder)) return false;
    }
    return paths.len > 0;
}

/// Cmd+V (a copy, names made unique) and Opt+Cmd+V (a move) into the folder the pane shows.
pub fn paste(m: *Model, move: bool) Allocator.Error!void {
    var arena = std.heap.ArenaAllocator.init(m.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const srcs = try pasteSources(a, m);
    if (srcs.len == 0) return;
    const dest = try a.dupe(u8, target.shown(m.focusedPane()).folder);
    try transfer(m, srcs, dest, move, true);
    if (move and m.notice == null) m.clip.clear();
}

/// Moves or copies `srcs` into `dest`, then refreshes and selects what arrived (in the pane
/// showing `dest`, if any). `say_noop`: a move into the folder the items are in raises a notice
/// (Paste), else it silently does nothing (a drop).
fn transfer(m: *Model, srcs: []const []const u8, dest: []const u8, move: bool, say_noop: bool) Allocator.Error!void {
    if (move and allIn(srcs, dest)) {
        if (!say_noop) return;
        var buf: [600]u8 = undefined;
        const name = std.fs.path.basename(dest);
        return m.raise(std.fmt.bufPrint(&buf, "The items are already in \u{201C}{s}\u{201D}.", .{if (name.len == 0) dest else name}) catch "The items are already there.");
    }
    const made = (if (move) m.ops.move(srcs, dest) else m.ops.copy(srcs, dest)) catch |e| return reportFailure(m, e);
    defer file_ops.freePaths(m.gpa, made);
    m.clearNotice();
    try refresh.parents(m, srcs);
    try refresh.folders(m, &.{dest});
    for (m.panes.items, 0..) |*p, i| {
        if (std.mem.eql(u8, target.shown(p).folder, dest)) return refresh.select(m, i, made);
    }
}

/// Whether any of `paths` is on another volume than folder `dest` (a move can't cross volumes,
/// and dragging from one is a copy, as in Finder).
pub fn otherVolume(paths: []const []const u8, dest: []const u8) bool {
    const d = fs.lstat(dest) orelse return false;
    for (paths) |p| {
        const st = fs.lstat(p) orelse continue;
        if (st.dev != d.dev) return true;
    }
    return false;
}

/// Files dropped on a folder (from Finder or another pane): a move, or a copy with Option or
/// when they come from another volume.
pub fn drop(m: *Model, job: DropJob) Allocator.Error!void {
    if (job.paths.len == 0) return;
    try transfer(m, job.paths, job.dest, !(job.copy or otherVolume(job.paths, job.dest)), false);
}

/// Copy Path: the selected paths (or the folder's), one per line, as text on the clipboard.
pub fn copyPath(m: *Model) Allocator.Error!void {
    const put = m.hooks.copy_text orelse return;
    var arena = std.heap.ArenaAllocator.init(m.gpa);
    defer arena.deinit();
    const paths = try selectionOrFolder(arena.allocator(), m);
    put(try std.mem.join(arena.allocator(), "\n", paths));
}

pub fn reveal(m: *Model) Allocator.Error!void {
    const f = m.hooks.reveal orelse return;
    var arena = std.heap.ArenaAllocator.init(m.gpa);
    defer arena.deinit();
    f(try selectionOrFolder(arena.allocator(), m));
}

/// Pin to Sidebar: the selected folders, or the folder shown.
pub fn pin(m: *Model) Allocator.Error!void {
    var arena = std.heap.ArenaAllocator.init(m.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var folders = try target.selectedFolders(a, m.focusedPane());
    if (target.count(m.focusedPane()) == 0) {
        folders = try a.dupe([]const u8, &.{target.shown(m.focusedPane()).folder});
    } else if (folders.len == 0) {
        return m.raise("Only folders can be pinned to the sidebar.");
    }
    for (folders) |f| try m.sidebar.pin(f);
}

pub fn undo(m: *Model) Allocator.Error!void {
    m.ops.undo() catch |e| {
        try reportFailure(m, e);
        return refresh.all(m);
    };
    m.clearNotice();
    try refresh.all(m);
}

pub fn redo(m: *Model) Allocator.Error!void {
    m.ops.redo() catch |e| {
        try reportFailure(m, e);
        return refresh.all(m);
    };
    m.clearNotice();
    try refresh.all(m);
}

pub fn selectAll(m: *Model) Allocator.Error!void {
    const s = target.shown(m.focusedPane());
    if (s.items.len == 0) return;
    var arena = std.heap.ArenaAllocator.init(m.gpa);
    defer arena.deinit();
    const paths = try arena.allocator().alloc([]const u8, s.items.len);
    for (s.items, paths) |it, *p| p.* = try arena.allocator().dupe(u8, it.path);
    try refresh.select(m, m.focused, paths);
}

/// Open in New Tab: each selected folder in a tab of its own (the folder shown when nothing is
/// selected).
pub fn openInNewTab(m: *Model) Allocator.Error!void {
    var arena = std.heap.ArenaAllocator.init(m.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var folders = try target.selectedFolders(a, m.focusedPane());
    if (folders.len == 0) {
        if (target.count(m.focusedPane()) > 0) return;
        folders = try a.dupe([]const u8, &.{target.shown(m.focusedPane()).folder});
    }
    for (folders) |f| try tab_ops.openInNewTab(m, f);
}

/// Open in Split: each selected folder in a pane docked beside the focused one.
pub fn openInSplit(m: *Model) Allocator.Error!void {
    var arena = std.heap.ArenaAllocator.init(m.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var folders = try target.selectedFolders(a, m.focusedPane());
    if (folders.len == 0) {
        if (target.count(m.focusedPane()) > 0) return;
        folders = try a.dupe([]const u8, &.{target.shown(m.focusedPane()).folder});
    }
    for (folders) |f| try layout_ops.dock(m, m.focused, .right, f);
}
