//! Render snapshots (only when NANOFM_SNAPSHOT_PNG names a file; the dark one goes beside it as
//! "<file>.dark.png"): a 2x2 layout with tabs, a focused pane, selections, and the layout popover.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const app_view = @import("../app.zig");
const model = @import("model.zig");
const sidebar_model = @import("sidebar_model.zig");
const state_model = @import("../core/state_model.zig");
const ts = @import("test_support.zig");

const testing = std.testing;

fn build(fx: *ts.Fixture) !void {
    try fx.dir("me/Desktop");
    try fx.dir("me/Downloads");
    try fx.dir("me/Documents/Invoices");
    try fx.dir("me/Documents/Taxes 2025");
    try fx.file("me/Documents/Annual Report.pdf", 482_113);
    try fx.file("me/Documents/budget.xlsx", 31_200);
    try fx.file("me/Documents/notes.txt", 812);
    try fx.file("me/Documents/archive.zip", 14_800_000);
    try fx.file("me/Downloads/installer.dmg", 92_000_000);
    try fx.file("me/Downloads/holiday photo.jpg", 2_904_331);
    try fx.file("me/Downloads/a-rather-long-file-name-that-will-need-an-ellipsis.md", 77);
    try fx.dir("me/Projects/nanofm/src");
    try fx.file("me/Projects/nanofm/build.zig", 1_900);
    try fx.file("me/Projects/nanofm/README.md", 3_300);
    try fx.file("me/Projects/nanofm/src/main.zig", 4_200);
    try fx.file("me/Desktop/todo.txt", 120);
}

test "snapshot: a 2x2 layout with tabs" {
    const out = std.c.getenv("NANOFM_SNAPSHOT_PNG") orelse return error.SkipZigTest;
    var fx = try ts.Fixture.init();
    defer fx.deinit();
    try build(&fx);
    const home = try fx.sub("me");
    defer testing.allocator.free(home);
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
    const docs = try fx.sub("me/Documents");
    defer testing.allocator.free(docs);
    const downloads = try fx.sub("me/Downloads");
    defer testing.allocator.free(downloads);
    const desktop = try fx.sub("me/Desktop");
    defer testing.allocator.free(desktop);
    const proj = try fx.sub("me/Projects/nanofm");
    defer testing.allocator.free(proj);

    try m.queue(.{ .apply_preset = .grid_2x2 });
    _ = try m.applyPending();
    const folders = [_][]const u8{ docs, downloads, proj, desktop };
    for (m.panes.items, folders) |*p, f| try p.tab().visit(f, m.opts(p));
    // Pane 0 has three tabs, pane 3 two; pane 1 is sorted by size.
    try m.queue(.{ .focus_pane = m.panes.items[0].id });
    try m.queue(.new_tab);
    try m.queue(.{ .open_in_new_tab = downloads });
    try m.queue(.{ .focus_pane = m.panes.items[3].id });
    try m.queue(.{ .open_in_new_tab = home });
    try m.queue(.{ .focus_pane = m.panes.items[1].id });
    try m.queue(.{ .sort = .size });
    try m.queue(.{ .select_tab = .{ .pane = m.panes.items[0].id, .tab = m.panes.items[0].tabs.items[0].id } });
    _ = try m.applyPending();

    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&m, app_view.view), .{ .width = 1100, .height = 700 });
    defer t.deinit();
    t.settle(0.3);
    try t.clickText("Annual Report.pdf");
    t.settle(0.3);
    try t.screenshot(std.mem.span(out));

    var dark: ui.Tester = undefined;
    try dark.init(testing.allocator, .init(&m, app_view.view), .{ .width = 1100, .height = 700, .dark = true });
    defer dark.deinit();
    dark.settle(0.3);
    // The layout popover open, over the dark theme.
    try ts.clickIconIn(&dark, ts.stripOf(try ts.paneRect(&dark, &m, 0)), "rectangle.split.2x2");
    dark.settle(0.5);
    const dark_path = try std.fmt.allocPrint(testing.allocator, "{s}.dark.png", .{std.mem.span(out)});
    defer testing.allocator.free(dark_path);
    try dark.screenshot(dark_path);
}
