//! Render snapshots of the sidebar (only when NANOFM_SNAPSHOT_PNG names a file; the others go
//! beside it as "<file>.sidebar.*.png"): Favorites, Pinned and Locations with volumes (one
//! internal, two with an eject button), the context menu of a favorite and of a volume, a drag
//! landing between two favorites, the dark theme, and the window with the sidebar hidden.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const app_view = @import("../app.zig");
const sidebar_model = @import("sidebar_model.zig");
const state_model = @import("../core/state_model.zig");
const volumes = @import("volumes.zig");
const ts = @import("test_support.zig");

const testing = std.testing;
const side: @import("pane_sizes.zig").Rect = .{ .x = 0, .y = 0, .w = 212, .h = 560 };

var vols: [3]volumes.Volume = undefined;

fn list(gpa: std.mem.Allocator) std.mem.Allocator.Error![]volumes.Volume {
    const out = try gpa.alloc(volumes.Volume, vols.len);
    var done: usize = 0;
    errdefer {
        for (out[0..done]) |v| {
            gpa.free(v.path);
            gpa.free(v.title);
        }
        gpa.free(out);
    }
    for (vols, out) |v, *o| {
        o.* = .{ .path = try gpa.dupe(u8, v.path), .title = try gpa.dupe(u8, v.title), .ejectable = v.ejectable };
        done += 1;
    }
    return out;
}

fn eject(_: []const u8) bool {
    return true;
}

fn path(base: []const u8, suffix: []const u8) ![]u8 {
    return std.fmt.allocPrint(testing.allocator, "{s}.sidebar.{s}.png", .{ base, suffix });
}

test "snapshot: the sidebar with volumes, its context menus, a drag, and hidden" {
    const out = std.c.getenv("NANOFM_SNAPSHOT_PNG") orelse return error.SkipZigTest;
    const base = std.mem.span(out);
    var fx = try ts.Fixture.init();
    defer fx.deinit();
    for ([_][]const u8{ "me/Desktop", "me/Documents/Invoices", "me/Downloads", "me/Projects/nanofm/src", "me/Volumes/Backup Drive", "me/Volumes/Camera SD" }) |d| try fx.dir(d);
    try fx.file("me/Documents/notes.txt", 812);
    try fx.file("me/Documents/budget.xlsx", 31_200);
    try fx.file("me/Projects/nanofm/build.zig", 1_900);
    const home = try fx.sub("me");
    defer testing.allocator.free(home);
    const start = try fx.sub("me/Documents");
    defer testing.allocator.free(start);
    const proj = try fx.sub("me/Projects/nanofm");
    defer testing.allocator.free(proj);
    const backup = try fx.sub("me/Volumes/Backup Drive");
    defer testing.allocator.free(backup);
    const camera = try fx.sub("me/Volumes/Camera SD");
    defer testing.allocator.free(camera);
    vols = .{
        .{ .path = "/", .title = "Macintosh HD" },
        .{ .path = backup, .title = "Backup Drive", .ejectable = true },
        .{ .path = camera, .title = "Camera SD", .ejectable = true },
    };

    var persisted = try state_model.PersistedState.defaults(testing.allocator, testing.io, home);
    defer persisted.deinit(testing.allocator);
    const fav = try sidebar_model.itemsOf(testing.allocator, persisted.favorites.items);
    defer testing.allocator.free(fav);
    var m = try app_view.State.init(testing.allocator, .{
        .start_path = start,
        .home_path = home,
        .favorites = fav,
        .pinned = &.{.{ .path = proj, .title = "nanofm" }},
        .volumes = .{ .list = list, .eject = eject },
        .hooks = ts.test_hooks,
    });
    defer m.deinit();

    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&m, app_view.view), .{ .width = 900, .height = 560 });
    defer t.deinit();
    t.settle(0.3);

    // The sidebar as it is, a volume hovered.
    const hover = t.findText("Backup Drive").?;
    t.moveTo(hover.x + 20, hover.y + hover.h / 2);
    t.settle(0.2);
    const plain = try path(base, "volumes");
    defer testing.allocator.free(plain);
    try t.screenshot(plain);

    // A favorite's context menu.
    const docs = ts.findTextIn(&t, side, "Documents").?;
    t.secondaryClick(docs.x + 10, docs.y + docs.h / 2);
    t.settle(0.4);
    const menu_path = try path(base, "menu");
    defer testing.allocator.free(menu_path);
    try t.screenshot(menu_path);
    t.key(.escape);
    t.settle(0.3);

    // A volume's: Eject is there.
    const cam = t.findText("Camera SD").?;
    t.secondaryClick(cam.x + 10, cam.y + cam.h / 2);
    t.settle(0.4);
    const vol_menu = try path(base, "volume-menu");
    defer testing.allocator.free(vol_menu);
    try t.screenshot(vol_menu);
    t.key(.escape);
    t.settle(0.3);

    // A favorite dragged over the lower half of another row: the marker where it would land.
    const from = t.findText("Downloads").?;
    const over = ts.findTextIn(&t, side, "Documents").?;
    t.moveTo(from.x + 10, from.y + from.h / 2);
    t.ctx.pointerDown();
    t.frame();
    var i: f32 = 1;
    while (i <= 8) : (i += 1) {
        t.ctx.input.mouse = .{ .x = from.x + 10 + (over.x - from.x) * i / 8, .y = from.y + from.h / 2 + (over.y + over.h - 1 - from.y - from.h / 2) * i / 8 };
        t.frame();
    }
    t.settle(0.2);
    const drag_path = try path(base, "drag");
    defer testing.allocator.free(drag_path);
    try t.screenshot(drag_path);
    t.ctx.pointerUp();
    t.frame();
    t.settle(0.3);

    // Dark.
    var dark: ui.Tester = undefined;
    try dark.init(testing.allocator, .init(&m, app_view.view), .{ .width = 900, .height = 560, .dark = true });
    defer dark.deinit();
    dark.settle(0.3);
    const dark_hover = dark.findText("Camera SD").?;
    dark.moveTo(dark_hover.x + 20, dark_hover.y + dark_hover.h / 2);
    dark.settle(0.2);
    const dark_path = try path(base, "dark");
    defer testing.allocator.free(dark_path);
    try dark.screenshot(dark_path);

    // Hidden: the panes take the room, and the strip keeps clear of the traffic lights.
    try m.queue(.{ .run_command = .view_sidebar });
    dark.settle(0.3);
    const hidden_path = try path(base, "hidden");
    defer testing.allocator.free(hidden_path);
    try dark.screenshot(hidden_path);
}
