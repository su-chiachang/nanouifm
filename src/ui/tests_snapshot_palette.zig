//! Render snapshots of the command palette and the toolbar (only when NANOFM_SNAPSHOT_PNG names a
//! file; the others go beside it as "<file>.<name>.png", the dark ones "<file>.<name>.dark.png"):
//! the palette on an empty query and on a typed one (every kind of row, a disabled command), the Sort
//! menu, and a split with a filter typed in one pane. Temp folders only; the index is injected.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const app_view = @import("../app.zig");
const palette_index = @import("palette_index.zig");
const sidebar_model = @import("sidebar_model.zig");
const state_model = @import("../core/state_model.zig");
const ts = @import("test_support.zig");

const testing = std.testing;
const S = ui.Shortcut;

fn populate(fx: *ts.Fixture) !void {
    try fx.dir("me/Desktop");
    try fx.dir("me/Downloads");
    try fx.dir("me/Documents/Invoices");
    try fx.dir("me/Documents/Taxes 2025");
    try fx.file("me/Documents/Invoices/inv-001.pdf", 52_113);
    try fx.file("me/Documents/Annual Report.pdf", 482_113);
    try fx.file("me/Documents/budget.xlsx", 31_200);
    try fx.file("me/Documents/notes.txt", 812);
    try fx.file("me/Documents/archive.zip", 14_800_000);
    try fx.file("me/Downloads/installer.dmg", 92_000_000);
    try fx.file("me/Downloads/holiday photo.jpg", 2_904_331);
    try fx.file("me/Downloads/domain-names.csv", 2_331);
    try fx.dir("me/Projects/dotfiles");
    try fx.file("me/Projects/dotfiles/zshrc", 1_900);
    try fx.file("me/Desktop/todo.txt", 120);
}

fn path(base: []const u8, name: []const u8, dark: bool) ![]u8 {
    return std.fmt.allocPrint(testing.allocator, "{s}.{s}{s}.png", .{ base, name, if (dark) ".dark" else "" });
}

test "snapshot: the command palette, empty and with results, light and dark" {
    const out = std.c.getenv("NANOFM_SNAPSHOT_PNG") orelse return error.SkipZigTest;
    const base = std.mem.span(out);
    var fx = try ts.Fixture.init();
    defer fx.deinit();
    try populate(&fx);
    const home = try fx.sub("me");
    defer testing.allocator.free(home);
    const projects = try fx.sub("me/Projects");
    defer testing.allocator.free(projects);
    var persisted = try state_model.PersistedState.defaults(testing.allocator, testing.io, home);
    defer persisted.deinit(testing.allocator);
    const fav = try sidebar_model.itemsOf(testing.allocator, persisted.favorites.items);
    defer testing.allocator.free(fav);
    var m = try app_view.State.init(testing.allocator, .{
        .start_path = home,
        .home_path = home,
        .favorites = fav,
        .pinned = &.{.{ .path = projects }},
        .locations = &.{.{ .path = "/", .title = "Macintosh HD" }},
        .index = .{ .roots = &.{home}, .runner = palette_index.runNow },
    });
    defer m.deinit();

    for ([_]bool{ false, true }) |dark| {
        var t: ui.Tester = undefined;
        try t.init(testing.allocator, .init(&m, app_view.view), .{ .width = 1000, .height = 640, .dark = dark });
        defer t.deinit();
        t.settle(0.3);
        try testing.expect(t.shortcut(.{ .key = 'k', .cmd = true }));
        t.settle(0.5);
        const empty = try path(base, "palette-empty", dark);
        defer testing.allocator.free(empty);
        try t.screenshot(empty);

        t.typeText("do");
        t.settle(0.5);
        try testing.expect(t.shortcut(.{ .key = S.down }));
        try testing.expect(t.shortcut(.{ .key = S.down }));
        t.settle(0.4);
        const typed = try path(base, "palette", dark);
        defer testing.allocator.free(typed);
        try t.screenshot(typed);
        // Files and folders of the index, and a command with nothing to do.
        t.textOps(&.{ .{ .command = .select_all }, .{ .command = .delete_backward } });
        t.typeText("inv");
        t.settle(0.5);
        const files = try path(base, "palette-files", dark);
        defer testing.allocator.free(files);
        try t.screenshot(files);
        try testing.expect(t.shortcut(.{ .key = S.escape }));
        t.settle(0.5);
    }
}

test "snapshot: the Sort menu, and a split with a filter typed in one pane" {
    const out = std.c.getenv("NANOFM_SNAPSHOT_PNG") orelse return error.SkipZigTest;
    const base = std.mem.span(out);
    var fx = try ts.Fixture.init();
    defer fx.deinit();
    try populate(&fx);
    const docs = try fx.sub("me/Documents");
    defer testing.allocator.free(docs);
    var m = try app_view.State.init(testing.allocator, .{
        .start_path = docs,
        .home_path = docs,
        .locations = &.{.{ .path = "/", .title = "Macintosh HD" }},
    });
    defer m.deinit();
    try m.queue(.{ .sort = .size });

    for ([_]bool{ false, true }) |dark| {
        var t: ui.Tester = undefined;
        try t.init(testing.allocator, .init(&m, app_view.view), .{ .width = 1000, .height = 560, .dark = dark });
        defer t.deinit();
        t.settle(0.3);
        try ts.clickIcon(&t, "arrow.up.arrow.down");
        t.settle(0.5);
        const sort = try path(base, "sort", dark);
        defer testing.allocator.free(sort);
        try t.screenshot(sort);
        try testing.expect(t.shortcut(.{ .key = S.escape }));
        t.settle(0.5);
    }

    try m.queue(.{ .run_command = .layout_grid_2x2 });
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&m, app_view.view), .{ .width = 1000, .height = 600 });
    defer t.deinit();
    t.settle(0.4);
    try testing.expect(t.shortcut(.{ .key = 'f', .cmd = true }));
    t.settle(0.3);
    t.typeText("re");
    t.settle(0.4);
    const split = try path(base, "filter-grid", false);
    defer testing.allocator.free(split);
    try t.screenshot(split);
}
