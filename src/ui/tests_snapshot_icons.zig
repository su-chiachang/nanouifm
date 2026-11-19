//! Render snapshots of the per-file-type icons (only when NANOFM_SNAPSHOT_PNG names a file; each
//! goes beside it with a suffix "icons..."): a list with a selected row and an opened folder, light
//! and dark, the inspector with the large icon, and a column view. The fake provider answers at
//! once with painted stand-ins (a blue folder, documents with a colour band per extension, an
//! orange app), as Finder's would be.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const app_view = @import("../app.zig");
const sidebar_model = @import("sidebar_model.zig");
const state_model = @import("../core/state_model.zig");
const file_icons = @import("file_icons.zig");
const ts = @import("test_support.zig");

const testing = std.testing;

fn build(fx: *ts.Fixture) !void {
    try fx.dir("me/Documents/Invoices/2025");
    try fx.dir("me/Documents/Taxes 2025");
    try fx.dir("me/Documents/Notes.app/Contents");
    try fx.dir("me/Documents/Mockups.bundle");
    try fx.file("me/Documents/Annual Report.pdf", 482_113);
    try fx.file("me/Documents/budget.xlsx", 31_200);
    try fx.file("me/Documents/notes.txt", 812);
    try fx.file("me/Documents/archive.zip", 14_800_000);
    try fx.file("me/Documents/holiday.jpg", 2_904_331);
    try fx.file("me/Documents/build.zig", 1_900);
    try fx.file("me/Documents/README", 400);
    try fx.file("me/Documents/Invoices/inv-001.pdf", 52_113);
    try fx.file("me/Documents/Invoices/inv-002.pdf", 61_090);
    try fx.file("me/Documents/Invoices/summary.xlsx", 9_000);
}

/// Whether the point (u, v) in the unit square is inside a rounded rectangle.
fn inRound(u: f32, v: f32, x0: f32, y0: f32, x1: f32, y1: f32, r: f32) bool {
    if (u < x0 or u > x1 or v < y0 or v > y1) return false;
    const cx = std.math.clamp(u, x0 + r, x1 - r);
    const cy = std.math.clamp(v, y0 + r, y1 - r);
    const dx = u - cx;
    const dy = v - cy;
    return dx * dx + dy * dy <= r * r;
}

fn hue(text: []const u8) [3]u8 {
    const h = std.hash.Wyhash.hash(7, text);
    return .{ @intCast(70 + h % 150), @intCast(70 + (h >> 8) % 150), @intCast(70 + (h >> 16) % 150) };
}

/// The stand-in icon of `key`, `side` pixels square, as premultiplied BGRA (opaque or empty).
fn paint(key: file_icons.Key, side: u32, done: file_icons.Done) void {
    var px: [128 * 128 * 4]u8 = undefined;
    const n: usize = @min(side, 128);
    const f: f32 = @floatFromInt(n);
    const band: [3]u8 = switch (key) {
        .ext => |e| hue(e),
        else => .{ 0, 0, 0 },
    };
    for (0..n) |y| for (0..n) |x| {
        const u = (@as(f32, @floatFromInt(x)) + 0.5) / f;
        const v = (@as(f32, @floatFromInt(y)) + 0.5) / f;
        var c: [4]u8 = .{ 0, 0, 0, 0 }; // b, g, r, a
        switch (key) {
            .folder => {
                if (inRound(u, v, 0.04, 0.14, 0.46, 0.34, 0.05) or inRound(u, v, 0.04, 0.24, 0.96, 0.88, 0.07)) c = .{ 240, 160, 70, 255 };
            },
            .path => {
                if (inRound(u, v, 0.06, 0.06, 0.94, 0.94, 0.22)) c = .{ @intFromFloat(60 + 40 * v), @intFromFloat(140 - 60 * v), 255, 255 };
            },
            else => {
                if (inRound(u, v, 0.2, 0.06, 0.8, 0.94, 0.08)) {
                    c = .{ 170, 165, 160, 255 }; // the outline
                    if (inRound(u, v, 0.23, 0.09, 0.77, 0.91, 0.06)) c = .{ 250, 247, 245, 255 };
                    if (v > 0.56 and v < 0.76 and u > 0.23 and u < 0.77) c = .{ band[2], band[1], band[0], 255 };
                    if (u > 0.62 and v < 0.26 and u - 0.62 > 0.26 - v) c = .{ 0, 0, 0, 0 }; // the folded corner
                }
            },
        }
        const o = (y * n + x) * 4;
        @memcpy(px[o .. o + 4], &c);
    };
    done.finish(.{ .bgra = px[0 .. n * n * 4], .width = @intCast(n), .height = @intCast(n) });
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
    hooks.file_icon = paint;
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
    const path = try std.fmt.allocPrint(testing.allocator, "{s}.icons.{s}.png", .{ std.mem.span(out), name });
    defer testing.allocator.free(path);
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(m, app_view.view), .{ .width = w, .height = h, .dark = dark });
    defer t.deinit();
    t.settle(0.3);
    t.settle(0.3); // (the first frame asked, the next one drew the answers)
    try steps(&t);
    t.settle(0.4);
    t.advance(0.3);
    try t.screenshot(path);
}

fn selectReport(t: *ui.Tester) !void {
    try t.clickText("Annual Report.pdf");
}

fn selectNotes(t: *ui.Tester) !void {
    try t.clickText("notes.txt");
}

test "snapshot: icons in a list with an opened folder and a selection (light and dark), and the inspector" {
    _ = std.c.getenv("NANOFM_SNAPSHOT_PNG") orelse return error.SkipZigTest;
    var fx = try ts.Fixture.init();
    defer fx.deinit();
    try build(&fx);
    var m = try model(&fx, "me/Documents");
    defer m.deinit();
    const inv = try fx.sub("me/Documents/Invoices");
    defer testing.allocator.free(inv);
    try m.panes.items[0].tab().setExpanded(inv, true, m.opts(&m.panes.items[0]));
    try shot(&m, "list", 1000, 560, false, selectReport);
    try shot(&m, "list.dark", 1000, 560, true, selectReport);
    m.focusedPane().inspector = true;
    try shot(&m, "inspector", 1100, 560, false, selectNotes);
}

test "snapshot: icons in column view" {
    _ = std.c.getenv("NANOFM_SNAPSHOT_PNG") orelse return error.SkipZigTest;
    var fx = try ts.Fixture.init();
    defer fx.deinit();
    try build(&fx);
    var m = try model(&fx, "me");
    defer m.deinit();
    m.focusedPane().view_mode = .column;
    try shot(&m, "columns", 1200, 560, false, selectInColumns);
}

fn selectInColumns(t: *ui.Tester) !void {
    try t.clickText("Documents");
    t.settle(0.3);
    try t.clickText("Invoices");
    t.settle(0.3);
    try t.clickText("summary.xlsx");
}
