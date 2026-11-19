//! Live refresh through ui.Tester with the manual watcher backend: which folders are watched as
//! tabs navigate, split and close; a fired change reloads what shows the folder and keeps the
//! selection; a hidden tab is read again when it comes into view; a change waits out a rename.
//! The operating system's watching is not involved (the core's dir_watcher has its own tests).
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const ts = @import("test_support.zig");

const testing = std.testing;
const S = ui.Shortcut;

fn watching(env: *ts.Env, rel: []const u8) !bool {
    const p = try env.fx.sub(rel);
    defer testing.allocator.free(p);
    return env.m.watch.isWatching(p);
}

fn fire(env: *ts.Env, rel: []const u8) !void {
    const p = try env.fx.sub(rel);
    defer testing.allocator.free(p);
    try env.m.watch.fire(p);
    env.t.frame();
    env.t.settle(0.2);
}

test "exactly the folders the panes draw are watched, as tabs navigate and close" {
    var env: ts.Env = undefined;
    try env.initWith(.{ .watch = .manual });
    defer env.deinit();

    try testing.expectEqual(@as(usize, 1), env.m.watch.count());
    try testing.expect(try watching(&env, ""));
    // Navigating moves the watcher.
    try env.click("dir");
    env.t.doubleClick(env.t.findText("dir").?.x + 2, env.t.findText("dir").?.y + 2);
    env.t.settle(0.3);
    try testing.expectEqual(@as(usize, 1), env.m.watch.count());
    try testing.expect(try watching(&env, "dir") and !try watching(&env, ""));
    // A split in the same folder shares it; a second folder adds one; closing the pane drops it.
    try ts.press(&env.t, 'd', .{ .cmd = true });
    try testing.expectEqual(@as(usize, 1), env.m.watch.count());
    try ts.press(&env.t, S.up, .{ .cmd = true });
    try testing.expectEqual(@as(usize, 2), env.m.watch.count());
    try testing.expect(try watching(&env, "dir") and try watching(&env, ""));
    try ts.press(&env.t, 'w', .{ .cmd = true, .alt = true });
    try testing.expectEqual(@as(usize, 1), env.m.watch.count());
    // Only the shown tab is watched; another tab's folder is not until it is shown.
    try ts.press(&env.t, 't', .{ .cmd = true });
    try ts.press(&env.t, S.up, .{ .cmd = true });
    try testing.expect(try watching(&env, "")); // the shown (new) tab
    try ts.press(&env.t, S.tab, .{ .ctrl = true });
    try testing.expect(try watching(&env, "dir") or try watching(&env, ""));
    try testing.expectEqual(@as(usize, 1), env.m.watch.count());
    // A folder opened in place in the list is watched too.
    try ts.press(&env.t, 'w', .{ .cmd = true });
    try env.m.queue(.{ .open = env.fx.root });
    _ = try env.m.applyPending();
    env.t.settle(0.2);
    const dir = try env.fx.sub("dir");
    defer testing.allocator.free(dir);
    try env.m.queue(.{ .toggle_expand = .{ .pane = env.m.focusedPane().id, .path = dir } });
    env.t.settle(0.2);
    try testing.expect(try watching(&env, "dir"));
    try testing.expectEqual(@as(usize, 2), env.m.watch.count());
    // Column view watches every column.
    try ts.press(&env.t, '2', .{ .cmd = true });
    try testing.expect(env.m.watch.count() >= 2);
}

test "a change reloads the folder, keeps the selection, and drops what vanished" {
    var env: ts.Env = undefined;
    try env.initWith(.{ .watch = .manual });
    defer env.deinit();

    try env.click("b.txt");
    try env.fx.file("new-file.txt", 4);
    try testing.expect(!env.t.hasText("new-file.txt")); // nothing polls
    try fire(&env, "");
    try testing.expect(env.t.hasText("new-file.txt"));
    try testing.expect(try env.selected("b.txt")); // selection survived
    try testing.expect(env.t.hasText("1 of 4 selected"));

    // The selected file disappears behind our back: the selection goes with it.
    try env.fx.tmp.dir.deleteFile(testing.io, "b.txt");
    try fire(&env, "");
    try testing.expect(!env.t.hasText("b.txt"));
    try testing.expectEqual(@as(usize, 0), env.m.focusedTab().selection.count());
    // A change in a folder nobody shows is ignored.
    try env.fx.file("dir/other.txt", 1);
    try fire(&env, "dir");
    try testing.expect(!env.t.hasText("other.txt"));
}

test "a change keeps the scroll position" {
    var env: ts.Env = undefined;
    try env.initWith(.{ .watch = .manual });
    defer env.deinit();
    var i: usize = 0;
    var name: [32]u8 = undefined;
    while (i < 60) : (i += 1) try env.fx.file(try std.fmt.bufPrint(&name, "f{d:0>3}.txt", .{i}), 1);
    try env.m.queue(.reload);
    env.t.settle(0.2);

    const r = try ts.paneRect(&env.t, &env.m, 0);
    env.t.scroll(r.x + 200, r.y + 200, -400);
    env.t.settle(0.3);
    // Some row far down is now in sight, and the first rows are not.
    try testing.expect(!env.t.hasText("a.txt"));
    const probe = env.t.findText("f040.txt") orelse env.t.findText("f030.txt") orelse return error.TextNotFound;
    const probe_name: []const u8 = if (env.t.hasText("f040.txt")) "f040.txt" else "f030.txt";
    try env.fx.file("zzz-new.txt", 1); // sorts last: nothing above the probe moves
    try fire(&env, "");
    const after = env.t.findText(probe_name) orelse return error.TextNotFound;
    try testing.expectEqual(probe.y, after.y);
    try testing.expect(!env.m.focusedTab().scroll_reset);
    const zzz = try env.fx.sub("zzz-new.txt");
    defer testing.allocator.free(zzz);
    try testing.expect(env.m.focusedTab().listing.indexOf(zzz) != null);
}

test "a tab brought into view is read again, and a change waits while a rename is open" {
    var env: ts.Env = undefined;
    try env.initWith(.{ .watch = .manual });
    defer env.deinit();

    // A second tab in dir; back to the first one. dir is no longer watched.
    const dir = try env.fx.sub("dir");
    defer testing.allocator.free(dir);
    try env.m.queue(.{ .open_in_new_tab = dir });
    _ = try env.m.applyPending();
    env.t.settle(0.2);
    try ts.press(&env.t, S.tab, .{ .ctrl = true });
    try testing.expect(!try watching(&env, "dir"));
    try env.fx.file("dir/while-hidden.txt", 1);
    try ts.press(&env.t, S.tab, .{ .ctrl = true }); // dir's tab again: read again
    try testing.expect(env.t.hasText("while-hidden.txt"));

    // A rename is not interrupted: the change is applied once it ends.
    try ts.press(&env.t, S.tab, .{ .ctrl = true });
    try env.click("a.txt");
    try ts.press(&env.t, S.enter, .{});
    try env.fx.file("arrived.txt", 1);
    try fire(&env, "");
    try testing.expect(!env.t.hasText("arrived.txt"));
    env.t.key(.escape);
    env.t.settle(0.3);
    try testing.expect(env.t.hasText("arrived.txt"));
}

test "a fired change asks the window for a frame" {
    var env: ts.Env = undefined;
    try env.initWith(.{ .watch = .manual });
    defer env.deinit();

    _ = env.t.woken.swap(false, .acq_rel);
    const p = try env.fx.sub("");
    defer testing.allocator.free(p);
    try env.m.watch.fire(p);
    try testing.expect(env.t.woken.load(.acquire));
}
