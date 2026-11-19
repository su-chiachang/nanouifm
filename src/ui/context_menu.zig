//! The context menu of the list and the columns, on an item and on empty space (Swift's
//! `ContextMenus.make`), drawn with nanoui's `kit.menu` at the pointer. Every entry is a
//! registry command (`commands.zig`), so titles, shortcut labels, enabled and checked states
//! come from there, and choosing one queues `Action.run_command` like the keyboard does.
//!
//! A right-click (or Control-click) on a row selects it first when it isn't selected, then opens
//! the item menu; on the empty part of the list it opens the folder's menu. "Open With" is flat rows
//! ("Open With Preview (default)", "Open With TextEdit", ...: kit menus have no submenus) for a single
//! selected file, from `open_with.zig`; until the apps are known, and for folders and several
//! items, the one row "Open With Default App" stays.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const kit = nanoui.kit;
const Model = @import("model.zig").Model;
const commands = @import("commands.zig");
const Id = commands.Id;
const style = @import("style.zig");
const open_with = @import("open_with.zig");
const target = @import("file_target.zig");

pub const State = struct {
    open: bool = false,
    /// Where the pointer was, in window points.
    x: f32 = 0,
    y: f32 = 0,
    /// The pane the menu belongs to.
    pane: u32 = 0,
    /// Right-clicked on an item (otherwise on empty space).
    on_item: bool = false,
    /// A row took this pass's right-click: the list around it doesn't also ask.
    claimed: bool = false,
};

/// One menu line: a command (with its own wording if `label` is set), or a separator.
pub const Line = struct {
    id: ?Id = null,
    label: ?[]const u8 = null,
    danger: bool = false,
    icon: ?[]const u8 = null,
};

pub const sep: Line = .{};

pub const item_lines = [_]Line{
    .{ .id = .file_open },
    .{ .id = .file_open_new_tab },
    .{ .id = .file_open_split },
    .{ .id = .file_open_down, .label = "Open With Default App", .icon = "app.badge" },
    .{ .id = .file_quick_look },
    sep,
    .{ .id = .file_rename },
    .{ .id = .file_duplicate },
    .{ .id = .edit_copy },
    .{ .id = .file_copy_path },
    sep,
    .{ .id = .file_trash, .danger = true },
    sep,
    .{ .id = .file_reveal },
    .{ .id = .file_pin },
    sep,
    .{ .id = .file_new_folder },
    .{ .id = .view_hidden },
};

pub const space_lines = [_]Line{
    .{ .id = .file_open_new_tab },
    .{ .id = .file_open_split },
    .{ .id = .edit_paste },
    .{ .id = .file_copy_path },
    .{ .id = .file_reveal },
    .{ .id = .file_pin },
    sep,
    .{ .id = .file_new_folder },
    .{ .id = .view_hidden },
    sep,
    .{ .id = .view_list },
    .{ .id = .view_column },
};

/// Opens the menu at the pointer for pane `pane_id`. The caller has already selected the row.
pub fn openAt(c: *ui.Context, m: *Model, pane_id: u32, on_item: bool) void {
    m.view_state.ctx_menu = .{ .open = true, .x = c.input.mouse.x, .y = c.input.mouse.y, .pane = pane_id, .on_item = on_item, .claimed = true };
    c.changed = true;
}

/// A right-click on the list's empty space (called after its rows, which claim their own).
pub fn emptySpaceClicked(c: *ui.Context, m: *Model, pane_id: u32, asked: bool) void {
    if (!asked or m.view_state.ctx_menu.claimed) return;
    style.post(c, m, .{ .focus_pane = pane_id });
    openAt(c, m, pane_id, false);
}

/// The menu entries of `lines` (frame memory), and the command each one runs: titles, shortcut
/// labels, enabled and checked states all come from the registry.
pub const Built = struct { items: []kit.MenuItem, ids: []?Id };

pub fn build(c: *ui.Context, m: *Model, lines: []const Line) ?Built {
    const items = c.alloc().alloc(kit.MenuItem, lines.len) catch return null;
    const ids = c.alloc().alloc(?Id, lines.len) catch return null;
    var tbuf: [96]u8 = undefined;
    for (lines, items, ids[0..]) |ln, *it, *id| {
        id.* = ln.id;
        const cmd = commands.find(ln.id orelse {
            it.* = .{ .separator = true };
            continue;
        });
        const title = ln.label orelse commands.titleOf(m, cmd, &tbuf);
        var sc: [24]u8 = undefined;
        it.* = .{
            .label = c.alloc().dupe(u8, title) catch title,
            .icon = ln.icon orelse cmd.symbol,
            .shortcut = if (cmd.shortcut) |s| c.alloc().dupe(u8, commands.shortcutLabel(&sc, s)) catch "" else "",
            .danger = ln.danger,
            .disabled = !commands.isEnabled(m, cmd),
            .checked = if (cmd.checked != null) commands.isChecked(m, cmd) else null,
        };
        // "Open With Default App" shows no shortcut of its own.
        if (ln.label != null) it.shortcut = "";
    }
    return .{ .items = items, .ids = ids };
}

const open_with_ids = [open_with.max_apps]Id{ .file_open_with_0, .file_open_with_1, .file_open_with_2, .file_open_with_3, .file_open_with_4, .file_open_with_5, .file_open_with_6, .file_open_with_7 };

/// `item_lines` with "Open With Default App" replaced by one row per app that can open the pane's
/// single selected file (the default first, marked), once the apps are known. Asks for them
/// (`open_with.ask`: looked up at the next pass, the menu does not wait) while they are not.
fn itemLines(c: *ui.Context, m: *Model, pane_id: u32) []const Line {
    const pane = &m.panes.items[m.paneIndex(pane_id) orelse return &item_lines];
    const it = target.single(pane) orelse return &item_lines;
    if (it.is_directory) return &item_lines;
    if (open_with.ask(m, it.path) catch false) c.changed = true;
    const apps = open_with.appsFor(m, it.path) orelse return &item_lines;
    if (apps.len == 0) return &item_lines;
    const out = c.alloc().alloc(Line, item_lines.len - 1 + apps.len) catch return &item_lines;
    var n: usize = 0;
    for (item_lines) |ln| {
        if (ln.id != null and ln.id.? == .file_open_down) {
            for (apps, 0..) |app, i| {
                out[n] = .{
                    .id = open_with_ids[i],
                    .label = c.print("Open With {s}{s}", .{ app.name, if (i == 0) " (default)" else "" }),
                    .icon = "app",
                };
                n += 1;
            }
        } else {
            out[n] = ln;
            n += 1;
        }
    }
    return out[0..n];
}

/// The menu, drawn over everything while it is open (called once, last, by the panes view).
pub fn view(c: *ui.Context, m: *Model) void {
    const st = &m.view_state.ctx_menu;
    const lines: []const Line = if (!st.on_item) &space_lines else if (st.open) itemLines(c, m, st.pane) else &item_lines;
    const built = build(c, m, lines) orelse return;
    const items = built.items;
    const ids = built.ids;
    const anchor: ui.Rect = .{ .x = st.x, .y = st.y - 6, .w = 0, .h = 0 };
    const p = kit.popover(c, "ctx-menu", &st.open, anchor, .{ .placement = .bottom_start, .width = menu_width, .padding = 5 }) orelse return;
    defer p.end();
    const chosen = rows(c, items) orelse return;
    st.open = false;
    c.changed = true;
    if (ids[chosen]) |id| {
        style.post(c, m, .{ .focus_pane = st.pane });
        style.post(c, m, .{ .run_command = id });
    }
}

const menu_width: f32 = 244;
const row_h: f32 = 26;

/// The menu's rows (`kit.menu`'s look at a tighter pitch), in a box that scrolls when the window
/// is too short for all of them. The index of the row chosen.
pub fn rows(c: *ui.Context, items: []const kit.MenuItem) ?usize {
    const t = kit.tokens(c);
    var chosen: ?usize = null;
    const checks = for (items) |it| {
        if (it.checked != null) break true;
    } else false;
    const body = ui.div(c).column().wFull().gap(0).maxH(@max(120, c.size.h - 28)).scrollY().scrollBarIdle(1.5);
    defer body.end();
    for (items, 0..) |it, i| {
        ui.key(c, c.print("mi-{d}", .{i}));
        if (it.separator) {
            const sp = ui.div(c).wFull().py(3);
            defer sp.end();
            _ = c.leaf(.{ .width = .fill, .height = .{ .px = 1 }, .background = t.border }, .none, null);
            continue;
        }
        const row = ui.div(c).row().wFull().gap(8).px(8).h(row_h).itemsCenter().rounded(t.radius - 2).control();
        const ix = row.interaction();
        const live = !it.disabled;
        if (live and ix.hovered) c.node(row.index).style.background = if (it.danger) t.danger.alpha(0.12) else t.surface_hover;
        if (!live) c.node(row.index).style.opacity = 0.45;
        defer row.end();
        const fg = if (it.danger) t.danger else t.foreground;
        if (checks) { // room for a check mark in every row once any row can have one
            const box = ui.div(c).w(14).center();
            defer box.end();
            if (it.checked orelse false) ui.icon(c, "checkmark", .{ .size = 11, .weight = .semibold, .color = fg });
        }
        if (it.icon.len > 0) ui.icon(c, it.icon, .{ .size = 13, .frame = 16, .color = if (it.danger) t.danger else t.muted });
        {
            // The label takes the room the shortcut leaves and is cut with an ellipsis (an app's name can be long).
            const lab = ui.div(c).row().grow().minW(0).clip();
            defer lab.end();
            ui.text(c, it.label, .{ .size = 13, .color = fg, .truncate = .ellipsis });
        }
        if (it.shortcut.len > 0) ui.text(c, it.shortcut, .{ .size = 11.5, .color = t.muted });
        if (live and ix.clicked) chosen = i;
    }
    return chosen;
}
