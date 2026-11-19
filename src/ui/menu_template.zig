//! The menu bar as a template, generated from the command registry (`commands.zig`) and the model:
//! a pure function (`build`), so it is tested without a window. App (nanoui's standard role:
//! About, Hide, Quit), File, Edit, View (with the Sort By and Layout submenus), Go and Window
//! (Minimize, Zoom, the tab and pane commands, Bring All to Front). Every item is a registry
//! command: its title (Undo and Redo name what they undo), accelerator, enabled state and check
//! mark come from the registry and the model, and clicking one queues `Action.run_command`, as the
//! keyboard does. Which of the menu and the view takes a key is `menu_link.zig`'s rule.
//!
//! The order and grouping of the menus is the `*_menu` tables below; a test checks that every
//! command the registry lists in the menu (`Command.in_menu`) appears exactly once.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const Allocator = std.mem.Allocator;
const Model = @import("model.zig").Model;
const commands = @import("commands.zig");
const Command = commands.Command;
const Id = commands.Id;
const menu_link = @import("menu_link.zig");

pub const Item = nanoui.MenuItem;
const S = ui.Shortcut;

/// What a menu click reaches: the model.
pub const Host = struct {
    m: *Model,

    /// A menu item (by its id, a command's name) was chosen: queue the command and wake a frame.
    /// A file command waits while a text field has the keyboard, as its key does.
    pub fn run(self: *Host, name: []const u8) bool {
        const cmd = commands.byName(name) orelse return false;
        if (cmd.file_scope and self.m.text_focus) return false;
        self.m.queue(.{ .run_command = cmd.id }) catch return false;
        if (self.m.waker) |w| w.wake(w.ctx);
        return true;
    }
};

fn clicked(h: *Host, it: *nanoui.menu.Item) void {
    _ = h.run(it.id);
}

/// A menu is about to show: its items' state is brought up to date first.
fn opened(h: *Host, _: *nanoui.menu.Item) void {
    h.m.menu.refresh();
}

/// A shortcut as nanoui's accelerators write it ("Cmd+Shift+N", "Cmd+Backspace", "Cmd+Alt+Right").
pub fn accelerator(buf: []u8, s: ui.Shortcut) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    writeAccelerator(&w, s) catch return "";
    return w.buffered();
}

fn writeAccelerator(w: *std.Io.Writer, s: ui.Shortcut) std.Io.Writer.Error!void {
    if (s.cmd) try w.writeAll("Cmd+");
    if (s.ctrl) try w.writeAll("Ctrl+");
    if (s.alt) try w.writeAll("Alt+");
    if (s.shift) try w.writeAll("Shift+");
    const name: ?[]const u8 = switch (s.key) {
        S.backspace => "Backspace",
        S.enter => "Enter",
        S.tab => "Tab",
        S.up => "Up",
        S.down => "Down",
        S.left => "Left",
        S.right => "Right",
        S.escape => "Escape",
        else => null,
    };
    if (name) |n| return w.writeAll(n);
    var enc: [4]u8 = undefined;
    const up: u21 = if (s.key < 128) std.ascii.toUpper(@intCast(s.key)) else s.key; // "Cmd+Shift+H"; parsed back lowercase
    const n = std.unicode.utf8Encode(up, &enc) catch return;
    try w.writeAll(enc[0..n]);
}

/// What an item shows of the model.
pub const ItemState = struct { enabled: bool, checked: bool };

pub fn stateOf(m: *Model, cmd: *const Command) ItemState {
    return .{ .enabled = commands.isEnabled(m, cmd), .checked = commands.isChecked(m, cmd) };
}

/// One line of a menu table.
const Spec = union(enum) {
    cmd: Id,
    sep,
    role: nanoui.MenuRole,
    /// A submenu of the commands whose names start with `prefix`, titled without `strip`; a
    /// separator goes before each of `breaks`.
    sub: struct { label: []const u8, prefix: []const u8, strip: []const []const u8, breaks: []const Id = &.{} },
};

const file_menu = [_]Spec{
    .{ .cmd = .tab_new },         .{ .cmd = .tab_close },       .{ .cmd = .pane_close }, .sep,
    .{ .cmd = .file_new_folder }, .sep,                         .{ .cmd = .file_open },  .{ .cmd = .file_open_new_tab },
    .{ .cmd = .file_open_split }, .{ .cmd = .file_quick_look }, .sep,                    .{ .cmd = .file_rename },
    .{ .cmd = .file_duplicate },  .{ .cmd = .file_trash },      .sep,                    .{ .cmd = .file_reveal },
    .{ .cmd = .file_copy_path },  .sep,                         .{ .cmd = .file_pin },   .{ .cmd = .file_add_favorite },
};

const edit_menu = [_]Spec{
    .{ .cmd = .edit_undo },       .{ .cmd = .edit_redo },  .sep,
    .{ .cmd = .edit_copy },       .{ .cmd = .edit_paste }, .{ .cmd = .edit_paste_move },
    .{ .cmd = .edit_select_all }, .sep,                    .{ .cmd = .filter_focus },
};

const view_menu = [_]Spec{
    .{ .cmd = .view_list },                                                           .{ .cmd = .view_column },
    .sep,                                                                             .{ .sub = .{ .label = "Sort By", .prefix = "sort_", .strip = &.{ "Sort by ", "Sort " }, .breaks = &.{ .sort_ascending, .sort_folders_first } } },
    .sep,                                                                             .{ .cmd = .view_hidden },
    .{ .cmd = .view_sidebar },                                                        .sep,
    .{ .cmd = .view_split_side },                                                     .{ .cmd = .view_split_stacked },
    .{ .sub = .{ .label = "Layout", .prefix = "layout_", .strip = &.{"Layout: "} } }, .sep,
    .{ .cmd = .palette_show },
};

const go_menu = [_]Spec{
    .{ .cmd = .go_back },      .{ .cmd = .go_forward },   .{ .cmd = .go_up },
    .sep,                      .{ .cmd = .go_home },      .{ .cmd = .go_desktop },
    .{ .cmd = .go_documents }, .{ .cmd = .go_downloads }, .{ .cmd = .go_applications },
    .sep,                      .{ .cmd = .go_to_folder },
};

const window_menu = [_]Spec{
    .{ .role = .minimize },       .{ .role = .zoom },
    .sep,                         .{ .cmd = .tab_next },
    .{ .cmd = .tab_prev },        .{ .cmd = .pane_focus_next },
    .{ .cmd = .pane_focus_prev }, .sep,
    .{ .role = .front },
};

/// Radio items: exactly one of their run is ticked. (The others with a check are plain toggles.)
fn isRadio(id: Id) bool {
    const n = @tagName(id);
    return (std.mem.startsWith(u8, n, "sort_") and id != .sort_folders_first) or std.mem.startsWith(u8, n, "layout_") or id == .view_list or id == .view_column;
}

const Builder = struct {
    a: Allocator,
    m: *Model,
    host: *Host,

    fn command(self: Builder, id: Id, strip: []const []const u8) Allocator.Error!Item {
        const cmd = commands.find(id);
        var tbuf: [128]u8 = undefined;
        var title: []const u8 = commands.titleOf(self.m, cmd, &tbuf);
        for (strip) |p| if (std.mem.startsWith(u8, title, p)) {
            title = title[p.len..];
            break;
        };
        var abuf: [48]u8 = undefined;
        const accel = if (menu_link.ownsKey(cmd)) accelerator(&abuf, cmd.shortcut.?) else "";
        const st = stateOf(self.m, cmd);
        return .{
            .id = @tagName(id),
            .label = try self.a.dupe(u8, title),
            .accelerator = try self.a.dupe(u8, accel),
            .kind = if (cmd.checked == null) .normal else if (isRadio(id)) .radio else .checkbox,
            .checked = st.checked,
            .disabled = !st.enabled,
            .click = nanoui.MenuClick.of(self.host, clicked),
        };
    }

    fn table(self: Builder, specs: []const Spec) Allocator.Error![]const Item {
        var out: std.ArrayList(Item) = .empty;
        for (specs) |sp| switch (sp) {
            .cmd => |id| try out.append(self.a, try self.command(id, &.{})),
            .sep => try out.append(self.a, Item.separator),
            .role => |r| try out.append(self.a, .{ .role = r }),
            .sub => |s| {
                var kids: std.ArrayList(Item) = .empty;
                for (&commands.all) |*c| {
                    if (!std.mem.startsWith(u8, @tagName(c.id), s.prefix)) continue;
                    if (std.mem.indexOfScalar(Id, s.breaks, c.id) != null) try kids.append(self.a, Item.separator);
                    try kids.append(self.a, try self.command(c.id, s.strip));
                }
                try out.append(self.a, .{ .label = s.label, .submenu = kids.items });
            },
        };
        return out.items;
    }

    fn top(self: Builder, label: []const u8, specs: []const Spec) Allocator.Error!Item {
        return .{ .label = label, .submenu = try self.table(specs), .on_open = nanoui.MenuClick.of(self.host, opened) };
    }
};

/// The menu bar for the model as it is now. Everything is allocated in `a` (an arena, freed once
/// the menu has been built from it); `host` must outlive the menu.
pub fn build(a: Allocator, m: *Model, host: *Host) Allocator.Error![]const Item {
    const b: Builder = .{ .a = a, .m = m, .host = host };
    return a.dupe(Item, &.{
        .{ .role = .app_menu },
        try b.top("File", &file_menu),
        try b.top("Edit", &edit_menu),
        try b.top("View", &view_menu),
        try b.top("Go", &go_menu),
        .{ .role = .window_menu, .label = "Window", .submenu = try b.table(&window_menu) },
    });
}
