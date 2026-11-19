//! Window growth through ui.Tester (`window_growth.zig`): a split or a layout preset that would
//! leave the panes under a comfortable size asks the injected window hook for a bigger frame,
//! clamped to the screen's visible frame, never smaller, and nothing happens without a hook. The
//! window is a fake (frames in points from the top left, the hook's convention): no real window is
//! ever touched. The tester's window is 900 x 560, so the panes' area (right of the 212-point
//! sidebar) is 688 x 560.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const hooks = @import("hooks.zig");
const ts = @import("test_support.zig");

const testing = std.testing;
const Frame = hooks.Frame;

var frame: ?Frame = null;
var visible_frame: ?Frame = null;
var sets: usize = 0;
var last: Frame = undefined;

fn fakeGet() ?Frame {
    return frame;
}
fn fakeVisible() ?Frame {
    return visible_frame;
}
fn fakeSet(f: Frame) void {
    sets += 1;
    last = f;
}

const fake: hooks.WindowFrame = .{ .get = fakeGet, .set = fakeSet, .visible = fakeVisible };

fn reset(f: Frame, vis: Frame) void {
    frame = f;
    visible_frame = vis;
    sets = 0;
}

const roomy: Frame = .{ .x = 0, .y = 25, .w = 1920, .h = 1055 };

fn start(env: *ts.Env, f: Frame, vis: Frame) !void {
    try env.init();
    env.m.hooks.window_frame = fake;
    reset(f, vis);
}

test "a split that still fits asks for nothing; the third column grows the window to the right" {
    var env: ts.Env = undefined;
    try start(&env, .{ .x = 100, .y = 50, .w = 900, .h = 560 }, roomy);
    defer env.deinit();
    try ts.press(&env.t, 'd', .{ .cmd = true }); // two columns need 641 of the 688
    try testing.expectEqual(@as(usize, 2), env.m.panes.items.len);
    try testing.expectEqual(@as(usize, 0), sets);
    try ts.press(&env.t, 'd', .{ .cmd = true }); // three need 962: 274 short
    try testing.expectEqual(@as(usize, 3), env.m.panes.items.len);
    try testing.expectEqual(@as(usize, 1), sets);
    try testing.expectEqual(Frame{ .x = 100, .y = 50, .w = 900 + 274, .h = 560 }, last); // the top left stays
}

test "stacked splits grow the window downward, and back onto the screen at its bottom edge" {
    var env: ts.Env = undefined;
    try start(&env, .{ .x = 100, .y = 50, .w = 900, .h = 560 }, roomy);
    defer env.deinit();
    try ts.press(&env.t, 'd', .{ .cmd = true, .shift = true }); // 401 of 560
    try ts.press(&env.t, 'd', .{ .cmd = true, .shift = true }); // 602: 42 short
    try testing.expectEqual(@as(usize, 3), env.m.panes.items.len);
    try testing.expectEqual(@as(usize, 1), sets);
    try testing.expectEqual(Frame{ .x = 100, .y = 50, .w = 900, .h = 602 }, last);

    // Near the bottom of the screen the extra height comes from above: the frame moves up.
    reset(.{ .x = 100, .y = 300, .w = 900, .h = 300 }, .{ .x = 0, .y = 25, .w = 1920, .h = 575 });
    try env.m.queue(.{ .apply_preset = .single });
    env.t.settle(0.2);
    try ts.press(&env.t, 'd', .{ .cmd = true, .shift = true });
    try ts.press(&env.t, 'd', .{ .cmd = true, .shift = true });
    try testing.expectEqual(@as(usize, 1), sets);
    try testing.expectEqual(Frame{ .x = 100, .y = 600 - 342, .w = 900, .h = 342 }, last);
}

test "a preset grows the window to what it needs" {
    var env: ts.Env = undefined;
    try start(&env, .{ .x = 100, .y = 50, .w = 900, .h = 560 }, roomy);
    defer env.deinit();
    try env.m.queue(.{ .apply_preset = .four_columns }); // 4 * 320 + 3 = 1283 of 688
    env.t.settle(0.2);
    try testing.expectEqual(@as(usize, 4), env.m.panes.items.len);
    try testing.expectEqual(@as(usize, 1), sets);
    try testing.expectEqual(Frame{ .x = 100, .y = 50, .w = 900 + 595, .h = 560 }, last);
    // A preset of the same shape does nothing at all (no layout change, no new request).
    try env.m.queue(.{ .apply_preset = .four_columns });
    env.t.settle(0.2);
    try testing.expectEqual(@as(usize, 1), sets);
    // A 2x2 needs 641 x 401: it fits, so nothing is asked.
    try env.m.queue(.{ .apply_preset = .grid_2x2 });
    env.t.settle(0.2);
    try testing.expectEqual(@as(usize, 1), sets);
}

test "growth stops at the screen's visible frame, shifting the window back onto it" {
    var env: ts.Env = undefined;
    try start(&env, .{ .x = 100, .y = 50, .w = 900, .h = 560 }, .{ .x = 0, .y = 25, .w = 1200, .h = 800 });
    defer env.deinit();
    try env.m.queue(.{ .apply_preset = .four_columns }); // wants 1495 wide, the screen has 1200
    env.t.settle(0.2);
    try testing.expectEqual(@as(usize, 1), sets);
    try testing.expectEqual(Frame{ .x = 0, .y = 50, .w = 1200, .h = 560 }, last);
}

test "a window already wider than the screen's room is never shrunk" {
    var env: ts.Env = undefined;
    try start(&env, .{ .x = -40, .y = 50, .w = 1300, .h = 560 }, .{ .x = 0, .y = 25, .w = 1000, .h = 800 });
    defer env.deinit();
    try env.m.queue(.{ .apply_preset = .four_columns });
    env.t.settle(0.2);
    try testing.expectEqual(@as(usize, 4), env.m.panes.items.len);
    try testing.expectEqual(@as(usize, 0), sets); // nothing to grow into: no request, no shrink
}

test "without a hook, or when the hook does not know the window, nothing happens" {
    var env: ts.Env = undefined;
    try env.init(); // no hook
    defer env.deinit();
    reset(.{ .x = 0, .y = 0, .w = 900, .h = 560 }, roomy);
    try env.m.queue(.{ .apply_preset = .four_columns });
    env.t.settle(0.2);
    try testing.expectEqual(@as(usize, 4), env.m.panes.items.len);
    try testing.expectEqual(@as(usize, 0), sets);

    env.m.hooks.window_frame = fake;
    frame = null; // no window yet
    try env.m.queue(.{ .apply_preset = .single });
    try env.m.queue(.{ .apply_preset = .four_columns });
    env.t.settle(0.2);
    try testing.expectEqual(@as(usize, 0), sets);
    frame = .{ .x = 0, .y = 0, .w = 900, .h = 560 };
    visible_frame = null; // no screen either
    try env.m.queue(.{ .apply_preset = .single });
    try env.m.queue(.{ .apply_preset = .four_columns });
    env.t.settle(0.2);
    try testing.expectEqual(@as(usize, 0), sets);
}

test "the hook runs from applyPending, once per batch, and not before the first frame" {
    var env: ts.Env = undefined;
    try start(&env, .{ .x = 0, .y = 25, .w = 900, .h = 560 }, roomy);
    defer env.deinit();
    // Two layout changes queued together: one request for the final layout.
    try env.m.queue(.{ .apply_preset = .two_columns });
    try env.m.queue(.{ .apply_preset = .four_columns });
    env.t.settle(0.2);
    try testing.expectEqual(@as(usize, 1), sets);
    try testing.expectEqual(@as(f64, 900 + 595), last.w);
    // The model alone (no view has told it the window's size) never asks.
    var bare = try ts.model(&env.fx, &.{});
    defer bare.deinit();
    bare.hooks.window_frame = fake;
    sets = 0;
    try bare.queue(.{ .apply_preset = .four_columns });
    _ = try bare.applyPending();
    try testing.expectEqual(@as(usize, 0), sets);
}
