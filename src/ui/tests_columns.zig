//! Column view through ui.Tester over temp trees: the stack for a nested folder, selecting
//! folders and files, the keys, type-to-select, resizing, and the mode toggle. Trees start at
//! least one folder deep so the column to the left (the parent) is inside the temp folder.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const app_view = @import("../app.zig");
const cm = @import("column_model.zig");
const ts = @import("test_support.zig");

const testing = std.testing;
const S = ui.Shortcut;

/// root/: alpha/ (beta/ (gamma/ (deep.txt), note.md), a1.txt), zeta/ (z.txt), types/ (banana,
/// blueberry, cherry, apricot), apple.txt, readme.md.
fn tree(fx: *ts.Fixture) !void {
    try fx.file("alpha/beta/gamma/deep.txt", 5);
    try fx.file("alpha/beta/note.md", 4000);
    try fx.file("alpha/a1.txt", 7);
    try fx.file("zeta/z.txt", 1);
    for ([_][]const u8{ "types/banana", "types/blueberry", "types/cherry", "types/apricot" }) |n| try fx.file(n, 1);
    try fx.file("apple.txt", 1);
    try fx.file("readme.md", 3);
}

fn start(fx: *ts.Fixture, rel: []const u8) !app_view.State {
    var m = try ts.modelAt(fx, rel, &.{});
    errdefer m.deinit();
    m.focusedPane().view_mode = .column;
    return m;
}

fn path(fx: *ts.Fixture, rel: []const u8) []u8 {
    return fx.sub(rel) catch unreachable;
}

fn expectCols(m: *app_view.State, fx: *ts.Fixture, rels: []const []const u8) !void {
    const cols = m.focusedTab().col.columns.items;
    try testing.expectEqual(rels.len, cols.len);
    for (rels, cols) |rel, c| {
        const want = try fx.sub(rel);
        defer testing.allocator.free(want);
        try testing.expectEqualStrings(want, c.path);
    }
}

test "the stack for a nested folder: its parent selecting it, then itself" {
    var fx = try ts.Fixture.init();
    defer fx.deinit();
    defer ts.resetOpened();
    try tree(&fx);
    var m = try start(&fx, "alpha/beta");
    defer m.deinit();
    var t: ui.Tester = undefined;
    try ts.open(&t, &m);
    defer t.deinit();

    try expectCols(&m, &fx, &.{ "alpha", "alpha/beta" });
    const beta = try fx.sub("alpha/beta");
    defer testing.allocator.free(beta);
    try testing.expect(m.focusedTab().col.columns.items[0].selection.contains(beta));
    try testing.expectEqual(@as(usize, 1), m.focusedTab().col.active);
    // The parent's rows, then the folder's: chevrons on the folders.
    for ([_][]const u8{ "beta", "a1.txt", "gamma", "note.md" }) |n| try testing.expect(t.hasText(n));
    try testing.expect(ts.hasIcon(&t, "chevron.right"));
    try testing.expect(!t.hasText("Date Modified")); // no list header
    try testing.expect(!m.focusedTab().canBack());
}

test "a deeper root keeps every column from it" {
    var fx = try ts.Fixture.init();
    defer fx.deinit();
    try tree(&fx);
    var m = try start(&fx, "alpha/beta/gamma");
    defer m.deinit();
    try m.focusedTab().col.setRoot(testing.allocator, fx.root);
    var t: ui.Tester = undefined;
    try ts.open(&t, &m);
    defer t.deinit();
    try expectCols(&m, &fx, &.{ "", "alpha", "alpha/beta", "alpha/beta/gamma" });
    // A root that doesn't contain the folder falls back to the parent.
    var m2 = try start(&fx, "zeta");
    defer m2.deinit();
    const other = try fx.sub("alpha");
    defer testing.allocator.free(other);
    try m2.focusedTab().col.setRoot(testing.allocator, other);
    try m2.queue(.reload);
    _ = try m2.applyPending();
    try expectCols(&m2, &fx, &.{ "", "zeta" });
}

test "selecting a folder adds a column; a file shows the preview" {
    var fx = try ts.Fixture.init();
    defer fx.deinit();
    try tree(&fx);
    var m = try start(&fx, "alpha/beta");
    defer m.deinit();
    var t: ui.Tester = undefined;
    try ts.open(&t, &m);
    defer t.deinit();

    try t.clickText("gamma");
    t.settle(0.3);
    try expectCols(&m, &fx, &.{ "alpha", "alpha/beta", "alpha/beta/gamma" });
    const gamma = try fx.sub("alpha/beta/gamma");
    defer testing.allocator.free(gamma);
    try testing.expectEqualStrings(gamma, m.focusedTab().path());
    try testing.expect(!m.focusedTab().canBack()); // drilling is not a visit
    try testing.expect(t.hasText("deep.txt"));
    try testing.expect(!t.hasText("Modified"));

    try t.clickText("deep.txt");
    t.settle(0.3);
    try expectCols(&m, &fx, &.{ "alpha", "alpha/beta", "alpha/beta/gamma" });
    try testing.expect(t.hasText("Modified") and t.hasText("Size"));
    try testing.expect(t.hasText("5 bytes") or t.hasText("5 B"));
    try testing.expectEqual(@as(usize, 1), m.focusedTab().selection.count()); // mirrored for the tab

    // Another folder in the parent's column replaces what was to its right.
    try t.clickText("note.md");
    t.settle(0.3);
    try expectCols(&m, &fx, &.{ "alpha", "alpha/beta" });
    try testing.expect(!t.hasText("deep.txt"));
    try testing.expect(t.hasText("Modified"));
    try t.clickText("gamma");
    t.settle(0.3);
    try expectCols(&m, &fx, &.{ "alpha", "alpha/beta", "alpha/beta/gamma" });
    try testing.expect(!t.hasText("Modified")); // a folder has no preview
}

test "Up, Down, Right and Left walk the columns" {
    var fx = try ts.Fixture.init();
    defer fx.deinit();
    try tree(&fx);
    var m = try start(&fx, "alpha");
    defer m.deinit();
    var t: ui.Tester = undefined;
    try ts.open(&t, &m);
    defer t.deinit();
    const tab = m.focusedTab();
    try expectCols(&m, &fx, &.{ "", "alpha" });

    try ts.press(&t, S.down, .{}); // first row of alpha: the folder beta
    try expectCols(&m, &fx, &.{ "", "alpha", "alpha/beta" });
    try testing.expectEqual(@as(usize, 1), tab.col.active);
    try ts.press(&t, S.right, .{}); // into beta: gamma selected
    try expectCols(&m, &fx, &.{ "", "alpha", "alpha/beta", "alpha/beta/gamma" });
    try testing.expectEqual(@as(usize, 2), tab.col.active);
    try ts.press(&t, S.right, .{}); // into gamma: deep.txt, a file
    try testing.expectEqual(@as(usize, 3), tab.col.active);
    try testing.expect(t.hasText("Modified"));
    try ts.press(&t, S.left, .{}); // back to beta's column, deep.txt let go
    try testing.expectEqual(@as(usize, 2), tab.col.active);
    try testing.expect(!t.hasText("Modified"));
    try testing.expectEqual(@as(usize, 0), tab.col.columns.items[3].selection.count());

    try ts.press(&t, S.down, .{}); // gamma -> note.md: a file ends the stack
    try expectCols(&m, &fx, &.{ "", "alpha", "alpha/beta" });
    try testing.expect(t.hasText("Modified"));
    try ts.press(&t, S.down, .{}); // already last: stays
    try ts.press(&t, S.up, .{}); // back on gamma
    try expectCols(&m, &fx, &.{ "", "alpha", "alpha/beta", "alpha/beta/gamma" });
    const gamma = try fx.sub("alpha/beta/gamma");
    defer testing.allocator.free(gamma);
    try testing.expectEqualStrings(gamma, tab.path());
    try ts.press(&t, S.left, .{}); // out of beta's column: gamma's folder column ends the stack
    try testing.expectEqual(@as(usize, 1), tab.col.active);
    try testing.expectEqual(@as(usize, 3), tab.col.columns.items.len);
    const beta = try fx.sub("alpha/beta");
    defer testing.allocator.free(beta);
    try testing.expectEqualStrings(beta, tab.path());
    try ts.press(&t, S.left, .{});
    try testing.expectEqual(@as(usize, 0), tab.col.active);
    try ts.press(&t, S.left, .{}); // at the first column: nothing
    try testing.expectEqual(@as(usize, 0), tab.col.active);
}

test "Up with nothing selected takes the last row, Home and End the ends, Shift extends" {
    var fx = try ts.Fixture.init();
    defer fx.deinit();
    try tree(&fx);
    var m = try start(&fx, "types");
    defer m.deinit();
    var t: ui.Tester = undefined;
    try ts.open(&t, &m);
    defer t.deinit();
    const tab = m.focusedTab();
    // types/ sorted: apricot, banana, blueberry, cherry.
    try ts.press(&t, S.up, .{});
    try testing.expect(tab.selection.count() == 1 and t.hasText("cherry"));
    const cherry = try fx.sub("types/cherry");
    defer testing.allocator.free(cherry);
    try testing.expect(tab.selection.contains(cherry));
    try ts.press(&t, S.home, .{});
    const apricot = try fx.sub("types/apricot");
    defer testing.allocator.free(apricot);
    try testing.expect(tab.selection.contains(apricot) and tab.selection.count() == 1);
    try ts.press(&t, S.down, .{ .shift = true });
    try ts.press(&t, S.down, .{ .shift = true });
    try testing.expectEqual(@as(usize, 3), tab.selection.count());
    try testing.expectEqual(@as(usize, 2), tab.col.columns.items.len); // no folder: no extra column
    try ts.press(&t, S.end, .{});
    try testing.expect(tab.selection.contains(cherry) and tab.selection.count() == 1);
    try testing.expect(t.hasText("Modified")); // one file selected again: its preview
}

test "type-to-select: the prefix grows within a second and starts over after" {
    var fx = try ts.Fixture.init();
    defer fx.deinit();
    try tree(&fx);
    var m = try start(&fx, "types");
    defer m.deinit();
    var t: ui.Tester = undefined;
    try ts.open(&t, &m);
    defer t.deinit();
    const tab = m.focusedTab();
    const sel = struct {
        fn is(tb: anytype, f: *ts.Fixture, name: []const u8) !bool {
            const p = try f.sub(name);
            defer testing.allocator.free(p);
            return tb.selection.contains(p) and tb.selection.count() == 1;
        }
    };

    try ts.press(&t, 'c', .{});
    try testing.expect(try sel.is(tab, &fx, "types/cherry"));
    t.advance(0.3);
    try ts.press(&t, 'b', .{}); // "cb": nothing starts so, the selection stays
    try testing.expect(try sel.is(tab, &fx, "types/cherry"));
    t.advance(1.5);
    try ts.press(&t, 'b', .{}); // a fresh "b"
    try testing.expect(try sel.is(tab, &fx, "types/banana"));
    t.advance(0.3);
    try ts.press(&t, 'l', .{}); // "bl"
    try testing.expect(try sel.is(tab, &fx, "types/blueberry"));
    t.advance(1.5);
    try ts.press(&t, 'a', .{ .shift = true }); // case is ignored
    try testing.expect(try sel.is(tab, &fx, "types/apricot"));
    // Keys with Cmd are not typing.
    try testing.expect(!t.shortcut(.{ .key = 'z', .cmd = true }));
}

test "column widths clamp, are remembered per tab, and dragging a divider resizes" {
    var fx = try ts.Fixture.init();
    defer fx.deinit();
    try tree(&fx);
    var m = try start(&fx, "alpha/beta");
    defer m.deinit();
    var t: ui.Tester = undefined;
    try ts.open(&t, &m);
    defer t.deinit();
    const tab = m.focusedTab();
    try testing.expectEqual(cm.default_width, tab.col.width(0));

    const pane = try ts.paneRect(&t, &m, 0);
    const y = pane.y + pane.h / 2;
    // The divider's grab band is the right 6 points of the column.
    t.drag(pane.x + cm.default_width - 3, y, pane.x + cm.default_width + 57, y);
    t.settle(0.2);
    try testing.expectApproxEqAbs(cm.default_width + 60, tab.col.width(0), 8);
    try testing.expectEqual(cm.default_width, tab.col.width(1));
    const grown = tab.col.width(0);
    t.drag(pane.x + grown - 3, y, pane.x + grown - 503, y);
    t.settle(0.2);
    try testing.expectEqual(cm.min_width, tab.col.width(0));
    t.drag(pane.x + cm.min_width - 3, y, pane.x + cm.min_width + 1500, y);
    t.settle(0.2);
    try testing.expectEqual(cm.max_width, tab.col.width(0));

    // Per tab: a second tab has its own widths, and the first keeps its own.
    try m.queue(.new_tab);
    _ = try m.applyPending();
    try testing.expectEqual(cm.default_width, m.focusedTab().col.width(0));
    try m.queue(.{ .cycle_tab = -1 });
    _ = try m.applyPending();
    try testing.expectEqual(cm.max_width, m.focusedTab().col.width(0));
}

test "the strip scrolls sideways and keeps its offset per tab" {
    var fx = try ts.Fixture.init();
    defer fx.deinit();
    try tree(&fx);
    var m = try start(&fx, "alpha/beta");
    defer m.deinit();
    const tab = m.focusedTab();
    for (0..4) |i| _ = try tab.col.setWidth(testing.allocator, i, 400);
    var t: ui.Tester = undefined;
    try ts.open(&t, &m);
    defer t.deinit();
    try t.clickText("gamma"); // a third column: 1200 wide in a pane of ~690
    t.settle(0.4);
    t.advance(0.2);
    try testing.expect(tab.col.scroll_x > 300); // scrolled to show the last column
    const at = tab.col.scroll_x;
    try testing.expect(t.hasText("deep.txt"));
    // A sideways wheel moves it back.
    const pane = try ts.paneRect(&t, &m, 0);
    t.hscroll(pane.x + 100, pane.y + 200, 150);
    t.advance(0.1);
    try testing.expect(tab.col.scroll_x < at);
}

test "the mode toggle keeps each tab's folder, and is per pane" {
    var fx = try ts.Fixture.init();
    defer fx.deinit();
    try tree(&fx);
    var m = try ts.modelAt(&fx, "alpha/beta", &.{});
    defer m.deinit();
    var t: ui.Tester = undefined;
    try ts.open(&t, &m);
    defer t.deinit();
    const tab = m.focusedTab();
    try testing.expect(t.hasText("Date Modified")); // list view to begin with

    try testing.expect(t.shortcut(.{ .key = '2', .cmd = true }));
    t.settle(0.3);
    try testing.expectEqual(.column, m.focusedPane().view_mode);
    try expectCols(&m, &fx, &.{ "alpha", "alpha/beta" });
    try t.clickText("gamma");
    t.settle(0.3);
    const gamma = try fx.sub("alpha/beta/gamma");
    defer testing.allocator.free(gamma);
    try testing.expectEqualStrings(gamma, tab.path());

    try testing.expect(t.shortcut(.{ .key = '1', .cmd = true }));
    t.settle(0.3);
    try testing.expectEqual(.list, m.focusedPane().view_mode);
    try testing.expectEqualStrings(gamma, tab.path()); // the folder drilled to
    try testing.expect(t.hasText("deep.txt") and t.hasText("Date Modified"));
    try testing.expectEqual(@as(usize, 0), tab.col.columns.items.len);
    try testing.expect(!tab.canBack());

    // Back to columns: the remembered root brings the whole chain again.
    try testing.expect(t.shortcut(.{ .key = '2', .cmd = true }));
    t.settle(0.3);
    try expectCols(&m, &fx, &.{ "alpha", "alpha/beta", "alpha/beta/gamma" });

    // The toolbar's "..." menu does the same.
    try ts.clickIcon(&t, "ellipsis");
    t.settle(0.4);
    try t.clickText("as List");
    t.settle(0.4);
    try testing.expectEqual(.list, m.focusedPane().view_mode);
    try ts.clickIcon(&t, "ellipsis");
    t.settle(0.4);
    try t.clickText("as Columns");
    t.settle(0.4);
    try testing.expectEqual(.column, m.focusedPane().view_mode);

    // A split: the new pane starts in the same mode, then has its own.
    try m.queue(.{ .split = .side_by_side });
    _ = try m.applyPending();
    try testing.expectEqual(@as(usize, 2), m.panes.items.len);
    try testing.expectEqual(.column, m.panes.items[0].view_mode);
    try testing.expectEqual(.column, m.panes.items[1].view_mode);
    try m.queue(.{ .focus_pane = m.panes.items[1].id });
    try m.queue(.{ .set_view_mode = .list });
    _ = try m.applyPending();
    try testing.expectEqual(.column, m.panes.items[0].view_mode);
    try testing.expectEqual(.list, m.panes.items[1].view_mode);
    t.settle(0.3);
    try testing.expect(t.hasText("Name")); // the list pane's header (narrow: no Date column)
    try testing.expect(!t.hasText("Date Modified"));
}

test "Cmd+Down and double-click open a folder (the stack re-roots) and a file (the opener)" {
    var fx = try ts.Fixture.init();
    defer fx.deinit();
    defer ts.resetOpened();
    try tree(&fx);
    var m = try start(&fx, "alpha");
    defer m.deinit();
    var t: ui.Tester = undefined;
    try ts.open(&t, &m);
    defer t.deinit();
    const tab = m.focusedTab();
    try expectCols(&m, &fx, &.{ "", "alpha" });

    try ts.press(&t, S.down, .{}); // beta
    try expectCols(&m, &fx, &.{ "", "alpha", "alpha/beta" });
    try ts.press(&t, S.down, .{ .cmd = true }); // opens beta as the tab's location, rooted at its parent
    try expectCols(&m, &fx, &.{ "alpha", "alpha/beta" });
    try testing.expectEqual(@as(usize, 0), ts.opened.items.len);

    try ts.press(&t, S.down, .{}); // gamma, in beta's column
    try ts.press(&t, S.down, .{}); // note.md: a file ends the stack
    try ts.press(&t, S.down, .{ .cmd = true });
    try testing.expectEqual(@as(usize, 1), ts.opened.items.len);
    const note = try fx.sub("alpha/beta/note.md");
    defer testing.allocator.free(note);
    try testing.expectEqualStrings(note, ts.opened.items[0]);
    try expectCols(&m, &fx, &.{ "alpha", "alpha/beta" }); // a file doesn't move the stack

    const r = t.findText("gamma").?;
    t.doubleClick(r.x + r.w / 2, r.y + r.h / 2);
    t.settle(0.3);
    const gamma = try fx.sub("alpha/beta/gamma");
    defer testing.allocator.free(gamma);
    try testing.expectEqualStrings(gamma, tab.path());
    try expectCols(&m, &fx, &.{ "alpha/beta", "alpha/beta/gamma" });
    try testing.expectEqual(@as(usize, 1), ts.opened.items.len);
    // Double-click on a file opens it.
    const f = t.findText("deep.txt").?;
    t.doubleClick(f.x + f.w / 2, f.y + f.h / 2);
    t.settle(0.3);
    try testing.expectEqual(@as(usize, 2), ts.opened.items.len);
}

test "sorting and hidden files reach every column; a refresh keeps the selection" {
    var fx = try ts.Fixture.init();
    defer fx.deinit();
    try tree(&fx);
    try fx.file("alpha/beta/.secret", 1);
    var m = try start(&fx, "alpha/beta");
    defer m.deinit();
    var t: ui.Tester = undefined;
    try ts.open(&t, &m);
    defer t.deinit();
    try testing.expect(!t.hasText(".secret"));
    try testing.expect(t.shortcut(.{ .key = '.', .cmd = true, .shift = true }));
    t.settle(0.3);
    try testing.expect(t.hasText(".secret"));
    try m.queue(.{ .sort = .size });
    _ = try m.applyPending();
    // Sorted by size, the folders still first, the files by size: .secret (1), then note.md.
    try testing.expect(try ts.textY(&t, ".secret") < try ts.textY(&t, "note.md"));
    try t.clickText("note.md");
    t.settle(0.3);
    try fx.file("alpha/beta/new.txt", 3);
    try m.queue(.reload);
    t.settle(0.3);
    try testing.expect(t.hasText("new.txt"));
    try testing.expect(t.hasText("Modified")); // note.md still selected: its preview stays
    try expectCols(&m, &fx, &.{ "alpha", "alpha/beta" });
}
