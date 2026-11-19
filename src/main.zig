//! Nanofm: one window showing the view in app.zig. The only place that knows the real home
//! folder: everything below it takes its folders from `app.Config`.
const std = @import("std");
const nanoui = @import("nanoui");
const app_view = @import("app.zig");
const persist = @import("ui/persist.zig");
const menu_bar = @import("ui/menu_bar.zig");
const system_volumes = @import("ui/system_volumes.zig");
const opener = @import("ui/opener.zig");
const system_hooks = @import("ui/system_hooks.zig");
const system_quick_look = @import("ui/system_quick_look.zig");

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

    // The state file: favorites, pinned, the layout with its tabs, the settings. Where it lives
    // is ~/Library/Application Support/nanofm, or $NANOFM_STATE_DIR (a copy of the app for a
    // trial, a test run). Missing or corrupt: the first-launch defaults, which the model then
    // restores like any other state (folders that are gone are skipped).
    const state_override: ?[]const u8 = if (@hasField(nanoui.Init, "environ_map"))
        init.environ_map.get("NANOFM_STATE_DIR")
    else
        init.environ.getPosix("NANOFM_STATE_DIR");
    const state_dir = try persist.stateDir(gpa, home, state_override);
    defer gpa.free(state_dir);
    var store = try persist.Store.init(gpa, app.io, state_dir, home);
    defer store.deinit();

    // The palette's file index: Home's well-known folders (Favorites and Pinned are added by the
    // model), crawled on a background thread.
    var index_roots: [3][]u8 = undefined;
    for (&index_roots, [_][]const u8{ "Desktop", "Documents", "Downloads" }) |*root, sub| {
        root.* = try std.fs.path.join(gpa, &.{ home, sub });
    }
    defer for (index_roots) |r| gpa.free(r);

    var state = try app_view.State.init(gpa, .{
        .start_path = home,
        .home_path = home,
        .store = &store,
        // Locations: the mounted volumes, read again when one is mounted or unmounted.
        .volumes = system_volumes.provider,
        // The only place a real app can be launched from.
        .opener = opener.system,
        // Clipboard mirror, Reveal in Finder, Option state; live refresh with real watchers.
        .hooks = system_hooks.hooks,
        .watch = .system,
        .index = .{ .roots = &.{ index_roots[0], index_roots[1], index_roots[2] } },
    });
    defer state.deinit();
    system_quick_look.attach(&state); // the Quick Look panel's arrow keys move this model's selection

    // The native menu bar (generated from the command registry), and the volumes' notifications.
    const bar = try menu_bar.Bar.install(gpa, app, &state);
    defer bar.destroy();
    system_volumes.observe(state.vol_signal);
    // Quitting writes the state at once; coming forward reads the volumes again (a fallback for
    // a notification that did not come).
    app.options.ctx = &state;
    app.options.on_terminate = onTerminate;
    app.options.on_active = onActive;

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
    state.flushState();
}

fn onTerminate(ctx: ?*anyopaque) void {
    const m: *app_view.State = @ptrCast(@alignCast(ctx.?));
    m.flushState();
}

fn onActive(ctx: ?*anyopaque, active: bool) void {
    const m: *app_view.State = @ptrCast(@alignCast(ctx.?));
    if (active) m.vol_signal.mark();
}
