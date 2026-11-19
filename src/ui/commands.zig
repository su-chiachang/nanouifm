//! THE command registry: one table of every command (id, title, category, shortcut, symbol,
//! enabled / checked predicates, action). The keyboard (`command_keys.zig`), the context menu, the
//! toolbar's menus and the command palette (`palette_rows.zig`) run from it, and the menu bar will,
//! so a command added here appears everywhere with its shortcut and its enabled state.
//!
//!   for (commands.all) |*cmd| ...              // every command, in menu order
//!   commands.find(.file_new_folder)            // one command
//!   commands.isEnabled(m, cmd), isChecked, titleOf(m, cmd, &buf), shortcutLabel(&buf, cmd.shortcut.?)
//!   try m.queue(.{ .run_command = id })        // how everything runs a command
//!
//! Running a command is always queued as `Action.run_command` and happens in
//! `Model.applyPending`, so nothing a frame is still drawing is changed under it.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const Allocator = std.mem.Allocator;
const Model = @import("model.zig").Model;
const command = @import("command.zig");
const impl = @import("command_impl.zig");
const pane_layout = @import("../core/pane_layout.zig");
const open_with = @import("open_with.zig");

pub const Command = command.Command;
pub const Id = command.Id;
pub const Category = command.Category;

const S = ui.Shortcut;

const static = [_]Command{
    // File
    .{ .id = .tab_new, .title = "New Tab", .category = .file, .shortcut = .{ .key = 't', .cmd = true }, .symbol = "plus.square.on.square", .run = impl.newTab },
    .{ .id = .tab_close, .title = "Close Tab", .category = .file, .shortcut = .{ .key = 'w', .cmd = true }, .symbol = "xmark", .run = impl.closeTab },
    .{ .id = .pane_close, .title = "Close Pane", .category = .file, .shortcut = .{ .key = 'w', .cmd = true, .alt = true }, .enabled = impl.manyPanes, .run = impl.closePane },
    .{ .id = .file_new_folder, .title = "New Folder", .category = .file, .shortcut = .{ .key = 'n', .cmd = true, .shift = true }, .symbol = "folder.badge.plus", .run = impl.newFolder },
    .{ .id = .file_open, .title = "Open", .category = .file, .shortcut = .{ .key = 'o', .cmd = true }, .symbol = "arrow.up.forward.app", .file_scope = true, .enabled = impl.hasSelection, .run = impl.open },
    .{ .id = .file_open_down, .title = "Open", .category = .file, .shortcut = .{ .key = S.down, .cmd = true }, .file_scope = true, .in_palette = false, .in_menu = false, .enabled = impl.hasSelection, .run = impl.open },
    .{ .id = .file_open_new_tab, .title = "Open in New Tab", .category = .file, .symbol = "plus.rectangle.on.rectangle", .enabled = impl.hasFolderTarget, .run = impl.openNewTab },
    .{ .id = .file_open_split, .title = "Open in Split", .category = .file, .symbol = "rectangle.split.2x1", .enabled = impl.hasFolderTarget, .run = impl.openSplit },
    .{ .id = .file_quick_look, .title = "Quick Look", .category = .file, .shortcut = .{ .key = 'y', .cmd = true }, .symbol = "eye", .file_scope = true, .enabled = impl.canQuickLook, .run = impl.quickLook },
    .{ .id = .file_quick_look_space, .title = "Quick Look", .category = .file, .shortcut = .{ .key = ' ' }, .file_scope = true, .in_palette = false, .in_menu = false, .enabled = impl.canQuickLook, .run = impl.quickLook },
    .{ .id = .file_rename, .title = "Rename", .category = .file, .shortcut = .{ .key = S.enter }, .symbol = "pencil", .file_scope = true, .enabled = impl.hasSingle, .run = impl.beginRename },
    .{ .id = .file_duplicate, .title = "Duplicate", .category = .file, .symbol = "plus.square.on.square", .file_scope = true, .enabled = impl.hasSelection, .run = impl.duplicate },
    .{ .id = .file_trash, .title = "Move to Trash", .category = .file, .shortcut = .{ .key = S.backspace, .cmd = true }, .symbol = "trash", .file_scope = true, .enabled = impl.hasSelection, .run = impl.trash },
    .{ .id = .file_share, .title = "Share\u{2026}", .category = .file, .symbol = "square.and.arrow.up", .file_scope = true, .in_menu = false, .enabled = impl.hasSelection, .run = impl.share },
    .{ .id = .file_reveal, .title = "Reveal in Finder", .category = .file, .symbol = "magnifyingglass", .run = impl.reveal },
    .{ .id = .file_copy_path, .title = "Copy Path", .category = .file, .shortcut = .{ .key = 'c', .cmd = true, .alt = true }, .symbol = "doc.on.clipboard", .file_scope = true, .run = impl.copyPath },
    .{ .id = .file_pin, .title = "Pin to Sidebar", .category = .file, .shortcut = .{ .key = 't', .cmd = true, .ctrl = true }, .symbol = "pin", .enabled = impl.canPin, .run = impl.pin },
    .{ .id = .file_add_favorite, .title = "Add to Favorites", .category = .file, .symbol = "star", .enabled = impl.canPin, .run = impl.addFavorite },
    // Edit
    .{ .id = .edit_undo, .title = "Undo", .category = .edit, .shortcut = .{ .key = 'z', .cmd = true }, .symbol = "arrow.uturn.backward", .file_scope = true, .enabled = impl.canUndo, .dynamic_title = impl.undoTitle, .run = impl.undo },
    .{ .id = .edit_redo, .title = "Redo", .category = .edit, .shortcut = .{ .key = 'z', .cmd = true, .shift = true }, .symbol = "arrow.uturn.forward", .file_scope = true, .enabled = impl.canRedo, .dynamic_title = impl.redoTitle, .run = impl.redo },
    .{ .id = .edit_copy, .title = "Copy", .category = .edit, .shortcut = .{ .key = 'c', .cmd = true }, .symbol = "doc.on.doc", .file_scope = true, .enabled = impl.hasSelection, .run = impl.copy },
    .{ .id = .edit_paste, .title = "Paste", .category = .edit, .shortcut = .{ .key = 'v', .cmd = true }, .symbol = "doc.on.clipboard", .file_scope = true, .enabled = impl.canPaste, .run = impl.paste },
    .{ .id = .edit_paste_move, .title = "Move Items Here", .category = .edit, .shortcut = .{ .key = 'v', .cmd = true, .alt = true }, .file_scope = true, .enabled = impl.canPaste, .run = impl.pasteMove },
    .{ .id = .edit_select_all, .title = "Select All", .category = .edit, .shortcut = .{ .key = 'a', .cmd = true }, .file_scope = true, .run = impl.selectAll },
    .{ .id = .filter_focus, .title = "Filter Folder", .category = .edit, .shortcut = .{ .key = 'f', .cmd = true }, .symbol = "magnifyingglass", .run = impl.focusFilter },
    // View
    .{ .id = .view_list, .title = "as List", .category = .view, .shortcut = .{ .key = '1', .cmd = true }, .symbol = "list.bullet", .checked = impl.isList, .run = impl.viewList },
    .{ .id = .view_column, .title = "as Columns", .category = .view, .shortcut = .{ .key = '2', .cmd = true }, .symbol = "rectangle.split.3x1", .checked = impl.isColumn, .run = impl.viewColumn },
    .{ .id = .sort_name, .title = "Sort by Name", .category = .view, .checked = impl.sortedBy(.name), .run = impl.sort(.name) },
    .{ .id = .sort_kind, .title = "Sort by Kind", .category = .view, .checked = impl.sortedBy(.kind), .run = impl.sort(.kind) },
    .{ .id = .sort_size, .title = "Sort by Size", .category = .view, .checked = impl.sortedBy(.size), .run = impl.sort(.size) },
    .{ .id = .sort_modified, .title = "Sort by Date Modified", .category = .view, .checked = impl.sortedBy(.modified), .run = impl.sort(.modified) },
    .{ .id = .sort_created, .title = "Sort by Date Created", .category = .view, .checked = impl.sortedBy(.created), .run = impl.sort(.created) },
    .{ .id = .sort_ascending, .title = "Sort Ascending", .category = .view, .checked = impl.isAscending, .run = impl.setAscending(true) },
    .{ .id = .sort_descending, .title = "Sort Descending", .category = .view, .checked = impl.isDescending, .run = impl.setAscending(false) },
    .{ .id = .sort_folders_first, .title = "Sort Folders First", .category = .view, .checked = impl.foldersFirst, .run = impl.toggleFoldersFirst },
    .{ .id = .view_hidden, .title = "Show Hidden Files", .category = .view, .shortcut = .{ .key = '.', .cmd = true, .shift = true }, .symbol = "eye.slash", .checked = impl.showsHidden, .run = impl.toggleHidden },
    .{ .id = .view_sidebar, .title = "Toggle Sidebar", .category = .view, .shortcut = .{ .key = 's', .cmd = true, .ctrl = true }, .symbol = "sidebar.left", .dynamic_title = impl.sidebarTitle, .run = impl.toggleSidebar },
    .{ .id = .view_inspector, .title = "Show Inspector", .category = .view, .shortcut = .{ .key = 'i', .cmd = true, .alt = true }, .symbol = "sidebar.right", .dynamic_title = impl.inspectorTitle, .run = impl.toggleInspector },
    .{ .id = .view_split_side, .title = "Split Side by Side", .category = .view, .shortcut = .{ .key = 'd', .cmd = true }, .symbol = "rectangle.split.2x1", .run = impl.splitSide },
    .{ .id = .view_split_stacked, .title = "Split Stacked", .category = .view, .shortcut = .{ .key = 'd', .cmd = true, .shift = true }, .symbol = "rectangle.split.1x2", .run = impl.splitStacked },
    // Cmd+K toggles; picking it from the palette itself would only reopen it.
    .{ .id = .palette_show, .title = "Command Palette\u{2026}", .category = .view, .shortcut = .{ .key = 'k', .cmd = true }, .symbol = "command", .in_palette = false, .run = impl.togglePalette },
};

const go = [_]Command{
    .{ .id = .go_back, .title = "Back", .category = .go, .shortcut = .{ .key = '[', .cmd = true }, .symbol = "chevron.left", .enabled = impl.canBack, .run = impl.back },
    .{ .id = .go_forward, .title = "Forward", .category = .go, .shortcut = .{ .key = ']', .cmd = true }, .symbol = "chevron.right", .enabled = impl.canForward, .run = impl.forward },
    .{ .id = .go_up, .title = "Enclosing Folder", .category = .go, .shortcut = .{ .key = S.up, .cmd = true }, .symbol = "arrow.up", .file_scope = true, .enabled = impl.canUp, .run = impl.up },
    .{ .id = .go_home, .title = "Go to Home", .category = .go, .shortcut = .{ .key = 'h', .cmd = true, .shift = true }, .symbol = "folder", .run = impl.place("") },
    .{ .id = .go_desktop, .title = "Go to Desktop", .category = .go, .symbol = "folder", .run = impl.place("Desktop") },
    .{ .id = .go_documents, .title = "Go to Documents", .category = .go, .symbol = "folder", .run = impl.place("Documents") },
    .{ .id = .go_downloads, .title = "Go to Downloads", .category = .go, .shortcut = .{ .key = 'l', .cmd = true, .alt = true }, .symbol = "folder", .run = impl.place("Downloads") },
    .{ .id = .go_applications, .title = "Go to Applications", .category = .go, .shortcut = .{ .key = 'a', .cmd = true, .shift = true }, .symbol = "folder", .run = impl.place("/Applications") },
    .{ .id = .go_to_folder, .title = "Go to Folder\u{2026}", .category = .go, .shortcut = .{ .key = 'g', .cmd = true, .shift = true }, .symbol = "arrow.right.circle", .run = impl.goToFolder },
    .{ .id = .tab_next, .title = "Show Next Tab", .category = .window, .shortcut = .{ .key = S.tab, .ctrl = true }, .run = impl.tabNext },
    .{ .id = .tab_prev, .title = "Show Previous Tab", .category = .window, .shortcut = .{ .key = S.tab, .ctrl = true, .shift = true }, .run = impl.tabPrev },
    .{ .id = .pane_focus_next, .title = "Focus Next Pane", .category = .window, .shortcut = .{ .key = S.right, .cmd = true, .alt = true }, .enabled = impl.manyPanes, .run = impl.focusNext },
    .{ .id = .pane_focus_prev, .title = "Focus Previous Pane", .category = .window, .shortcut = .{ .key = S.left, .cmd = true, .alt = true }, .enabled = impl.manyPanes, .run = impl.focusPrev },
};

const preset_count = pane_layout.LayoutPreset.all.len;

/// "Layout: Single" ... one command per preset, ticked while the panes have its shape.
fn layoutCommands() [preset_count]Command {
    var out: [preset_count]Command = undefined;
    for (pane_layout.LayoutPreset.all, 0..) |p, i| out[i] = .{
        .id = @field(Id, "layout_" ++ @tagName(p)),
        .title = "Layout: " ++ p.title(),
        .category = .view,
        .checked = impl.layoutIs(p),
        .run = impl.layout(p),
    };
    return out;
}

/// `file_open_with_0` ... `_7`: the context menu's app rows. They only run from there, so the menu
/// bar and the palette do not list them (the row's wording comes from the app, not the table).
fn openWithCommands() [open_with.max_apps]Command {
    var out: [open_with.max_apps]Command = undefined;
    for (&out, 0..) |*c, i| c.* = .{
        .id = @field(Id, "file_open_with_" ++ [1]u8{'0' + @as(u8, @intCast(i))}),
        .title = "Open With",
        .category = .file,
        .symbol = "app",
        .file_scope = true,
        .in_palette = false,
        .in_menu = false,
        .enabled = impl.canOpenWith(i),
        .run = impl.openWith(i),
    };
    return out;
}

/// Every command, grouped by menu (File, Edit, View, Go, Window); within View: modes, sorting,
/// hidden files, splits, then the layouts.
pub const all = static ++ openWithCommands() ++ layoutCommands() ++ go;

/// The command with this id.
pub fn find(id: Id) *const Command {
    for (&all) |*c| if (c.id == id) return c;
    unreachable; // the table has every id (tested)
}

/// The command named `name` (`@tagName(id)`, e.g. "file_new_folder"), for scripts and the palette.
pub fn byName(name: []const u8) ?*const Command {
    for (&all) |*c| if (std.mem.eql(u8, @tagName(c.id), name)) return c;
    return null;
}

/// Whether running it would do something right now.
pub fn isEnabled(m: *Model, c: *const Command) bool {
    return if (c.enabled) |f| f(m) else true;
}

pub fn isChecked(m: *Model, c: *const Command) bool {
    return if (c.checked) |f| f(m) else false;
}

/// The title as the menu shows it now ("Undo Move of 3 Items"); valid until `buf` is reused.
pub fn titleOf(m: *Model, c: *const Command, buf: []u8) []const u8 {
    return if (c.dynamic_title) |f| f(m, buf) else c.title;
}

/// Runs a command now (an action of `Model.applyPending`); one that doesn't apply does nothing.
pub fn run(m: *Model, id: Id) Allocator.Error!void {
    const c = find(id);
    if (!isEnabled(m, c)) return;
    try c.run(m);
}

/// A shortcut as menus write it: "⇧⌘N", "⌘⌫", "⌥⌘L".
pub fn shortcutLabel(buf: []u8, s: ui.Shortcut) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    labelTo(&w, s) catch return "";
    return w.buffered();
}

fn labelTo(w: *std.Io.Writer, s: ui.Shortcut) std.Io.Writer.Error!void {
    if (s.ctrl) try w.writeAll("\u{2303}");
    if (s.alt) try w.writeAll("\u{2325}");
    if (s.shift) try w.writeAll("\u{21E7}");
    if (s.cmd) try w.writeAll("\u{2318}");
    switch (s.key) {
        S.backspace => try w.writeAll("\u{232B}"),
        S.enter => try w.writeAll("\u{21A9}"),
        S.tab => try w.writeAll("\u{21E5}"),
        S.up => try w.writeAll("\u{2191}"),
        S.down => try w.writeAll("\u{2193}"),
        S.left => try w.writeAll("\u{2190}"),
        S.right => try w.writeAll("\u{2192}"),
        S.escape => try w.writeAll("\u{238B}"),
        else => {
            var enc: [4]u8 = undefined;
            const up = if (s.key < 128) std.ascii.toUpper(@intCast(s.key)) else s.key;
            const n = std.unicode.utf8Encode(@intCast(up), &enc) catch return;
            try w.writeAll(enc[0..n]);
        },
    }
}

const testing = std.testing;

test "every command id has exactly one entry" {
    for (std.enums.values(Id)) |id| {
        var n: usize = 0;
        for (&all) |*c| {
            if (c.id == id) n += 1;
        }
        try testing.expectEqual(@as(usize, 1), n);
    }
    try testing.expectEqual(std.enums.values(Id).len, all.len);
}

test "no two commands share a shortcut" {
    for (&all, 0..) |*a, i| {
        const sa = (a.shortcut orelse continue).native();
        for (all[i + 1 ..]) |*b| {
            const sb = (b.shortcut orelse continue).native();
            const same = sa.key == sb.key and sa.cmd == sb.cmd and sa.ctrl == sb.ctrl and sa.alt == sb.alt and sa.shift == sb.shift;
            try testing.expect(!same);
        }
    }
}

test "shortcut labels" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("\u{21E7}\u{2318}N", shortcutLabel(&buf, .{ .key = 'n', .cmd = true, .shift = true }));
    try testing.expectEqualStrings("\u{2318}\u{232B}", shortcutLabel(&buf, .{ .key = S.backspace, .cmd = true }));
    try testing.expectEqualStrings("\u{2325}\u{2318}L", shortcutLabel(&buf, .{ .key = 'l', .cmd = true, .alt = true }));
    try testing.expectEqualStrings("\u{21A9}", shortcutLabel(&buf, .{ .key = S.enter }));
}
