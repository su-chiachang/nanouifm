//! The path bar: crumbs with their icons (the home icon for Home), the item count, a click on a
//! crumb navigating, and the crumbs as drop targets (Finder drops and rows dragged from another
//! pane: a move, Option copies, a highlight). Temp folders only.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const ts = @import("test_support.zig");
const Rect = @import("pane_sizes.zig").Rect;

const testing = std.testing;

fn urlOf(a: std.mem.Allocator, path: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, "file://");
    for (path) |ch| switch (ch) {
        ' ', '%', '#', '?' => try out.print(a, "%{X:0>2}", .{ch}),
        else => try out.append(a, ch),
    };
    return out.items;
}

/// root/: a.txt, b.txt, dir/ (inner.txt), src/ (moveme.txt, "my file.txt"), dest/.
fn extra(env: *ts.Env) !void {
    try env.fx.file("src/moveme.txt", 7);
    try env.fx.file("src/my file.txt", 9);
    try env.fx.dir("dest");
    try env.m.queue(.reload);
    env.t.settle(0.2);
}

fn goTo(env: *ts.Env, rel: []const u8) !void {
    const p = try env.fx.sub(rel);
    defer testing.allocator.free(p);
    try env.m.queue(.{ .open = p });
    env.t.settle(0.3);
}

/// The crumb text `s` in the path bar of pane `i`: the bar is the bottom strip of the pane.
fn crumb(env: *ts.Env, i: usize, s: []const u8) !ui.Rect {
    const r = try ts.paneRect(&env.t, &env.m, i);
    const bar: Rect = .{ .x = r.x, .y = r.y + r.h - 32, .w = r.w, .h = 32 };
    return ts.findTextIn(&env.t, bar, s) orelse error.TextNotFound;
}

fn mid(r: ui.Rect) struct { x: f32, y: f32 } {
    return .{ .x = r.x + r.w / 2, .y = r.y + r.h / 2 };
}

fn rootName(env: *ts.Env) []const u8 {
    return std.fs.path.basename(env.fx.root);
}

test "crumbs: the home icon for Home, folder icons below it, a click navigates" {
    var env: ts.Env = undefined;
    try env.init();
    defer env.deinit();
    try goTo(&env, "dir");
    try testing.expect(ts.hasIcon(&env.t, "house")); // Home (the temp folder is home here)
    try testing.expect(ts.hasIcon(&env.t, "chevron.right"));
    const dir_crumb = try crumb(&env, 0, "dir");
    try testing.expect(dir_crumb.w > 0);
    const root_crumb = try crumb(&env, 0, rootName(&env));
    const p = mid(root_crumb);
    env.t.click(p.x, p.y);
    env.t.settle(0.3);
    try testing.expectEqualStrings(env.fx.root, env.m.focusedTab().path());
    // Back below Home: the crumb of the folder you are in is the last one.
    try goTo(&env, "dir");
    const here = mid(try crumb(&env, 0, "dir"));
    env.t.click(here.x, here.y); // its own crumb: navigates to where it already is
    env.t.settle(0.3);
    try testing.expect(env.m.notice == null);
}

test "the item count sits beside the crumbs" {
    var env: ts.Env = undefined;
    try env.init();
    defer env.deinit();
    try testing.expect(env.t.hasText("3 items"));
    try env.click("a.txt");
    try testing.expect(env.t.hasText("1 of 3 selected"));
    try goTo(&env, "dir");
    try testing.expect(env.t.hasText("1 item"));
}

test "files dropped from Finder on a crumb move into that folder; Option copies" {
    var env: ts.Env = undefined;
    try env.init();
    defer env.deinit();
    try extra(&env);
    try goTo(&env, "dest");
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The pane shows dest/; the root's crumb is a folder further up. The drop lands in the ROOT,
    // not in dest (the pane's own drop target is below the crumb).
    const moveme = try std.fs.path.join(a, &.{ env.fx.root, "src/moveme.txt" });
    const p = mid(try crumb(&env, 0, rootName(&env)));
    env.t.drop(p.x, p.y, &.{try urlOf(a, moveme)}, "");
    env.t.settle(0.3);
    try testing.expect(env.fx.exists("moveme.txt"));
    try testing.expect(!env.fx.exists("src/moveme.txt") and !env.fx.exists("dest/moveme.txt"));
    try testing.expect(env.m.notice == null);
    try testing.expectEqualStrings("Move of 1 Item", env.m.ops.undoTitle().?);

    // Option: a copy; the name has a space.
    const myfile = try std.fs.path.join(a, &.{ env.fx.root, "src/my file.txt" });
    env.t.setMods(.{ .alt = true });
    env.t.drop(p.x, p.y, &.{try urlOf(a, myfile)}, "");
    env.t.setMods(.{});
    env.t.settle(0.3);
    try testing.expect(env.fx.exists("my file.txt") and env.fx.exists("src/my file.txt"));
    try testing.expect(!env.fx.exists("dest/my file.txt"));
    try testing.expectEqualStrings("Copy of 1 Item", env.m.ops.undoTitle().?);
    // The pane is still where it was.
    const dest = try env.fx.sub("dest");
    defer testing.allocator.free(dest);
    try testing.expectEqualStrings(dest, env.m.focusedTab().path());
}

test "a drop on the crumb of the folder shown lands there, as on the pane" {
    var env: ts.Env = undefined;
    try env.init();
    defer env.deinit();
    try extra(&env);
    try goTo(&env, "dest");
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const moveme = try std.fs.path.join(a, &.{ env.fx.root, "src/moveme.txt" });
    const p = mid(try crumb(&env, 0, "dest"));
    env.t.drop(p.x, p.y, &.{try urlOf(a, moveme)}, "");
    env.t.settle(0.3);
    try testing.expect(env.fx.exists("dest/moveme.txt") and !env.fx.exists("src/moveme.txt"));
}

fn twoPanes(env: *ts.Env) !void {
    try extra(env);
    try ts.press(&env.t, 'd', .{ .cmd = true });
    try goTo(env, "dest"); // pane 1 (the new one, focused)
    try env.m.queue(.{ .focus_pane = env.m.panes.items[0].id });
    env.t.settle(0.2);
    try goTo(env, "src");
}

test "a row dragged from another pane onto a crumb moves into that folder" {
    var env: ts.Env = undefined;
    try env.init();
    defer env.deinit();
    try twoPanes(&env);
    // Pane 0 shows src/, pane 1 dest/: drag moveme.txt onto pane 1's root crumb.
    const row = ts.findTextIn(&env.t, try ts.paneRect(&env.t, &env.m, 0), "moveme.txt").?;
    const to = mid(try crumb(&env, 1, rootName(&env)));
    env.t.drag(row.x + row.w / 2, row.y + row.h / 2, to.x, to.y);
    env.t.settle(0.3);
    try testing.expect(env.fx.exists("moveme.txt"));
    try testing.expect(!env.fx.exists("src/moveme.txt") and !env.fx.exists("dest/moveme.txt"));
    try testing.expect(env.m.view_state.file_drag == null);

    // Option copies.
    const row2 = ts.findTextIn(&env.t, try ts.paneRect(&env.t, &env.m, 0), "my file.txt").?;
    env.t.setMods(.{ .alt = true });
    env.t.drag(row2.x + row2.w / 2, row2.y + row2.h / 2, to.x, to.y);
    env.t.setMods(.{});
    env.t.settle(0.3);
    try testing.expect(env.fx.exists("my file.txt") and env.fx.exists("src/my file.txt"));
}

test "a crumb lights up under a dragged row" {
    var env: ts.Env = undefined;
    try env.init();
    defer env.deinit();
    try twoPanes(&env);
    const row = ts.findTextIn(&env.t, try ts.paneRect(&env.t, &env.m, 0), "moveme.txt").?;
    const target = try crumb(&env, 1, rootName(&env));
    const to = mid(target);
    env.t.down(row.x + row.w / 2, row.y + row.h / 2);
    env.t.move(row.x + row.w / 2 + 12, row.y + row.h / 2 + 12);
    env.t.move(to.x, to.y);
    env.t.settle(0.2);
    var lit = false;
    const accent = env.t.ctx.theme.accent.alpha(0.3);
    for (env.t.ctx.nodes.items) |n| {
        const bg = n.style.background orelse continue;
        if (bg.r == accent.r and bg.g == accent.g and bg.b == accent.b and bg.a == accent.a and
            n.rect.x < target.x + target.w and n.rect.x + n.rect.w > target.x and
            n.rect.y < target.y + target.h and n.rect.y + n.rect.h > target.y) lit = true;
    }
    env.t.up();
    env.t.settle(0.3);
    try testing.expect(lit);
}
