//! Where the panes go: pure geometry over the core `LayoutTree` of pane ids. The tree says how
//! panes nest; `Sizes` keeps one list of weights per split (in pre-order, so a split is found by
//! its number) and `layout` turns tree + weights + the panes' area into rectangles for the
//! panes and the 1-point dividers between them. `drag` moves one divider, within the minimum
//! sizes of the two sides.
//!
//! Weights are reset to equal shares whenever the tree changes shape (like the Swift app, which
//! equalizes after every rebuild); only a divider drag changes them. No window is needed, so the
//! tests here need none.
const std = @import("std");
const Allocator = std.mem.Allocator;
const pane_layout = @import("../core/pane_layout.zig");

pub const Tree = pane_layout.LayoutTree(u32);
pub const SplitAxis = pane_layout.SplitAxis;

/// The least a pane can be dragged down to. (Swift's 320 x 200 would freeze every divider of a
/// four-column layout in a small window; there is no window growing here.)
pub const min_pane_w: f32 = 160;
pub const min_pane_h: f32 = 120;
/// The gap between two panes: a hairline. The grab band around it is the view's business.
pub const divider_w: f32 = 1;

pub const Rect = struct {
    x: f32 = 0,
    y: f32 = 0,
    w: f32 = 0,
    h: f32 = 0,

    pub fn contains(r: Rect, px: f32, py: f32) bool {
        return px >= r.x and py >= r.y and px < r.x + r.w and py < r.y + r.h;
    }
};

pub const PaneRect = struct { id: u32, rect: Rect };

/// The divider after child `index` of split number `split` (pre-order).
pub const Divider = struct {
    split: u32,
    index: u32,
    axis: SplitAxis,
    rect: Rect,
    /// The split's room for its children (its extent minus its dividers): what weights share.
    avail: f32,
    /// The least extent of the child before and the child after, along the axis.
    min_a: f32,
    min_b: f32,
};

pub const Frame = struct {
    /// In reading order, like the tree's leaves.
    panes: []const PaneRect,
    dividers: []const Divider,

    pub fn rectOf(self: Frame, id: u32) ?Rect {
        for (self.panes) |p| if (p.id == id) return p.rect;
        return null;
    }

    pub fn paneAt(self: Frame, x: f32, y: f32) ?u32 {
        for (self.panes) |p| if (p.rect.contains(x, y)) return p.id;
        return null;
    }
};

pub const Sizes = struct {
    /// One slice per split in pre-order; each child's share, summing to 1.
    weights: std.ArrayList([]f32) = .empty,

    pub fn deinit(self: *Sizes, gpa: Allocator) void {
        for (self.weights.items) |w| gpa.free(w);
        self.weights.deinit(gpa);
        self.* = undefined;
    }

    /// Equal shares for every split of `tree`.
    pub fn reset(self: *Sizes, gpa: Allocator, tree: *const Tree) Allocator.Error!void {
        var fresh: std.ArrayList([]f32) = .empty;
        errdefer {
            for (fresh.items) |w| gpa.free(w);
            fresh.deinit(gpa);
        }
        try collect(gpa, tree, &fresh);
        for (self.weights.items) |w| gpa.free(w);
        self.weights.deinit(gpa);
        self.weights = fresh;
    }

    fn collect(gpa: Allocator, node: *const Tree, out: *std.ArrayList([]f32)) Allocator.Error!void {
        switch (node.*) {
            .leaf => {},
            .split => |s| {
                const w = try gpa.alloc(f32, s.children.len);
                errdefer gpa.free(w);
                @memset(w, 1 / @as(f32, @floatFromInt(s.children.len)));
                try out.append(gpa, w);
                for (s.children) |*c| try collect(gpa, c, out);
            },
        }
    }
};

fn extentOf(r: Rect, axis: SplitAxis) f32 {
    return if (axis == .side_by_side) r.w else r.h;
}

/// The least extent a subtree needs along `axis`.
fn minExtent(node: *const Tree, axis: SplitAxis) f32 {
    switch (node.*) {
        .leaf => return if (axis == .side_by_side) min_pane_w else min_pane_h,
        .split => |s| {
            var sum: f32 = 0;
            var biggest: f32 = 0;
            for (s.children) |*c| {
                const e = minExtent(c, axis);
                sum += e;
                biggest = @max(biggest, e);
            }
            const gaps = divider_w * @as(f32, @floatFromInt(s.children.len - 1));
            return if (s.axis == axis) sum + gaps else biggest;
        },
    }
}

/// The panes' and dividers' rectangles inside `bounds`, allocated from `arena` (a frame's).
pub fn layout(arena: Allocator, tree: *const Tree, sizes: *const Sizes, bounds: Rect) Allocator.Error!Frame {
    var panes: std.ArrayList(PaneRect) = .empty;
    var divs: std.ArrayList(Divider) = .empty;
    var next_split: u32 = 0;
    try place(arena, tree, sizes, bounds, &next_split, &panes, &divs);
    return .{ .panes = panes.items, .dividers = divs.items };
}

fn place(arena: Allocator, node: *const Tree, sizes: *const Sizes, r: Rect, next_split: *u32, panes: *std.ArrayList(PaneRect), divs: *std.ArrayList(Divider)) Allocator.Error!void {
    switch (node.*) {
        .leaf => |id| try panes.append(arena, .{ .id = id, .rect = r }),
        .split => |s| {
            const idx = next_split.*;
            next_split.* += 1;
            const n = s.children.len;
            const weights: ?[]const f32 = if (idx < sizes.weights.items.len and sizes.weights.items[idx].len == n) sizes.weights.items[idx] else null;
            var total: f32 = 0;
            for (0..n) |i| total += if (weights) |w| w[i] else 1;
            const along = @max(0, extentOf(r, s.axis) - divider_w * @as(f32, @floatFromInt(n - 1)));
            var cum: f32 = 0;
            var start: f32 = 0;
            for (s.children, 0..) |*child, i| {
                cum += if (weights) |w| w[i] else 1;
                const end: f32 = if (i + 1 == n) along else @round(cum / total * along);
                const origin = start + divider_w * @as(f32, @floatFromInt(i));
                var cr = r;
                if (s.axis == .side_by_side) {
                    cr.x = r.x + origin;
                    cr.w = end - start;
                } else {
                    cr.y = r.y + origin;
                    cr.h = end - start;
                }
                try place(arena, child, sizes, cr, next_split, panes, divs);
                if (i + 1 < n) {
                    var dr = r;
                    if (s.axis == .side_by_side) {
                        dr.x = r.x + end + divider_w * @as(f32, @floatFromInt(i));
                        dr.w = divider_w;
                    } else {
                        dr.y = r.y + end + divider_w * @as(f32, @floatFromInt(i));
                        dr.h = divider_w;
                    }
                    try divs.append(arena, .{
                        .split = idx,
                        .index = @intCast(i),
                        .axis = s.axis,
                        .rect = dr,
                        .avail = along,
                        .min_a = minExtent(child, s.axis),
                        .min_b = minExtent(&s.children[i + 1], s.axis),
                    });
                }
                start = end;
            }
        },
    }
}

/// Moves divider `d` by `delta` points: the child before it grows and the one after shrinks,
/// within their minimum sizes (a side already below its minimum may still grow, never shrink).
/// True if any weight changed.
pub fn drag(sizes: *Sizes, d: Divider, delta_in: f32) bool {
    if (!std.math.isFinite(delta_in) or d.avail <= 0 or d.split >= sizes.weights.items.len) return false;
    const w = sizes.weights.items[d.split];
    if (d.index + 1 >= w.len) return false;
    const cur_a = w[d.index] * d.avail;
    const cur_b = w[d.index + 1] * d.avail;
    const lower = @min(0, d.min_a - cur_a);
    const upper = @max(0, cur_b - d.min_b);
    const delta = std.math.clamp(delta_in, lower, upper);
    if (delta == 0) return false;
    w[d.index] += delta / d.avail;
    w[d.index + 1] -= delta / d.avail;
    return true;
}

// ---- tests ----

const testing = std.testing;
const LayoutPreset = pane_layout.LayoutPreset;

fn frameOf(arena: Allocator, preset: LayoutPreset, sizes: *Sizes, bounds: Rect) !Frame {
    var shape = try preset.shape(testing.allocator);
    defer shape.deinit(testing.allocator);
    try sizes.reset(testing.allocator, &shape);
    return layout(arena, &shape, sizes, bounds);
}

test "one pane fills the area; two columns share it around a hairline" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var sizes: Sizes = .{};
    defer sizes.deinit(testing.allocator);
    const area: Rect = .{ .x = 10, .y = 5, .w = 801, .h = 400 };
    var f = try frameOf(arena.allocator(), .single, &sizes, area);
    try testing.expectEqual(@as(usize, 1), f.panes.len);
    try testing.expectEqual(area, f.panes[0].rect);
    try testing.expectEqual(@as(usize, 0), f.dividers.len);

    f = try frameOf(arena.allocator(), .two_columns, &sizes, area);
    try testing.expectEqual(@as(usize, 2), f.panes.len);
    try testing.expectEqual(@as(f32, 400), f.panes[0].rect.w);
    try testing.expectEqual(@as(f32, 10), f.panes[0].rect.x);
    try testing.expectEqual(@as(f32, 411), f.panes[1].rect.x);
    try testing.expectEqual(@as(f32, 400), f.panes[1].rect.w);
    try testing.expectEqual(@as(f32, 400), f.panes[0].rect.h);
    try testing.expectEqual(@as(f32, 410), f.dividers[0].rect.x);
    try testing.expectEqual(@as(f32, 1), f.dividers[0].rect.w);
    try testing.expectEqual(@as(f32, 400), f.dividers[0].rect.h);
}

test "a 2x2 grid tiles the area exactly, in reading order" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var sizes: Sizes = .{};
    defer sizes.deinit(testing.allocator);
    const f = try frameOf(arena.allocator(), .grid_2x2, &sizes, .{ .w = 701, .h = 501 });
    try testing.expectEqual(@as(usize, 4), f.panes.len);
    try testing.expectEqual(@as(usize, 3), f.dividers.len); // one row divider, two column ones
    for (f.panes, 0..) |p, i| try testing.expectEqual(@as(u32, @intCast(i)), p.id);
    const a = f.panes[0].rect;
    const b = f.panes[1].rect;
    const c = f.panes[2].rect;
    const d = f.panes[3].rect;
    try testing.expectEqual(@as(f32, 350), a.w);
    try testing.expectEqual(@as(f32, 350), b.w);
    try testing.expectEqual(a.x + a.w + 1, b.x);
    try testing.expectEqual(b.x + b.w, 701);
    try testing.expectEqual(a.h, b.h);
    try testing.expectEqual(a.y + a.h + 1, c.y);
    try testing.expectEqual(c.y + c.h, 501);
    try testing.expectEqual(c.x, a.x);
    try testing.expectEqual(d.x, b.x);
    try testing.expectEqual(@as(?u32, 3), f.paneAt(d.x + 5, d.y + 5));
    try testing.expectEqual(@as(?u32, null), f.paneAt(-1, 0));
}

test "dragging a divider moves the weights and stops at the minimum sizes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var shape = try LayoutPreset.left_and_right_stack.shape(testing.allocator);
    defer shape.deinit(testing.allocator);
    var sizes: Sizes = .{};
    defer sizes.deinit(testing.allocator);
    try sizes.reset(testing.allocator, &shape);
    const area: Rect = .{ .w = 801, .h = 400 };
    var f = try layout(a, &shape, &sizes, area);
    try testing.expectEqual(@as(usize, 2), sizes.weights.items.len); // the row, then the stack
    try testing.expectEqual(@as(f32, 400), f.panes[0].rect.w);
    // The row's divider: the left pane grows by 100.
    try testing.expect(drag(&sizes, dividerOn(f, .side_by_side), 100));
    f = try layout(a, &shape, &sizes, area);
    try testing.expectEqual(@as(f32, 500), f.panes[0].rect.w);
    try testing.expectEqual(@as(f32, 300), f.panes[1].rect.w);
    try testing.expectEqual(@as(f32, 300), f.panes[2].rect.w);
    // Far to the right: the right side keeps its minimum.
    _ = drag(&sizes, dividerOn(f, .side_by_side), 10_000);
    f = try layout(a, &shape, &sizes, area);
    try testing.expectEqual(min_pane_w, f.panes[1].rect.w);
    try testing.expectEqual(@as(f32, 800) - min_pane_w, f.panes[0].rect.w);
    // The stack's divider is independent of the row's.
    try testing.expect(drag(&sizes, dividerOn(f, .stacked), -50));
    f = try layout(a, &shape, &sizes, area);
    try testing.expectEqual(@as(f32, 150), f.panes[1].rect.h);
    try testing.expectEqual(@as(f32, 249), f.panes[2].rect.h);
    try testing.expect(!drag(&sizes, dividerOn(f, .side_by_side), std.math.nan(f32)));
}

fn dividerOn(f: Frame, axis: SplitAxis) Divider {
    for (f.dividers) |d| if (d.axis == axis) return d;
    unreachable;
}
