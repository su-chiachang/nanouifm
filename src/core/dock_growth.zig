//! Pure arithmetic for "how much must the window grow so a pane can be split once more"
//! (port of DockGrowth.swift). Sizes and rects are in points; rect origin is bottom-left
//! (AppKit convention), so growing downward lowers the origin.
const std = @import("std");
const SplitAxis = @import("layout_tree.zig").SplitAxis;

pub const Size = struct { w: f64, h: f64 };

pub const Rect = struct {
    x: f64,
    y: f64,
    w: f64,
    h: f64,

    pub fn minX(r: Rect) f64 {
        return r.x;
    }
    pub fn maxX(r: Rect) f64 {
        return r.x + r.w;
    }
    pub fn minY(r: Rect) f64 {
        return r.y;
    }
    pub fn maxY(r: Rect) f64 {
        return r.y + r.h;
    }
};

fn along(axis: SplitAxis, s: Size) f64 {
    return if (axis == .side_by_side) s.w else s.h;
}

/// Smallest extent a pane needs along `axis` to hold two minimum-size halves and the divider.
pub fn requiredExtent(axis: SplitAxis, min_pane: Size, divider: f64) f64 {
    return 2 * along(axis, min_pane) + divider;
}

/// Extra window extent along `axis` (0 when the target already fits). The target only receives
/// `target/root` of any growth (siblings share the rest), so the deficit is scaled up by `root/target`.
pub fn windowGrowth(axis: SplitAxis, target: Size, root: Size, min_pane: Size, divider: f64) f64 {
    const need = requiredExtent(axis, min_pane, divider);
    const have = along(axis, target);
    const whole = along(axis, root);
    const deficit = need - have;
    if (deficit <= 0.5) return 0;
    return @ceil(deficit * whole / @max(have, 1));
}

/// Whether a window of `current` size can reach `current + growth` without exceeding `limit`.
pub fn fitsAfterGrowth(current: Size, growth: Size, limit: Size) bool {
    return current.w + growth.w <= limit.w + 0.5 and current.h + growth.h <= limit.h + 0.5;
}

/// New window frame after growing by `growth`: top-left anchored, shifted back onto `visible`, clamped to it.
pub fn grownFrame(frame: Rect, growth: Size, visible: Rect) Rect {
    const w = @min(frame.w + growth.w, visible.w);
    const h = @min(frame.h + growth.h, visible.h);
    var x = @min(frame.minX(), visible.maxX() - w);
    x = @max(x, visible.minX());
    var y = @max(frame.maxY() - h, visible.minY());
    y = @min(y, visible.maxY() - h);
    return .{ .x = x, .y = y, .w = w, .h = h };
}

// ---- tests (port of DockGrowthTests) ----

const testing = std.testing;
const test_min: Size = .{ .w = 320, .h = 200 };

test "no growth when the target fits" {
    const g = windowGrowth(.side_by_side, .{ .w = 700, .h = 400 }, .{ .w = 1000, .h = 800 }, test_min, 1);
    try testing.expectEqual(@as(f64, 0), g);
}

test "growth scales by root over target" {
    // Target 505 of root 1010 (half): needs 641, deficit 136, window must grow 272.
    const g = windowGrowth(.side_by_side, .{ .w = 505, .h = 400 }, .{ .w = 1010, .h = 800 }, test_min, 1);
    try testing.expectEqual(@as(f64, 272), g);
    const v = windowGrowth(.stacked, .{ .w = 505, .h = 195 }, .{ .w = 1010, .h = 390 }, test_min, 1);
    try testing.expectEqual(@as(f64, 412), v); // need 401, deficit 206, scale 2
}

test "fits after growth" {
    const limit: Size = .{ .w = 1900, .h = 1000 };
    try testing.expect(fitsAfterGrowth(.{ .w = 1240, .h = 780 }, .{ .w = 272, .h = 0 }, limit));
    try testing.expect(!fitsAfterGrowth(.{ .w = 1240, .h = 780 }, .{ .w = 700, .h = 0 }, limit));
}

test "grown frame stays on screen" {
    const visible: Rect = .{ .x = 0, .y = 25, .w = 1920, .h = 1025 };
    // Near the right edge: shifts left; top stays put, grows downward.
    const f = grownFrame(.{ .x = 1500, .y = 400, .w = 400, .h = 500 }, .{ .w = 300, .h = 100 }, visible);
    try testing.expectEqual(Rect{ .x = 1220, .y = 300, .w = 700, .h = 600 }, f);
    // Clamped to the visible frame, bottom crossing shifts up.
    const g = grownFrame(.{ .x = 100, .y = 50, .w = 400, .h = 500 }, .{ .w = 5000, .h = 5000 }, visible);
    try testing.expectEqual(visible, g);
}
