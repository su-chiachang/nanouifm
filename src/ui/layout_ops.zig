//! Pane operations on the model: docking a new pane beside the focused one, closing a pane,
//! moving the focus, and rearranging into a layout preset. The tree arithmetic is the core's
//! (`LayoutTree.docking`/`removing`, `LayoutPreset.arranged`, `PresetPlan`); this file keeps the
//! model's panes in step with it.
//!
//! Every operation does its allocating work first and then commits in one step that cannot
//! fail, so an out-of-memory error leaves the model as it was.
const std = @import("std");
const Allocator = std.mem.Allocator;
const pane_layout = @import("../core/pane_layout.zig");
const model_mod = @import("model.zig");
const Model = model_mod.Model;
const Pane = @import("pane.zig").Pane;
const pane_sizes = @import("pane_sizes.zig");
const Tree = pane_sizes.Tree;

const SplitAxis = pane_layout.SplitAxis;
const LayoutPreset = pane_layout.LayoutPreset;

/// Makes `new_tree` the layout (taking ownership of it and of the panes in `fresh`, which are not
/// in `m.panes` yet): the panes are put in its reading order, panes it no longer has are retired,
/// the weights start equal, and the pane with id `focus_id` is focused (else the first).
/// On error nothing has changed and the caller still owns `new_tree` and `fresh`.
fn adopt(m: *Model, new_tree: *Tree, fresh: []const Pane, focus_id: u32) Allocator.Error!void {
    const gpa = m.gpa;
    const leaves = try new_tree.leaves(gpa);
    defer gpa.free(leaves);
    var sizes: pane_sizes.Sizes = .{};
    errdefer sizes.deinit(gpa);
    try sizes.reset(gpa, new_tree);
    var ordered: std.ArrayList(Pane) = .empty;
    errdefer ordered.deinit(gpa);
    try ordered.ensureTotalCapacityPrecise(gpa, leaves.len);
    try m.retired_panes.ensureUnusedCapacity(gpa, m.panes.items.len);

    // Commit: nothing below fails.
    for (leaves) |id| {
        const p = if (m.paneIndex(id)) |i| m.panes.items[i] else for (fresh) |f| {
            if (f.id == id) break f;
        } else unreachable;
        ordered.appendAssumeCapacity(p);
    }
    for (m.panes.items) |p| {
        if (std.mem.indexOfScalar(u32, leaves, p.id) == null) m.retired_panes.appendAssumeCapacity(p);
    }
    m.panes.deinit(gpa);
    m.panes = ordered;
    m.layout.deinit(gpa);
    m.layout = new_tree.*;
    m.sizes.deinit(gpa);
    m.sizes = sizes;
    m.focused = std.mem.indexOfScalar(u32, leaves, focus_id) orelse 0;
}

/// A new pane in `folder` with `like`'s sort order and view mode.
fn newPane(m: *Model, folder: []const u8, like: *const Pane) Allocator.Error!Pane {
    var p = try Pane.init(m.gpa, folder, .{ .show_hidden = m.show_hidden, .sort = like.sort }, .{ .pane = m.nextId(), .tab = m.nextId() });
    p.view_mode = like.view_mode;
    return p;
}

/// Docks a new pane beside pane `target` (an index), on `side`, showing `folder` (default: the
/// target's folder), and focuses it.
pub fn dock(m: *Model, target: usize, side: pane_layout.DockSide, folder: ?[]const u8) Allocator.Error!void {
    const gpa = m.gpa;
    const t = &m.panes.items[target];
    var np = try newPane(m, folder orelse t.tab().path(), t);
    errdefer np.deinit();
    var tree = try m.layout.docking(gpa, &np.id, &t.id, side);
    errdefer tree.deinit(gpa);
    try adopt(m, &tree, &.{np}, np.id);
}

/// Cmd+D (`.side_by_side`: a pane to the right) and Shift+Cmd+D (`.stacked`: one below), docked
/// next to the focused pane at its folder.
pub fn split(m: *Model, axis: SplitAxis) Allocator.Error!void {
    return dock(m, m.focused, if (axis == .side_by_side) .right else .bottom, null);
}

/// Closes pane `index` with its tabs. The last pane stays. If it had the focus, the pane before it
/// (else the first) takes it.
pub fn closePane(m: *Model, index: usize) Allocator.Error!void {
    if (m.panes.items.len < 2 or index >= m.panes.items.len) return;
    const id = m.panes.items[index].id;
    var tree = (try m.layout.removing(m.gpa, &id)) orelse return;
    errdefer tree.deinit(m.gpa);
    const was_focused = index == m.focused;
    const keep_focus = m.focusedPane().id;
    const next_focus = m.panes.items[if (index == 0) 1 else index - 1].id;
    try adopt(m, &tree, &.{}, if (was_focused) next_focus else keep_focus);
}

/// Cmd+Opt+Right (+1) / Left (-1): the next pane in reading order, wrapping around.
pub fn focusMove(m: *Model, delta: i8) void {
    const n: isize = @intCast(m.panes.items.len);
    if (n < 2) return;
    m.focused = @intCast(@mod(@as(isize, @intCast(m.focused)) + delta, n));
}

/// Rearranges the panes into `preset`: existing panes fill the slots in reading order, missing
/// ones open at the focused pane's folder (its sort order and view mode too), and extra ones
/// close with their tabs appended, unselected and keeping their histories, to the last pane. If
/// the focused pane was one of them, the first pane takes the focus.
pub fn applyPreset(m: *Model, preset: LayoutPreset) Allocator.Error!void {
    const gpa = m.gpa;
    const ids = try gpa.alloc(u32, m.panes.items.len);
    defer gpa.free(ids);
    for (m.panes.items, ids) |p, *id| id.* = p.id;
    const plan = pane_layout.PresetPlan(u32).make(ids, preset);
    if (!try rearrange(m, preset, plan)) return;

    // Fold: the retired panes' tabs move on (room was made); the panes are left empty and freed
    // with the rest. The last pane is the last leaf.
    const target = &m.panes.items[m.panes.items.len - 1];
    const first_folded = target.tabs.items.len;
    for (m.retired_panes.items) |*rp| {
        if (std.mem.indexOfScalar(u32, plan.dropped, rp.id) == null) continue;
        target.tabs.appendSliceAssumeCapacity(rp.tabs.items);
        rp.tabs.clearRetainingCapacity();
    }
    for (target.tabs.items[first_folded..]) |*t| try t.refilter(m.opts(target));
}

/// Everything up to and including the commit: new panes for empty slots, the arranged tree, room
/// for the folded tabs. False if the layout already is `preset`.
fn rearrange(m: *Model, preset: LayoutPreset, plan: pane_layout.PresetPlan(u32)) Allocator.Error!bool {
    const gpa = m.gpa;
    var fresh: std.ArrayList(Pane) = .empty;
    defer fresh.deinit(gpa);
    errdefer for (fresh.items) |*p| p.deinit();
    const like = m.focusedPane();
    const folder = like.tab().path();
    try fresh.ensureTotalCapacityPrecise(gpa, plan.created);
    for (0..plan.created) |_| fresh.appendAssumeCapacity(try newPane(m, folder, like));

    // The slots, in reading order: kept panes, then new ones.
    const slots = try gpa.alloc(u32, plan.kept.len + plan.created);
    defer gpa.free(slots);
    @memcpy(slots[0..plan.kept.len], plan.kept);
    for (fresh.items, slots[plan.kept.len..]) |p, *s| s.* = p.id;
    var tree = preset.arranged(gpa, u32, slots) catch |e| switch (e) {
        error.WrongPaneCount => unreachable, // one slot id per slot, by construction
        error.OutOfMemory => return error.OutOfMemory,
    };
    errdefer tree.deinit(gpa);
    if (tree.eql(&m.layout)) {
        tree.deinit(gpa);
        return false;
    }

    // Room for the dropped panes' tabs in the last pane.
    const last_id = slots[slots.len - 1];
    const last: *Pane = if (m.paneIndex(last_id)) |i| &m.panes.items[i] else &fresh.items[fresh.items.len - 1];
    var folding: usize = 0;
    for (plan.dropped) |id| folding += m.panes.items[m.paneIndex(id).?].tabs.items.len;
    try last.tabs.ensureUnusedCapacity(gpa, folding);

    try adopt(m, &tree, fresh.items, m.focusedPane().id);
    fresh.clearRetainingCapacity(); // the model owns them now
    return true;
}
