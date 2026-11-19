//! Dropping files: from Finder (ui.Tester's `drop` with file URLs, as nanoui delivers them,
//! percent-encoded) onto a pane, a folder row and a sidebar folder; a move by default and a copy
//! with Option; refusals in the service's words; undo. And dragging rows from one pane to
//! another with the mouse (nanoui's in-window drag). Temp folders only.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const drops = @import("drops.zig");
const ts = @import("test_support.zig");

const testing = std.testing;
const S = ui.Shortcut;

/// A file URL for `path` as the drop brings it: "file://" and percent-encoded (frame memory).
fn urlOf(a: std.mem.Allocator, path: []const u8, trailing_slash: bool) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, "file://");
    for (path) |ch| switch (ch) {
        ' ', '%', '#', '?' => try out.print(a, "%{X:0>2}", .{ch}),
        else => try out.append(a, ch),
    };
    if (trailing_slash) try out.append(a, '/');
    return out.items;
}

/// `rel` under the root, in `a`.
fn sub(a: std.mem.Allocator, env: *ts.Env, rel: []const u8) ![]const u8 {
    return std.fs.path.join(a, &.{ env.fx.root, rel });
}

/// root/: a.txt, b.txt, dir/, src/ (moveme.txt, "my file.txt", sub/), dest/ (nothing)
fn extra(env: *ts.Env) !void {
    try env.fx.file("src/moveme.txt", 7);
    try env.fx.file("src/my file.txt", 9);
    try env.fx.dir("src/sub");
    try env.fx.dir("dest");
    try env.m.queue(.reload);
    env.t.settle(0.2);
}

/// Where the empty part of pane `i`'s list is.
fn emptyPoint(env: *ts.Env, i: usize) !struct { x: f32, y: f32 } {
    const r = try ts.paneRect(&env.t, &env.m, i);
    return .{ .x = r.x + r.w / 2, .y = r.y + r.h - 90 };
}

test "file URLs decode to paths" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("/Users/me/a b.txt", drops.pathOfUrl(a, "file:///Users/me/a%20b.txt").?);
    try testing.expectEqualStrings("/Users/me/Folder", drops.pathOfUrl(a, "file:///Users/me/Folder/").?);
    try testing.expectEqualStrings("/x/y", drops.pathOfUrl(a, "file://localhost/x/y").?);
    try testing.expectEqualStrings("/caf\u{e9}", drops.pathOfUrl(a, "file:///caf%C3%A9").?);
    try testing.expectEqualStrings("/100%zz", drops.pathOfUrl(a, "file:///100%zz").?); // not an escape: kept
    try testing.expectEqualStrings("/", drops.pathOfUrl(a, "file:///").?);
    try testing.expect(drops.pathOfUrl(a, "https://example.com/a") == null);
    try testing.expect(drops.pathOfUrl(a, "file://host/a") == null);
    try testing.expect(drops.pathOfUrl(a, "") == null);
}

test "a drop from another volume is a copy, on the same volume a move" {
    const fa = @import("file_actions.zig");
    // /dev is its own file system: a path there is "another volume" for a folder in /tmp.
    try testing.expect(fa.otherVolume(&.{"/dev/null"}, "/tmp"));
    try testing.expect(!fa.otherVolume(&.{"/tmp"}, "/tmp"));
    try testing.expect(!fa.otherVolume(&.{"/no/such/file"}, "/tmp")); // unknown: not "other"
}

test "files dropped on a pane move into the folder it shows; Option copies; Undo puts them back" {
    var env: ts.Env = undefined;
    try env.init();
    defer env.deinit();
    try extra(&env);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const moveme = try sub(a, &env, "src/moveme.txt");
    const p = try emptyPoint(&env, 0);
    env.t.drop(p.x, p.y, &.{try urlOf(a, moveme, false)}, "");
    env.t.settle(0.3);
    try testing.expect(env.fx.exists("moveme.txt") and !env.fx.exists("src/moveme.txt"));
    try testing.expect(env.t.hasText("moveme.txt"));
    try testing.expect(try env.selected("moveme.txt")); // what arrived is selected
    try testing.expect(env.m.notice == null);
    try ts.press(&env.t, 'z', .{ .cmd = true });
    try testing.expect(!env.fx.exists("moveme.txt") and env.fx.exists("src/moveme.txt"));

    // Option: a copy. The name has a space and arrives percent-encoded; a folder URL ends in "/".
    const myfile = try sub(a, &env, "src/my file.txt");
    const subdir = try sub(a, &env, "src/sub");
    env.t.setMods(.{ .alt = true });
    env.t.drop(p.x, p.y, &.{ try urlOf(a, myfile, false), try urlOf(a, subdir, true) }, "");
    env.t.setMods(.{});
    env.t.settle(0.3);
    try testing.expect(env.fx.exists("my file.txt") and env.fx.exists("src/my file.txt"));
    try testing.expect(env.fx.exists("sub") and env.fx.exists("src/sub"));
    try testing.expectEqualStrings("Copy of 2 Items", env.m.ops.undoTitle().?);
}

test "a drop on a folder row goes into that folder; into the same folder it does nothing" {
    var env: ts.Env = undefined;
    try env.init();
    defer env.deinit();
    try extra(&env);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const moveme = try sub(a, &env, "src/moveme.txt");
    const row = env.t.findText("dest").?;
    env.t.drop(row.x + row.w / 2, row.y + row.h / 2, &.{try urlOf(a, moveme, false)}, "");
    env.t.settle(0.3);
    try testing.expect(env.fx.exists("dest/moveme.txt") and !env.fx.exists("moveme.txt"));

    // a.txt dropped back on the folder it is in: a no-op, no banner, nothing to undo.
    const before = env.m.ops.undo_stack.items.len;
    const at = try sub(a, &env, "a.txt");
    const p = try emptyPoint(&env, 0);
    env.t.drop(p.x, p.y, &.{try urlOf(a, at, false)}, "");
    env.t.settle(0.3);
    try testing.expectEqual(before, env.m.ops.undo_stack.items.len);
    try testing.expect(env.m.notice == null and env.fx.exists("a.txt"));
}

test "a folder dropped on itself is refused in the service's words; other URLs are ignored" {
    var env: ts.Env = undefined;
    try env.init();
    defer env.deinit();
    try extra(&env);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src = try sub(a, &env, "src");
    const row = env.t.findText("src").?;
    env.t.drop(row.x + row.w / 2, row.y + row.h / 2, &.{try urlOf(a, src, true)}, "");
    env.t.settle(0.3);
    try testing.expect(env.m.notice != null);
    try testing.expect(std.mem.indexOf(u8, env.m.notice.?, "inside itself") != null);
    try testing.expect(env.fx.exists("src/moveme.txt"));

    env.m.clearNotice();
    const p = try emptyPoint(&env, 0);
    env.t.drop(p.x, p.y, &.{"https://example.com/a.txt"}, "just text");
    env.t.settle(0.3);
    try testing.expect(env.m.notice == null and !env.m.ops.canUndo());
}

test "a drop on a sidebar folder moves into it" {
    var env: ts.Env = undefined;
    try env.initWith(.{ .favorite = "dest" });
    defer env.deinit();
    try extra(&env);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const moveme = try sub(a, &env, "src/moveme.txt");
    const row = env.t.findText("Fav").?;
    env.t.drop(row.x + row.w / 2, row.y + row.h / 2, &.{try urlOf(a, moveme, false)}, "");
    env.t.settle(0.3);
    try testing.expect(env.fx.exists("dest/moveme.txt") and !env.fx.exists("src/moveme.txt"));
    // The pane showing the root is unchanged: the file went to the sidebar's folder.
    try testing.expect(!env.fx.exists("moveme.txt"));
}

/// Two panes: pane 0 at the root, pane 1 in `dest`.
fn twoPanes(env: *ts.Env) !void {
    try extra(env);
    try ts.press(&env.t, 'd', .{ .cmd = true });
    const dest = try std.fs.path.join(testing.allocator, &.{ env.fx.root, "dest" });
    defer testing.allocator.free(dest);
    try env.m.queue(.{ .open = dest });
    env.t.settle(0.3);
    try env.m.queue(.{ .focus_pane = env.m.panes.items[0].id });
    env.t.settle(0.2);
}

fn dragRow(env: *ts.Env, name: []const u8, to_x: f32, to_y: f32) !void {
    const r = env.t.findText(name) orelse return error.TextNotFound;
    env.t.drag(r.x + r.w / 2, r.y + r.h / 2, to_x, to_y);
    env.t.settle(0.3);
}

test "dragging a row to another pane moves it there; Option copies" {
    var env: ts.Env = undefined;
    try env.init();
    defer env.deinit();
    try twoPanes(&env);

    const p = try emptyPoint(&env, 1);
    try dragRow(&env, "a.txt", p.x, p.y);
    try testing.expect(env.fx.exists("dest/a.txt") and !env.fx.exists("a.txt"));
    try testing.expect(env.m.view_state.file_drag == null); // the drag is over
    try testing.expectEqualStrings("Move of 1 Item", env.m.ops.undoTitle().?);

    env.t.setMods(.{ .alt = true });
    try dragRow(&env, "b.txt", p.x, p.y);
    env.t.setMods(.{});
    try testing.expect(env.fx.exists("dest/b.txt") and env.fx.exists("b.txt"));
    // The dragged row was not opened or toggled by the press: the tab is still the root.
    try testing.expectEqualStrings(env.fx.root, env.m.panes.items[0].tab().path());
}

test "dragging several selected rows moves them all, onto a folder row of the other pane" {
    var env: ts.Env = undefined;
    try env.init();
    defer env.deinit();
    try twoPanes(&env);
    // Pane 1 shows the root too, so it has a "src" folder row.
    const root = env.fx.root;
    try env.m.queue(.{ .focus_pane = env.m.panes.items[1].id });
    try env.m.queue(.{ .open = root });
    env.t.settle(0.3);
    try env.m.queue(.{ .focus_pane = env.m.panes.items[0].id });
    env.t.settle(0.2);

    try env.click("a.txt");
    try ts.clickTextWith(&env.t, "b.txt", .{ .cmd = true });
    env.t.settle(0.2);
    try testing.expectEqual(@as(usize, 2), env.m.panes.items[0].tab().selection.count());
    // Pane 1's "dest" row (the same text is in both panes: take the right-hand one).
    const r1 = try ts.paneRect(&env.t, &env.m, 1);
    const dest_row = ts.findTextIn(&env.t, r1, "dest").?;
    const from = ts.findTextIn(&env.t, try ts.paneRect(&env.t, &env.m, 0), "a.txt").?;
    env.t.drag(from.x + from.w / 2, from.y + from.h / 2, dest_row.x + dest_row.w / 2, dest_row.y + dest_row.h / 2);
    env.t.settle(0.3);
    try testing.expect(env.fx.exists("dest/a.txt") and env.fx.exists("dest/b.txt"));
    try testing.expect(!env.fx.exists("a.txt") and !env.fx.exists("b.txt"));
}

test "a drag that is let go over nothing does nothing, and a plain click still selects" {
    var env: ts.Env = undefined;
    try env.init();
    defer env.deinit();
    try extra(&env);

    const r = env.t.findText("a.txt").?;
    // Dragged within the same pane's empty area: the same folder, a no-op.
    const p = try emptyPoint(&env, 0);
    env.t.drag(r.x + 2, r.y + 2, p.x, p.y);
    env.t.settle(0.3);
    try testing.expect(env.fx.exists("a.txt") and env.m.notice == null);
    try testing.expect(env.m.view_state.file_drag == null);
    try env.click("b.txt");
    try testing.expect(try env.selected("b.txt"));
}
