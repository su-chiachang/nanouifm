//! The native menu bar's template (`menu_template.zig`, a pure function of the model: no menu is
//! ever built here) and the rule for who takes a key, the menu or the view (`menu_link.zig`).
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const app_view = @import("../app.zig");
const commands = @import("commands.zig");
const menu_template = @import("menu_template.zig");
const menu_link = @import("menu_link.zig");
const ts = @import("test_support.zig");

const testing = std.testing;
const Item = menu_template.Item;
const S = ui.Shortcut;

fn walk(items: []const Item, counts: *[menu_link.count]u8) void {
    for (items) |it| {
        if (it.id.len > 0) if (commands.byName(it.id)) |c| {
            counts[@backingInt(c.id)] += 1;
        };
        if (it.submenu) |sub| walk(sub, counts);
    }
}

fn find(items: []const Item, name: []const u8) ?Item {
    for (items) |it| {
        if (it.id.len > 0 and std.mem.eql(u8, it.id, name)) return it;
        if (it.submenu) |sub| if (find(sub, name)) |f| return f;
    }
    return null;
}

fn titled(items: []const Item, label: []const u8) ?Item {
    for (items) |it| if (std.mem.eql(u8, it.label, label)) return it;
    return null;
}

/// What `menu_bar.Bar.sync` records for the menu's keys: each command's item, enabled or not.
fn installFake(m: *app_view.State) void {
    m.menu.installed = true;
    for (&commands.all) |*c| m.menu.enabled.setValue(@backingInt(c.id), commands.isEnabled(m, c));
}

test "every command the registry lists in the menu appears exactly once" {
    var env: ts.Env = undefined;
    try env.init();
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var host: menu_template.Host = .{ .m = &env.m };
    const bar = try menu_template.build(arena.allocator(), &env.m, &host);

    var counts: [menu_link.count]u8 = @splat(0);
    walk(bar, &counts);
    for (&commands.all) |*c| try testing.expectEqual(@as(u8, if (c.in_menu) 1 else 0), counts[@backingInt(c.id)]);
    // The one command left out is Open's second key, Cmd+Down.
    var left_out: usize = 0;
    for (&commands.all) |*c| {
        if (!c.in_menu) {
            left_out += 1;
            try testing.expect(c.id == .file_open_down);
        }
    }
    try testing.expectEqual(@as(usize, 1), left_out);
    // The bar: the App role, then File, Edit, View, Go, and the Window role.
    try testing.expectEqual(@as(usize, 6), bar.len);
    try testing.expect(bar[0].role.? == .app_menu and bar[5].role.? == .window_menu);
    for ([_][]const u8{ "File", "Edit", "View", "Go" }, bar[1..5]) |label, it| try testing.expectEqualStrings(label, it.label);
    // Standard roles are there: Minimize, Zoom, Bring All to Front.
    var roles: usize = 0;
    for (bar[5].submenu.?) |it| if (it.role) |r| switch (r) {
        .minimize, .zoom, .front => roles += 1,
        else => {},
    };
    try testing.expectEqual(@as(usize, 3), roles);
    // Every top-level menu refreshes its items as it opens.
    for (bar[1..5]) |it| try testing.expect(it.on_open != null);
}

test "accelerators come from the shortcuts, and agree with what nanoui parses" {
    var env: ts.Env = undefined;
    try env.init();
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var host: menu_template.Host = .{ .m = &env.m };
    const bar = try menu_template.build(arena.allocator(), &env.m, &host);

    var owned: usize = 0;
    for (&commands.all) |*c| {
        if (!c.in_menu) continue;
        const it = find(bar, @tagName(c.id)).?;
        if (!menu_link.ownsKey(c)) {
            try testing.expectEqualStrings("", it.accelerator); // Return, Ctrl+Tab: the view keeps them
            continue;
        }
        owned += 1;
        const s = c.shortcut.?;
        const a = nanoui.menu.parseAccelerator(it.accelerator);
        const want_mods = (if (s.cmd) nanoui.menu.mod_cmd else 0) | (if (s.ctrl) nanoui.menu.mod_ctrl else 0) |
            (if (s.alt) nanoui.menu.mod_alt else 0) | (if (s.shift) nanoui.menu.mod_shift else 0);
        try testing.expectEqual(want_mods, a.mods);
        // AppKit writes the Delete key as the backspace character.
        const want_key: u21 = if (s.key == S.backspace) 0x08 else s.key;
        try testing.expectEqual(want_key, a.key);
    }
    try testing.expect(owned > 30);
    // The Go menu, as the spec has it: no Desktop shortcut (Shift+Cmd+D is the stacked split).
    try testing.expectEqualStrings("Cmd+Shift+H", find(bar, "go_home").?.accelerator);
    try testing.expectEqualStrings("Cmd+Alt+L", find(bar, "go_downloads").?.accelerator);
    try testing.expectEqualStrings("Cmd+Shift+G", find(bar, "go_to_folder").?.accelerator);
    try testing.expectEqualStrings("", find(bar, "go_desktop").?.accelerator);
    try testing.expectEqualStrings("Cmd+Shift+D", find(bar, "view_split_stacked").?.accelerator);
    try testing.expectEqualStrings("Cmd+Ctrl+S", find(bar, "view_sidebar").?.accelerator);
    // Move to Trash is NOT a menu accelerator: the view owns Cmd+Backspace, so a Delete-key mismatch
    // in AppKit can never leave the command dead (and the two never both fire).
    try testing.expectEqualStrings("", find(bar, "file_trash").?.accelerator);
    try testing.expectEqualStrings("Cmd+Alt+Right", find(bar, "pane_focus_next").?.accelerator);
    // Writing one by hand.
    var buf: [48]u8 = undefined;
    try testing.expectEqualStrings("Cmd+Shift+N", menu_template.accelerator(&buf, .{ .key = 'n', .cmd = true, .shift = true }));
    try testing.expectEqualStrings("Ctrl+Tab", menu_template.accelerator(&buf, .{ .key = S.tab, .ctrl = true }));
    try testing.expectEqualStrings("Cmd+Up", menu_template.accelerator(&buf, .{ .key = S.up, .cmd = true }));
}

test "View has Layout and Sort By submenus; Layout and the sort keys are exclusive choices" {
    var env: ts.Env = undefined;
    try env.init();
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var host: menu_template.Host = .{ .m = &env.m };
    const bar = try menu_template.build(arena.allocator(), &env.m, &host);

    const view = bar[3].submenu.?;
    const layout = titled(view, "Layout").?.submenu.?;
    try testing.expectEqual(@as(usize, 12), layout.len);
    try testing.expectEqualStrings("Single Pane", layout[0].label); // "Layout: " is the submenu's title
    try testing.expect(layout[0].checked and layout[0].kind == .radio and !layout[1].checked);
    const sort = titled(view, "Sort By").?.submenu.?;
    try testing.expectEqualStrings("Name", sort[0].label);
    try testing.expect(sort[0].checked and sort[0].kind == .radio);
    const hidden = find(bar, "view_hidden").?;
    try testing.expect(hidden.kind == .checkbox and !hidden.checked);
    const folders_first = find(bar, "sort_folders_first").?;
    try testing.expect(folders_first.kind == .checkbox and folders_first.checked);
    try testing.expect(find(bar, "view_list").?.checked and !find(bar, "view_column").?.checked);
}

test "the template follows the model: Show Hidden ticks, Undo and Redo name what they undo" {
    var env: ts.Env = undefined;
    try env.init();
    defer env.deinit();
    var host: menu_template.Host = .{ .m = &env.m };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    {
        const bar = try menu_template.build(arena.allocator(), &env.m, &host);
        const undo = find(bar, "edit_undo").?;
        try testing.expectEqualStrings("Undo", undo.label);
        try testing.expect(undo.disabled and find(bar, "edit_redo").?.disabled);
        try testing.expect(!find(bar, "view_hidden").?.checked);
        try testing.expect(find(bar, "file_rename").?.disabled); // nothing selected
        try testing.expect(find(bar, "file_quick_look").?.disabled); // a stub until Quick Look
        try testing.expect(!find(bar, "file_new_folder").?.disabled);
        try testing.expectEqualStrings("Hide Sidebar", find(bar, "view_sidebar").?.label);
    }
    try ts.press(&env.t, 'n', .{ .cmd = true, .shift = true });
    env.renameTo("Renamed");
    try ts.press(&env.t, '.', .{ .cmd = true, .shift = true });
    try env.m.queue(.{ .run_command = .view_sidebar });
    env.t.settle(0.2);
    {
        const bar = try menu_template.build(arena.allocator(), &env.m, &host);
        const undo = find(bar, "edit_undo").?;
        try testing.expectEqualStrings("Undo Rename", undo.label);
        try testing.expect(!undo.disabled);
        try testing.expect(find(bar, "view_hidden").?.checked);
        try testing.expectEqualStrings("Show Sidebar", find(bar, "view_sidebar").?.label);
        try testing.expectEqualStrings("Cmd+Z", undo.accelerator);
    }
    // Undo it through the menu's path: the command is queued as the keyboard queues it.
    try testing.expect(host.run("edit_undo"));
    env.t.settle(0.2);
    try testing.expectEqualStrings("Redo Rename", find(try menu_template.build(arena.allocator(), &env.m, &host), "edit_redo").?.label);
}

test "a click on an item queues its command; file commands wait while a text field has the keyboard" {
    var env: ts.Env = undefined;
    try env.init();
    defer env.deinit();
    var host: menu_template.Host = .{ .m = &env.m };
    try testing.expect(!host.run("no_such_command"));
    try testing.expect(host.run("view_hidden"));
    try testing.expectEqual(@as(usize, 1), env.m.pending.items.len);
    env.t.settle(0.2);
    try testing.expect(env.m.show_hidden);
    env.m.text_focus = true;
    try testing.expect(!host.run("edit_select_all")); // would select files, not text
    try testing.expect(host.run("view_hidden")); // not a file command
    env.m.text_focus = false;
    env.t.settle(0.2);
    try testing.expect(!env.m.show_hidden);
}

test "with a menu bar the menu owns its keys while enabled; the view takes them otherwise and in text fields" {
    var env: ts.Env = undefined;
    try env.init();
    defer env.deinit();
    installFake(&env.m);
    const tabs = struct {
        fn n(e: *ts.Env) usize {
            return e.m.panes.items[0].tabs.items.len;
        }
    }.n;

    // Cmd+T: the menu's (its item is enabled): the view's dispatcher leaves it, so it is not
    // run twice, and not by the view at all.
    try testing.expect(!env.t.shortcut(.{ .key = 't', .cmd = true }));
    env.t.settle(0.2);
    try testing.expectEqual(@as(usize, 1), tabs(&env));
    // What the menu would do on its own: the click runs it once.
    var host: menu_template.Host = .{ .m = &env.m };
    try testing.expect(host.run("tab_new"));
    env.t.settle(0.2);
    try testing.expectEqual(@as(usize, 2), tabs(&env));

    // A command whose item is disabled in the menu (AppKit skips it) but applies: the view runs it.
    env.m.menu.enabled.unset(@backingInt(commands.Id.tab_new));
    try ts.press(&env.t, 't', .{ .cmd = true });
    try testing.expectEqual(@as(usize, 3), tabs(&env));
    env.m.menu.enabled.set(@backingInt(commands.Id.tab_new));

    // A text field has the keyboard (the filter): the menu's keys are held back, the view takes
    // the ones that are not about files, and leaves the file ones to the field.
    env.m.view_state.focus_filter = env.m.panes.items[0].id;
    env.t.settle(0.3);
    try testing.expect(env.t.ctx.focus_is_text);
    try ts.press(&env.t, 't', .{ .cmd = true });
    try testing.expectEqual(@as(usize, 4), tabs(&env));
    try testing.expect(!env.t.shortcut(.{ .key = 'a', .cmd = true })); // Select All: the field's
    // Keys that are not accelerators (Return renames) stay with the view whatever the menu does.
    try testing.expect(!menu_link.ownsKey(commands.find(.file_rename)));
    try testing.expect(!menu_link.ownsKey(commands.find(.file_open_down)));
    try testing.expect(!menu_link.ownsKey(commands.find(.tab_next)));
    try testing.expect(menu_link.ownsKey(commands.find(.tab_new)));
}

test "keys that are not menu accelerators still work with a menu bar" {
    var env: ts.Env = undefined;
    try env.init();
    defer env.deinit();
    installFake(&env.m);
    try env.click("a.txt");
    try ts.press(&env.t, S.enter, .{}); // Rename
    try testing.expect(env.m.rename != null);
    env.t.key(.escape);
    env.t.settle(0.2);
    // Cmd+Down is Open's second key: the view's, since only Cmd+O is in the menu.
    try env.click("dir");
    try ts.press(&env.t, S.down, .{ .cmd = true });
    try testing.expectEqualStrings("dir", std.fs.path.basename(env.m.focusedTab().path()));
}

var role_ran: ?@import("hooks.zig").AppRole = null;

fn recordRole(role: @import("hooks.zig").AppRole) void {
    role_ran = role;
}

test "while a text field holds the menu's keys back the view quits, hides and minimizes itself" {
    var env: ts.Env = undefined;
    try env.init();
    defer env.deinit();
    installFake(&env.m);
    env.m.hooks.app_role = recordRole;
    // No text field: those keys belong to the menu bar's roles, and the view leaves them.
    role_ran = null;
    try testing.expect(!env.t.shortcut(.{ .key = 'q', .cmd = true }));
    try testing.expect(role_ran == null);

    env.m.view_state.focus_filter = env.m.panes.items[0].id;
    env.t.settle(0.3);
    try testing.expect(env.t.ctx.focus_is_text);
    for ([_]struct { s: ui.Shortcut, role: @import("hooks.zig").AppRole }{
        .{ .s = .{ .key = 'q', .cmd = true }, .role = .quit },
        .{ .s = .{ .key = 'h', .cmd = true }, .role = .hide },
        .{ .s = .{ .key = 'h', .cmd = true, .alt = true }, .role = .hide_others },
        .{ .s = .{ .key = 'm', .cmd = true }, .role = .minimize },
    }) |ch| {
        role_ran = null;
        try testing.expect(env.t.shortcut(ch.s));
        try testing.expectEqual(ch.role, role_ran.?);
    }
}
