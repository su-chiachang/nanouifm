//! The pane toolbar through ui.Tester: the Sort menu (keys, direction, folders first, per pane),
//! the name filter (Cmd+F, typing, Escape, per pane, cleared when the folder changes, list and
//! column view), the "..." menu, "+" (new folder) and the layout of the row in narrow panes.
//! Temp folders only.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const commands = @import("commands.zig");
const lister = @import("../core/lister.zig");
const ts = @import("test_support.zig");

const testing = std.testing;
const S = ui.Shortcut;

fn names(env: *ts.Env) []const []const u8 {
    const S_ = struct {
        var buf: [64][]const u8 = undefined;
    };
    return ts.rowNames(&env.m, &S_.buf);
}

fn expectRows(env: *ts.Env, want: []const []const u8) !void {
    const got = names(env);
    try testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| try testing.expectEqualStrings(w, g);
}

fn pick(env: *ts.Env, s: []const u8) !void {
    try ts.clickLowestText(&env.t, s);
    env.t.settle(0.5);
}

fn openSort(env: *ts.Env) !void {
    try ts.clickIcon(&env.t, "arrow.up.arrow.down");
    env.t.settle(0.5);
    try testing.expect(env.m.view_state.toolbar_menu.open);
}

test "the Sort menu: keys, direction and folders first change the order and show their ticks" {
    var env: ts.Env = undefined;
    try env.init(); // a.txt (10 bytes), b.txt (20), dir/
    defer env.deinit();

    try expectRows(&env, &.{ "dir", "a.txt", "b.txt" });
    try openSort(&env);
    for ([_][]const u8{ "Sort By", "Name", "Kind", "Size", "Date Modified", "Date Created", "Ascending", "Descending", "Folders First" }) |s| {
        try testing.expect(env.t.hasText(s));
    }
    try testing.expect(ts.hasIcon(&env.t, "checkmark")); // Name, Ascending and Folders First are ticked

    try pick(&env, "Size");
    try testing.expect(!env.m.view_state.toolbar_menu.open);
    try testing.expectEqual(lister.SortKey.size, env.m.focusedPane().sort.key);
    try expectRows(&env, &.{ "dir", "a.txt", "b.txt" });

    try openSort(&env);
    try pick(&env, "Descending");
    try testing.expect(!env.m.focusedPane().sort.ascending);
    try expectRows(&env, &.{ "dir", "b.txt", "a.txt" }); // folders still first

    try openSort(&env);
    try pick(&env, "Folders First");
    try testing.expect(!env.m.focusedPane().sort.folders_first);
    try expectRows(&env, &.{ "b.txt", "a.txt", "dir" }); // a folder has no size: last

    try openSort(&env);
    try pick(&env, "Ascending");
    try expectRows(&env, &.{ "a.txt", "b.txt", "dir" });
    try openSort(&env);
    try pick(&env, "Folders First");
    try openSort(&env);
    try pick(&env, "Name");
    try testing.expectEqual(lister.SortKey.name, env.m.focusedPane().sort.key);
    try expectRows(&env, &.{ "dir", "a.txt", "b.txt" });
    // The header's own click still flips the direction of the key it sorts by.
    try env.t.clickText("Name");
    env.t.settle(0.3);
    try expectRows(&env, &.{ "dir", "b.txt", "a.txt" });
}

test "the Sort menu button acts on its own pane and shows the order in its tint" {
    var env: ts.Env = undefined;
    try env.init();
    defer env.deinit();
    try env.m.queue(.{ .split = .side_by_side });
    _ = try env.m.applyPending();
    try env.m.queue(.{ .focus_pane = env.m.panes.items[0].id });
    env.t.settle(0.4);

    // The unfocused right pane's button: the menu opens for that pane, which takes the focus.
    const right = try ts.paneRect(&env.t, &env.m, 1);
    try ts.clickIconIn(&env.t, right, "arrow.up.arrow.down");
    env.t.settle(0.5);
    try testing.expectEqual(env.m.panes.items[1].id, env.m.view_state.toolbar_menu.pane);
    try pick(&env, "Kind");
    try testing.expectEqual(lister.SortKey.kind, env.m.panes.items[1].sort.key);
    try testing.expectEqual(lister.SortKey.name, env.m.panes.items[0].sort.key);
    try testing.expectEqual(@as(usize, 1), env.m.focused);
    // The menu hung from the right pane's button.
    try testing.expect(!env.m.view_state.toolbar_menu.open);
}

test "the sort commands of the registry: each key, both directions and folders first" {
    var env: ts.Env = undefined;
    try env.init();
    defer env.deinit();
    const pane = env.m.focusedPane();

    for ([_]struct { id: commands.Id, key: lister.SortKey }{
        .{ .id = .sort_kind, .key = .kind },
        .{ .id = .sort_size, .key = .size },
        .{ .id = .sort_modified, .key = .modified },
        .{ .id = .sort_created, .key = .created },
        .{ .id = .sort_name, .key = .name },
    }) |c| {
        try env.m.queue(.{ .run_command = c.id });
        env.t.settle(0.2);
        try testing.expectEqual(c.key, pane.sort.key);
        try testing.expect(commands.isChecked(&env.m, commands.find(c.id)));
    }
    try env.m.queue(.{ .run_command = .sort_descending });
    env.t.settle(0.2);
    try testing.expect(!pane.sort.ascending and commands.isChecked(&env.m, commands.find(.sort_descending)) and !commands.isChecked(&env.m, commands.find(.sort_ascending)));
    try expectRows(&env, &.{ "dir", "b.txt", "a.txt" });
    try env.m.queue(.{ .run_command = .sort_descending }); // already: stays
    try env.m.queue(.{ .run_command = .sort_ascending });
    try env.m.queue(.{ .run_command = .sort_folders_first });
    env.t.settle(0.2);
    try testing.expect(pane.sort.ascending and !pane.sort.folders_first);
    try expectRows(&env, &.{ "a.txt", "b.txt", "dir" });
    try env.m.queue(.{ .run_command = .sort_folders_first });
    env.t.settle(0.2);
    try testing.expect(pane.sort.folders_first);
    // They are in the palette (the menu lists them under their own words).
    for ([_]commands.Id{ .sort_created, .sort_ascending, .sort_descending, .sort_folders_first, .filter_focus }) |id| {
        try testing.expect(commands.find(id).in_palette);
    }
}

test "the filter field narrows the list by name, Escape clears it" {
    var env: ts.Env = undefined;
    try env.init();
    defer env.deinit();

    try ts.press(&env.t, 'f', .{ .cmd = true }); // Cmd+F
    env.t.settle(0.3);
    try testing.expect(env.t.ctx.focus_is_text);
    env.t.typeText("A.T");
    env.t.settle(0.3);
    try testing.expectEqualStrings("A.T", env.m.focusedPane().filter.text());
    try expectRows(&env, &.{"a.txt"}); // case doesn't matter
    try testing.expect(!env.t.hasText("b.txt") and !env.t.hasText("dir"));

    env.t.textOps(&.{ .{ .command = .select_all }, .{ .command = .delete_backward } });
    env.t.typeText("xt");
    env.t.settle(0.3);
    try expectRows(&env, &.{ "a.txt", "b.txt" }); // anywhere in the name
    env.t.typeText("zz");
    env.t.settle(0.3);
    try expectRows(&env, &.{});
    try testing.expect(env.t.hasText("No Matches"));

    // Escape empties the field and gives the keyboard back.
    try ts.press(&env.t, S.escape, .{});
    env.t.settle(0.3);
    try testing.expectEqualStrings("", env.m.focusedPane().filter.text());
    try expectRows(&env, &.{ "dir", "a.txt", "b.txt" });
    try testing.expect(!env.t.ctx.focus_is_text);

    // Return keeps the text and hands the keyboard to the list: arrows work again.
    try ts.press(&env.t, 'f', .{ .cmd = true });
    env.t.typeText("txt");
    env.t.settle(0.3);
    env.t.key(.enter);
    env.t.settle(0.3);
    try testing.expect(!env.t.ctx.focus_is_text);
    try expectRows(&env, &.{ "a.txt", "b.txt" });
    try ts.press(&env.t, S.down, .{});
    try testing.expectEqual(@as(usize, 1), env.m.focusedTab().selection.count());
    // The field's own clear button.
    try ts.clickIcon(&env.t, "xmark.circle.fill");
    env.t.settle(0.3);
    try testing.expectEqualStrings("", env.m.focusedPane().filter.text());
    try expectRows(&env, &.{ "dir", "a.txt", "b.txt" });
}

test "a filter is per pane and goes when the folder changes; a tab switch keeps it" {
    var env: ts.Env = undefined;
    try env.init();
    defer env.deinit();

    try env.m.queue(.{ .split = .side_by_side });
    _ = try env.m.applyPending();
    env.t.settle(0.4);
    try testing.expectEqual(@as(usize, 1), env.m.focused);
    try ts.press(&env.t, 'f', .{ .cmd = true });
    env.t.typeText("dir");
    env.t.settle(0.3);
    try expectRows(&env, &.{"dir"});
    try testing.expectEqual(@as(usize, 3), env.m.panes.items[0].tab().exp.items.len); // the other pane is whole
    try testing.expectEqualStrings("", env.m.panes.items[0].filter.text());

    // A new tab shows the same folder through the same filter.
    try env.m.queue(.new_tab);
    env.t.settle(0.3);
    try expectRows(&env, &.{"dir"});
    try testing.expectEqualStrings("dir", env.m.focusedPane().filter.text());

    // Going into the folder drops the filter (and the field shows it).
    const dir = try env.fx.sub("dir");
    defer testing.allocator.free(dir);
    try env.m.queue(.{ .open = dir });
    env.t.settle(0.3);
    try testing.expectEqualStrings("", env.m.focusedPane().filter.text());
    try expectRows(&env, &.{"inner.txt"});
    try env.m.queue(.back);
    env.t.settle(0.3);
    try expectRows(&env, &.{ "dir", "a.txt", "b.txt" });
    // The other tab of the pane was filtered with it, and is whole again now.
    for (env.m.focusedPane().tabs.items) |*t| try testing.expectEqual(@as(usize, 3), t.exp.items.len);
}

test "the filter applies to the active column of the column view" {
    var env: ts.Env = undefined;
    try env.init();
    defer env.deinit();
    try ts.press(&env.t, '2', .{ .cmd = true });
    env.t.settle(0.3);
    const cols = &env.m.focusedTab().col;
    try testing.expect(cols.columns.items.len >= 1);
    const last = cols.columns.items.len - 1;
    try testing.expectEqual(@as(usize, 3), cols.columns.items[last].items().len);

    try ts.press(&env.t, 'f', .{ .cmd = true });
    env.t.typeText("b.");
    env.t.settle(0.3);
    try testing.expectEqual(@as(usize, 1), cols.columns.items[last].items().len);
    try testing.expectEqualStrings("b.txt", cols.columns.items[last].items()[0].name);
    try testing.expect(env.t.hasText("b.txt") and !env.t.hasText("a.txt"));
    if (last > 0) try testing.expect(cols.columns.items[0].items().len >= 1); // the column before: unfiltered
    try ts.press(&env.t, S.escape, .{});
    env.t.settle(0.3);
    try testing.expectEqual(@as(usize, 3), cols.columns.items[last].items().len);
}

test "+ makes a new folder in the pane's folder and starts its rename" {
    var env: ts.Env = undefined;
    try env.init();
    defer env.deinit();

    try ts.clickIcon(&env.t, "folder.badge.plus");
    env.t.settle(0.4);
    try testing.expect(env.fx.exists("untitled folder"));
    try testing.expect(env.m.rename != null);

    // In another pane: that pane's folder, and the pane takes the focus.
    try env.m.queue(.{ .split = .side_by_side });
    _ = try env.m.applyPending();
    const dir = try env.fx.sub("dir");
    defer testing.allocator.free(dir);
    try env.m.panes.items[1].tab().visit(dir, env.m.opts(&env.m.panes.items[1]));
    try env.m.queue(.{ .focus_pane = env.m.panes.items[0].id });
    env.t.settle(0.4);
    try ts.clickIconIn(&env.t, try ts.paneRect(&env.t, &env.m, 1), "folder.badge.plus");
    env.t.settle(0.4);
    try testing.expect(env.fx.exists("dir/untitled folder"));
    try testing.expectEqual(@as(usize, 1), env.m.focused);
}

test "the ... menu: view mode, hidden files, splits and the palette" {
    var env: ts.Env = undefined;
    try env.init();
    defer env.deinit();

    try ts.clickIcon(&env.t, "ellipsis");
    env.t.settle(0.5);
    for ([_][]const u8{ "as List", "as Columns", "Show Hidden Files", "Split Side by Side", "Split Stacked", "Command Palette\u{2026}" }) |s| {
        try testing.expect(env.t.hasText(s));
    }
    try pick(&env, "as Columns");
    try testing.expectEqual(.column, env.m.focusedPane().view_mode);
    try ts.clickIcon(&env.t, "ellipsis");
    env.t.settle(0.5);
    try pick(&env, "Split Side by Side");
    try testing.expectEqual(@as(usize, 2), env.m.panes.items.len);
    try ts.clickIconIn(&env.t, try ts.paneRect(&env.t, &env.m, 1), "ellipsis");
    env.t.settle(0.5);
    try pick(&env, "Command Palette\u{2026}");
    try testing.expect(env.m.view_state.palette.open);
}

test "the toolbar row fits a narrow pane: nothing leaves its pane" {
    var env: ts.Env = undefined;
    try env.init();
    defer env.deinit();
    // One wide pane has everything; the panes of a 2x2 grid lose the name; four columns keep
    // Sort, the filter and "...".
    const all = [_][]const u8{ "chevron.left", "chevron.up", "arrow.up.arrow.down", "magnifyingglass", "ellipsis", "folder.badge.plus" };
    for (all) |sym| try testing.expect(ts.iconIn(&env.t, try ts.paneRect(&env.t, &env.m, 0), sym) != null);
    try env.m.queue(.{ .run_command = .layout_grid_2x2 });
    env.t.settle(0.4);
    for (0..4) |i| {
        const r = try ts.paneRect(&env.t, &env.m, i);
        for (all) |sym| {
            const ic = ts.iconIn(&env.t, r, sym) orelse return error.IconMissing;
            try testing.expect(ic.x >= r.x and ic.x + ic.w <= r.x + r.w);
        }
    }
    try env.m.queue(.{ .run_command = .layout_four_columns });
    env.t.settle(0.4);
    try testing.expectEqual(@as(usize, 4), env.m.panes.items.len);
    for (0..4) |i| {
        const r = try ts.paneRect(&env.t, &env.m, i);
        for (all[2..5]) |sym| {
            const ic = ts.iconIn(&env.t, r, sym) orelse return error.IconMissing;
            try testing.expect(ic.x >= r.x and ic.x + ic.w <= r.x + r.w);
        }
    }
}
