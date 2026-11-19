//! The window grows when a layout change would leave the panes cramped (Swift's `prepareDock` /
//! `prepareFit`): after a split or a layout preset is applied, `apply` works out how much room the
//! panes need at a comfortable size (320 x 200 each, the Swift app's minimum) with the equal shares
//! a new layout starts with, asks the injected `Hooks.window_frame` for the window's frame and the
//! screen's visible frame, and sets a larger frame, never beyond the screen and never smaller than
//! the window already is. The arithmetic is the core's (`dock_growth.zig`, AppKit's bottom-left
//! origin); the hook speaks nanoui's top-left origin, and `toCore` / `fromCore` convert explicitly.
//!
//! `Model.applyPending` calls `apply` once its actions have run, never mid-view. Without a hook
//! (every test but the growth tests) or before the first frame told us the window's size, nothing
//! happens.
//!
//! The comfortable size is deliberately NOT the divider's minimum (`pane_sizes.min_pane_w`, 160 x
//! 120): the window can only grow to the screen, so on a small screen four columns cannot all be
//! 320 wide, and dividers must still be draggable then.
const std = @import("std");
const pane_layout = @import("../core/pane_layout.zig");
const DockGrowth = pane_layout.DockGrowth;
const pane_sizes = @import("pane_sizes.zig");
const style = @import("style.zig");
const hooks = @import("hooks.zig");
const Model = @import("model.zig").Model;

const Tree = pane_sizes.Tree;
const SplitAxis = pane_layout.SplitAxis;

/// The Swift app's minimum pane (PanesViewController.minPaneWidth / minPaneHeight).
pub const comfy_w: f64 = 320;
pub const comfy_h: f64 = 200;

pub const State = struct {
    /// A layout change happened since the last `apply`.
    want: bool = false,
    /// The window's content size in the last frame (the view tells us); null before the first.
    size: ?struct { w: f32, h: f32 } = null,
};

/// The least extent `node` needs along `axis` for every pane in it to have at least the comfortable
/// size when each split shares its room equally (what a layout change starts with).
pub fn needed(node: *const Tree, axis: SplitAxis) f64 {
    const own: f64 = if (axis == .side_by_side) comfy_w else comfy_h;
    switch (node.*) {
        .leaf => return own,
        .split => |s| {
            var biggest: f64 = 0;
            for (s.children) |*c| biggest = @max(biggest, needed(c, axis));
            if (s.axis != axis) return biggest;
            const n: f64 = @floatFromInt(s.children.len);
            const gaps = pane_sizes.divider_w * (n - 1);
            return n * biggest + gaps;
        },
    }
}

/// How much the window must grow, width and height, for panes in `area` to have what `tree` needs.
pub fn growthFor(tree: *const Tree, area_w: f64, area_h: f64) DockGrowth.Size {
    return .{
        .w = @max(0, @ceil(needed(tree, .side_by_side) - area_w)),
        .h = @max(0, @ceil(needed(tree, .stacked) - area_h)),
    };
}

/// nanoui's frames have y down from the screen's top; the core's have y up. Any fixed flip works
/// because only differences matter, so the screen's own height is not needed: y' = -(y + h).
pub fn toCore(f: hooks.Frame) DockGrowth.Rect {
    return .{ .x = f.x, .y = -(f.y + f.h), .w = f.w, .h = f.h };
}

pub fn fromCore(r: DockGrowth.Rect) hooks.Frame {
    return .{ .x = r.x, .y = -(r.y + r.h), .w = r.w, .h = r.h };
}

/// The frame after growing `frame` by `growth` within `visible` (all top-left origin): the top left
/// stays put unless the screen's edge forces it back, and no side ever gets smaller.
pub fn grown(frame: hooks.Frame, growth: DockGrowth.Size, visible: hooks.Frame) hooks.Frame {
    const f = toCore(frame);
    const g = DockGrowth.grownFrame(f, growth, toCore(visible));
    var out = f;
    if (g.w > f.w) {
        out.x = g.x;
        out.w = g.w;
    }
    if (g.h > f.h) {
        out.y = g.y;
        out.h = g.h;
    }
    return fromCore(out);
}

/// Grows the window if the layout needs room: see the file header.
pub fn apply(m: *Model) void {
    if (!m.growth.want) return;
    m.growth.want = false;
    const wf = m.hooks.window_frame orelse return;
    const size = m.growth.size orelse return;
    const growth = growthFor(&m.layout, style.panesBounds(size.w, size.h, m.sidebar_visible).w, size.h);
    if (growth.w == 0 and growth.h == 0) return;
    const frame = wf.get() orelse return;
    const visible = wf.visible() orelse return;
    const next = grown(frame, growth, visible);
    if (next.w == frame.w and next.h == frame.h and next.x == frame.x and next.y == frame.y) return;
    wf.set(next);
}

// ---- tests ----

const testing = std.testing;
const LayoutPreset = pane_layout.LayoutPreset;

test "the need of a layout follows its nesting" {
    var one = try LayoutPreset.single.shape(testing.allocator);
    defer one.deinit(testing.allocator);
    try testing.expectEqual(@as(f64, 320), needed(&one, .side_by_side));
    try testing.expectEqual(@as(f64, 200), needed(&one, .stacked));
    var two = try LayoutPreset.two_columns.shape(testing.allocator);
    defer two.deinit(testing.allocator);
    // The core's formula for one more split of a minimum pane agrees.
    try testing.expectEqual(DockGrowth.requiredExtent(.side_by_side, .{ .w = comfy_w, .h = comfy_h }, pane_sizes.divider_w), needed(&two, .side_by_side));
    try testing.expectEqual(@as(f64, 200), needed(&two, .stacked));
    var grid = try LayoutPreset.grid_2x2.shape(testing.allocator);
    defer grid.deinit(testing.allocator);
    try testing.expectEqual(@as(f64, 641), needed(&grid, .side_by_side));
    try testing.expectEqual(@as(f64, 401), needed(&grid, .stacked));
    // One column beside a stack of two: the equal split gives the stack as much as the column.
    var mixed = try LayoutPreset.left_and_right_stack.shape(testing.allocator);
    defer mixed.deinit(testing.allocator);
    try testing.expectEqual(@as(f64, 641), needed(&mixed, .side_by_side));
    try testing.expectEqual(@as(f64, 401), needed(&mixed, .stacked));
    var four = try LayoutPreset.four_columns.shape(testing.allocator);
    defer four.deinit(testing.allocator);
    try testing.expectEqual(@as(f64, 1283), needed(&four, .side_by_side));
}

test "growth is what the panes' area lacks, never negative" {
    var two = try LayoutPreset.two_columns.shape(testing.allocator);
    defer two.deinit(testing.allocator);
    const g = growthFor(&two, 500, 600);
    try testing.expectEqual(@as(f64, 141), g.w); // 641 - 500
    try testing.expectEqual(@as(f64, 0), g.h);
    const none = growthFor(&two, 900, 600);
    try testing.expectEqual(@as(f64, 0), none.w);
}

test "top-left frames convert to the core's bottom-left ones and back" {
    const f: hooks.Frame = .{ .x = 100, .y = 80, .w = 600, .h = 400 };
    const c = toCore(f);
    try testing.expectEqual(@as(f64, -480), c.y);
    try testing.expectEqual(@as(f64, -80), c.maxY()); // the top edge, now the larger y
    try testing.expectEqual(f, fromCore(c));
    // Higher on the screen (smaller y, top-left) is a larger y in the core.
    try testing.expect(toCore(.{ .x = 0, .y = 10, .w = 10, .h = 10 }).y > toCore(.{ .x = 0, .y = 90, .w = 10, .h = 10 }).y);
}

test "growing keeps the top left, grows right and down, and is pulled back onto the screen" {
    const visible: hooks.Frame = .{ .x = 0, .y = 25, .w = 1440, .h = 875 };
    // Room all around: only the size changes.
    const a = grown(.{ .x = 100, .y = 100, .w = 600, .h = 400 }, .{ .w = 300, .h = 150 }, visible);
    try testing.expectEqual(hooks.Frame{ .x = 100, .y = 100, .w = 900, .h = 550 }, a);
    // Near the right and bottom edges: shifted left and up.
    const b = grown(.{ .x = 1000, .y = 600, .w = 400, .h = 280 }, .{ .w = 300, .h = 200 }, visible);
    try testing.expectEqual(hooks.Frame{ .x = 1000 - 260, .y = 900 - 480, .w = 700, .h = 480 }, b);
    // Clamped to the visible frame.
    const c = grown(.{ .x = 100, .y = 100, .w = 600, .h = 400 }, .{ .w = 5000, .h = 5000 }, visible);
    try testing.expectEqual(visible, c);
}

test "growing never shrinks a window that is already larger than the screen's room" {
    const visible: hooks.Frame = .{ .x = 0, .y = 25, .w = 1000, .h = 700 };
    const big: hooks.Frame = .{ .x = -50, .y = 10, .w = 1200, .h = 500 };
    const out = grown(big, .{ .w = 100, .h = 100 }, visible);
    try testing.expectEqual(big.w, out.w); // wider than the screen: left as it is
    try testing.expectEqual(big.x, out.x);
    try testing.expect(out.h > big.h);
}
