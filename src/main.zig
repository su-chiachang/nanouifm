//! Nanofm: one window showing the view in app.zig. The only place that knows the real home
//! folder: everything below it takes its folders from `app.Config`.
const std = @import("std");
const nanoui = @import("nanoui");
const app_view = @import("app.zig");
const state_model = @import("core/state_model.zig");
const sidebar_model = @import("ui/sidebar_model.zig");

pub const panic = nanoui.panic;
pub const std_options = nanoui.std_options;
pub const std_options_debug_threaded_io = nanoui.std_options_debug_threaded_io;

pub fn main(init: nanoui.Init) void {
    run(init) catch return;
}

fn run(init: nanoui.Init) !void {
    const gpa = std.heap.smp_allocator;
    // `nanoui.Init` is the Minimal init on the Mac (the environment block, no gpa or io).
    const home: []const u8 = if (@hasField(nanoui.Init, "environ_map"))
        init.environ_map.get("HOME") orelse "/"
    else
        init.environ.getPosix("HOME") orelse "/";

    // The app's own Io (the one nanoui runs on): `std.Io.Threaded` is deliberately kept out of
    // the app's compilation unit.
    const app = try nanoui.App.create(init, .{ .name = "Nanofm" });
    defer app.destroy();

    // Favorites come from the core state's first-launch defaults (Desktop, Documents,
    // Downloads, Home). Slice 1 neither loads nor saves the persisted state file.
    var persisted = try state_model.PersistedState.defaults(gpa, app.io, home);
    defer persisted.deinit(gpa);
    const favorites = try sidebar_model.itemsOf(gpa, persisted.favorites.items);
    defer gpa.free(favorites);
    const pinned = try sidebar_model.itemsOf(gpa, persisted.pinned.items);
    defer gpa.free(pinned);

    var state = try app_view.State.init(gpa, .{
        .start_path = home,
        .home_path = home,
        .favorites = favorites,
        .pinned = pinned,
        // A stub: the startup volume. Mounted volumes (live) come in a later slice.
        .locations = &.{.{ .path = "/", .title = "Macintosh HD" }},
        .show_hidden = persisted.show_hidden,
    });
    defer state.deinit();

    _ = try app.newWindow(.{
        .title = "Nanofm",
        .width = 1000,
        .height = 640,
        .min_width = 640,
        .min_height = 380,
        .title_bar = .hidden,
        .content = .{ .view = .init(&state, app_view.view) },
    });
    try app.run();
}
