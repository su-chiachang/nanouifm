//! Tabs: the index rules of a pane (no window), per-tab history, selection and scroll, and the
//! tab strip through ui.Tester: Cmd+T, "+", close buttons, Cmd+W, Ctrl+Tab, the sidebar's
//! Cmd-click, and dragging a chip along the strip. Every test works in a fresh temp folder.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const app_view = @import("../app.zig");
const model = @import("model.zig");
const Pane = @import("pane.zig").Pane;
const ts = @import("test_support.zig");

const testing = std.testing;
const Fixture = ts.Fixture;

/// root/: alpha/a1.txt, beta/b1.txt, gamma/g1.txt, root.txt.
fn populate(fx: *Fixture) !void {
    try fx.file("alpha/a1.txt", 1);
    try fx.file("beta/b1.txt", 1);
    try fx.file("gamma/g1.txt", 1);
    try fx.file("root.txt", 1);
}

fn ids(p: *const Pane, buf: []u32) []u32 {
    for (p.tabs.items, 0..) |t, i| buf[i] = t.id;
    return buf[0..p.tabs.items.len];
}

fn tabRef(p: *const Pane, i: usize) model.TabRef {
    return .{ .pane = p.id, .tab = p.tabs.items[i].id };
}

fn run(m: *app_view.State, a: model.Action) !void {
    try m.queue(a);
    _ = try m.applyPending();
}

test "pane: addTab, closeTab, cycleTab and moveTab follow the Swift PaneModel" {
    var fx = try Fixture.init();
    defer fx.deinit();
    var p = try Pane.init(testing.allocator, fx.root, .{}, .{ .pane = 1, .tab = 10 });
    defer p.deinit();
    var buf: [8]u32 = undefined;

    _ = try p.addTab(fx.root, 11, false, null, true); // after the shown one, selected
    _ = try p.addTab(fx.root, 12, false, null, true);
    try testing.expectEqualSlices(u32, &.{ 10, 11, 12 }, ids(&p, &buf));
    try testing.expectEqual(@as(usize, 2), p.active);
    // Not selected, inserted before the shown tab: the shown tab moves right and stays shown.
    _ = try p.addTab(fx.root, 13, false, 0, false);
    try testing.expectEqualSlices(u32, &.{ 10, 13, 11, 12 }, ids(&p, &buf));
    try testing.expectEqual(@as(u32, 12), p.tab().id);
    // Not selected, inserted after it: nothing shifts.
    _ = try p.addTab(fx.root, 14, false, 3, false);
    try testing.expectEqualSlices(u32, &.{ 10, 13, 11, 12, 14 }, ids(&p, &buf));
    try testing.expectEqual(@as(u32, 12), p.tab().id);

    // Closing before the shown tab keeps it shown; closing the shown one shows its successor;
    // closing the shown last tab shows the one before.
    var gone = p.closeTab(1).?;
    gone.deinit();
    try testing.expectEqual(@as(u32, 12), p.tab().id);
    gone = p.closeTab(2).?;
    gone.deinit();
    try testing.expectEqualSlices(u32, &.{ 10, 11, 14 }, ids(&p, &buf));
    try testing.expectEqual(@as(u32, 14), p.tab().id);
    gone = p.closeTab(2).?;
    gone.deinit();
    try testing.expectEqual(@as(u32, 11), p.tab().id);
    try testing.expect(p.closeTab(7) == null);

    // Cycling wraps both ways.
    p.cycleTab(1);
    try testing.expectEqual(@as(usize, 0), p.active);
    p.cycleTab(-1);
    try testing.expectEqual(@as(usize, 1), p.active);
    p.cycleTab(-1);
    p.cycleTab(-1);
    try testing.expectEqual(@as(usize, 1), p.active);

    // Moving keeps the same tab shown, whichever tab moved.
    _ = try p.addTab(fx.root, 15, false, null, false); // [10, 11, 15], 11 shown
    p.moveTab(1, 2);
    try testing.expectEqualSlices(u32, &.{ 10, 15, 11 }, ids(&p, &buf));
    try testing.expectEqual(@as(u32, 11), p.tab().id);
    p.moveTab(0, 1);
    try testing.expectEqualSlices(u32, &.{ 15, 10, 11 }, ids(&p, &buf));
    try testing.expectEqual(@as(u32, 11), p.tab().id);
    p.moveTab(2, 0);
    try testing.expectEqualSlices(u32, &.{ 11, 15, 10 }, ids(&p, &buf));
    try testing.expectEqual(@as(u32, 11), p.tab().id);
    p.moveTab(0, 9); // out of range: nothing
    try testing.expectEqualSlices(u32, &.{ 11, 15, 10 }, ids(&p, &buf));

    // The last tab can't be closed.
    gone = p.closeTab(0).?;
    gone.deinit();
    gone = p.closeTab(0).?;
    gone.deinit();
    try testing.expect(p.closeTab(0) == null);
    try testing.expectEqual(@as(usize, 1), p.tabs.items.len);
}

test "model: a new tab keeps its own history, selection and sort-independent listing" {
    var fx = try Fixture.init();
    defer fx.deinit();
    try populate(&fx);
    const alpha = try fx.sub("alpha");
    defer testing.allocator.free(alpha);
    const beta = try fx.sub("beta");
    defer testing.allocator.free(beta);
    var m = try ts.model(&fx, &.{});
    defer m.deinit();

    try m.navigate(alpha); // tab 0: root -> alpha
    try run(&m, .new_tab); // tab 1: alpha, shown, a copy of the folder not of the history
    const p = m.focusedPane();
    try testing.expectEqual(@as(usize, 2), p.tabs.items.len);
    try testing.expectEqual(@as(usize, 1), p.active);
    try testing.expectEqualStrings(alpha, p.tabs.items[1].path());
    try testing.expect(!p.tabs.items[1].canBack()); // its own, fresh history
    try m.navigate(beta); // tab 1: alpha -> beta
    try testing.expectEqualStrings(alpha, p.tabs.items[0].path());

    // Selecting in tab 0 doesn't touch tab 1, and survives switching away and back.
    try run(&m, .{ .select_tab = tabRef(p, 0) });
    const t0 = &p.tabs.items[0];
    try t0.selection.click(m.gpa, t0.listing.visible, 0, .{});
    try testing.expectEqual(@as(usize, 1), t0.selection.count());
    try run(&m, .{ .select_tab = tabRef(p, 1) });
    try testing.expectEqual(@as(usize, 0), m.focusedTab().selection.count());
    try run(&m, .{ .select_tab = tabRef(p, 0) });
    try testing.expectEqual(@as(usize, 1), m.focusedTab().selection.count());

    // Back in tab 0 goes to root; tab 1 stays in beta and can still go back to alpha.
    try m.back();
    try testing.expectEqualStrings(fx.root, p.tabs.items[0].path());
    try testing.expectEqualStrings(beta, p.tabs.items[1].path());
    try run(&m, .{ .select_tab = tabRef(p, 1) });
    try m.back();
    try testing.expectEqualStrings(alpha, p.tabs.items[1].path());
    try testing.expect(p.tabs.items[0].canForward()); // tab 0's own forward entry
}

test "model: actions name tabs by id, so a repeat or a stale one does nothing" {
    var fx = try Fixture.init();
    defer fx.deinit();
    var m = try ts.model(&fx, &.{});
    defer m.deinit();
    try run(&m, .new_tab);
    try run(&m, .new_tab);
    const p = m.focusedPane();
    const doomed = tabRef(p, 1);
    try m.queue(.{ .close_tab = doomed });
    try m.queue(.{ .close_tab = doomed }); // the same click twice
    try m.queue(.{ .select_tab = doomed }); // and a select for a tab that is gone
    try m.queue(.{ .focus_pane = 9999 });
    _ = try m.applyPending();
    try testing.expectEqual(@as(usize, 2), p.tabs.items.len);
    // Closing the only remaining way to lose the last tab does nothing in the last pane.
    try run(&m, .{ .close_tab = tabRef(p, 0) });
    try run(&m, .close_active_tab);
    try run(&m, .close_active_tab);
    try testing.expectEqual(@as(usize, 1), p.tabs.items.len);
    try testing.expectEqual(@as(usize, 1), m.panes.items.len);
}

test "the strip: Cmd+T, the plus button, chips, close buttons, Cmd+W and Ctrl+Tab" {
    var fx = try Fixture.init();
    defer fx.deinit();
    try populate(&fx);
    const alpha = try fx.sub("alpha");
    defer testing.allocator.free(alpha);
    const beta = try fx.sub("beta");
    defer testing.allocator.free(beta);
    const gamma = try fx.sub("gamma");
    defer testing.allocator.free(gamma);
    var m = try ts.model(&fx, &.{});
    defer m.deinit();
    var t: ui.Tester = undefined;
    try ts.open(&t, &m);
    defer t.deinit();
    const pane_rect = try ts.paneRect(&t, &m, 0);
    const strip = ts.stripOf(pane_rect);

    // A tab shows a folder icon and the folder's name.
    try testing.expect(ts.findTextIn(&t, strip, std.fs.path.basename(fx.root)) != null);
    try testing.expect(ts.hasIcon(&t, "folder.fill") and ts.hasIcon(&t, "plus"));

    try m.navigate(alpha);
    try testing.expect(t.shortcut(.{ .key = 't', .cmd = true }));
    t.settle(0.2);
    try testing.expectEqual(@as(usize, 2), m.focusedPane().tabs.items.len); // exactly one
    try testing.expectEqual(@as(usize, 1), m.focusedPane().active);
    try testing.expectEqualStrings(alpha, m.focusedTab().path());
    try m.navigate(beta);
    try ts.clickIconIn(&t, strip, "plus"); // the plus button: also exactly one
    t.settle(0.2);
    try testing.expectEqual(@as(usize, 3), m.focusedPane().tabs.items.len);
    try testing.expectEqual(@as(usize, 2), m.focusedPane().active);
    try m.navigate(gamma);
    t.settle(0.2);
    for ([_][]const u8{ "alpha", "beta", "gamma" }) |n| try testing.expect(ts.findTextIn(&t, strip, n) != null);

    // A chip shows its tab, each with its own listing.
    try ts.clickTextIn(&t, strip, "alpha");
    t.settle(0.2);
    try testing.expectEqual(@as(usize, 0), m.focusedPane().active);
    try testing.expect(t.hasText("a1.txt") and !t.hasText("g1.txt"));
    // Ctrl+Tab and Ctrl+Shift+Tab cycle, wrapping.
    try testing.expect(t.shortcut(.{ .key = ui.Shortcut.tab, .ctrl = true }));
    t.settle(0.2);
    try testing.expect(t.hasText("b1.txt"));
    try testing.expect(t.shortcut(.{ .key = ui.Shortcut.tab, .ctrl = true, .shift = true }));
    try testing.expect(t.shortcut(.{ .key = ui.Shortcut.tab, .ctrl = true, .shift = true }));
    t.settle(0.2);
    try testing.expectEqual(@as(usize, 2), m.focusedPane().active);
    try testing.expect(t.hasText("g1.txt"));

    // The shown tab's close button (the pointer is off the strip, so only that chip has one);
    // then Cmd+W; the last tab of the last pane stays.
    t.moveTo(pane_rect.x + 50, pane_rect.y + 300);
    t.settle(0.2);
    try ts.clickIconIn(&t, strip, "xmark");
    t.settle(0.2);
    try testing.expectEqual(@as(usize, 2), m.focusedPane().tabs.items.len);
    try testing.expect(t.hasText("b1.txt")); // the one before it is shown
    try testing.expect(t.shortcut(.{ .key = 'w', .cmd = true }));
    t.settle(0.2);
    try testing.expectEqual(@as(usize, 1), m.focusedPane().tabs.items.len);
    try testing.expect(t.hasText("a1.txt"));
    try testing.expect(t.shortcut(.{ .key = 'w', .cmd = true }));
    t.settle(0.2);
    try testing.expectEqual(@as(usize, 1), m.focusedPane().tabs.items.len);
    try testing.expectEqual(@as(usize, 1), m.panes.items.len);
    try testing.expect(t.hasText("a1.txt"));
}

test "sidebar: a click navigates the shown tab, a Cmd-click opens a new tab" {
    var fx = try Fixture.init();
    defer fx.deinit();
    try populate(&fx);
    const alpha = try fx.sub("alpha");
    defer testing.allocator.free(alpha);
    const beta = try fx.sub("beta");
    defer testing.allocator.free(beta);
    var m = try ts.model(&fx, &.{ .{ .path = alpha, .title = "Alpha" }, .{ .path = beta, .title = "Beta" } });
    defer m.deinit();
    var t: ui.Tester = undefined;
    try ts.open(&t, &m);
    defer t.deinit();

    try ts.clickTextWith(&t, "Alpha", .{ .cmd = true });
    t.settle(0.2);
    const p = m.focusedPane();
    try testing.expectEqual(@as(usize, 2), p.tabs.items.len);
    try testing.expectEqual(@as(usize, 1), p.active); // the new tab is shown
    try testing.expectEqualStrings(alpha, p.tabs.items[1].path());
    try testing.expectEqualStrings(fx.root, p.tabs.items[0].path());
    try testing.expect(t.hasText("a1.txt"));
    // A plain click moves the shown tab only.
    try t.clickText("Beta");
    t.settle(0.2);
    try testing.expectEqual(@as(usize, 2), p.tabs.items.len);
    try testing.expectEqualStrings(beta, p.tabs.items[1].path());
    try testing.expectEqualStrings(fx.root, p.tabs.items[0].path());
}

test "the strip: dragging a chip along it reorders the tabs; a small move doesn't" {
    var fx = try Fixture.init();
    defer fx.deinit();
    try populate(&fx);
    const alpha = try fx.sub("alpha");
    defer testing.allocator.free(alpha);
    const beta = try fx.sub("beta");
    defer testing.allocator.free(beta);
    const gamma = try fx.sub("gamma");
    defer testing.allocator.free(gamma);
    var m = try ts.model(&fx, &.{});
    defer m.deinit();
    try m.navigate(alpha);
    try run(&m, .new_tab);
    try m.navigate(beta);
    try run(&m, .new_tab);
    try m.navigate(gamma);
    var t: ui.Tester = undefined;
    try ts.open(&t, &m);
    defer t.deinit();
    const strip = ts.stripOf(try ts.paneRect(&t, &m, 0));
    const p = m.focusedPane();
    const alpha_id = p.tabs.items[0].id;

    const a = ts.findTextIn(&t, strip, "alpha").?;
    const g = ts.findTextIn(&t, strip, "gamma").?;
    const y = a.y + a.h / 2;
    // Two points of wobble is a click, not a drag.
    t.down(a.x + a.w / 2, y);
    t.move(a.x + a.w / 2 + 2, y);
    t.up();
    t.settle(0.2);
    try testing.expectEqual(alpha_id, p.tabs.items[0].id);
    try testing.expectEqual(@as(usize, 0), p.active); // pressing a chip showed it

    // Dragging it over the last chip moves it there, and it stays the shown tab.
    t.down(a.x + a.w / 2, y);
    t.move(g.x + g.w / 2, y);
    t.up();
    t.settle(0.2);
    try testing.expectEqual(alpha_id, p.tabs.items[2].id);
    try testing.expectEqual(@as(usize, 2), p.active);
    try testing.expectEqualStrings("beta", p.tabs.items[0].title());
    try testing.expectEqualStrings("gamma", p.tabs.items[1].title());
    try testing.expectEqualStrings("alpha", p.tabs.items[2].title());
    try testing.expect(t.hasText("a1.txt"));
}

test "each tab keeps its own scroll position" {
    var fx = try Fixture.init();
    defer fx.deinit();
    var name: [24]u8 = undefined;
    for (0..300) |i| try fx.file(try std.fmt.bufPrint(&name, "many/n{d:0>4}.txt", .{i}), 1);
    const many = try fx.sub("many");
    defer testing.allocator.free(many);
    var m = try app_view.State.init(testing.allocator, .{ .start_path = many, .home_path = fx.root });
    defer m.deinit();
    var t: ui.Tester = undefined;
    try ts.open(&t, &m);
    defer t.deinit();

    t.scroll(500, 300, -3000);
    t.settle(0.3);
    try testing.expect(t.hasText("n0125.txt") and !t.hasText("n0000.txt"));
    try testing.expect(t.shortcut(.{ .key = 't', .cmd = true })); // a new tab starts at the top
    t.settle(0.3);
    try testing.expect(t.hasText("n0000.txt") and !t.hasText("n0125.txt"));
    try testing.expect(t.shortcut(.{ .key = ui.Shortcut.tab, .ctrl = true, .shift = true }));
    t.settle(0.3);
    try testing.expect(t.hasText("n0125.txt") and !t.hasText("n0000.txt")); // the first is where it was
    try testing.expect(t.shortcut(.{ .key = ui.Shortcut.tab, .ctrl = true }));
    t.settle(0.3);
    try testing.expect(t.hasText("n0000.txt"));
}
