//! The command palette through ui.Tester: Cmd+K and Escape, the sections of an empty and a typed
//! query, fuzzy command ranking, file hits from an injected index over temp folders, Return and its
//! Cmd / Opt variants on each kind of row, wrapping, disabled commands, the Layout commands, and
//! the index's runner (a crawl held and run later, so nothing blocks). Temp folders only; the
//! opener is the recorder, the index never sees the real home.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const commands = @import("commands.zig");
const fuzzy = @import("../core/fuzzy.zig");
const pane_layout = @import("../core/pane_layout.zig");
const pm = @import("palette_model.zig");
const palette_ops = @import("palette_ops.zig");
const palette_rows = @import("palette_rows.zig");
const ts = @import("test_support.zig");

const testing = std.testing;
const S = ui.Shortcut;

const files = [_][]const u8{ "dir/report-final.pdf", "notes/meeting-notes.md" };

fn start(env: *ts.Env) !void {
    try env.initWith(.{ .index = .now, .files = &files, .favorite = "dir" });
}

fn st(env: *ts.Env) *pm.State {
    return &env.m.view_state.palette;
}

fn rows(env: *ts.Env) []const pm.Row {
    return st(env).rows();
}

fn openPalette(env: *ts.Env) !void {
    try ts.press(&env.t, 'k', .{ .cmd = true });
    env.t.settle(0.4);
    try testing.expect(st(env).open);
}

fn typeQuery(env: *ts.Env, s: []const u8) void {
    env.t.typeText(s);
    env.t.settle(0.3);
}

/// Empties the field.
fn clearQuery(env: *ts.Env) void {
    env.t.textOps(&.{ .{ .command = .select_all }, .{ .command = .delete_backward } });
    env.t.settle(0.3);
}

/// The row with this title (and kind), if shown.
fn find(env: *ts.Env, kind: pm.Kind, title: []const u8) ?usize {
    for (rows(env), 0..) |r, i| if (r.kind == kind and std.mem.eql(u8, r.title, title)) return i;
    return null;
}

/// The titles of the section headers, in order.
fn headers(env: *ts.Env, out: *[8][]const u8) []const []const u8 {
    var n: usize = 0;
    for (rows(env)) |r| if (r.kind == .header and n < out.len) {
        out[n] = r.title;
        n += 1;
    };
    return out[0..n];
}

fn expectHeaders(env: *ts.Env, want: []const []const u8) !void {
    var buf: [8][]const u8 = undefined;
    const got = headers(env, &buf);
    try testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| try testing.expectEqualStrings(w, g);
}

fn clickRow(env: *ts.Env, s: []const u8) !void {
    try ts.clickLowestText(&env.t, s);
    env.t.settle(0.4);
}

/// Down until row `index` is the highlighted one.
fn moveTo(env: *ts.Env, index: usize) !void {
    var n: usize = 0;
    while (st(env).selected != index) : (n += 1) {
        if (n > rows(env).len) return error.RowNotReachable;
        try ts.press(&env.t, S.down, .{});
    }
}

fn pressReturn(env: *ts.Env, mods: struct { cmd: bool = false, alt: bool = false }) !void {
    if (mods.cmd or mods.alt) {
        try testing.expect(env.t.shortcut(.{ .key = S.enter, .cmd = mods.cmd, .alt = mods.alt }));
    } else {
        env.t.key(.enter);
    }
    env.t.settle(0.4);
}

test "Cmd+K opens the palette over the window, Cmd+K and Escape close it" {
    var env: ts.Env = undefined;
    try start(&env);
    defer env.deinit();

    try testing.expect(!st(&env).open and !env.t.hasText("Esc") and !env.t.hasText("Close"));
    try openPalette(&env);
    try testing.expect(env.t.ctx.focus_is_text);
    try testing.expect(env.t.hasText("Open") and env.t.hasText("New Tab") and env.t.hasText("Split") and env.t.hasText("Close"));
    try testing.expect(env.t.hasText("Commands"));
    try ts.press(&env.t, 'k', .{ .cmd = true });
    env.t.settle(0.5);
    try testing.expect(!st(&env).open and !env.t.hasText("Close"));

    try openPalette(&env);
    try ts.press(&env.t, S.escape, .{});
    env.t.settle(0.5);
    try testing.expect(!st(&env).open and !env.t.hasText("Close"));

    // A click on the scrim closes it too.
    try openPalette(&env);
    env.t.click(env.t.size.w - 12, env.t.size.h - 12);
    env.t.settle(0.5);
    try testing.expect(!st(&env).open);
}

test "the palette is modal: other shortcuts and bare keys don't reach the panes" {
    var env: ts.Env = undefined;
    try start(&env);
    defer env.deinit();

    try openPalette(&env);
    try testing.expectError(error.KeyNotTaken, ts.press(&env.t, 't', .{ .cmd = true })); // New Tab
    try testing.expectEqual(@as(usize, 1), env.m.focusedPane().tabs.items.len);
    typeQuery(&env, "a"); // goes to the field, not type-to-select
    try testing.expectEqualStrings("a", st(&env).buf.text());
    try testing.expectEqual(@as(usize, 0), env.m.focusedTab().selection.count());
}

test "empty query: Favorites, then Pinned, then every palette command in menu order" {
    var env: ts.Env = undefined;
    try start(&env);
    defer env.deinit();

    try openPalette(&env);
    try expectHeaders(&env, &.{ "Favorites", "Commands" });
    try testing.expectEqual(pm.Kind.location, rows(&env)[1].kind);
    try testing.expectEqualStrings("Fav", rows(&env)[1].title);
    try testing.expectEqualStrings("~", rows(&env)[1].subtitle); // dir's folder is Home
    try testing.expectEqual(@as(?usize, 1), st(&env).selected); // the first row that can be chosen
    try testing.expect(env.t.hasText("Fav") and env.t.hasText("New Folder"));

    // Every command with a place in the palette, once, in registry order, with its key.
    var i: usize = 0;
    const cmd_rows = rows(&env)[3..];
    for (&commands.all) |*cmd| {
        if (!cmd.in_palette) continue;
        try testing.expectEqual(pm.Kind.command, cmd_rows[i].kind);
        try testing.expectEqual(cmd.id, cmd_rows[i].command.?);
        if (cmd.shortcut != null) try testing.expect(cmd_rows[i].shortcut.len > 0);
        i += 1;
    }
    try testing.expectEqual(i, cmd_rows.len);
    try testing.expect(find(&env, .command, "Open") != null); // (the Cmd+Down twin is not listed twice)

    // A pinned folder gets its own section the next time.
    const pinned = try env.fx.sub("notes");
    defer testing.allocator.free(pinned);
    try env.m.sidebar.pin(pinned);
    try ts.press(&env.t, S.escape, .{});
    env.t.settle(0.4);
    try openPalette(&env);
    try expectHeaders(&env, &.{ "Favorites", "Pinned", "Commands" });
    try testing.expectEqualStrings("notes", rows(&env)[3].title);
}

test "typing fuzzy-matches commands, best first, ties in menu order" {
    var env: ts.Env = undefined;
    try start(&env);
    defer env.deinit();

    try openPalette(&env);
    typeQuery(&env, "new");
    try expectHeaders(&env, &.{"Commands"});

    // The order the matcher gives, worked out here from the registry.
    const Scored = struct { score: i64, id: commands.Id };
    var want: std.ArrayList(Scored) = .empty;
    defer want.deinit(testing.allocator);
    for (&commands.all) |*cmd| {
        if (!cmd.in_palette) continue;
        if (fuzzy.score("new", cmd.title)) |s| try want.append(testing.allocator, .{ .score = s, .id = cmd.id });
    }
    std.sort.block(Scored, want.items, {}, struct {
        fn gt(_: void, a: Scored, b: Scored) bool {
            return a.score > b.score;
        }
    }.gt);
    const n = @min(want.items.len, palette_rows.max_commands);
    try testing.expect(n >= 2);
    try testing.expectEqual(n, rows(&env).len - 1);
    for (want.items[0..n], rows(&env)[1..]) |w, r| try testing.expectEqual(w.id, r.command.?);
    // The better title leads: "New Tab" / "New Folder" over a looser match.
    try testing.expect(std.mem.startsWith(u8, rows(&env)[1].title, "New "));
    try testing.expectEqual(@as(?usize, 1), st(&env).selected);

    // The matches are what is drawn.
    try testing.expect(env.t.hasText("New Folder") and env.t.hasText("New Tab"));
    try testing.expect(env.t.hasText("\u{21E7}\u{2318}N") and env.t.hasText("\u{2318}T"));
    // Nothing matches: no rows, a message.
    typeQuery(&env, "qzxv");
    try testing.expectEqual(@as(usize, 0), rows(&env).len);
    try testing.expect(env.t.hasText("No results"));
}

test "typing finds files and folders of the index, with their folder abbreviated" {
    var env: ts.Env = undefined;
    try start(&env);
    defer env.deinit();

    try openPalette(&env);
    typeQuery(&env, "report");
    const hit = find(&env, .file, "report-final.pdf") orelse return error.NoHit;
    try testing.expectEqualStrings("~/dir", rows(&env)[hit].subtitle);
    const want = try env.fx.sub("dir/report-final.pdf");
    defer testing.allocator.free(want);
    try testing.expectEqualStrings(want, rows(&env)[hit].path);
    try testing.expect(!rows(&env)[hit].is_dir);
    try testing.expect(env.t.hasText("Files & Folders") and env.t.hasText("report-final.pdf") and env.t.hasText("~/dir"));
    try testing.expect(env.t.containsText("files indexed"));

    // Favorites and Pinned match by name, before the commands and files.
    clearQuery(&env);
    typeQuery(&env, "fav");
    try testing.expectEqualStrings("Favorites & Pinned", rows(&env)[0].title);
    try testing.expectEqualStrings("Fav", rows(&env)[1].title);
    typeQuery(&env, "ot"); // "favot" matches nothing
    try testing.expectEqual(@as(usize, 0), rows(&env).len);
    // A folder is a hit too.
    clearQuery(&env);
    typeQuery(&env, "notes");
    const folder = find(&env, .file, "notes") orelse return error.NoHit;
    try testing.expect(rows(&env)[folder].is_dir);
    // A folder already listed as a Favorite is not listed again among the files.
    clearQuery(&env);
    typeQuery(&env, "dir");
    const dir = try env.fx.sub("dir");
    defer testing.allocator.free(dir);
    var shown: usize = 0;
    for (rows(&env)) |r| if (r.kind != .header and std.mem.eql(u8, r.path, dir)) {
        shown += 1;
    };
    try testing.expectEqual(@as(usize, 1), shown);
}

test "Return runs the highlighted command, navigates to a folder and opens a file" {
    var env: ts.Env = undefined;
    try start(&env);
    defer env.deinit();
    ts.resetOpened();
    defer ts.resetOpened();

    // A command: New Folder.
    try openPalette(&env);
    typeQuery(&env, "New Folder");
    try testing.expectEqualStrings("New Folder", rows(&env)[st(&env).selected.?].title);
    try pressReturn(&env, .{});
    try testing.expect(!st(&env).open);
    try testing.expect(env.fx.exists("untitled folder"));

    // A Favorites row: the focused pane goes there.
    try openPalette(&env);
    try pressReturn(&env, .{}); // the first row is "Fav"
    const dir = try env.fx.sub("dir");
    defer testing.allocator.free(dir);
    try testing.expectEqualStrings(dir, env.m.focusedTab().path());

    // A folder hit.
    try openPalette(&env);
    typeQuery(&env, "notes");
    try moveTo(&env, find(&env, .file, "notes").?);
    try pressReturn(&env, .{});
    const notes = try env.fx.sub("notes");
    defer testing.allocator.free(notes);
    try testing.expectEqualStrings(notes, env.m.focusedTab().path());

    // A file hit: the injected opener gets it (not Finder, not an app).
    try openPalette(&env);
    typeQuery(&env, "meeting");
    try moveTo(&env, find(&env, .file, "meeting-notes.md").?);
    try pressReturn(&env, .{});
    const md = try env.fx.sub("notes/meeting-notes.md");
    defer testing.allocator.free(md);
    try testing.expectEqual(@as(usize, 1), ts.opened.items.len);
    try testing.expectEqualStrings(md, ts.opened.items[0]);
    try testing.expectEqualStrings(notes, env.m.focusedTab().path()); // the pane stays
}

test "Cmd+Return opens in a new tab, Opt+Return in a split; a file is shown selected in its folder" {
    var env: ts.Env = undefined;
    try start(&env);
    defer env.deinit();
    ts.resetOpened();
    defer ts.resetOpened();

    const dir = try env.fx.sub("dir");
    defer testing.allocator.free(dir);
    const report = try env.fx.sub("dir/report-final.pdf");
    defer testing.allocator.free(report);

    // A folder, Cmd+Return: a new tab of the focused pane; the first stays where it was.
    try openPalette(&env);
    try pressReturn(&env, .{ .cmd = true }); // "Fav" is the first row
    try testing.expectEqual(@as(usize, 2), env.m.focusedPane().tabs.items.len);
    try testing.expectEqualStrings(dir, env.m.focusedTab().path());
    try testing.expectEqualStrings(env.fx.root, env.m.focusedPane().tabs.items[0].path());

    // A folder, Opt+Return: a pane docked beside it.
    try openPalette(&env);
    try pressReturn(&env, .{ .alt = true });
    try testing.expectEqual(@as(usize, 2), env.m.panes.items.len);
    try testing.expectEqualStrings(dir, env.m.focusedTab().path());
    try ts.expectInSync(&env.m);

    // A file, Cmd+Return: its folder in another new tab, the file selected; nothing is launched.
    try openPalette(&env);
    typeQuery(&env, "report");
    try moveTo(&env, find(&env, .file, "report-final.pdf").?);
    const tabs_before = env.m.focusedPane().tabs.items.len;
    try pressReturn(&env, .{ .cmd = true });
    try testing.expectEqual(tabs_before + 1, env.m.focusedPane().tabs.items.len);
    try testing.expect(try env.selected("dir/report-final.pdf"));

    // A file, Opt+Return: a third pane with its folder, the file selected.
    try openPalette(&env);
    typeQuery(&env, "report");
    try moveTo(&env, find(&env, .file, "report-final.pdf").?);
    try pressReturn(&env, .{ .alt = true });
    try testing.expectEqual(@as(usize, 3), env.m.panes.items.len);
    try testing.expectEqualStrings(dir, env.m.focusedTab().path());
    try testing.expect(try env.selected("dir/report-final.pdf"));
    try testing.expectEqual(@as(usize, 0), ts.opened.items.len);
    try ts.expectInSync(&env.m);
}

test "a click on a row chooses it; a path that vanished raises the banner" {
    var env: ts.Env = undefined;
    try start(&env);
    defer env.deinit();

    try openPalette(&env);
    typeQuery(&env, "meeting");
    const path = try env.fx.sub("notes/meeting-notes.md");
    defer testing.allocator.free(path);
    // The file goes away after the index saw it.
    try env.fx.tmp.dir.deleteFile(testing.io, "notes/meeting-notes.md");
    try clickRow(&env, "meeting-notes.md");
    try testing.expect(!st(&env).open);
    try testing.expect(env.noticeHas("no longer exists"));

    try openPalette(&env);
    typeQuery(&env, "Sort by Kind");
    try clickRow(&env, "Sort by Kind");
    try testing.expect(!st(&env).open);
    try testing.expectEqual(@import("../core/lister.zig").SortKey.kind, env.m.focusedPane().sort.key);
}

test "Up and Down move through the rows that can be chosen and wrap around" {
    var env: ts.Env = undefined;
    try start(&env);
    defer env.deinit();

    try openPalette(&env);
    const all = rows(&env);
    var last: usize = 0;
    for (all, 0..) |r, i| if (r.selectable()) {
        last = i;
    };
    try testing.expectEqual(@as(?usize, 1), st(&env).selected);
    try ts.press(&env.t, S.up, .{}); // from the first: wraps to the last
    try testing.expectEqual(@as(?usize, last), st(&env).selected);
    try ts.press(&env.t, S.down, .{}); // and back to the first
    try testing.expectEqual(@as(?usize, 1), st(&env).selected);
    try ts.press(&env.t, S.down, .{}); // Fav -> past the "Commands" header
    try testing.expectEqual(pm.Kind.command, rows(&env)[st(&env).selected.?].kind);
    try testing.expectEqual(@as(?usize, 3), st(&env).selected);

    // Typing starts again at the top; the highlighted row is drawn selected and in view.
    typeQuery(&env, "go");
    try testing.expectEqual(@as(?usize, 1), st(&env).selected);
}

test "a command that doesn't apply is dimmed and never chosen" {
    var env: ts.Env = undefined;
    try start(&env);
    defer env.deinit();

    try openPalette(&env);
    const q = find(&env, .command, "Quick Look") orelse return error.NoRow;
    try testing.expect(!rows(&env)[q].enabled);
    // The keyboard never lands on it (nor on Paste, Undo ...: nothing to do now).
    var n: usize = 0;
    while (n < rows(&env).len + 2) : (n += 1) {
        try ts.press(&env.t, S.down, .{});
        const r = rows(&env)[st(&env).selected.?];
        try testing.expect(r.kind != .header and r.enabled);
    }
    // Only a disabled command matches: nothing is highlighted, Return does nothing.
    typeQuery(&env, "quick look");
    try testing.expectEqual(@as(usize, 2), rows(&env).len);
    try testing.expectEqual(@as(?usize, null), st(&env).selected);
    try pressReturn(&env, .{});
    try testing.expect(st(&env).open and env.m.notice == null);
    // Nor does a click on it.
    try clickRow(&env, "Quick Look");
    try testing.expect(st(&env).open);
}

test "every palette command is listed and runs from the palette, the Layout ones included" {
    var env: ts.Env = undefined;
    try start(&env);
    defer env.deinit();

    // All 12 layouts match a typed "layout".
    try openPalette(&env);
    typeQuery(&env, "layout");
    var layouts: usize = 0;
    for (rows(&env)) |r| if (r.kind == .command and std.mem.startsWith(u8, r.title, "Layout: ")) {
        layouts += 1;
    };
    try testing.expectEqual(pane_layout.LayoutPreset.all.len, layouts);
    try ts.press(&env.t, S.escape, .{});
    env.t.settle(0.4);

    // Each one, typed by its title and chosen, applies its preset.
    inline for (pane_layout.LayoutPreset.all) |p| {
        const id = @field(commands.Id, "layout_" ++ @tagName(p));
        try openPalette(&env);
        typeQuery(&env, "Layout: " ++ comptime p.title());
        try moveTo(&env, find(&env, .command, "Layout: " ++ comptime p.title()).?);
        try pressReturn(&env, .{});
        try testing.expect(commands.isChecked(&env.m, commands.find(id)));
        try ts.expectInSync(&env.m);
    }

    // Every command of the registry that has a place in the palette is chosen from its list and
    // queued like any other.
    for (&commands.all) |*cmd| {
        // (Go to Applications is a real folder; Undo and Redo would send the new folder through the
        // Trash, which tests_commands covers on its own.)
        if (!cmd.in_palette or cmd.id == .go_applications or cmd.id == .edit_undo or cmd.id == .edit_redo) continue;
        try palette_ops.show(&env.m);
        var idx: usize = 0;
        for (rows(&env), 0..) |r, i| if (r.command != null and r.command.? == cmd.id) {
            idx = i;
        };
        try testing.expect(idx > 0);
        const chosen = try palette_ops.choose(&env.m, rows(&env)[idx], .here);
        try testing.expectEqual(commands.isEnabled(&env.m, cmd), chosen);
        _ = try env.m.applyPending();
        if (chosen) try testing.expect(!st(&env).open);
    }
    try ts.expectInSync(&env.m);
}

test "the index crawl goes to the injected runner: the palette answers while it is pending" {
    var env: ts.Env = undefined;
    try env.initWith(.{ .index = .held, .files = &files });
    defer env.deinit();

    // The first pass asked for a crawl; nobody has run it: nothing blocked.
    try testing.expect(ts.held_job != null);
    try testing.expectEqual(@as(u32, 1), st(&env).index.crawls);
    try testing.expect(st(&env).index.isBuilding());

    try openPalette(&env);
    try testing.expectEqual(@as(u32, 1), st(&env).index.crawls); // not stale: no second crawl
    try testing.expect(env.t.hasText("Indexing files\u{2026}"));
    typeQuery(&env, "report");
    try testing.expect(find(&env, .file, "report-final.pdf") == null);
    try testing.expectEqual(@as(usize, 0), rows(&env).len); // (nothing else matches "report")

    // The crawl finishes: the next frame searches again by itself.
    try testing.expect(ts.runHeld());
    env.t.settle(0.3);
    try testing.expect(!st(&env).index.isBuilding());
    try testing.expect(find(&env, .file, "report-final.pdf") != null);
    try testing.expect(env.t.containsText("files indexed") and !env.t.hasText("Indexing files\u{2026}"));
}

test "the index is crawled again when it is stale at opening and when a folder is pinned" {
    var env: ts.Env = undefined;
    // Only dir/ is a root.
    try env.initWith(.{ .index = .now, .files = &(files ++ [_][]const u8{"other/elsewhere.txt"}), .index_rel = "dir" });
    defer env.deinit();

    try testing.expectEqual(@as(u32, 1), st(&env).index.crawls);
    try openPalette(&env);
    typeQuery(&env, "report");
    try testing.expect(find(&env, .file, "report-final.pdf") != null);
    clearQuery(&env);
    typeQuery(&env, "elsewhere");
    try testing.expect(find(&env, .file, "elsewhere.txt") == null); // outside the roots
    try ts.press(&env.t, S.escape, .{});
    env.t.settle(0.4);
    try testing.expectEqual(@as(u32, 1), st(&env).index.crawls);

    // Pinning a folder outside it adds a root: crawled at once, no palette needed.
    const other = try env.fx.sub("other");
    defer testing.allocator.free(other);
    try env.m.sidebar.pin(other);
    env.t.settle(0.2);
    try testing.expectEqual(@as(u32, 2), st(&env).index.crawls);
    try openPalette(&env);
    typeQuery(&env, "elsewhere");
    try testing.expect(find(&env, .file, "elsewhere.txt") != null);
    try testing.expectEqual(@as(u32, 2), st(&env).index.crawls); // fresh: opening didn't crawl

    // An old index is crawled again the next time the palette opens.
    try ts.press(&env.t, S.escape, .{});
    env.t.settle(0.4);
    env.t.time += 700;
    env.t.settle(0.2);
    try openPalette(&env);
    try testing.expectEqual(@as(u32, 3), st(&env).index.crawls);
}

test "with no index configured (the default) nothing is crawled and files don't appear" {
    var env: ts.Env = undefined;
    try env.init();
    defer env.deinit();
    try openPalette(&env);
    typeQuery(&env, "inner");
    try testing.expect(find(&env, .file, "inner.txt") == null);
    try testing.expectEqual(@as(u32, 0), st(&env).index.crawls);
    try testing.expect(!st(&env).index.enabled);
}
