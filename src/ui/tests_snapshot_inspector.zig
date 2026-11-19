//! Render snapshots of the inspector (only when NANOFM_SNAPSHOT_PNG names a file; each goes beside
//! it with a suffix): a list with the inspector on a picture (its thumbnail from a fake provider,
//! its resolution from a real PNG header), light and dark; and a two-pane layout with the inspector
//! in both panes (a picture, and a folder), and a column view with its preview.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const app_view = @import("../app.zig");
const sidebar_model = @import("sidebar_model.zig");
const state_model = @import("../core/state_model.zig");
const image_info = @import("image_info.zig");
const thumbs = @import("thumbs.zig");
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
    const png = image_info.pngHeader(4032, 3024);
    const body = try testing.allocator.alloc(u8, 2_300_000); // a real photo's weight
    defer testing.allocator.free(body);
    @memset(body, 0);
    @memcpy(body[0..png.len], &png);
    try fx.bytes("me/Documents/sunset.png", body);
    try fx.dir("me/Documents/Invoices/2025");
    try fx.file("me/Documents/Invoices/inv-001.pdf", 52_113);
}

/// A sky-to-sand gradient with a sun: what a thumbnail would be, made at once (the cache takes it
/// at the next pass).
fn gradient(path: []const u8, side: u32, done: thumbs.Done) void {
    _ = path;
    _ = side;
    const w = 260;
    const h = 195;
    var px: [w * h * 4]u8 = undefined;
    for (0..h) |y| for (0..w) |x| {
        const o = (y * w + x) * 4;
        const t: f32 = @as(f32, @floatFromInt(y)) / h;
        var r: f32 = 90 + 150 * t;
        var g: f32 = 150 + 40 * t;
        var b: f32 = 235 - 150 * t;
        const dx = @as(f32, @floatFromInt(x)) - 190;
        const dy = @as(f32, @floatFromInt(y)) - 55;
        if (dx * dx + dy * dy < 24 * 24) {
            r = 255;
            g = 230;
            b = 120;
        }
        px[o] = @intFromFloat(b);
        px[o + 1] = @intFromFloat(g);
        px[o + 2] = @intFromFloat(r);
        px[o + 3] = 255;
    };
    done.finish(.{ .bgra = &px, .width = w, .height = h });
}

fn model(fx: *ts.Fixture, start_rel: []const u8) !app_view.State {
    const home = try fx.sub("me");
    defer testing.allocator.free(home);
    const start = try fx.sub(start_rel);
    defer testing.allocator.free(start);
    var persisted = try state_model.PersistedState.defaults(testing.allocator, testing.io, home);
    defer persisted.deinit(testing.allocator);
    const fav = try sidebar_model.itemsOf(testing.allocator, persisted.favorites.items);
    defer testing.allocator.free(fav);
    var hooks = ts.test_hooks;
    hooks.thumbnail = gradient;
    return app_view.State.init(testing.allocator, .{
        .start_path = start,
        .home_path = home,
        .favorites = fav,
        .locations = &.{.{ .path = "/", .title = "Macintosh HD" }},
        .hooks = hooks,
    });
}

fn shot(m: *app_view.State, name: []const u8, w: f32, h: f32, dark: bool, steps: *const fn (*ui.Tester) anyerror!void) !void {
    const out = std.c.getenv("NANOFM_SNAPSHOT_PNG") orelse return error.SkipZigTest;
    const path = try std.fmt.allocPrint(testing.allocator, "{s}.{s}.png", .{ std.mem.span(out), name });
    defer testing.allocator.free(path);
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(m, app_view.view), .{ .width = w, .height = h, .dark = dark });
    defer t.deinit();
    t.settle(0.3);
    try steps(&t);
    t.settle(0.4);
    t.advance(0.3);
    try t.screenshot(path);
}

fn selectPhoto(t: *ui.Tester) !void {
    try t.clickText("sunset.png");
}

test "snapshot: the inspector beside a list, on a picture (light and dark)" {
    _ = std.c.getenv("NANOFM_SNAPSHOT_PNG") orelse return error.SkipZigTest;
    var fx = try ts.Fixture.init();
    defer fx.deinit();
    try build(&fx);
    var m = try model(&fx, "me/Documents");
    defer m.deinit();
    m.focusedPane().inspector = true;
    try shot(&m, "inspector", 1100, 700, false, selectPhoto);
    try shot(&m, "inspector.dark", 1100, 700, true, selectPhoto);
}

fn selectFolder(t: *ui.Tester) !void {
    try t.clickText("Invoices");
}

test "snapshot: a two-pane layout with the inspector in both panes" {
    _ = std.c.getenv("NANOFM_SNAPSHOT_PNG") orelse return error.SkipZigTest;
    var fx = try ts.Fixture.init();
    defer fx.deinit();
    try build(&fx);
    var m = try model(&fx, "me/Documents");
    defer m.deinit();
    try m.queue(.{ .apply_preset = .two_columns });
    _ = try m.applyPending();
    for (m.panes.items) |*p| p.inspector = true;
    try shot(&m, "inspector.two", 1100, 700, false, selectPhoto);
    try shot(&m, "inspector.two.dark", 1100, 700, true, selectPhoto);
}

test "snapshot: column view's preview, and several items selected" {
    _ = std.c.getenv("NANOFM_SNAPSHOT_PNG") orelse return error.SkipZigTest;
    var fx = try ts.Fixture.init();
    defer fx.deinit();
    try build(&fx);
    var m = try model(&fx, "me/Documents");
    defer m.deinit();
    m.focusedPane().view_mode = .column;
    try shot(&m, "inspector.columns", 1200, 640, false, selectPhoto);
    m.focusedPane().view_mode = .list;
    m.focusedPane().inspector = true;
    try shot(&m, "inspector.multi", 1100, 700, false, selectSeveral);
}

fn selectSeveral(t: *ui.Tester) !void {
    try t.clickText("notes.txt");
    t.settle(0.2);
    try ts.clickTextWith(t, "archive.zip", .{ .cmd = true });
    t.settle(0.2);
    try ts.clickTextWith(t, "Invoices", .{ .cmd = true });
}
