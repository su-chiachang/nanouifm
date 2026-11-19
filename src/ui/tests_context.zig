//! The context menu through ui.Tester: right-click on an item (selecting it first when it isn't
//! selected) and on empty space, the entries it offers, and each one acting. Temp folders only;
//! the opener and the clipboard/Reveal hooks are recorders.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const commands = @import("commands.zig");
const ts = @import("test_support.zig");

const testing = std.testing;

fn rightClick(env: *ts.Env, name: []const u8) !void {
    const r = env.t.findText(name) orelse return error.TextNotFound;
    env.t.secondaryClick(r.x + r.w / 2, r.y + r.h / 2);
    env.t.settle(0.4);
}

/// Right-click on the list's empty part (below the rows).
fn rightClickEmpty(env: *ts.Env) !void {
    const r = try ts.paneRect(&env.t, &env.m, 0);
    env.t.secondaryClick(r.x + r.w / 2, r.y + r.h - 90);
    env.t.settle(0.4);
}

fn choose(env: *ts.Env, label: []const u8) !void {
    try env.t.clickText(label);
    env.t.settle(0.4);
}

fn menuShows(env: *ts.Env, labels: []const []const u8) bool {
    for (labels) |l| if (!env.t.hasText(l)) return false;
    return true;
}

test "right-click on an unselected row selects it and offers the item menu" {
    var env: ts.Env = undefined;
    try env.init();
    defer env.deinit();
    ts.resetOpened();
    defer ts.resetOpened();

    try env.click("a.txt");
    try rightClick(&env, "b.txt");
    try testing.expect(try env.selected("b.txt")); // selected first
    try testing.expect(env.m.view_state.ctx_menu.open and env.m.view_state.ctx_menu.on_item);
    try testing.expect(menuShows(&env, &.{
        "Open",        "Open in New Tab", "Open in Split",  "Open With Default App", "Quick Look", "Rename",
        "Duplicate",   "Copy",            "Copy Path",      "Move to Trash",         "Reveal in Finder",
        "Pin to Sidebar", "New Folder",   "Show Hidden Files",
    }));
    // Shortcut hints from the registry.
    try testing.expect(env.t.hasText("\u{2318}\u{232B}") and env.t.hasText("\u{21E7}\u{2318}N"));
    // A file isn't a folder: no tab, split or pin for it.
    try testing.expect(!commands.isEnabled(&env.m, commands.find(.file_open_new_tab)));
    // Quick Look applies to the selected file (its hook is tested in tests_preview.zig).
    try testing.expect(commands.isEnabled(&env.m, commands.find(.file_quick_look)));
    // Open acts on the selection: the injected opener gets the file.
    try choose(&env, "Open");
    try testing.expect(!env.m.view_state.ctx_menu.open);
    try testing.expectEqual(@as(usize, 1), ts.opened.items.len);
    try testing.expect(std.mem.endsWith(u8, ts.opened.items[0], "b.txt"));
    env.t.advance(0.8);
    try testing.expect(!env.t.hasText("Open in Split")); // gone
}

test "right-click on a selected row keeps a multi-selection" {
    var env: ts.Env = undefined;
    try env.init();
    defer env.deinit();

    try env.click("dir");
    try ts.clickTextWith(&env.t, "b.txt", .{ .cmd = true });
    env.t.settle(0.2);
    try testing.expectEqual(@as(usize, 2), env.m.focusedTab().selection.count());
    try rightClick(&env, "b.txt");
    try testing.expectEqual(@as(usize, 2), env.m.focusedTab().selection.count());
    try testing.expect(env.t.hasText("Move to Trash"));
    // Renaming needs one item: disabled with two.
    try testing.expect(!commands.isEnabled(&env.m, commands.find(.file_rename)));
    try testing.expect(commands.isEnabled(&env.m, commands.find(.file_open_new_tab))); // dir is among them
}

test "Open in New Tab, Open in Split, Rename, Duplicate, Copy, Copy Path, Reveal, Pin from the menu" {
    var env: ts.Env = undefined;
    try env.init();
    defer env.deinit();

    // Open in New Tab on a folder.
    try rightClick(&env, "dir");
    try choose(&env, "Open in New Tab");
    try testing.expectEqual(@as(usize, 2), env.m.focusedPane().tabs.items.len);
    const dir = try env.fx.sub("dir");
    defer testing.allocator.free(dir);
    try testing.expectEqualStrings(dir, env.m.focusedTab().path());
    try ts.press(&env.t, 'w', .{ .cmd = true }); // back to the first tab
    try testing.expectEqualStrings(env.fx.root, env.m.focusedTab().path());

    // Open in Split.
    try rightClick(&env, "dir");
    try choose(&env, "Open in Split");
    try testing.expectEqual(@as(usize, 2), env.m.panes.items.len);
    try testing.expectEqualStrings(dir, env.m.focusedTab().path());
    try ts.press(&env.t, 'w', .{ .cmd = true, .alt = true }); // close the pane again
    try testing.expectEqual(@as(usize, 1), env.m.panes.items.len);

    // Pin to Sidebar.
    try rightClick(&env, "dir");
    try choose(&env, "Pin to Sidebar");
    try testing.expectEqual(@as(usize, 1), env.m.sidebar.sections[2].rows.items.len);

    // Copy Path and Reveal in Finder, through the hooks.
    try rightClick(&env, "a.txt");
    try choose(&env, "Copy Path");
    const a = try env.fx.sub("a.txt");
    defer testing.allocator.free(a);
    try testing.expectEqualStrings(a, ts.copiedText());
    try rightClick(&env, "a.txt");
    try choose(&env, "Reveal in Finder");
    try testing.expectEqualStrings(a, ts.revealedPaths());

    // Copy: the internal clipboard (and the mirror hook).
    try rightClick(&env, "b.txt");
    try choose(&env, "Copy");
    try testing.expectEqual(@as(usize, 1), env.m.clip.paths.items.len);
    try testing.expect(std.mem.endsWith(u8, ts.mirroredPaths(), "b.txt"));

    // Duplicate.
    try rightClick(&env, "a.txt");
    try choose(&env, "Duplicate");
    try testing.expect(env.fx.exists("a copy.txt"));

    // Rename: the field opens in the row.
    try rightClick(&env, "b.txt");
    try choose(&env, "Rename");
    try testing.expect(env.m.rename != null);
    env.t.key(.escape);
    env.t.settle(0.2);
    try testing.expect(env.m.rename == null);
}

test "Move to Trash from the menu, undone so the user's Trash stays clean" {
    var env: ts.Env = undefined;
    try env.init();
    defer env.deinit();
    try env.fx.file("menu-trash.tmp", 2);
    try env.m.queue(.reload);
    env.t.settle(0.2);

    try rightClick(&env, "menu-trash.tmp");
    try choose(&env, "Move to Trash");
    try testing.expect(!env.fx.exists("menu-trash.tmp"));
    try ts.press(&env.t, 'z', .{ .cmd = true });
    try testing.expect(env.fx.exists("menu-trash.tmp"));
}

test "right-click on empty space offers the folder's menu" {
    var env: ts.Env = undefined;
    try env.init();
    defer env.deinit();

    try env.click("a.txt");
    try rightClickEmpty(&env);
    try testing.expect(env.m.view_state.ctx_menu.open and !env.m.view_state.ctx_menu.on_item);
    try testing.expect(menuShows(&env, &.{ "Open in New Tab", "Open in Split", "Paste", "Copy Path", "Reveal in Finder", "Pin to Sidebar", "New Folder", "Show Hidden Files", "as List", "as Columns" }));
    try testing.expect(!env.t.hasText("Move to Trash") and !env.t.hasText("Rename"));
    // Paste is disabled until something is copied; New Folder works on the folder shown.
    try testing.expect(!commands.isEnabled(&env.m, commands.find(.edit_paste)));
    try choose(&env, "New Folder");
    try testing.expect(env.fx.exists("untitled folder"));
    try testing.expect(env.m.rename != null);
    env.t.key(.escape);
    env.t.settle(0.2);

    // Show Hidden Files toggles (and is ticked once on); as Columns switches the view.
    try rightClickEmpty(&env);
    try testing.expect(!env.m.show_hidden);
    try choose(&env, "Show Hidden Files");
    try testing.expect(env.m.show_hidden);
    try rightClickEmpty(&env);
    try choose(&env, "as Columns");
    try testing.expectEqual(.column, env.m.focusedPane().view_mode);
}

test "right-click on empty space of an empty folder, and Paste from there" {
    var env: ts.Env = undefined;
    try env.init();
    defer env.deinit();
    try env.fx.dir("empty");
    try env.m.queue(.reload);
    env.t.settle(0.2);

    try env.click("a.txt");
    try ts.press(&env.t, 'c', .{ .cmd = true });
    try env.m.queue(.{ .open = env.m.focusedTab().exp.items[1].path }); // "empty" (folders first, by name)
    _ = try env.m.applyPending();
    env.t.settle(0.3);
    try testing.expect(env.t.hasText("This folder is empty") or env.m.focusedTab().exp.items.len == 0);
    const r = try ts.paneRect(&env.t, &env.m, 0);
    env.t.secondaryClick(r.x + r.w / 2, r.y + r.h / 2);
    env.t.settle(0.4);
    try testing.expect(env.m.view_state.ctx_menu.open);
    try testing.expect(commands.isEnabled(&env.m, commands.find(.edit_paste)));
    try choose(&env, "Paste");
    try testing.expect(env.fx.exists("empty/a.txt"));
}

test "Escape closes the menu and a click elsewhere too" {
    var env: ts.Env = undefined;
    try env.init();
    defer env.deinit();

    try rightClick(&env, "a.txt");
    try testing.expect(env.m.view_state.ctx_menu.open);
    try ts.press(&env.t, ui.Shortcut.escape, .{});
    try testing.expect(!env.m.view_state.ctx_menu.open);
    try rightClick(&env, "a.txt");
    const r = env.t.findText("Name").?;
    env.t.click(r.x + 2, r.y + 2);
    env.t.settle(0.4);
    try testing.expect(!env.m.view_state.ctx_menu.open);
}
