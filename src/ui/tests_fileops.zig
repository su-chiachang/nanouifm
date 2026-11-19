//! File operations through the view: New Folder with inline rename, rename (valid, invalid, a
//! taken name, Escape), Copy / Paste / Move Here through the internal clipboard, Duplicate,
//! Move to Trash, Undo / Redo with their titles, Copy Path and Reveal through the injected hooks,
//! Pin to Sidebar, and the banner. Every test works in a temp folder; the system clipboard is
//! never touched (the hooks are recorders), and the one test that trashes uses a tiny temp file.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const app_view = @import("../app.zig");
const commands = @import("commands.zig");
const ts = @import("test_support.zig");

const testing = std.testing;
const S = ui.Shortcut;

test "New Folder makes an untitled folder, selects it, and opens its name for editing" {
    var env: ts.Env = undefined;
    try env.init();
    defer env.deinit();

    try ts.press(&env.t, 'n', .{ .cmd = true, .shift = true });
    try testing.expect(env.fx.exists("untitled folder"));
    try testing.expect(try env.selected("untitled folder"));
    try testing.expect(env.m.rename != null);
    try testing.expect(env.t.hasText("untitled folder")); // the field's text
    try testing.expect(env.t.ctx.focus_is_text);

    env.renameTo("Reports");
    try testing.expect(env.m.rename == null);
    try testing.expect(env.fx.exists("Reports") and !env.fx.exists("untitled folder"));
    try testing.expect(try env.selected("Reports"));
    try testing.expect(env.t.hasText("Reports"));
    try testing.expect(env.m.notice == null);
    try testing.expectEqualStrings("Rename", env.m.ops.undoTitle().?);

    // Undo steps back: the rename, then the folder itself (trashed: nothing left in the folder).
    try ts.press(&env.t, 'z', .{ .cmd = true });
    try testing.expect(env.fx.exists("untitled folder") and !env.fx.exists("Reports"));
    try testing.expect(env.t.hasText("untitled folder"));
    try testing.expectEqualStrings("New Folder", env.m.ops.undoTitle().?);
    try ts.press(&env.t, 'z', .{ .cmd = true });
    try testing.expect(!env.fx.exists("untitled folder"));
    try testing.expect(!env.t.hasText("untitled folder"));
    try testing.expect(!env.m.ops.canUndo() and env.m.ops.canRedo());

    // Redo brings the folder back.
    try ts.press(&env.t, 'z', .{ .cmd = true, .shift = true });
    try testing.expect(env.fx.exists("untitled folder"));
    try testing.expect(env.t.hasText("untitled folder"));
}

test "Return renames the selected item (the stem is selected), Return again commits" {
    var env: ts.Env = undefined;
    try env.init();
    defer env.deinit();

    // Nothing selected: Return isn't taken.
    try testing.expectError(error.KeyNotTaken, ts.press(&env.t, S.enter, .{}));
    try env.click("a.txt");
    try ts.press(&env.t, S.enter, .{});
    try testing.expect(env.m.rename != null);
    // Typing replaces the part before the extension.
    env.t.typeText("renamed");
    env.t.key(.enter);
    env.t.settle(0.2);
    try testing.expect(env.fx.exists("renamed.txt") and !env.fx.exists("a.txt"));
    try testing.expect(try env.selected("renamed.txt"));
    try testing.expect(env.t.hasText("renamed.txt") and !env.t.hasText("a.txt"));
    try testing.expect(env.m.rename == null);
    // The list stays sorted: b.txt comes before renamed.txt, and the rename scrolled nothing away.
    try testing.expect(try ts.textY(&env.t, "b.txt") < try ts.textY(&env.t, "renamed.txt"));
}

test "invalid names are refused with the service's words and the field stays; Escape cancels" {
    var env: ts.Env = undefined;
    try env.init();
    defer env.deinit();

    try env.click("a.txt");
    try ts.press(&env.t, S.enter, .{});
    env.renameTo("bad/name");
    try testing.expect(env.fx.exists("a.txt"));
    try testing.expect(env.m.rename != null); // still editing
    try testing.expect(env.noticeHas("is not a valid name"));
    try testing.expect(env.t.containsText("is not a valid name")); // the banner
    env.renameTo("a:b");
    try testing.expect(env.noticeHas("a:b"));
    env.renameTo(""); // empty
    try testing.expect(env.noticeHas("can\u{2019}t be empty"));
    env.renameTo("b.txt"); // taken
    try testing.expect(env.noticeHas("already exists"));
    try testing.expect(env.fx.exists("a.txt") and env.fx.exists("b.txt"));
    try testing.expect(!env.m.ops.canUndo()); // nothing was done

    env.t.key(.escape);
    env.t.settle(0.2);
    try testing.expect(env.m.rename == null);
    try testing.expect(env.t.hasText("a.txt")); // the name is back as text
    try testing.expect(env.fx.exists("a.txt"));
    // The banner stays until dismissed.
    try testing.expect(env.m.notice != null);
    try env.t.clickText("Dismiss");
    env.t.settle(0.2);
    try testing.expect(env.m.notice == null);
}

test "an unchanged name is a no-op and a click elsewhere commits the edit" {
    var env: ts.Env = undefined;
    try env.init();
    defer env.deinit();

    try env.click("a.txt");
    try ts.press(&env.t, S.enter, .{});
    env.t.key(.enter); // the same name
    env.t.settle(0.2);
    try testing.expect(env.m.rename == null and env.m.notice == null);
    try testing.expect(!env.m.ops.canUndo());

    try ts.press(&env.t, S.enter, .{});
    env.t.typeText("moved");
    try env.click("b.txt"); // the keyboard leaves the field: Finder commits
    try testing.expect(env.fx.exists("moved.txt"));
    try testing.expect(env.m.rename == null);
    try testing.expect(try env.selected("b.txt")); // the click's selection wins
}

test "Copy then Paste copies into the folder shown; names stay unique; Undo removes the copy" {
    var env: ts.Env = undefined;
    try env.init();
    defer env.deinit();

    try env.click("a.txt");
    try ts.press(&env.t, 'c', .{ .cmd = true });
    try testing.expectEqual(@as(usize, 1), env.m.clip.paths.items.len);
    const a = try env.fx.sub("a.txt");
    defer testing.allocator.free(a);
    try testing.expectEqualStrings(a, ts.mirroredPaths()); // mirrored through the hook only

    // Into dir.
    try env.t.clickText("dir");
    env.t.doubleClick(env.t.findText("dir").?.x + 2, env.t.findText("dir").?.y + 2);
    env.t.settle(0.3);
    const dir = try env.fx.sub("dir");
    defer testing.allocator.free(dir);
    try testing.expectEqualStrings(dir, env.m.focusedTab().path());
    try ts.press(&env.t, 'v', .{ .cmd = true });
    try testing.expect(env.fx.exists("dir/a.txt") and env.fx.exists("a.txt"));
    try testing.expect(env.t.hasText("a.txt"));
    const pasted = try env.fx.sub("dir/a.txt");
    defer testing.allocator.free(pasted);
    try testing.expectEqualStrings(pasted, ts.selectedOnly(&env.m).?); // the new item is selected
    // Again: a second copy gets a new name.
    try ts.press(&env.t, 'v', .{ .cmd = true });
    try testing.expect(env.fx.exists("dir/a 2.txt"));
    // Undo takes the last copy away again (to the Trash: only what this test made).
    try testing.expectEqualStrings("Undo Copy of 1 Item", try undoTitle(&env));
    try ts.press(&env.t, 'z', .{ .cmd = true });
    try testing.expect(!env.fx.exists("dir/a 2.txt") and env.fx.exists("dir/a.txt"));
    // Redo takes it back out of the Trash (nothing of the test is left there).
    try ts.press(&env.t, 'z', .{ .cmd = true, .shift = true });
    try testing.expect(env.fx.exists("dir/a 2.txt"));
}

fn undoTitle(env: *ts.Env) ![]const u8 {
    const cmd = commands.find(.edit_undo);
    const S2 = struct {
        var buf: [96]u8 = undefined;
    };
    return commands.titleOf(&env.m, cmd, &S2.buf);
}

test "Opt+Cmd+V moves, a conflict is refused, moving into the same folder says so" {
    var env: ts.Env = undefined;
    try env.init();
    defer env.deinit();
    try env.fx.file("dir/b.txt", 1); // a name that will clash

    // Move a.txt into dir through the clipboard.
    try env.click("a.txt");
    try ts.press(&env.t, 'c', .{ .cmd = true });
    try env.m.queue(.{ .open = env.m.focusedTab().exp.items[0].path }); // dir
    _ = try env.m.applyPending();
    env.t.settle(0.2);
    try ts.press(&env.t, 'v', .{ .cmd = true, .alt = true });
    try testing.expect(env.fx.exists("dir/a.txt") and !env.fx.exists("a.txt"));
    try testing.expect(env.m.clip.isEmpty()); // moved: nothing left to paste
    try testing.expect(!commands.isEnabled(&env.m, commands.find(.edit_paste)));
    try testing.expectEqualStrings("Undo Move of 1 Item", try undoTitle(&env));

    // b.txt (in root) clashes with dir/b.txt: refused, banner in the service's words.
    try ts.press(&env.t, S.up, .{ .cmd = true });
    try env.click("b.txt");
    try ts.press(&env.t, 'c', .{ .cmd = true });
    try env.m.queue(.{ .open = env.m.focusedTab().exp.items[0].path });
    _ = try env.m.applyPending();
    env.t.settle(0.2);
    try ts.press(&env.t, 'v', .{ .cmd = true, .alt = true });
    try testing.expect(env.fx.exists("b.txt")); // nothing moved
    try testing.expect(env.noticeHas("already exists in the destination"));
    try testing.expect(env.t.containsText("already exists"));

    // Move Here in the folder the item is already in.
    try ts.press(&env.t, S.up, .{ .cmd = true });
    try ts.press(&env.t, 'v', .{ .cmd = true, .alt = true });
    try testing.expect(env.noticeHas("already in"));
}

test "Duplicate puts a copy next to the original and selects it" {
    var env: ts.Env = undefined;
    try env.init();
    defer env.deinit();

    try env.click("a.txt");
    try env.m.queue(.{ .run_command = .file_duplicate });
    env.t.settle(0.2);
    try testing.expect(env.fx.exists("a copy.txt"));
    try testing.expect(try env.selected("a copy.txt"));
    try testing.expect(env.t.hasText("a copy.txt"));
    try testing.expectEqualStrings("Undo Duplicate of 1 Item", try undoTitle(&env));
    try ts.press(&env.t, 'z', .{ .cmd = true });
    try testing.expect(!env.fx.exists("a copy.txt") and env.fx.exists("a.txt"));
    try ts.press(&env.t, 'z', .{ .cmd = true, .shift = true }); // out of the Trash again
    try testing.expect(env.fx.exists("a copy.txt"));
}

test "Cmd+Backspace moves to the Trash (never deletes) and Undo brings it back" {
    var env: ts.Env = undefined;
    try env.init();
    defer env.deinit();
    try env.fx.file("trash-me.tmp", 3);
    try env.m.queue(.reload);
    env.t.settle(0.2);

    try testing.expectError(error.KeyNotTaken, ts.press(&env.t, S.backspace, .{ .cmd = true })); // nothing selected
    try env.click("trash-me.tmp");
    try ts.press(&env.t, S.backspace, .{ .cmd = true });
    try testing.expect(!env.fx.exists("trash-me.tmp"));
    try testing.expect(!env.t.hasText("trash-me.tmp"));
    try testing.expectEqualStrings("Undo Move to Trash", try undoTitle(&env));
    try ts.press(&env.t, 'z', .{ .cmd = true });
    try testing.expect(env.fx.exists("trash-me.tmp"));
    try testing.expect(env.t.hasText("trash-me.tmp"));
    try ts.press(&env.t, 'z', .{ .cmd = true, .shift = true }); // Redo: trashed again
    try testing.expect(!env.fx.exists("trash-me.tmp"));
    try ts.press(&env.t, 'z', .{ .cmd = true }); // leave nothing in the user's Trash
    try testing.expect(env.fx.exists("trash-me.tmp"));
}

test "Copy Path and Reveal in Finder go through their hooks; no selection means the folder" {
    var env: ts.Env = undefined;
    try env.init();
    defer env.deinit();

    try env.m.queue(.{ .run_command = .file_copy_path });
    env.t.settle(0.2);
    try testing.expectEqualStrings(env.fx.root, ts.copiedText());
    try env.click("a.txt");
    try env.t.clickText("b.txt"); // plain click: one item
    try ts.press(&env.t, 'c', .{ .cmd = true, .alt = true });
    const b = try env.fx.sub("b.txt");
    defer testing.allocator.free(b);
    try testing.expectEqualStrings(b, ts.copiedText());
    // Two items: one path per line.
    try ts.press(&env.t, S.home, .{});
    try ts.press(&env.t, S.down, .{ .shift = true });
    try ts.press(&env.t, 'c', .{ .cmd = true, .alt = true });
    try testing.expect(std.mem.indexOfScalar(u8, ts.copiedText(), '\n') != null);

    try env.m.queue(.{ .run_command = .file_reveal });
    env.t.settle(0.2);
    try testing.expect(std.mem.indexOf(u8, ts.revealedPaths(), "a.txt") != null or std.mem.indexOf(u8, ts.revealedPaths(), "dir") != null);
}

test "Pin to Sidebar adds the folder; a file can't be pinned" {
    var env: ts.Env = undefined;
    try env.init();
    defer env.deinit();

    try env.click("a.txt");
    try testing.expect(!commands.isEnabled(&env.m, commands.find(.file_pin)));
    try env.click("dir");
    try testing.expect(commands.isEnabled(&env.m, commands.find(.file_pin)));
    try ts.press(&env.t, 't', .{ .cmd = true, .ctrl = true });
    const pinned = env.m.sidebar.sections[2].rows.items;
    try testing.expectEqual(@as(usize, 1), pinned.len);
    try testing.expectEqualStrings("dir", pinned[0].title);
    // Pinning again is a no-op.
    try ts.press(&env.t, 't', .{ .cmd = true, .ctrl = true });
    try testing.expectEqual(@as(usize, 1), env.m.sidebar.sections[2].rows.items.len);
}

test "file shortcuts leave the keys to a text field being edited" {
    var env: ts.Env = undefined;
    try env.init();
    defer env.deinit();

    try env.click("a.txt");
    try ts.press(&env.t, S.enter, .{});
    try testing.expect(env.t.ctx.focus_is_text);
    // Cmd+Backspace and Cmd+Z belong to the field now.
    try testing.expectError(error.KeyNotTaken, ts.press(&env.t, S.backspace, .{ .cmd = true }));
    // Cmd+Z is the field's own undo (it takes it): no file operation is undone.
    try ts.press(&env.t, 'z', .{ .cmd = true });
    try testing.expect(env.fx.exists("a.txt") and !env.m.ops.canUndo() and env.m.rename != null);
}

test "operations in column view select and rename in the column" {
    var env: ts.Env = undefined;
    try env.init();
    defer env.deinit();

    try ts.press(&env.t, '2', .{ .cmd = true });
    try env.click("a.txt");
    try ts.press(&env.t, 'n', .{ .cmd = true, .shift = true });
    try testing.expect(env.fx.exists("untitled folder"));
    try testing.expect(env.m.rename != null);
    env.renameTo("Fresh");
    try testing.expect(env.fx.exists("Fresh"));
    try testing.expect(env.t.hasText("Fresh"));
}

/// A fake system pasteboard: its change count, and the file another app "copied".
const Fake = struct {
    var count: isize = 1;
    var path_buf: [512]u8 = undefined;
    var path_len: usize = 0;

    fn change() isize {
        return count;
    }

    fn read(gpa: std.mem.Allocator) ?[][]u8 {
        const out = gpa.alloc([]u8, 1) catch return null;
        out[0] = gpa.dupe(u8, path_buf[0..path_len]) catch {
            gpa.free(out);
            return null;
        };
        return out;
    }
};

test "Paste uses files another app put on the pasteboard since Copy (through the hooks only)" {
    var env: ts.Env = undefined;
    try env.init();
    defer env.deinit();
    env.m.hooks.change_count = Fake.change;
    env.m.hooks.read_files = Fake.read;

    try env.click("a.txt");
    try ts.press(&env.t, 'c', .{ .cmd = true }); // our copy: mirrored at count 1
    try testing.expectEqual(@as(isize, 1), env.m.clip.mirrored);
    // Another app copies b.txt.
    const b = try env.fx.sub("b.txt");
    defer testing.allocator.free(b);
    @memcpy(Fake.path_buf[0..b.len], b);
    Fake.path_len = b.len;
    Fake.count = 2;
    try env.fx.dir("dest");
    try env.m.queue(.reload);
    env.t.settle(0.2);
    const dest = try env.fx.sub("dest");
    defer testing.allocator.free(dest);
    try env.m.queue(.{ .open = dest });
    _ = try env.m.applyPending();
    env.t.settle(0.2);
    try ts.press(&env.t, 'v', .{ .cmd = true });
    try testing.expect(env.fx.exists("dest/b.txt") and !env.fx.exists("dest/a.txt"));
    // Copy again: ours wins once more.
    try ts.press(&env.t, S.up, .{ .cmd = true });
    try env.click("a.txt");
    try ts.press(&env.t, 'c', .{ .cmd = true });
    try env.m.queue(.{ .open = dest });
    _ = try env.m.applyPending();
    env.t.settle(0.2);
    try ts.press(&env.t, 'v', .{ .cmd = true });
    try testing.expect(env.fx.exists("dest/a.txt"));
}

test "the real (system) hooks are only referenced, never run, by the tests" {
    const system = @import("system_hooks.zig");
    try testing.expect(system.hooks.copy_files != null and system.hooks.reveal != null and system.hooks.option_held != null);
}

test "the new folder is scrolled into sight in a long list" {
    var env: ts.Env = undefined;
    try env.init();
    defer env.deinit();
    var i: usize = 0;
    var name: [32]u8 = undefined;
    while (i < 80) : (i += 1) try env.fx.file(try std.fmt.bufPrint(&name, "f{d:0>3}.txt", .{i}), 1);
    try env.m.queue(.reload);
    env.t.settle(0.2);
    const r = try ts.paneRect(&env.t, &env.m, 0);
    env.t.scroll(r.x + 200, r.y + 200, -2000); // to the bottom
    env.t.settle(0.3);
    try testing.expect(!env.t.hasText("dir")); // the folders at the top are out of sight

    try ts.press(&env.t, 'n', .{ .cmd = true, .shift = true });
    env.t.settle(0.4);
    try testing.expect(env.t.hasText("untitled folder")); // scrolled up to it (it sorts among the folders)
    try testing.expect(env.t.ctx.focus_is_text);
}

test "Escape reaches the rename as a key, as a shortcut and as the input system's cancel" {
    var env: ts.Env = undefined;
    try env.init();
    defer env.deinit();

    for (0..3) |how| {
        try env.click("a.txt");
        try ts.press(&env.t, S.enter, .{});
        try testing.expect(env.m.rename != null);
        switch (how) {
            0 => env.t.key(.escape),
            1 => try ts.press(&env.t, S.escape, .{}),
            else => env.t.textOps(&.{.{ .command = .cancel }}),
        }
        env.t.settle(0.2);
        try testing.expect(env.m.rename == null);
        try testing.expect(env.fx.exists("a.txt") and env.m.notice == null);
    }
}

test "a rename whose row is gone (its tab closed) is dropped, not left hanging" {
    var env: ts.Env = undefined;
    try env.init();
    defer env.deinit();

    try ts.press(&env.t, 't', .{ .cmd = true });
    try env.click("a.txt");
    try ts.press(&env.t, S.enter, .{});
    try testing.expect(env.m.rename != null);
    try env.m.queue(.{ .open = env.m.focusedTab().exp.items[0].path }); // into dir: the row is gone
    _ = try env.m.applyPending();
    try testing.expect(env.m.rename == null);
}
