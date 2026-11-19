//! Split panes: docking beside the focused pane, focus, closing panes, the layout presets,
//! dividers, and what a pane keeps to itself (sort order, tabs). Through ui.Tester over temp
//! folders; the layout rules are the core's, so these check that the model and the view apply
//! them (reading order, folders, tabs folded into the last pane).
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const app_view = @import("../app.zig");
const model = @import("model.zig");
const pane_sizes = @import("pane_sizes.zig");
const pane_layout = @import("../core/pane_layout.zig");
const ts = @import("test_support.zig");

const testing = std.testing;
const Fixture = ts.Fixture;
const LayoutPreset = pane_layout.LayoutPreset;

/// root/: alpha/a1.txt, beta/b1.txt, gamma/g1.txt, root.txt, .hid.
fn populate(fx: *Fixture) !void {
    try fx.file("alpha/a1.txt", 1);
    try fx.file("beta/b1.txt", 1);
    try fx.file("gamma/g1.txt", 1);
    try fx.file("root.txt", 1);
    try fx.file(".hid", 1);
}

fn run(m: *app_view.State, a: model.Action) !void {
    try m.queue(a);
    _ = try m.applyPending();
    try ts.expectInSync(m);
}

fn preset(m: *app_view.State) !?LayoutPreset {
    return LayoutPreset.matching(testing.allocator, &m.layout);
}

fn pathOf(m: *app_view.State, i: usize) []const u8 {
    return m.panes.items[i].tab().path();
}

test "Cmd+D docks a pane to the right at the focused folder, Shift+Cmd+D below" {
    var fx = try Fixture.init();
    defer fx.deinit();
    try populate(&fx);
    const alpha = try fx.sub("alpha");
    defer testing.allocator.free(alpha);
    var m = try ts.model(&fx, &.{});
    defer m.deinit();
    try m.navigate(alpha);
    var t: ui.Tester = undefined;
    try ts.open(&t, &m);
    defer t.deinit();

    try testing.expect(t.shortcut(.{ .key = 'd', .cmd = true }));
    t.settle(0.2);
    try ts.expectInSync(&m);
    try testing.expectEqual(@as(usize, 2), m.panes.items.len); // exactly one
    try testing.expectEqual(LayoutPreset.two_columns, (try preset(&m)).?);
    try testing.expectEqual(@as(usize, 1), m.focused); // the new pane has the focus
    try testing.expectEqualStrings(alpha, pathOf(&m, 0));
    try testing.expectEqualStrings(alpha, pathOf(&m, 1));
    const a = try ts.paneRect(&t, &m, 0);
    const b = try ts.paneRect(&t, &m, 1);
    try testing.expect(@abs(a.w - b.w) <= 1 and a.h == b.h and a.y == b.y);
    try testing.expectEqual(a.x + a.w + 1, b.x); // a hairline between them
    try testing.expectEqual(@as(f32, 212), a.x); // right of the sidebar
    try testing.expectEqual(@as(f32, 900), b.x + b.w);

    try testing.expect(t.shortcut(.{ .key = 'd', .cmd = true, .shift = true }));
    t.settle(0.2);
    try ts.expectInSync(&m);
    try testing.expectEqual(@as(usize, 3), m.panes.items.len);
    try testing.expectEqual(LayoutPreset.left_and_right_stack, (try preset(&m)).?);
    try testing.expectEqual(@as(usize, 2), m.focused);
    const c = try ts.paneRect(&t, &m, 2);
    const b2 = try ts.paneRect(&t, &m, 1);
    try testing.expectEqual(b2.x, c.x);
    try testing.expect(c.y > b2.y and @abs(c.h - b2.h) <= 1);
    // Each pane draws its own list, strip and path bar.
    for (0..3) |i| try testing.expect(ts.findTextIn(&t, try ts.paneRect(&t, &m, i), "a1.txt") != null);
}

test "a pane docks next to the focused one, not at the end" {
    var fx = try Fixture.init();
    defer fx.deinit();
    var m = try ts.model(&fx, &.{});
    defer m.deinit();
    try run(&m, .{ .split = .side_by_side });
    try run(&m, .{ .split = .side_by_side }); // three columns, the last focused
    const first = m.panes.items[0].id;
    const last = m.panes.items[2].id;
    try run(&m, .{ .focus_pane = first });
    try run(&m, .{ .split = .side_by_side });
    try testing.expectEqual(@as(usize, 4), m.panes.items.len);
    try testing.expectEqual(LayoutPreset.four_columns, (try preset(&m)).?);
    try testing.expectEqual(first, m.panes.items[0].id);
    try testing.expectEqual(last, m.panes.items[3].id);
    try testing.expectEqual(@as(usize, 1), m.focused); // the new pane sits right of the first
    // Ids are unique and stable.
    for (m.panes.items, 0..) |p, i| for (m.panes.items[i + 1 ..]) |q| try testing.expect(p.id != q.id);
}

test "Cmd+Opt+Left and Right move the focus, wrapping around" {
    var fx = try Fixture.init();
    defer fx.deinit();
    var m = try ts.model(&fx, &.{});
    defer m.deinit();
    var t: ui.Tester = undefined;
    try ts.open(&t, &m);
    defer t.deinit();
    try testing.expect(t.shortcut(.{ .key = 'd', .cmd = true }));
    try testing.expect(t.shortcut(.{ .key = 'd', .cmd = true }));
    t.settle(0.2);
    try testing.expectEqual(@as(usize, 2), m.focused);
    try testing.expect(t.shortcut(.{ .key = ui.Shortcut.right, .cmd = true, .alt = true }));
    t.settle(0.2);
    try testing.expectEqual(@as(usize, 0), m.focused); // wrapped
    try testing.expect(t.shortcut(.{ .key = ui.Shortcut.left, .cmd = true, .alt = true }));
    t.settle(0.2);
    try testing.expectEqual(@as(usize, 2), m.focused);
    try testing.expect(t.shortcut(.{ .key = ui.Shortcut.left, .cmd = true, .alt = true }));
    t.settle(0.2);
    try testing.expectEqual(@as(usize, 1), m.focused);
}

test "a click focuses a pane and acts in it; the sidebar goes to the focused pane" {
    var fx = try Fixture.init();
    defer fx.deinit();
    try populate(&fx);
    const alpha = try fx.sub("alpha");
    defer testing.allocator.free(alpha);
    const beta = try fx.sub("beta");
    defer testing.allocator.free(beta);
    const gamma = try fx.sub("gamma");
    defer testing.allocator.free(gamma);
    var m = try ts.model(&fx, &.{ .{ .path = alpha, .title = "Alpha" }, .{ .path = beta, .title = "Beta" }, .{ .path = gamma, .title = "Gamma" } });
    defer m.deinit();
    try m.navigate(alpha);
    var t: ui.Tester = undefined;
    try ts.open(&t, &m);
    defer t.deinit();
    try testing.expect(t.shortcut(.{ .key = 'd', .cmd = true }));
    t.settle(0.2);
    try testing.expectEqual(@as(usize, 1), m.focused);
    const left = try ts.paneRect(&t, &m, 0);
    const right = try ts.paneRect(&t, &m, 1);

    // Clicking a row in the left pane focuses it and selects there only.
    try ts.clickTextIn(&t, left, "a1.txt");
    t.settle(0.2);
    try testing.expectEqual(@as(usize, 0), m.focused);
    try testing.expectEqual(@as(usize, 1), m.panes.items[0].tab().selection.count());
    try testing.expectEqual(@as(usize, 0), m.panes.items[1].tab().selection.count());

    // The sidebar navigates the focused pane only.
    try t.clickText("Beta");
    t.settle(0.2);
    try testing.expectEqualStrings(beta, pathOf(&m, 0));
    try testing.expectEqualStrings(alpha, pathOf(&m, 1));
    try testing.expect(ts.findTextIn(&t, left, "b1.txt") != null and ts.findTextIn(&t, right, "a1.txt") != null);
    try ts.clickTextIn(&t, right, "a1.txt"); // focus the right pane, then the sidebar again
    t.settle(0.2);
    try testing.expectEqual(@as(usize, 1), m.focused);
    try t.clickText("Gamma");
    t.settle(0.2);
    try testing.expectEqualStrings(beta, pathOf(&m, 0));
    try testing.expectEqualStrings(gamma, pathOf(&m, 1));
    // A Cmd-click opens a new tab in the focused pane.
    try ts.clickTextWith(&t, "Beta", .{ .cmd = true });
    t.settle(0.2);
    try testing.expectEqual(@as(usize, 2), m.panes.items[1].tabs.items.len);
    try testing.expectEqual(@as(usize, 1), m.panes.items[0].tabs.items.len);

    // A toolbar button in the unfocused pane acts on that pane, which takes the focus.
    try ts.clickIconIn(&t, left, "chevron.up");
    t.settle(0.2);
    try testing.expectEqual(@as(usize, 0), m.focused);
    try testing.expectEqualStrings(fx.root, pathOf(&m, 0));
    try testing.expectEqualStrings(beta, pathOf(&m, 1)); // untouched: its new tab shows beta
}

test "closing the last tab of a pane closes the pane; the focus goes to the one before" {
    var fx = try Fixture.init();
    defer fx.deinit();
    var m = try ts.model(&fx, &.{});
    defer m.deinit();
    var t: ui.Tester = undefined;
    try ts.open(&t, &m);
    defer t.deinit();
    try testing.expect(t.shortcut(.{ .key = 'd', .cmd = true }));
    try testing.expect(t.shortcut(.{ .key = 'd', .cmd = true }));
    t.settle(0.2);
    try testing.expectEqual(@as(usize, 3), m.panes.items.len);
    try run(&m, .new_tab); // the third pane has two tabs
    const second = m.panes.items[1].id;

    try testing.expect(t.shortcut(.{ .key = 'w', .cmd = true })); // a tab, not the pane
    t.settle(0.2);
    try testing.expectEqual(@as(usize, 3), m.panes.items.len);
    try testing.expectEqual(@as(usize, 1), m.panes.items[2].tabs.items.len);
    try testing.expect(t.shortcut(.{ .key = 'w', .cmd = true })); // the last tab: the pane
    t.settle(0.2);
    try ts.expectInSync(&m);
    try testing.expectEqual(@as(usize, 2), m.panes.items.len);
    try testing.expectEqual(second, m.panes.items[m.focused].id);
    try testing.expectEqual(LayoutPreset.two_columns, (try preset(&m)).?);

    // The close button of a lone tab does the same, in a pane that isn't the focused one.
    const first_strip = ts.stripOf(try ts.paneRect(&t, &m, 0));
    try ts.clickIconIn(&t, first_strip, "xmark");
    t.settle(0.2);
    try ts.expectInSync(&m);
    try testing.expectEqual(@as(usize, 1), m.panes.items.len);
    try testing.expectEqual(second, m.panes.items[0].id);
    try testing.expectEqual(@as(usize, 0), m.focused);
    // The last pane keeps its last tab.
    try testing.expect(t.shortcut(.{ .key = 'w', .cmd = true }));
    t.settle(0.2);
    try testing.expectEqual(@as(usize, 1), m.panes.items.len);
    try testing.expectEqual(@as(usize, 1), m.panes.items[0].tabs.items.len);
}

test "presets: panes fill the slots in reading order, new ones open at the focused folder" {
    var fx = try Fixture.init();
    defer fx.deinit();
    try populate(&fx);
    const alpha = try fx.sub("alpha");
    defer testing.allocator.free(alpha);
    var m = try ts.model(&fx, &.{});
    defer m.deinit();
    try m.navigate(alpha);
    const first = m.panes.items[0].id;
    try m.panes.items[0].sortBy(.size, false); // the new panes take its order
    try m.panes.items[0].sortBy(.size, false);

    try run(&m, .{ .apply_preset = .grid_2x2 });
    try testing.expectEqual(@as(usize, 4), m.panes.items.len);
    try testing.expectEqual(LayoutPreset.grid_2x2, (try preset(&m)).?);
    try testing.expectEqual(first, m.panes.items[0].id);
    try testing.expectEqual(@as(usize, 0), m.focused);
    for (m.panes.items) |*p| {
        try testing.expectEqualStrings(alpha, p.tab().path());
        try testing.expectEqual(@import("../core/lister.zig").SortKey.size, p.sort.key);
        try testing.expect(!p.sort.ascending);
    }
    // Applying the layout that is already there changes nothing.
    var before: [4]u32 = undefined;
    for (m.panes.items, &before) |p, *id| id.* = p.id;
    try run(&m, .{ .apply_preset = .grid_2x2 });
    for (m.panes.items, before) |p, id| try testing.expectEqual(id, p.id);

    // Four panes onto two rows: the last two close, their folders kept as tabs in the last pane.
    const beta = try fx.sub("beta");
    defer testing.allocator.free(beta);
    const gamma = try fx.sub("gamma");
    defer testing.allocator.free(gamma);
    try m.panes.items[1].tab().visit(fx.root, m.opts(&m.panes.items[1])); // alpha -> root, with history
    try m.panes.items[2].tab().visit(beta, m.opts(&m.panes.items[2]));
    try m.panes.items[3].tab().visit(gamma, m.opts(&m.panes.items[3]));
    try run(&m, .{ .focus_pane = m.panes.items[3].id });
    try run(&m, .{ .apply_preset = .two_rows });
    try testing.expectEqual(@as(usize, 2), m.panes.items.len);
    try testing.expectEqual(LayoutPreset.two_rows, (try preset(&m)).?);
    try testing.expectEqual(@as(usize, 0), m.focused); // the focused pane was closed
    try testing.expectEqual(@as(usize, 1), m.panes.items[0].tabs.items.len);
    const last = &m.panes.items[1];
    try testing.expectEqual(@as(usize, 3), last.tabs.items.len);
    try testing.expectEqual(@as(usize, 0), last.active); // the shown tab stays
    try testing.expectEqualStrings(fx.root, last.tabs.items[0].path()); // its own tab first
    try testing.expectEqualStrings("beta", last.tabs.items[1].title());
    try testing.expectEqualStrings("gamma", last.tabs.items[2].title());
    try testing.expect(last.tabs.items[0].canBack()); // histories came along
}

test "presets: single pane from many, and every preset from a single pane" {
    var fx = try Fixture.init();
    defer fx.deinit();
    try populate(&fx);
    const beta = try fx.sub("beta");
    defer testing.allocator.free(beta);
    var m = try ts.model(&fx, &.{});
    defer m.deinit();
    for (LayoutPreset.all) |p| {
        try run(&m, .{ .apply_preset = p });
        try testing.expectEqual(p.slotCount(), m.panes.items.len);
        try testing.expectEqual(p, (try preset(&m)).?);
        try testing.expectEqual(@as(usize, 0), m.focused);
        for (m.panes.items) |*pane| try testing.expectEqualStrings(fx.root, pane.tab().path());
    }
    // Four rows down to a single pane: all four folders in one pane, none lost.
    try run(&m, .{ .apply_preset = .four_rows });
    try m.panes.items[1].tab().visit(beta, m.opts(&m.panes.items[1]));
    try m.panes.items[3].tab().visit(beta, m.opts(&m.panes.items[3]));
    try run(&m, .{ .apply_preset = .single });
    try testing.expectEqual(@as(usize, 1), m.panes.items.len);
    try testing.expectEqual(@as(usize, 4), m.panes.items[0].tabs.items.len);
    try testing.expectEqualStrings(beta, m.panes.items[0].tabs.items[1].path());
    // Missing panes: three from two panes keeps both, adds one.
    try run(&m, .{ .apply_preset = .two_columns });
    const ids = .{ m.panes.items[0].id, m.panes.items[1].id };
    try run(&m, .{ .apply_preset = .top_row_and_bottom });
    try testing.expectEqual(@as(usize, 3), m.panes.items.len);
    try testing.expectEqual(ids[0], m.panes.items[0].id);
    try testing.expectEqual(ids[1], m.panes.items[1].id);
    try testing.expectEqual(LayoutPreset.top_row_and_bottom, (try preset(&m)).?);
}

test "the layout popover lists the 12 presets, ticks the current one and applies a choice" {
    var fx = try Fixture.init();
    defer fx.deinit();
    var m = try ts.model(&fx, &.{});
    defer m.deinit();
    var t: ui.Tester = undefined;
    try ts.open(&t, &m);
    defer t.deinit();
    try testing.expect(!t.hasText("Four Columns"));
    try ts.clickIconIn(&t, ts.stripOf(try ts.paneRect(&t, &m, 0)), "rectangle.split.2x2");
    t.settle(0.5);
    for (LayoutPreset.all) |p| try testing.expect(t.hasText(p.title()));
    try testing.expect(ts.hasIcon(&t, "checkmark")); // Single Pane is current
    try t.clickText("Four Columns");
    t.settle(0.5);
    try ts.expectInSync(&m);
    try testing.expectEqual(@as(usize, 4), m.panes.items.len);
    try testing.expectEqual(LayoutPreset.four_columns, (try preset(&m)).?);
    try testing.expect(!t.hasText("Four Columns")); // closed
    try testing.expect(!m.view_state.layout_menu_open);
    try testing.expectEqual(@as(usize, 0), m.focused);
    // Narrow panes drop the Kind and Date columns.
    try testing.expect(!t.hasText("Kind") and !t.hasText("Date Modified") and t.hasText("Size"));
}

test "dragging a divider resizes the panes; a new split starts equal again" {
    var fx = try Fixture.init();
    defer fx.deinit();
    var m = try ts.model(&fx, &.{});
    defer m.deinit();
    var t: ui.Tester = undefined;
    try ts.open(&t, &m);
    defer t.deinit();
    try testing.expect(t.shortcut(.{ .key = 'd', .cmd = true }));
    t.settle(0.2);
    const w0 = (try ts.paneRect(&t, &m, 0)).w;
    const w1 = (try ts.paneRect(&t, &m, 1)).w;
    var mid = ts.center(try ts.dividerRect(&t, &m, 0));
    t.drag(mid.x, mid.y, mid.x + 100, mid.y);
    t.settle(0.2);
    try testing.expectApproxEqAbs(w0 + 100, (try ts.paneRect(&t, &m, 0)).w, 1.5);
    try testing.expectApproxEqAbs(w1 - 100, (try ts.paneRect(&t, &m, 1)).w, 1.5);
    try testing.expect(m.view_state.divider == null); // released
    // The panes' content follows: the right one starts where the divider went.
    try testing.expectEqual((try ts.paneRect(&t, &m, 0)).x + (try ts.paneRect(&t, &m, 0)).w + 1, (try ts.paneRect(&t, &m, 1)).x);

    // As far as it goes: the other side keeps its minimum.
    mid = ts.center(try ts.dividerRect(&t, &m, 0));
    t.drag(mid.x, mid.y, mid.x + 2000, mid.y);
    t.settle(0.2);
    try testing.expectEqual(pane_sizes.min_pane_w, (try ts.paneRect(&t, &m, 1)).w);

    // A split, or any layout change, starts from equal shares again.
    try testing.expect(t.shortcut(.{ .key = 'd', .cmd = true }));
    t.settle(0.2);
    const a = (try ts.paneRect(&t, &m, 0)).w;
    const b = (try ts.paneRect(&t, &m, 1)).w;
    const c = (try ts.paneRect(&t, &m, 2)).w;
    try testing.expect(@abs(a - b) <= 1 and @abs(b - c) <= 1);

    // A stacked pair has a horizontal divider that moves vertically.
    try run(&m, .{ .apply_preset = .two_rows });
    const h0 = (try ts.paneRect(&t, &m, 0)).h;
    t.settle(0.2);
    const row = ts.center(try ts.dividerRect(&t, &m, 0));
    t.drag(row.x, row.y, row.x, row.y - 60);
    t.settle(0.2);
    try testing.expectApproxEqAbs(h0 - 60, (try ts.paneRect(&t, &m, 0)).h, 1.5);
}

test "a pane keeps its own sort order and tabs; hidden files stay global" {
    var fx = try Fixture.init();
    defer fx.deinit();
    try populate(&fx);
    var m = try ts.model(&fx, &.{});
    defer m.deinit();
    var t: ui.Tester = undefined;
    try ts.open(&t, &m);
    defer t.deinit();
    try testing.expect(t.shortcut(.{ .key = 'd', .cmd = true }));
    t.settle(0.2);
    const left = try ts.paneRect(&t, &m, 0);
    const right = try ts.paneRect(&t, &m, 1);

    try ts.clickTextIn(&t, left, "Size"); // the left pane, by size
    t.settle(0.2);
    try testing.expectEqual(@import("../core/lister.zig").SortKey.size, m.panes.items[0].sort.key);
    try testing.expectEqual(@import("../core/lister.zig").SortKey.name, m.panes.items[1].sort.key);
    try testing.expectEqual(@as(usize, 0), m.focused);
    // A pane docked from it starts with its order.
    try testing.expect(t.shortcut(.{ .key = 'd', .cmd = true, .shift = true }));
    t.settle(0.2);
    try testing.expectEqual(@import("../core/lister.zig").SortKey.size, m.panes.items[1].sort.key);
    try testing.expectEqual(@as(usize, 3), m.panes.items.len);

    // Tabs belong to their pane.
    try ts.clickIconIn(&t, ts.stripOf(right), "plus");
    t.settle(0.2);
    try testing.expectEqual(@as(usize, 1), m.panes.items[0].tabs.items.len);
    try testing.expectEqual(@as(usize, 2), m.panes.items[m.focused].tabs.items.len);
    // Sorting a pane with several tabs sorts them all.
    try run(&m, .new_tab);
    try run(&m, .{ .sort = .kind });
    for (m.panes.items[m.focused].tabs.items) |tab| try testing.expect(tab.listing.visible.len > 0);

    // Hidden files: one switch for every pane's tabs.
    for (m.panes.items) |*p| for (p.tabs.items) |*tab| try testing.expectEqual(@as(usize, 4), tab.listing.visible.len);
    try run(&m, .toggle_hidden);
    for (m.panes.items) |*p| for (p.tabs.items) |*tab| try testing.expectEqual(@as(usize, 5), tab.listing.visible.len);
}
