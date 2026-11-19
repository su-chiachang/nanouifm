//! List view's keyboard and folder expansion through ui.Tester over temp trees: arrows, Home/End,
//! Shift extension, type-to-select, Cmd+Down and double-click (a folder opens, a file goes to the
//! injected opener, never to a real app), and disclosure triangles with their persistence.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const app_view = @import("../app.zig");
const style = @import("style.zig");
const ts = @import("test_support.zig");

const testing = std.testing;
const S = ui.Shortcut;
const right_tri = "arrowtriangle.right.fill";
const down_tri = "arrowtriangle.down.fill";

/// root/: alpha/ (beta/ (gamma/ (deep.txt)), a1.txt), types/ (banana, cherry), apple.txt, readme.md.
/// Rows: alpha, types, apple.txt, readme.md.
fn tree(fx: *ts.Fixture) !void {
    try fx.file("alpha/beta/gamma/deep.txt", 5);
    try fx.file("alpha/a1.txt", 7);
    try fx.file("types/banana", 1);
    try fx.file("types/cherry", 1);
    try fx.file("apple.txt", 100);
    try fx.file("readme.md", 3);
}

fn selectedIs(m: *app_view.State, fx: *ts.Fixture, rel: []const u8) !bool {
    const p = try fx.sub(rel);
    defer testing.allocator.free(p);
    const sel = &m.focusedTab().selection;
    return sel.count() == 1 and sel.contains(p);
}

fn rowNames(m: *app_view.State, out: *std.ArrayList([]const u8)) !void {
    for (m.focusedTab().exp.items) |it| try out.append(testing.allocator, it.name);
}

fn expectRows(m: *app_view.State, want: []const []const u8) !void {
    var got: std.ArrayList([]const u8) = .empty;
    defer got.deinit(testing.allocator);
    try rowNames(m, &got);
    try testing.expectEqual(want.len, got.items.len);
    for (want, got.items) |w, g| try testing.expectEqualStrings(w, g);
}

test "Up, Down, Home and End move the selection; Shift extends it" {
    var fx = try ts.Fixture.init();
    defer fx.deinit();
    try tree(&fx);
    var m = try ts.model(&fx, &.{});
    defer m.deinit();
    var t: ui.Tester = undefined;
    try ts.open(&t, &m);
    defer t.deinit();
    const tab = m.focusedTab();
    try expectRows(&m, &.{ "alpha", "types", "apple.txt", "readme.md" });

    try ts.press(&t, S.down, .{}); // nothing selected: the first row
    try testing.expect(try selectedIs(&m, &fx, "alpha"));
    try ts.press(&t, S.down, .{});
    try testing.expect(try selectedIs(&m, &fx, "types"));
    try ts.press(&t, S.up, .{});
    try ts.press(&t, S.up, .{}); // at the top: stays
    try testing.expect(try selectedIs(&m, &fx, "alpha"));
    try ts.press(&t, S.end, .{});
    try testing.expect(try selectedIs(&m, &fx, "readme.md"));
    try ts.press(&t, S.down, .{}); // at the bottom: stays
    try testing.expect(try selectedIs(&m, &fx, "readme.md"));
    try ts.press(&t, S.home, .{});
    try testing.expect(try selectedIs(&m, &fx, "alpha"));
    try ts.press(&t, S.down, .{ .shift = true });
    try ts.press(&t, S.down, .{ .shift = true });
    try testing.expectEqual(@as(usize, 3), tab.selection.count()); // alpha, types, apple.txt
    try ts.press(&t, S.up, .{ .shift = true });
    try testing.expectEqual(@as(usize, 2), tab.selection.count());
    try ts.press(&t, S.end, .{ .shift = true });
    try testing.expectEqual(@as(usize, 4), tab.selection.count());
    try ts.press(&t, S.up, .{}); // plain: collapses to the row above the lead
    try testing.expect(try selectedIs(&m, &fx, "apple.txt"));
    // Up on a list with nothing selected takes the last row.
    tab.selection.clear(testing.allocator);
    try ts.press(&t, S.up, .{});
    try testing.expect(try selectedIs(&m, &fx, "readme.md"));
}

test "the keys scroll the selected row into sight" {
    var fx = try ts.Fixture.init();
    defer fx.deinit();
    for (0..60) |i| {
        var buf: [32]u8 = undefined;
        try fx.file(try std.fmt.bufPrint(&buf, "d/file{d:0>2}.txt", .{i}), 1);
    }
    var m = try ts.modelAt(&fx, "d", &.{});
    defer m.deinit();
    var t: ui.Tester = undefined;
    try ts.open(&t, &m);
    defer t.deinit();
    try testing.expect(t.hasText("file00.txt") and !t.hasText("file59.txt"));
    try ts.press(&t, S.end, .{});
    t.advance(0.2);
    try testing.expect(t.hasText("file59.txt") and !t.hasText("file00.txt"));
    try ts.press(&t, S.home, .{});
    t.advance(0.2);
    try testing.expect(t.hasText("file00.txt") and !t.hasText("file59.txt"));
    for (0..30) |_| try ts.press(&t, S.down, .{});
    t.advance(0.2);
    try testing.expect(t.hasText("file29.txt")); // moved down a page and a half: follows the selection
}

test "type-to-select in the list" {
    var fx = try ts.Fixture.init();
    defer fx.deinit();
    try tree(&fx);
    var m = try ts.model(&fx, &.{});
    defer m.deinit();
    var t: ui.Tester = undefined;
    try ts.open(&t, &m);
    defer t.deinit();
    try ts.press(&t, 'r', .{});
    try testing.expect(try selectedIs(&m, &fx, "readme.md"));
    t.advance(0.2);
    try ts.press(&t, 'e', .{});
    try testing.expect(try selectedIs(&m, &fx, "readme.md"));
    t.advance(1.4);
    try ts.press(&t, 'a', .{});
    try testing.expect(try selectedIs(&m, &fx, "alpha"));
    t.advance(0.2);
    try ts.press(&t, 'p', .{}); // "ap": apple.txt
    try testing.expect(try selectedIs(&m, &fx, "apple.txt"));
    // An arrow key ends the prefix.
    try ts.press(&t, S.up, .{});
    try testing.expect(try selectedIs(&m, &fx, "types"));
    t.advance(0.2);
    try ts.press(&t, 'a', .{});
    try testing.expect(try selectedIs(&m, &fx, "alpha"));
}

test "Cmd+Down (Return renames now) opens a folder; a file goes to the injected opener only" {
    var fx = try ts.Fixture.init();
    defer fx.deinit();
    defer ts.resetOpened();
    try tree(&fx);
    var m = try ts.model(&fx, &.{});
    defer m.deinit();
    var t: ui.Tester = undefined;
    try ts.open(&t, &m);
    defer t.deinit();

    try t.clickText("apple.txt");
    t.settle(0.2);
    try ts.press(&t, S.down, .{ .cmd = true });
    try testing.expectEqual(@as(usize, 1), ts.opened.items.len);
    const apple = try fx.sub("apple.txt");
    defer testing.allocator.free(apple);
    try testing.expectEqualStrings(apple, ts.opened.items[0]);
    try testing.expectEqualStrings(fx.root, m.focusedTab().path()); // a file leaves the folder alone

    // Double-click on a file: the same.
    const r = t.findText("readme.md").?;
    t.doubleClick(r.x + r.w / 2, r.y + r.h / 2);
    t.settle(0.2);
    try testing.expectEqual(@as(usize, 2), ts.opened.items.len);
    try testing.expect(std.mem.endsWith(u8, ts.opened.items[1], "readme.md"));

    // Return on a folder goes there, with a history entry.
    try t.clickText("types");
    t.settle(0.2);
    try ts.press(&t, S.down, .{ .cmd = true });
    const types = try fx.sub("types");
    defer testing.allocator.free(types);
    try testing.expectEqualStrings(types, m.focusedTab().path());
    try testing.expect(m.focusedTab().canBack());
    try testing.expect(t.hasText("banana"));
    try testing.expectEqual(@as(usize, 2), ts.opened.items.len);

    // With a file and a folder selected only the file opens.
    try ts.press(&t, S.up, .{ .cmd = true });
    try testing.expectEqualStrings(fx.root, m.focusedTab().path());
    try ts.press(&t, S.home, .{});
    try ts.press(&t, S.end, .{ .shift = true });
    try ts.press(&t, S.down, .{ .cmd = true });
    try testing.expectEqual(@as(usize, 4), ts.opened.items.len); // apple.txt and readme.md
    try testing.expectEqualStrings(fx.root, m.focusedTab().path());
}

test "without an opener nothing is launched, and a failing one raises a notice" {
    var fx = try ts.Fixture.init();
    defer fx.deinit();
    defer ts.resetOpened();
    try tree(&fx);
    const apple = try fx.sub("apple.txt");
    defer testing.allocator.free(apple);
    var m = try app_view.State.init(testing.allocator, .{ .start_path = fx.root, .home_path = fx.root });
    defer m.deinit();
    try testing.expect(m.opener == null);
    try m.queue(.{ .open_file = apple });
    _ = try m.applyPending();
    try testing.expectEqual(@as(usize, 0), ts.opened.items.len);
    try testing.expect(m.notice == null);
    m.opener = struct {
        fn never(_: []const u8) bool {
            return false;
        }
    }.never;
    try m.queue(.{ .open_file = apple });
    _ = try m.applyPending();
    try testing.expect(m.notice != null and std.mem.indexOf(u8, m.notice.?, "apple.txt") != null);
}

test "disclosure triangles open folders in place, nested and indented" {
    var fx = try ts.Fixture.init();
    defer fx.deinit();
    try tree(&fx);
    var m = try ts.model(&fx, &.{});
    defer m.deinit();
    var t: ui.Tester = undefined;
    try ts.open(&t, &m);
    defer t.deinit();
    const tab = m.focusedTab();
    const pane = try ts.paneRect(&t, &m, 0);
    const below = pane.y + style.tab_strip_height + style.toolbar_height + style.header_height;

    try testing.expect(ts.hasIcon(&t, right_tri) and !ts.hasIcon(&t, down_tri));
    var tri = ts.iconRectBelow(&t, right_tri, below).?;
    t.click(tri.x + tri.w / 2, tri.y + tri.h / 2); // alpha's
    t.settle(0.3);
    try expectRows(&m, &.{ "alpha", "beta", "a1.txt", "types", "apple.txt", "readme.md" });
    try testing.expectEqual(@as(u16, 1), tab.exp.depth[1]);
    try testing.expectEqual(@as(usize, 0), tab.selection.count()); // the triangle doesn't select
    try testing.expect(ts.hasIcon(&t, down_tri));
    // The nested row is indented relative to its parent.
    try testing.expect(t.findText("beta").?.x > t.findText("alpha").?.x + 10);

    tri = ts.iconRectBelow(&t, right_tri, below).?; // beta's (alpha's is open now)
    t.click(tri.x + tri.w / 2, tri.y + tri.h / 2);
    t.settle(0.3);
    try expectRows(&m, &.{ "alpha", "beta", "gamma", "a1.txt", "types", "apple.txt", "readme.md" });
    try testing.expectEqual(@as(u16, 2), tab.exp.depth[2]);

    // Closing alpha closes beta with it: alpha opens again with beta closed.
    tri = ts.iconRectBelow(&t, down_tri, below).?;
    t.click(tri.x + tri.w / 2, tri.y + tri.h / 2);
    t.settle(0.3);
    try expectRows(&m, &.{ "alpha", "types", "apple.txt", "readme.md" });
    tri = ts.iconRectBelow(&t, right_tri, below).?;
    t.click(tri.x + tri.w / 2, tri.y + tri.h / 2);
    t.settle(0.3);
    try expectRows(&m, &.{ "alpha", "beta", "a1.txt", "types", "apple.txt", "readme.md" });
    // Clicking a nested row selects it like any other (double-click opens a folder there).
    try t.clickText("a1.txt");
    t.settle(0.2);
    try testing.expect(try selectedIs(&m, &fx, "alpha/a1.txt"));
}

test "expansion and a nested selection survive a refresh, a sort and hidden files; a visit drops it" {
    var fx = try ts.Fixture.init();
    defer fx.deinit();
    try tree(&fx);
    try fx.file("alpha/.hidden", 1);
    var m = try ts.model(&fx, &.{});
    defer m.deinit();
    var t: ui.Tester = undefined;
    try ts.open(&t, &m);
    defer t.deinit();
    const tab = m.focusedTab();
    const alpha = try fx.sub("alpha");
    defer testing.allocator.free(alpha);
    try tab.setExpanded(alpha, true, m.opts(m.focusedPane()));
    t.settle(0.3);
    try t.clickText("a1.txt");
    t.settle(0.2);
    try expectRows(&m, &.{ "alpha", "beta", "a1.txt", "types", "apple.txt", "readme.md" });

    try fx.file("alpha/new.txt", 3); // appears in the open folder at the next refresh
    try m.queue(.reload);
    t.settle(0.3);
    try expectRows(&m, &.{ "alpha", "beta", "a1.txt", "new.txt", "types", "apple.txt", "readme.md" });
    try testing.expect(try selectedIs(&m, &fx, "alpha/a1.txt"));

    try m.queue(.toggle_hidden);
    t.settle(0.3);
    try testing.expect(t.hasText(".hidden"));
    try testing.expect(try selectedIs(&m, &fx, "alpha/a1.txt"));
    try m.queue(.toggle_hidden);
    try m.queue(.{ .sort = .size });
    t.settle(0.3);
    // By size ascending the open folder's files too: a1.txt (7), new.txt (3) -> new.txt first.
    try expectRows(&m, &.{ "alpha", "beta", "new.txt", "a1.txt", "types", "readme.md", "apple.txt" });
    try testing.expect(try selectedIs(&m, &fx, "alpha/a1.txt"));

    try m.navigate(alpha);
    try testing.expect(!tab.exp.isExpanded(alpha));
    try m.back();
    try expectRows(&m, &.{ "alpha", "types", "readme.md", "apple.txt" });
}

test "Right opens a folder, Right again steps in, Left steps out and closes" {
    var fx = try ts.Fixture.init();
    defer fx.deinit();
    try tree(&fx);
    var m = try ts.model(&fx, &.{});
    defer m.deinit();
    var t: ui.Tester = undefined;
    try ts.open(&t, &m);
    defer t.deinit();
    try ts.press(&t, S.down, .{}); // alpha
    try ts.press(&t, S.right, .{});
    try expectRows(&m, &.{ "alpha", "beta", "a1.txt", "types", "apple.txt", "readme.md" });
    try testing.expect(try selectedIs(&m, &fx, "alpha"));
    try ts.press(&t, S.right, .{}); // into the opened folder: beta
    try testing.expect(try selectedIs(&m, &fx, "alpha/beta"));
    try ts.press(&t, S.right, .{}); // opens beta
    try ts.press(&t, S.down, .{});
    try testing.expect(try selectedIs(&m, &fx, "alpha/beta/gamma"));
    try ts.press(&t, S.left, .{}); // gamma is closed: up to its parent beta
    try testing.expect(try selectedIs(&m, &fx, "alpha/beta"));
    try ts.press(&t, S.left, .{}); // beta is open: closes
    try expectRows(&m, &.{ "alpha", "beta", "a1.txt", "types", "apple.txt", "readme.md" });
    try ts.press(&t, S.left, .{}); // beta is closed now: up to its parent alpha
    try testing.expect(try selectedIs(&m, &fx, "alpha"));
    try ts.press(&t, S.left, .{}); // alpha is open: closes
    try expectRows(&m, &.{ "alpha", "types", "apple.txt", "readme.md" });
}
