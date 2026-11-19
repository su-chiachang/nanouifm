//! Quick Look (Space, Cmd+Y) against a recording hook: the real panel can't be exercised without a
//! window, so what is checked here is that the right command and the right item list reach
//! `Hooks.quick_look`, when, and that typing is never taken for it. Temp folders only.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const hooks_mod = @import("hooks.zig");
const ts = @import("test_support.zig");

const testing = std.testing;
const S = ui.Shortcut;

// ---- the recorder ----

var open: bool = false;
var toggles: usize = 0;
var updates: usize = 0;
var last: [1024]u8 = undefined;
var last_len: usize = 0;
var last_count: usize = 0;

fn record(paths: []const []const u8) void {
    var w: std.Io.Writer = .fixed(&last);
    for (paths, 0..) |p, i| {
        if (i > 0) w.writeAll("\n") catch break;
        w.writeAll(p) catch break;
    }
    last_len = w.buffered().len;
    last_count = paths.len;
}

fn fakeToggle(paths: []const []const u8) void {
    toggles += 1;
    open = !open;
    record(paths);
}

fn fakeUpdate(paths: []const []const u8) void {
    updates += 1;
    record(paths);
}

fn fakeIsOpen() bool {
    return open;
}

const fake: hooks_mod.QuickLook = .{ .toggle = fakeToggle, .update = fakeUpdate, .is_open = fakeIsOpen };

fn reset() void {
    open = false;
    toggles = 0;
    updates = 0;
    last_len = 0;
    last_count = 0;
}

fn lastList() []const u8 {
    return last[0..last_len];
}

fn expectLast(env: *ts.Env, rels: []const []const u8) !void {
    var want: std.ArrayList(u8) = .empty;
    defer want.deinit(testing.allocator);
    for (rels, 0..) |r, i| {
        if (i > 0) try want.append(testing.allocator, '\n');
        const p = try env.fx.sub(r);
        defer testing.allocator.free(p);
        try want.appendSlice(testing.allocator, p);
    }
    try testing.expectEqualStrings(want.items, lastList());
    try testing.expectEqual(rels.len, last_count);
}

fn start(env: *ts.Env) !void {
    reset();
    try env.init();
    env.m.hooks.quick_look = fake;
}

test "Space and Cmd+Y toggle Quick Look on the selection, in row order" {
    var env: ts.Env = undefined;
    try start(&env);
    defer env.deinit();

    // Nothing selected: neither key is taken, the hook hears nothing.
    // (Space itself falls through to type-to-select, which ignores a space that starts a prefix.)
    _ = env.t.shortcut(.{ .key = ' ' });
    try testing.expectError(error.KeyNotTaken, ts.press(&env.t, 'y', .{ .cmd = true }));
    try testing.expectEqual(@as(usize, 0), toggles);

    try env.click("a.txt");
    try ts.press(&env.t, ' ', .{});
    try testing.expectEqual(@as(usize, 1), toggles);
    try testing.expect(open);
    try expectLast(&env, &.{"a.txt"});
    // Open: Space closes it (the hook is told to toggle with nothing to show).
    try ts.press(&env.t, ' ', .{});
    try testing.expectEqual(@as(usize, 2), toggles);
    try testing.expect(!open and last_count == 0);

    // Cmd+Y with a multi-selection: all of it, in row order (dir, a.txt, b.txt).
    try ts.press(&env.t, 'a', .{ .cmd = true });
    try ts.press(&env.t, 'y', .{ .cmd = true });
    try testing.expect(open);
    try expectLast(&env, &.{ "dir", "a.txt", "b.txt" });
    try ts.press(&env.t, 'y', .{ .cmd = true });
    try testing.expect(!open);
    // Space is not type-to-select: no row moved.
    try testing.expectEqual(@as(usize, 3), env.m.focusedTab().selection.count());
}

test "while it is open the arrows and clicks change the previewed item" {
    var env: ts.Env = undefined;
    try start(&env);
    defer env.deinit();

    try env.click("a.txt");
    try ts.press(&env.t, ' ', .{});
    try testing.expectEqual(@as(usize, 0), updates);
    try ts.press(&env.t, S.down, .{});
    try testing.expectEqual(@as(usize, 1), updates);
    try expectLast(&env, &.{"b.txt"});
    try ts.press(&env.t, S.up, .{});
    try expectLast(&env, &.{"a.txt"});
    try testing.expectEqual(@as(usize, 2), updates);
    try env.click("b.txt");
    try expectLast(&env, &.{"b.txt"});
    try testing.expectEqual(@as(usize, 3), updates);
    // Nothing changed, nothing sent.
    env.t.settle(0.3);
    env.t.advance(0.2);
    try testing.expectEqual(@as(usize, 3), updates);
    try testing.expectEqual(@as(usize, 1), toggles);
}

test "a panel closed with its own button is forgotten: later selections are not sent" {
    var env: ts.Env = undefined;
    try start(&env);
    defer env.deinit();
    try env.click("a.txt");
    try ts.press(&env.t, ' ', .{});
    open = false; // the user pressed the panel's close button
    try env.click("b.txt");
    try testing.expectEqual(@as(usize, 0), updates);
    try testing.expect(!env.m.preview.ql.shown);
    // And Space shows it again.
    try ts.press(&env.t, ' ', .{});
    try testing.expect(open and toggles == 2);
}

test "Space is not taken while a text field has the keyboard, nor while the palette is open" {
    var env: ts.Env = undefined;
    try start(&env);
    defer env.deinit();
    try env.click("a.txt");

    try ts.press(&env.t, 'f', .{ .cmd = true }); // the filter field
    env.t.settle(0.2);
    try testing.expect(env.t.ctx.focus_is_text);
    try testing.expectError(error.KeyNotTaken, ts.press(&env.t, ' ', .{}));
    _ = env.t.shortcut(.{ .key = 'y', .cmd = true }); // (the field may take this one itself)
    try testing.expectEqual(@as(usize, 0), toggles);
    try ts.press(&env.t, S.escape, .{});

    try ts.press(&env.t, 'k', .{ .cmd = true }); // the palette
    env.t.settle(0.2);
    try testing.expect(env.m.view_state.palette.open);
    try testing.expectError(error.KeyNotTaken, ts.press(&env.t, ' ', .{}));
    try testing.expectEqual(@as(usize, 0), toggles);
    try ts.press(&env.t, S.escape, .{});

    // The rename field.
    try testing.expect(!env.m.view_state.palette.open);
    try env.click("a.txt");
    try testing.expectEqual(@as(usize, 1), env.m.focusedTab().selection.count());
    try ts.press(&env.t, S.enter, .{});
    env.t.settle(0.2);
    try testing.expect(env.m.rename != null);
    try testing.expectError(error.KeyNotTaken, ts.press(&env.t, ' ', .{}));
    try testing.expectEqual(@as(usize, 0), toggles);
}

test "the context menu and the palette run Quick Look too" {
    var env: ts.Env = undefined;
    try start(&env);
    defer env.deinit();
    const r = env.t.findText("b.txt").?;
    env.t.secondaryClick(r.x + r.w / 2, r.y + r.h / 2);
    env.t.settle(0.4);
    try env.t.clickText("Quick Look");
    env.t.settle(0.3);
    try testing.expect(open and !env.m.view_state.ctx_menu.open);
    try expectLast(&env, &.{"b.txt"});
    try ts.press(&env.t, ' ', .{}); // close it again
    try testing.expect(!open);

    try testing.expectEqual(@as(usize, 2), toggles);
    // The registry: both keys, one command's worth of behaviour.
    const cmds = @import("commands.zig");
    try testing.expect(cmds.isEnabled(&env.m, cmds.find(.file_quick_look)));
    try testing.expect(cmds.isEnabled(&env.m, cmds.find(.file_quick_look_space)));
    try testing.expect(cmds.find(.file_quick_look).in_palette and !cmds.find(.file_quick_look_space).in_palette);
}

test "no hook: the command applies to a selection but does nothing" {
    reset();
    var env: ts.Env = undefined;
    try env.init();
    defer env.deinit();
    try env.click("a.txt");
    try ts.press(&env.t, ' ', .{});
    try testing.expect(env.m.notice == null and !env.m.preview.ql.shown);
}
