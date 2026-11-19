//! The list pane and sidebar through ui.Tester, over fresh temp folders.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const app_view = @import("../app.zig");
const ts = @import("test_support.zig");

const testing = std.testing;
const Fixture = ts.Fixture;

/// root/: docs/ (inner.txt), projects/ (p1.txt), big.dat, file2.txt, file10.txt, small.md,
/// .hidden-note. Sidebar: "Work" -> root/projects.
fn populate(fx: *Fixture) !void {
    try fx.file("docs/inner.txt", 5);
    try fx.file("projects/p1.txt", 5);
    try fx.file("big.dat", 5000);
    try fx.file("file2.txt", 20);
    try fx.file("file10.txt", 30);
    try fx.file("small.md", 10);
    try fx.file(".hidden-note", 1);
}

fn model(fx: *Fixture, work: []const u8) !app_view.State {
    return app_view.State.init(testing.allocator, .{
        .start_path = fx.root,
        .home_path = fx.root,
        .favorites = &.{.{ .path = work, .title = "Work" }},
        .locations = &.{.{ .path = "/", .title = "Volume" }},
    });
}

test "the listing shows the folder's files, folders first, hidden ones not" {
    var fx = try Fixture.init();
    defer fx.deinit();
    try populate(&fx);
    const work = try fx.sub("projects");
    defer testing.allocator.free(work);
    var m = try model(&fx, work);
    defer m.deinit();
    var t: ui.Tester = undefined;
    try ts.open(&t, &m);
    defer t.deinit();

    for ([_][]const u8{ "docs", "projects", "big.dat", "file2.txt", "file10.txt", "small.md" }) |n| try testing.expect(t.hasText(n));
    try testing.expect(!t.hasText(".hidden-note"));
    try testing.expect(t.hasText("6 items"));
    try testing.expect(t.hasText("Name") and t.hasText("Kind") and t.hasText("Size") and t.hasText("Date Modified"));
    try testing.expect(t.hasText("5,000 bytes") or t.hasText("5.0 KB"));
    try testing.expect(t.hasText("Folder"));
    // Folders sort first, then names the Finder way.
    try testing.expect(try ts.textY(&t, "docs") < try ts.textY(&t, "big.dat"));
    try testing.expect(try ts.textY(&t, "file2.txt") < try ts.textY(&t, "file10.txt"));
    // Folder and file icons.
    try testing.expect(ts.hasIcon(&t, "folder.fill") and ts.hasIcon(&t, "doc"));
    // The sidebar: Home, the favorite by its title, an empty Pinned group, Locations.
    for ([_][]const u8{ "Home", "Favorites", "Work", "Pinned", "Locations", "Volume" }) |n| try testing.expect(t.hasText(n));
}

test "a header click sorts, and a second click reverses" {
    var fx = try Fixture.init();
    defer fx.deinit();
    try populate(&fx);
    const work = try fx.sub("projects");
    defer testing.allocator.free(work);
    var m = try model(&fx, work);
    defer m.deinit();
    var t: ui.Tester = undefined;
    try ts.open(&t, &m);
    defer t.deinit();

    try t.clickText("Name"); // already by name: descending
    t.settle(0.2);
    try testing.expect(!m.focusedPane().sort.ascending);
    try testing.expect(try ts.textY(&t, "file10.txt") < try ts.textY(&t, "file2.txt"));
    try testing.expect(try ts.textY(&t, "projects") < try ts.textY(&t, "docs")); // folders still first
    try testing.expect(try ts.textY(&t, "docs") < try ts.textY(&t, "small.md"));
    try t.clickText("Name");
    t.settle(0.2);
    try testing.expect(try ts.textY(&t, "file2.txt") < try ts.textY(&t, "file10.txt"));

    try t.clickText("Size"); // ascending by size: 10, 20, 30, 5000 bytes
    t.settle(0.2);
    try testing.expectEqual(@import("../core/lister.zig").SortKey.size, m.focusedPane().sort.key);
    try testing.expect(m.focusedPane().sort.ascending);
    try testing.expect(try ts.textY(&t, "small.md") < try ts.textY(&t, "file2.txt"));
    try testing.expect(try ts.textY(&t, "file10.txt") < try ts.textY(&t, "big.dat"));
    try t.clickText("Size");
    t.settle(0.2);
    try testing.expect(try ts.textY(&t, "big.dat") < try ts.textY(&t, "file10.txt"));
}

test "double-clicking a folder opens it; back, forward and up" {
    var fx = try Fixture.init();
    defer fx.deinit();
    try populate(&fx);
    const work = try fx.sub("projects");
    defer testing.allocator.free(work);
    const docs = try fx.sub("docs");
    defer testing.allocator.free(docs);
    var m = try model(&fx, work);
    defer m.deinit();
    var t: ui.Tester = undefined;
    try ts.open(&t, &m);
    defer t.deinit();

    try testing.expect(!m.focusedTab().canBack());
    const r = t.findText("docs").?;
    t.doubleClick(r.x + r.w / 2, r.y + r.h / 2);
    t.settle(0.2);
    try testing.expectEqualStrings(docs, m.focusedTab().path());
    try testing.expect(t.hasText("inner.txt") and !t.hasText("file2.txt"));
    try testing.expect(t.hasText("1 item"));
    try testing.expect(m.focusedTab().canBack() and !m.focusedTab().canForward());
    // The path bar: crumbs from Home (the root) to here.
    try testing.expect(t.hasText(std.fs.path.basename(fx.root)));

    // Cmd+[ goes back, Cmd+] forward.
    try testing.expect(t.shortcut(.{ .key = '[', .cmd = true }));
    t.settle(0.2);
    try testing.expectEqualStrings(fx.root, m.focusedTab().path());
    try testing.expect(t.hasText("file2.txt"));
    try testing.expect(t.shortcut(.{ .key = ']', .cmd = true }));
    t.settle(0.2);
    try testing.expectEqualStrings(docs, m.focusedTab().path());
    try testing.expect(!m.focusedTab().canForward());

    // The toolbar's buttons do the same.
    try ts.clickIcon(&t, "chevron.left");
    t.settle(0.2);
    try testing.expectEqualStrings(fx.root, m.focusedTab().path());
    try ts.clickIcon(&t, "chevron.right");
    t.settle(0.2);
    try testing.expectEqualStrings(docs, m.focusedTab().path());

    // Up one level: Cmd+Up, and the toolbar button.
    try testing.expect(t.shortcut(.{ .key = ui.Shortcut.up, .cmd = true }));
    t.settle(0.2);
    try testing.expectEqualStrings(fx.root, m.focusedTab().path());
    try testing.expect(t.hasText("file2.txt"));
    try m.navigate(docs);
    t.settle(0.2);
    try ts.clickIcon(&t, "chevron.up");
    t.settle(0.2);
    try testing.expectEqualStrings(fx.root, m.focusedTab().path());
}

test "click, cmd-click and shift-click select rows" {
    var fx = try Fixture.init();
    defer fx.deinit();
    try populate(&fx);
    const work = try fx.sub("projects");
    defer testing.allocator.free(work);
    var m = try model(&fx, work);
    defer m.deinit();
    var t: ui.Tester = undefined;
    try ts.open(&t, &m);
    defer t.deinit();
    const sel = &m.focusedTab().selection;
    const f2 = try fx.sub("file2.txt");
    defer testing.allocator.free(f2);
    const f10 = try fx.sub("file10.txt");
    defer testing.allocator.free(f10);
    const sm = try fx.sub("small.md");
    defer testing.allocator.free(sm);

    try t.clickText("file2.txt");
    try testing.expect(sel.count() == 1 and sel.contains(f2));
    try testing.expect(t.hasText("1 of 6 selected"));
    try ts.clickTextWith(&t, "small.md", .{ .shift = true }); // file2.txt .. small.md
    try testing.expect(sel.count() == 3 and sel.contains(f10) and sel.contains(sm));
    try testing.expect(t.hasText("3 of 6 selected"));
    try ts.clickTextWith(&t, "file10.txt", .{ .cmd = true }); // toggles one off
    try testing.expect(sel.count() == 2 and !sel.contains(f10));
    try t.clickText("big.dat"); // a plain click starts over
    try testing.expect(sel.count() == 1 and !sel.contains(f2));
    // Navigating clears it.
    const r = t.findText("docs").?;
    t.doubleClick(r.x + r.w / 2, r.y + r.h / 2);
    t.settle(0.2);
    try testing.expectEqual(@as(usize, 0), sel.count());
}

test "a sidebar entry navigates the pane; Home comes back" {
    var fx = try Fixture.init();
    defer fx.deinit();
    try populate(&fx);
    const work = try fx.sub("projects");
    defer testing.allocator.free(work);
    var m = try model(&fx, work);
    defer m.deinit();
    var t: ui.Tester = undefined;
    try ts.open(&t, &m);
    defer t.deinit();

    try t.clickText("Work");
    t.settle(0.2);
    try testing.expectEqualStrings(work, m.focusedTab().path());
    try testing.expect(t.hasText("p1.txt") and !t.hasText("file2.txt"));
    try testing.expect(m.sidebar.highlighted(m.focusedTab().path()).?.section == 1);
    try t.clickText("Home");
    t.settle(0.2);
    try testing.expectEqualStrings(fx.root, m.focusedTab().path());
    try testing.expect(t.hasText("file2.txt"));
    try testing.expect(m.sidebar.highlighted(m.focusedTab().path()).?.section == 0);
    try t.clickText("Volume"); // a location: the filesystem root, listed read-only
    t.settle(0.2);
    try testing.expectEqualStrings("/", m.focusedTab().path());
    try testing.expect(t.hasText("Macintosh HD")); // its crumb
    // And back through the history.
    try testing.expect(t.shortcut(.{ .key = '[', .cmd = true }));
    t.settle(0.2);
    try testing.expectEqualStrings(fx.root, m.focusedTab().path());
}

test "show hidden toggles with the shortcut and the toolbar button" {
    var fx = try Fixture.init();
    defer fx.deinit();
    try populate(&fx);
    const work = try fx.sub("projects");
    defer testing.allocator.free(work);
    var m = try model(&fx, work);
    defer m.deinit();
    var t: ui.Tester = undefined;
    try ts.open(&t, &m);
    defer t.deinit();

    try testing.expect(!m.show_hidden and !t.hasText(".hidden-note") and t.hasText("6 items"));
    try testing.expect(t.shortcut(.{ .key = '.', .cmd = true, .shift = true }));
    t.settle(0.2);
    try testing.expect(m.show_hidden and t.hasText(".hidden-note") and t.hasText("7 items"));
    try ts.clickIcon(&t, "eye");
    t.settle(0.2);
    try testing.expect(!m.show_hidden and !t.hasText(".hidden-note"));
}

test "an unreadable folder raises a notice and changes nothing" {
    var fx = try Fixture.init();
    defer fx.deinit();
    try populate(&fx);
    const work = try fx.sub("projects");
    defer testing.allocator.free(work);
    var m = try model(&fx, work);
    defer m.deinit();
    var t: ui.Tester = undefined;
    try ts.open(&t, &m);
    defer t.deinit();

    const gone = try fx.sub("not-here");
    defer testing.allocator.free(gone);
    try m.navigate(gone);
    t.settle(0.2);
    try testing.expectEqualStrings(fx.root, m.focusedTab().path());
    try testing.expect(!m.focusedTab().canBack()); // nothing was pushed
    try testing.expect(t.containsText("Can't open \"not-here\""));
    try t.clickText("Dismiss");
    t.settle(0.2);
    try testing.expect(m.notice == null and !t.containsText("Can't open"));
}

test "a long folder is virtualized" {
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

    try testing.expect(t.hasText("300 items"));
    try testing.expect(t.hasText("n0000.txt") and !t.hasText("n0299.txt"));
    t.scroll(500, 300, -100000); // far down
    t.settle(0.3);
    try testing.expect(t.hasText("n0299.txt") and !t.hasText("n0000.txt"));
}

test "the path bar collapses a deep path and a crumb navigates" {
    var fx = try Fixture.init();
    defer fx.deinit();
    try fx.dir("lvl1/lvl2/lvl3/lvl4/lvl5/lvl6/lvl7/lvl8");
    const deep = try fx.sub("lvl1/lvl2/lvl3/lvl4/lvl5/lvl6/lvl7/lvl8");
    defer testing.allocator.free(deep);
    const lvl6 = try fx.sub("lvl1/lvl2/lvl3/lvl4/lvl5/lvl6");
    defer testing.allocator.free(lvl6);
    var m = try app_view.State.init(testing.allocator, .{ .start_path = deep, .home_path = fx.root });
    defer m.deinit();
    var t: ui.Tester = undefined;
    try ts.open(&t, &m);
    defer t.deinit();

    try testing.expect(t.hasText("\u{2026}")); // the middle crumbs are folded away
    try testing.expect(t.hasText(std.fs.path.basename(fx.root)) and !t.hasText("lvl2"));
    try testing.expect(t.hasText("lvl8") and t.hasText("lvl6"));
    try t.clickText("lvl6");
    t.settle(0.2);
    try testing.expectEqualStrings(lvl6, m.focusedTab().path());
    try testing.expect(t.hasText("lvl7")); // its only item
}

test "model: navigation, history and the sort order without a window" {
    var fx = try Fixture.init();
    defer fx.deinit();
    try populate(&fx);
    const docs = try fx.sub("docs");
    defer testing.allocator.free(docs);
    var m = try app_view.State.init(testing.allocator, .{ .start_path = fx.root, .home_path = fx.root });
    defer m.deinit();
    const tab = m.focusedTab();
    try testing.expectEqual(@as(usize, 6), tab.listing.visible.len);
    try testing.expectEqualStrings("docs", tab.listing.visible[0].name);
    try m.navigate(docs);
    try testing.expectEqualStrings("inner.txt", tab.listing.visible[0].name);
    try m.back();
    try testing.expectEqualStrings(fx.root, tab.path());
    try m.forward();
    try testing.expectEqualStrings(docs, tab.path());
    try m.up();
    try testing.expectEqualStrings(fx.root, tab.path());
    try m.queue(.{ .sort = .size });
    try m.queue(.toggle_hidden);
    try testing.expect(try m.applyPending());
    try testing.expectEqual(@as(usize, 7), tab.listing.visible.len);
    try testing.expect(!try m.applyPending());
}

test "snapshot: a populated list" {
    const out = std.c.getenv("NANOFM_SNAPSHOT_PNG") orelse return error.SkipZigTest;
    var fx = try Fixture.init();
    defer fx.deinit();
    try fx.dir("me/Desktop");
    try fx.dir("me/Downloads");
    try fx.dir("me/Documents/Invoices");
    try fx.dir("me/Documents/Reference");
    try fx.dir("me/Documents/Taxes 2025");
    try fx.file("me/Documents/Annual Report.pdf", 482_113);
    try fx.file("me/Documents/budget.xlsx", 31_200);
    try fx.file("me/Documents/cover-letter.docx", 18_400);
    try fx.file("me/Documents/holiday photo.jpg", 2_904_331);
    try fx.file("me/Documents/notes.txt", 812);
    try fx.file("me/Documents/archive.zip", 14_800_000);
    try fx.file("me/Documents/main.zig", 4_200);
    try fx.file("me/Documents/a-rather-long-file-name-that-will-need-an-ellipsis-to-fit-in-the-name-column-of-the-list.md", 77);
    try fx.file("me/Documents/file2.txt", 3);
    try fx.file("me/Documents/file10.txt", 3);
    const home = try fx.sub("me");
    defer testing.allocator.free(home);
    const start = try fx.sub("me/Documents");
    defer testing.allocator.free(start);
    const state_model = @import("../core/state_model.zig");
    const sidebar_model = @import("sidebar_model.zig");
    var persisted = try state_model.PersistedState.defaults(testing.allocator, testing.io, home);
    defer persisted.deinit(testing.allocator);
    const fav = try sidebar_model.itemsOf(testing.allocator, persisted.favorites.items);
    defer testing.allocator.free(fav);
    var m = try app_view.State.init(testing.allocator, .{
        .start_path = home,
        .home_path = home,
        .favorites = fav,
        .locations = &.{.{ .path = "/", .title = "Macintosh HD" }},
    });
    defer m.deinit();
    try m.navigate(start);
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&m, app_view.view), .{ .width = 1000, .height = 560 });
    defer t.deinit();
    t.settle(0.3);
    try t.clickText("Annual Report.pdf");
    try ts.clickTextWith(&t, "notes.txt", .{ .cmd = true });
    t.settle(0.3);
    try t.screenshot(std.mem.span(out));
    // The same in the dark theme.
    var dark: ui.Tester = undefined;
    try dark.init(testing.allocator, .init(&m, app_view.view), .{ .width = 1000, .height = 560, .dark = true });
    defer dark.deinit();
    dark.settle(0.3);
    const dark_path = try std.fmt.allocPrint(testing.allocator, "{s}.dark.png", .{std.mem.span(out)});
    defer testing.allocator.free(dark_path);
    try dark.screenshot(dark_path);
}
