//! The command registry: enabled/disabled/checked states against the model, titles that follow
//! state (Undo/Redo), shortcut -> command routing (every command's key takes and runs it, a
//! disabled one doesn't take its key), Go commands, Go to Folder, and the table's invariants.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const commands = @import("commands.zig");
const pane_layout = @import("../core/pane_layout.zig");
const ts = @import("test_support.zig");

const testing = std.testing;
const S = ui.Shortcut;

fn enabled(env: *ts.Env, id: commands.Id) bool {
    return commands.isEnabled(&env.m, commands.find(id));
}

test "the table has the menu's commands with the Swift app's shortcuts" {
    const want = [_]struct { id: commands.Id, key: u21, cmd: bool = false, shift: bool = false, alt: bool = false, ctrl: bool = false }{
        .{ .id = .file_new_folder, .key = 'n', .cmd = true, .shift = true },
        .{ .id = .edit_paste, .key = 'v', .cmd = true },
        .{ .id = .edit_paste_move, .key = 'v', .cmd = true, .alt = true },
        .{ .id = .file_trash, .key = S.backspace, .cmd = true },
        .{ .id = .file_rename, .key = S.enter },
        .{ .id = .edit_undo, .key = 'z', .cmd = true },
        .{ .id = .edit_redo, .key = 'z', .cmd = true, .shift = true },
        .{ .id = .go_downloads, .key = 'l', .cmd = true, .alt = true },
        .{ .id = .go_to_folder, .key = 'g', .cmd = true, .shift = true },
        .{ .id = .go_up, .key = S.up, .cmd = true },
        .{ .id = .view_hidden, .key = '.', .cmd = true, .shift = true },
    };
    for (want) |w| {
        const s = commands.find(w.id).shortcut.?;
        try testing.expectEqual(w.key, s.key);
        try testing.expectEqual(w.cmd, s.cmd);
        try testing.expectEqual(w.shift, s.shift);
        try testing.expectEqual(w.alt, s.alt);
        try testing.expectEqual(w.ctrl, s.ctrl);
    }
    // Commands without a key of their own (Duplicate: Cmd+D is the split).
    try testing.expect(commands.find(.file_duplicate).shortcut == null);
    try testing.expect(commands.find(.file_open_split).shortcut == null);
    try testing.expectEqualStrings("Layout: " ++ comptime pane_layout.LayoutPreset.grid_2x2.title(), commands.find(.layout_grid_2x2).title);
    try testing.expect(commands.byName("file_new_folder").? == commands.find(.file_new_folder));
    try testing.expect(commands.byName("nope") == null);
    try testing.expect(!commands.find(.file_open_down).in_palette);
}

test "enabled states follow the selection, the clipboard and the undo stack" {
    var env: ts.Env = undefined;
    try env.init();
    defer env.deinit();

    // Nothing selected.
    for ([_]commands.Id{ .file_open, .file_rename, .file_duplicate, .file_trash, .edit_copy, .edit_paste, .edit_paste_move, .edit_undo, .edit_redo, .file_quick_look }) |id| {
        try testing.expect(!enabled(&env, id));
    }
    // The folder shown is the target of these.
    for ([_]commands.Id{ .file_new_folder, .file_open_new_tab, .file_open_split, .file_reveal, .file_copy_path, .file_pin, .tab_new, .view_list }) |id| {
        try testing.expect(enabled(&env, id));
    }
    try testing.expect(!enabled(&env, .go_back) and !enabled(&env, .go_forward) and enabled(&env, .go_up));
    try testing.expect(!enabled(&env, .pane_close) and !enabled(&env, .pane_focus_next));

    try env.click("a.txt");
    for ([_]commands.Id{ .file_open, .file_rename, .file_duplicate, .file_trash, .edit_copy }) |id| try testing.expect(enabled(&env, id));
    try testing.expect(!enabled(&env, .file_quick_look)); // a stub: never
    try testing.expect(!enabled(&env, .file_open_new_tab) and !enabled(&env, .file_pin)); // a file
    try ts.clickTextWith(&env.t, "b.txt", .{ .shift = true });
    try testing.expect(!enabled(&env, .file_rename)); // two items
    try testing.expect(enabled(&env, .file_duplicate));

    try ts.press(&env.t, 'c', .{ .cmd = true });
    try testing.expect(enabled(&env, .edit_paste) and enabled(&env, .edit_paste_move));

    // Undo/Redo and their titles.
    var buf: [96]u8 = undefined;
    try testing.expectEqualStrings("Undo", commands.titleOf(&env.m, commands.find(.edit_undo), &buf));
    try env.m.queue(.{ .run_command = .file_duplicate });
    env.t.settle(0.2);
    try testing.expect(enabled(&env, .edit_undo) and !enabled(&env, .edit_redo));
    try testing.expectEqualStrings("Undo Duplicate of 2 Items", commands.titleOf(&env.m, commands.find(.edit_undo), &buf));
    try ts.press(&env.t, 'z', .{ .cmd = true });
    try testing.expectEqualStrings("Redo Duplicate of 2 Items", commands.titleOf(&env.m, commands.find(.edit_redo), &buf));
    try testing.expect(!enabled(&env, .edit_undo) and enabled(&env, .edit_redo));
    try testing.expectEqualStrings("Undo", commands.titleOf(&env.m, commands.find(.edit_undo), &buf));
    try ts.press(&env.t, 'z', .{ .cmd = true, .shift = true }); // out of the Trash again
    try testing.expect(env.fx.exists("a copy.txt") and !enabled(&env, .edit_redo));

    // Checked states.
    try testing.expect(commands.isChecked(&env.m, commands.find(.view_list)) and !commands.isChecked(&env.m, commands.find(.view_column)));
    try testing.expect(commands.isChecked(&env.m, commands.find(.sort_name)) and !commands.isChecked(&env.m, commands.find(.sort_size)));
    try testing.expect(commands.isChecked(&env.m, commands.find(.layout_single)));
    try testing.expect(!commands.isChecked(&env.m, commands.find(.view_hidden)));
}

test "a disabled command doesn't take its key, and queued by id it does nothing" {
    var env: ts.Env = undefined;
    try env.init();
    defer env.deinit();

    try testing.expectError(error.KeyNotTaken, ts.press(&env.t, 'z', .{ .cmd = true }));
    try testing.expectError(error.KeyNotTaken, ts.press(&env.t, 'v', .{ .cmd = true }));
    try testing.expectError(error.KeyNotTaken, ts.press(&env.t, 'y', .{ .cmd = true })); // Quick Look
    try testing.expectError(error.KeyNotTaken, ts.press(&env.t, '[', .{ .cmd = true })); // no history
    try env.m.queue(.{ .run_command = .file_trash });
    try env.m.queue(.{ .run_command = .edit_undo });
    try env.m.queue(.{ .run_command = .pane_close });
    env.t.settle(0.2);
    try testing.expect(env.fx.exists("a.txt") and env.m.panes.items.len == 1 and env.m.notice == null);
}

test "shortcuts run the tab, split, view and layout commands (the keys app.zig used to hold)" {
    var env: ts.Env = undefined;
    try env.init();
    defer env.deinit();

    try ts.press(&env.t, 't', .{ .cmd = true });
    try testing.expectEqual(@as(usize, 2), env.m.focusedPane().tabs.items.len);
    try ts.press(&env.t, S.tab, .{ .ctrl = true });
    try testing.expectEqual(@as(usize, 0), env.m.focusedPane().active);
    try ts.press(&env.t, S.tab, .{ .ctrl = true, .shift = true });
    try testing.expectEqual(@as(usize, 1), env.m.focusedPane().active);
    try ts.press(&env.t, 'w', .{ .cmd = true });
    try testing.expectEqual(@as(usize, 1), env.m.focusedPane().tabs.items.len);

    try ts.press(&env.t, 'd', .{ .cmd = true });
    try testing.expectEqual(@as(usize, 2), env.m.panes.items.len);
    try ts.press(&env.t, 'd', .{ .cmd = true, .shift = true });
    try testing.expectEqual(@as(usize, 3), env.m.panes.items.len);
    try ts.press(&env.t, S.left, .{ .cmd = true, .alt = true });
    try testing.expect(enabled(&env, .pane_close));
    try ts.press(&env.t, 'w', .{ .cmd = true, .alt = true });
    try testing.expectEqual(@as(usize, 2), env.m.panes.items.len);

    try ts.press(&env.t, '2', .{ .cmd = true });
    try testing.expectEqual(.column, env.m.focusedPane().view_mode);
    try ts.press(&env.t, '1', .{ .cmd = true });
    try testing.expectEqual(.list, env.m.focusedPane().view_mode);
    try ts.press(&env.t, '.', .{ .cmd = true, .shift = true });
    try testing.expect(env.m.show_hidden);
    try ts.press(&env.t, '.', .{ .cmd = true, .shift = true });
    try testing.expect(!env.m.show_hidden);

    // A layout command, and the menu's "ticked" state follows it.
    try env.m.queue(.{ .run_command = .layout_grid_2x2 });
    env.t.settle(0.2);
    try testing.expectEqual(@as(usize, 4), env.m.panes.items.len);
    try testing.expect(commands.isChecked(&env.m, commands.find(.layout_grid_2x2)));
    try env.m.queue(.{ .run_command = .layout_single });
    env.t.settle(0.2);
    try testing.expectEqual(@as(usize, 1), env.m.panes.items.len);
    try ts.expectInSync(&env.m);
}

test "Go commands: Home, Downloads, Enclosing Folder, Back and Forward" {
    var env: ts.Env = undefined;
    try env.init();
    defer env.deinit();
    try env.fx.dir("Downloads");

    try ts.press(&env.t, 'l', .{ .cmd = true, .alt = true });
    const dl = try env.fx.sub("Downloads");
    defer testing.allocator.free(dl);
    try testing.expectEqualStrings(dl, env.m.focusedTab().path());
    try ts.press(&env.t, '[', .{ .cmd = true });
    try testing.expectEqualStrings(env.fx.root, env.m.focusedTab().path());
    try ts.press(&env.t, ']', .{ .cmd = true });
    try testing.expectEqualStrings(dl, env.m.focusedTab().path());
    try ts.press(&env.t, S.up, .{ .cmd = true });
    try testing.expectEqualStrings(env.fx.root, env.m.focusedTab().path());
    try env.m.queue(.{ .run_command = .go_downloads });
    env.t.settle(0.2);
    try ts.press(&env.t, 'h', .{ .cmd = true, .shift = true }); // home is the fixture root
    try testing.expectEqualStrings(env.fx.root, env.m.focusedTab().path());
}

test "Go to Folder: Shift+Cmd+G opens a field; Return goes there, a bad path raises the banner" {
    var env: ts.Env = undefined;
    try env.init();
    defer env.deinit();

    try ts.press(&env.t, 'g', .{ .cmd = true, .shift = true });
    env.t.settle(0.4);
    try testing.expect(env.m.goto.open and env.t.hasText("Go to Folder"));
    // Escape closes it (offered as a shortcut even with the field focused).
    try ts.press(&env.t, S.escape, .{});
    env.t.settle(0.4);
    try testing.expect(!env.m.goto.open);
    try ts.press(&env.t, 'g', .{ .cmd = true, .shift = true });
    env.t.settle(0.4);
    try testing.expect(env.m.goto.open);
    try testing.expect(env.t.ctx.focus_is_text);
    env.t.textOps(&.{ .{ .command = .select_all }, .{ .command = .delete_backward } });
    env.t.typeText("~/dir");
    env.t.key(.enter);
    env.t.settle(0.4);
    try testing.expect(!env.m.goto.open);
    const dir = try env.fx.sub("dir");
    defer testing.allocator.free(dir);
    try testing.expectEqualStrings(dir, env.m.focusedTab().path());
    // "~" is Home in the dialog (Home is the fixture root here).
    try ts.press(&env.t, 'g', .{ .cmd = true, .shift = true });
    env.t.settle(0.4);
    env.t.textOps(&.{ .{ .command = .select_all }, .{ .command = .delete_backward } });
    env.t.typeText("/no/such/folder");
    env.t.key(.enter);
    env.t.settle(0.4);
    try testing.expect(env.m.notice != null);
    try testing.expectEqualStrings(dir, env.m.focusedTab().path()); // stays
}
