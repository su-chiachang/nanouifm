//! Render snapshots of this slice (only when NANOFM_SNAPSHOT_PNG names a file; each goes beside it
//! with a suffix): the context menu on an item (light) and on empty space (dark), and an inline
//! rename with the error banner.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const app_view = @import("../app.zig");
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
}

fn path(base: []const u8, suffix: []const u8) ![]u8 {
    return std.fmt.allocPrint(testing.allocator, "{s}.{s}.png", .{ base, suffix });
}

fn model(fx: *ts.Fixture) !app_view.State {
    const home = try fx.sub("me");
    defer testing.allocator.free(home);
    const start = try fx.sub("me/Documents");
    defer testing.allocator.free(start);
    var persisted = try state_model.PersistedState.defaults(testing.allocator, testing.io, home);
    defer persisted.deinit(testing.allocator);
    const fav = try sidebar_model.itemsOf(testing.allocator, persisted.favorites.items);
    defer testing.allocator.free(fav);
    return app_view.State.init(testing.allocator, .{
        .start_path = start,
        .home_path = home,
        .favorites = fav,
        .locations = &.{.{ .path = "/", .title = "Macintosh HD" }},
        .hooks = ts.test_hooks,
    });
}

fn rightClick(t: *ui.Tester, name: []const u8) !void {
    const r = t.findText(name) orelse return error.TextNotFound;
    t.secondaryClick(r.x + r.w / 2, r.y + r.h / 2);
    t.settle(0.6);
}

test "snapshot: the context menu on an item, and on empty space (dark)" {
    const out = std.c.getenv("NANOFM_SNAPSHOT_PNG") orelse return error.SkipZigTest;
    const base = std.mem.span(out);
    var fx = try ts.Fixture.init();
    defer fx.deinit();
    try build(&fx);
    var m = try model(&fx);
    defer m.deinit();

    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&m, app_view.view), .{ .width = 1000, .height = 640 });
    defer t.deinit();
    t.settle(0.3);
    try rightClick(&t, "Invoices");
    const p1 = try path(base, "context");
    defer testing.allocator.free(p1);
    try t.screenshot(p1);

    var dark: ui.Tester = undefined;
    try dark.init(testing.allocator, .init(&m, app_view.view), .{ .width = 1000, .height = 640, .dark = true });
    defer dark.deinit();
    dark.settle(0.3);
    m.view_state.ctx_menu.open = false;
    dark.settle(0.3);
    const r = try ts.paneRect(&dark, &m, 0);
    dark.secondaryClick(r.x + r.w / 2, r.y + r.h - 120);
    dark.settle(0.6);
    const p2 = try path(base, "context.dark");
    defer testing.allocator.free(p2);
    try dark.screenshot(p2);
}

test "snapshot: the item menu in the smallest window (it scrolls)" {
    const out = std.c.getenv("NANOFM_SNAPSHOT_PNG") orelse return error.SkipZigTest;
    var fx = try ts.Fixture.init();
    defer fx.deinit();
    try build(&fx);
    var m = try model(&fx);
    defer m.deinit();

    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&m, app_view.view), .{ .width = 640, .height = 380 });
    defer t.deinit();
    t.settle(0.3);
    try rightClick(&t, "Invoices");
    const p = try path(std.mem.span(out), "context.small");
    defer testing.allocator.free(p);
    try t.screenshot(p);
    // The last line is reachable by scrolling the menu.
    const r = t.findText("Reveal in Finder").?;
    t.scroll(r.x + 20, r.y, -400);
    t.settle(0.3);
    try testing.expect(t.hasText("Show Hidden Files"));
    const bottom = t.findText("Show Hidden Files").?;
    try testing.expect(bottom.y + bottom.h <= 380);
}

test "snapshot: inline rename with the invalid-name banner" {
    const out = std.c.getenv("NANOFM_SNAPSHOT_PNG") orelse return error.SkipZigTest;
    var fx = try ts.Fixture.init();
    defer fx.deinit();
    try build(&fx);
    var m = try model(&fx);
    defer m.deinit();

    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&m, app_view.view), .{ .width = 1000, .height = 640 });
    defer t.deinit();
    t.settle(0.3);
    try t.clickText("Annual Report.pdf");
    t.settle(0.2);
    if (!t.shortcut(.{ .key = ui.Shortcut.enter })) return error.KeyNotTaken;
    t.settle(0.3);
    t.textOps(&.{ .{ .command = .select_all }, .{ .command = .delete_backward } });
    t.typeText("Q3/Report");
    t.key(.enter);
    t.settle(0.4);
    const p = try path(std.mem.span(out), "rename");
    defer testing.allocator.free(p);
    try t.screenshot(p);
}

fn fakeApps(gpa: std.mem.Allocator, file: []const u8) std.mem.Allocator.Error![]@import("hooks.zig").OpenApp {
    _ = file;
    const names = [_][]const u8{ "TextEdit", "Visual Studio Code", "Xcode", "Sublime Text" };
    const out = try gpa.alloc(@import("hooks.zig").OpenApp, names.len);
    for (names, out) |n, *o| o.* = .{ .name = try gpa.dupe(u8, n), .path = try std.fmt.allocPrint(gpa, "/Applications/{s}.app", .{n}) };
    return out;
}

fn fakeOpenApp(app: []const u8, file: []const u8) bool {
    _ = app;
    _ = file;
    return true;
}

test "snapshot: the item menu of a file with its Open With rows" {
    const out = std.c.getenv("NANOFM_SNAPSHOT_PNG") orelse return error.SkipZigTest;
    var fx = try ts.Fixture.init();
    defer fx.deinit();
    try build(&fx);
    var m = try model(&fx);
    defer m.deinit();
    m.hooks.open_with = .{ .list = fakeApps, .open = fakeOpenApp };

    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&m, app_view.view), .{ .width = 1000, .height = 760 });
    defer t.deinit();
    t.settle(0.3);
    try rightClick(&t, "notes.txt");
    const p = try path(std.mem.span(out), "context.openwith");
    defer testing.allocator.free(p);
    try t.screenshot(p);
}
