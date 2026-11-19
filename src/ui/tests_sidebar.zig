//! The sidebar through ui.Tester: hiding it, the Locations (a fake list of volumes, changed as a
//! test likes: no real volume is read), the eject button, the context menu, reordering and
//! adding by drag, and the Add to Favorites command. Temp folders only.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const app_view = @import("../app.zig");
const volumes = @import("volumes.zig");
const ts = @import("test_support.zig");
const style = @import("style.zig");
const commands = @import("commands.zig");

const testing = std.testing;

// ---- the fake provider ----

var fake: [4]volumes.Volume = undefined;
var fake_n: usize = 0;
var ejected: [256]u8 = undefined;
var ejected_len: usize = 0;
var eject_works = true;

fn setFake(list: []const volumes.Volume) void {
    @memcpy(fake[0..list.len], list);
    fake_n = list.len;
}

fn fakeList(gpa: std.mem.Allocator) std.mem.Allocator.Error![]volumes.Volume {
    const out = try gpa.alloc(volumes.Volume, fake_n);
    var done: usize = 0;
    errdefer {
        for (out[0..done]) |v| {
            gpa.free(v.path);
            gpa.free(v.title);
        }
        gpa.free(out);
    }
    for (fake[0..fake_n], out) |v, *o| {
        o.* = .{ .path = try gpa.dupe(u8, v.path), .title = try gpa.dupe(u8, v.title), .ejectable = v.ejectable };
        done += 1;
    }
    return out;
}

fn fakeEject(path: []const u8) bool {
    @memcpy(ejected[0..path.len], path);
    ejected_len = path.len;
    if (!eject_works) return false;
    var kept: usize = 0;
    for (fake[0..fake_n]) |v| {
        if (std.mem.eql(u8, v.path, path)) continue;
        fake[kept] = v;
        kept += 1;
    }
    fake_n = kept;
    return true;
}

const provider: volumes.Provider = .{ .list = fakeList, .eject = fakeEject };

fn reset() void {
    fake_n = 0;
    ejected_len = 0;
    eject_works = true;
}

fn favRow(env: *ts.Env) ui.Rect {
    return env.t.findText("Fav").?;
}

fn favoriteTitles(m: *app_view.State, out: *[8][]const u8) []const []const u8 {
    const rows = m.sidebar.sections[1].rows.items;
    for (rows, 0..) |r, i| out[i] = r.title;
    return out[0..rows.len];
}

fn expectFavorites(m: *app_view.State, want: []const []const u8) !void {
    var buf: [8][]const u8 = undefined;
    const got = favoriteTitles(m, &buf);
    try testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| try testing.expectEqualStrings(w, g);
}

// ---- visibility ----

test "the sidebar hides with its button and Ctrl+Cmd+S, and the panes take its room" {
    var env: ts.Env = undefined;
    try env.initWith(.{ .favorite = "dir" });
    defer env.deinit();
    try testing.expect(env.t.hasText("Favorites") and env.m.sidebar_visible);
    try testing.expectEqual(style.sidebar_width, (try ts.paneRect(&env.t, &env.m, 0)).x);

    try ts.clickIcon(&env.t, "sidebar.left");
    env.t.settle(0.3);
    try testing.expect(!env.m.sidebar_visible);
    try testing.expect(!env.t.hasText("Favorites") and !env.t.hasText("Fav"));
    const wide = try ts.paneRect(&env.t, &env.m, 0);
    try testing.expectEqual(@as(f32, 0), wide.x);
    try testing.expectEqual(env.t.size.w, wide.w);
    // Hidden, the first pane's tab strip has the button that brings it back, clear of the
    // window's traffic lights.
    const back = ts.iconIn(&env.t, ts.stripOf(wide), "sidebar.left").?;
    try testing.expect(back.x >= style.lead_gap);
    try ts.clickIcon(&env.t, "sidebar.left");
    env.t.settle(0.3);
    try testing.expect(env.m.sidebar_visible and env.t.hasText("Fav"));

    try ts.press(&env.t, 's', .{ .cmd = true, .ctrl = true });
    try testing.expect(!env.m.sidebar_visible);
    try ts.press(&env.t, 's', .{ .cmd = true, .ctrl = true });
    try testing.expect(env.m.sidebar_visible);
    try testing.expectEqual(style.sidebar_width, (try ts.paneRect(&env.t, &env.m, 0)).x);
}

// ---- Locations ----

test "Locations are the mounted volumes, read again when the system says one changed" {
    reset();
    const hd: volumes.Volume = .{ .path = "/", .title = "Macintosh HD" };
    setFake(&.{hd});
    var env: ts.Env = undefined;
    try env.initWith(.{ .volumes = provider, .files = &.{"usb/f.txt"} });
    defer env.deinit();
    const usb_path = try env.fx.sub("usb");
    defer testing.allocator.free(usb_path);
    const usb: volumes.Volume = .{ .path = usb_path, .title = "USB Stick", .ejectable = true };

    // The provider's list replaces the config's stub.
    try testing.expect(env.t.hasText("Macintosh HD") and !env.t.hasText("Volume"));
    try testing.expect(ts.hasIcon(&env.t, "internaldrive") and !ts.hasIcon(&env.t, "eject.fill"));

    // A mount: the signal marked (as the system's notification does), the next pass reads it.
    setFake(&.{ hd, usb });
    try testing.expect(env.m.vol_signal.waker != null); // the callback can wake a frame
    env.m.vol_signal.mark();
    env.t.settle(0.2);
    try testing.expect(env.t.hasText("USB Stick") and ts.hasIcon(&env.t, "eject.fill"));
    try testing.expectEqual(@as(usize, 2), env.m.sidebar.sections[3].rows.items.len);
    try testing.expect(env.m.sidebar.sections[3].rows.items[1].ejectable);

    // Without a signal the list is not read: a change nobody announced waits.
    setFake(&.{hd});
    env.t.settle(0.2);
    try testing.expect(env.t.hasText("USB Stick"));
    // An unmount.
    env.m.vol_signal.mark();
    env.t.settle(0.2);
    try testing.expect(!env.t.hasText("USB Stick") and !ts.hasIcon(&env.t, "eject.fill"));

    // A click on a volume goes there.
    setFake(&.{ hd, usb });
    env.m.vol_signal.mark();
    env.t.settle(0.2);
    try env.click("USB Stick");
    try testing.expectEqualStrings(usb_path, env.m.focusedTab().path());
    try testing.expect(env.t.hasText("f.txt"));
}

test "the eject button calls the hook, and the volume leaves; a failure raises the banner" {
    reset();
    const hd: volumes.Volume = .{ .path = "/", .title = "Macintosh HD" };
    var env: ts.Env = undefined;
    setFake(&.{hd});
    try env.initWith(.{ .volumes = provider, .files = &.{"usb/f.txt"} });
    defer env.deinit();
    const usb_path = try env.fx.sub("usb");
    defer testing.allocator.free(usb_path);
    setFake(&.{ hd, .{ .path = usb_path, .title = "USB Stick", .ejectable = true } });
    env.m.vol_signal.mark();
    env.t.settle(0.2);

    eject_works = false;
    try ts.clickIcon(&env.t, "eject.fill");
    env.t.settle(0.2);
    try testing.expectEqualStrings(usb_path, ejected[0..ejected_len]);
    try testing.expect(env.noticeHas("Can't eject \"usb\""));
    try testing.expect(env.t.hasText("USB Stick")); // still mounted
    try testing.expect(!std.mem.eql(u8, usb_path, env.m.focusedTab().path()));

    eject_works = true;
    env.m.clearNotice();
    try ts.clickIcon(&env.t, "eject.fill");
    env.t.settle(0.2);
    try testing.expect(!env.t.hasText("USB Stick") and env.m.notice == null);
}

// ---- the context menu ----

test "a favorite's context menu: Open in New Tab, Open in Split, Reveal, Remove" {
    reset();
    var env: ts.Env = undefined;
    try env.initWith(.{ .favorite = "dir" });
    defer env.deinit();
    const fav = try env.fx.sub("dir");
    defer testing.allocator.free(fav);

    var r = favRow(&env);
    env.t.secondaryClick(r.x + r.w / 2, r.y + r.h / 2);
    env.t.settle(0.3);
    for ([_][]const u8{ "Open", "Open in New Tab", "Open in Split", "Reveal in Finder", "Remove from Sidebar" }) |label| {
        try testing.expect(env.t.hasText(label));
    }
    try testing.expect(!env.t.hasText("Eject"));
    try env.click("Open in New Tab");
    try testing.expectEqual(@as(usize, 2), env.m.panes.items[0].tabs.items.len);
    try testing.expectEqualStrings(fav, env.m.focusedTab().path());
    try testing.expect(!env.t.hasText("Remove from Sidebar")); // the menu closed

    r = favRow(&env);
    env.t.secondaryClick(r.x + r.w / 2, r.y + r.h / 2);
    env.t.settle(0.3);
    try env.click("Open in Split");
    try testing.expectEqual(@as(usize, 2), env.m.panes.items.len);
    try testing.expectEqualStrings(fav, env.m.focusedTab().path());
    try ts.expectInSync(&env.m);

    r = favRow(&env);
    env.t.secondaryClick(r.x + r.w / 2, r.y + r.h / 2);
    env.t.settle(0.3);
    try env.click("Reveal in Finder");
    try testing.expectEqualStrings(fav, ts.revealedPaths());

    r = favRow(&env);
    env.t.secondaryClick(r.x + r.w / 2, r.y + r.h / 2);
    env.t.settle(0.3);
    try env.click("Remove from Sidebar");
    try testing.expectEqual(@as(usize, 0), env.m.sidebar.sections[1].rows.items.len);
    try testing.expect(!env.t.hasText("Fav"));
    try testing.expect(env.fx.exists("dir")); // only the entry went
}

test "Home and volumes have no Remove; a volume that can be ejected has Eject" {
    reset();
    const hd: volumes.Volume = .{ .path = "/", .title = "Macintosh HD" };
    setFake(&.{hd});
    var env: ts.Env = undefined;
    try env.initWith(.{ .volumes = provider, .files = &.{"usb/f.txt"} });
    defer env.deinit();
    const usb_path = try env.fx.sub("usb");
    defer testing.allocator.free(usb_path);
    setFake(&.{ hd, .{ .path = usb_path, .title = "USB Stick", .ejectable = true } });
    env.m.vol_signal.mark();
    env.t.settle(0.2);

    var r = env.t.findText("Home").?;
    env.t.secondaryClick(r.x + r.w / 2, r.y + r.h / 2);
    env.t.settle(0.3);
    try testing.expect(env.t.hasText("Open in New Tab") and !env.t.hasText("Remove from Sidebar") and !env.t.hasText("Eject"));
    env.t.key(.escape);
    env.t.settle(0.3);

    r = env.t.findText("Macintosh HD").?;
    env.t.secondaryClick(r.x + r.w / 2, r.y + r.h / 2);
    env.t.settle(0.3);
    try testing.expect(env.t.hasText("Open in Split") and !env.t.hasText("Eject"));
    env.t.key(.escape);
    env.t.settle(0.3);

    r = env.t.findText("USB Stick").?;
    env.t.secondaryClick(r.x + r.w / 2, r.y + r.h / 2);
    env.t.settle(0.3);
    try testing.expect(env.t.hasText("Eject") and !env.t.hasText("Remove from Sidebar"));
    try env.click("Eject");
    try testing.expectEqualStrings(usb_path, ejected[0..ejected_len]);
    try testing.expect(!env.t.hasText("USB Stick"));
}

// ---- reorder ----

test "dragging a favorite above or below another reorders them (and keeps their ids)" {
    reset();
    var env: ts.Env = undefined;
    try env.initWith(.{ .favorite = "dir", .favorite2 = "dest", .files = &.{"dest/x.txt"} });
    defer env.deinit();
    try expectFavorites(&env.m, &.{ "Fav", "Fav2" });
    const id_fav = env.m.sidebar.sections[1].rows.items[0].id.?;

    // Fav2 dropped on the upper half of Fav's row: it goes before.
    var from = env.t.findText("Fav2").?;
    var over = favRow(&env);
    env.t.drag(from.x + 4, from.y + from.h / 2, over.x + 4, over.y + 1);
    env.t.settle(0.3);
    try expectFavorites(&env.m, &.{ "Fav2", "Fav" });
    try testing.expect(env.m.sidebar.sections[1].rows.items[1].id.?.eql(id_fav));
    try testing.expect(!env.t.hasText("Fav2") or env.t.findText("Fav2").?.y < favRow(&env).y);

    // Fav2 (now first) dropped on the lower half of Fav's row: it goes after.
    from = env.t.findText("Fav2").?;
    over = favRow(&env);
    env.t.drag(from.x + 4, from.y + from.h / 2, over.x + 4, over.y + over.h - 1);
    env.t.settle(0.3);
    try expectFavorites(&env.m, &.{ "Fav", "Fav2" });
    // Not a navigation and not a file move.
    try testing.expectEqualStrings(env.fx.root, env.m.focusedTab().path());
    try testing.expect(env.fx.exists("dest/x.txt") and env.m.notice == null);
}

test "an entry dragged onto the Pinned header moves there; the Home row is not draggable" {
    reset();
    var env: ts.Env = undefined;
    try env.initWith(.{ .favorite = "dir", .favorite2 = "dest", .files = &.{"dest/x.txt"} });
    defer env.deinit();

    const from = env.t.findText("Fav2").?;
    const head = env.t.findText("Pinned").?;
    env.t.drag(from.x + 4, from.y + from.h / 2, head.x + 4, head.y + head.h / 2);
    env.t.settle(0.3);
    try expectFavorites(&env.m, &.{"Fav"});
    try testing.expectEqual(@as(usize, 1), env.m.sidebar.sections[2].rows.items.len);
    try testing.expectEqualStrings("Fav2", env.m.sidebar.sections[2].rows.items[0].title);

    const home = env.t.findText("Home").?;
    const favs = env.t.findText("Favorites").?;
    env.t.drag(home.x + 4, home.y + home.h / 2, favs.x + 4, favs.y + favs.h / 2);
    env.t.settle(0.3);
    try expectFavorites(&env.m, &.{"Fav"});
    try testing.expectEqual(@as(usize, 1), env.m.sidebar.sections[0].rows.items.len);
}

// ---- adding by drag ----

test "a folder dragged from a pane onto Favorites is added; a file is not; no duplicates" {
    reset();
    var env: ts.Env = undefined;
    try env.initWith(.{ .favorite = "dest", .files = &.{"dest/x.txt"} });
    defer env.deinit();
    const dir_path = try env.fx.sub("dir");
    defer testing.allocator.free(dir_path);

    // The folder "dir" of the list, onto the Favorites header.
    try env.click("dir");
    var head = env.t.findText("Favorites").?;
    var from = ts.findTextIn(&env.t, try ts.paneRect(&env.t, &env.m, 0), "dir").?;
    env.t.drag(from.x + from.w / 2, from.y + from.h / 2, head.x + 4, head.y + head.h / 2);
    env.t.settle(0.3);
    try expectFavorites(&env.m, &.{ "Fav", "dir" });
    try testing.expectEqualStrings(dir_path, env.m.sidebar.sections[1].rows.items[1].path);
    try testing.expect(env.fx.exists("dir/inner.txt")); // nothing moved

    // Again: not twice.
    head = env.t.findText("Favorites").?;
    from = ts.findTextIn(&env.t, try ts.paneRect(&env.t, &env.m, 0), "dir").?;
    env.t.drag(from.x + from.w / 2, from.y + from.h / 2, head.x + 4, head.y + head.h / 2);
    env.t.settle(0.3);
    try expectFavorites(&env.m, &.{ "Fav", "dir" });

    // A file: nothing.
    try env.click("a.txt");
    head = env.t.findText("Favorites").?;
    from = ts.findTextIn(&env.t, try ts.paneRect(&env.t, &env.m, 0), "a.txt").?;
    env.t.drag(from.x + from.w / 2, from.y + from.h / 2, head.x + 4, head.y + head.h / 2);
    env.t.settle(0.3);
    try expectFavorites(&env.m, &.{ "Fav", "dir" });
    try testing.expect(env.fx.exists("a.txt"));

    // A folder onto the Pinned header pins it.
    try env.click("dir");
    head = env.t.findText("Pinned").?;
    from = ts.findTextIn(&env.t, try ts.paneRect(&env.t, &env.m, 0), "dir").?;
    env.t.drag(from.x + from.w / 2, from.y + from.h / 2, head.x + 4, head.y + head.h / 2);
    env.t.settle(0.3);
    try testing.expectEqual(@as(usize, 1), env.m.sidebar.sections[2].rows.items.len);
    try testing.expectEqualStrings(dir_path, env.m.sidebar.sections[2].rows.items[0].path);
}

test "dropping files on a favorite's row still moves them into its folder" {
    reset();
    var env: ts.Env = undefined;
    try env.initWith(.{ .favorite = "dest", .files = &.{"dest/x.txt"} });
    defer env.deinit();
    try env.click("a.txt");
    const from = ts.findTextIn(&env.t, try ts.paneRect(&env.t, &env.m, 0), "a.txt").?;
    const row = favRow(&env);
    env.t.drag(from.x + from.w / 2, from.y + from.h / 2, row.x + row.w / 2, row.y + row.h / 2);
    env.t.settle(0.3);
    try testing.expect(env.fx.exists("dest/a.txt") and !env.fx.exists("a.txt"));
    try expectFavorites(&env.m, &.{"Fav"});
}

// ---- the Add to Favorites command ----

test "Add to Favorites adds the selected folders, or the folder shown, once" {
    reset();
    var env: ts.Env = undefined;
    try env.init();
    defer env.deinit();
    const dir_path = try env.fx.sub("dir");
    defer testing.allocator.free(dir_path);

    try env.m.queue(.{ .run_command = .file_add_favorite }); // nothing selected: the root, shown
    env.t.settle(0.2);
    try testing.expectEqual(@as(usize, 1), env.m.sidebar.sections[1].rows.items.len);
    try testing.expectEqualStrings(env.fx.root, env.m.sidebar.sections[1].rows.items[0].path);
    try env.m.queue(.{ .run_command = .file_add_favorite });
    env.t.settle(0.2);
    try testing.expectEqual(@as(usize, 1), env.m.sidebar.sections[1].rows.items.len);

    try env.click("dir");
    try env.m.queue(.{ .run_command = .file_add_favorite });
    env.t.settle(0.2);
    try testing.expectEqual(@as(usize, 2), env.m.sidebar.sections[1].rows.items.len);
    try testing.expectEqualStrings(dir_path, env.m.sidebar.sections[1].rows.items[1].path);
    try testing.expect(env.t.hasText("dir") and env.t.hasText(std.fs.path.basename(env.fx.root)));

    // A file selected: the command does not apply (its menu item is greyed).
    try env.click("a.txt");
    try testing.expect(!commands.isEnabled(&env.m, commands.find(.file_add_favorite)));
    try env.m.queue(.{ .run_command = .file_add_favorite });
    env.t.settle(0.2);
    try testing.expectEqual(@as(usize, 2), env.m.sidebar.sections[1].rows.items.len);
}
