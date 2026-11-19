//! A pane's toolbar row (Swift's `PaneToolbar`): back, forward and up, the folder's name, the Sort
//! menu, the name filter field, the "..." menu (view mode, hidden files, splits) and "+" (new
//! folder). Every button focuses its pane before it acts; menus are `toolbar_menu.zig`'s. The
//! filter field edits the pane's own text (`Pane.filter`); each change queues `apply_filter`,
//! Escape clears it, Return hands the keyboard back to the list, and Cmd+F (`focus_filter` on the
//! view state) takes it.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const model_mod = @import("model.zig");
const Model = model_mod.Model;
const Action = model_mod.Action;
const Pane = @import("pane.zig").Pane;
const style = @import("style.zig");
const toolbar_menu = @import("toolbar_menu.zig");

/// What a pane `w` points wide has room for: the row gives up the folder's name, Up, Back and
/// Forward, then "+" (New Folder is in the "..." menu too), as the pane narrows, and keeps Sort,
/// the filter field and "...". The numbers are the buttons' widths (30), the gaps (4) and the
/// row's padding (24): all of it takes 232 points and the field, the name gets what is left.
const Tier = struct {
    nav: bool,
    up: bool,
    title: bool,
    plus: bool,
    /// The filter field's width.
    filter: f32,

    fn of(w: f32) Tier {
        if (w >= 520) return .{ .nav = true, .up = true, .title = true, .plus = true, .filter = 150 };
        if (w >= 330) return .{ .nav = true, .up = true, .title = false, .plus = true, .filter = std.math.clamp(w - 228, 100, 160) };
        if (w >= 280) return .{ .nav = true, .up = false, .title = false, .plus = true, .filter = std.math.clamp(w - 194, 86, 130) };
        if (w >= 200) return .{ .nav = false, .up = false, .title = false, .plus = true, .filter = w - 126 };
        return .{ .nav = false, .up = false, .title = false, .plus = false, .filter = @max(60, w - 92) };
    }
};

/// The toolbar of `pane`, `w` points wide.
pub fn view(c: *ui.Context, m: *Model, pane: *Pane, w: f32) void {
    const th = c.theme;
    const tab = pane.tab();
    const tier = Tier.of(w);
    const bar = ui.div(c).row().wFull().h(style.toolbar_height).px(style.pad).gap(4).itemsCenter();
    defer bar.end();
    if (tier.nav) {
        if (style.iconButton(c, "back", "chevron.left", tab.canBack(), false)) act(c, m, pane, .back);
        if (style.iconButton(c, "forward", "chevron.right", tab.canForward(), false)) act(c, m, pane, .forward);
    }
    if (tier.up and style.iconButton(c, "up", "chevron.up", std.fs.path.dirname(tab.path()) != null, false)) act(c, m, pane, .up);
    if (tier.title) {
        const t = ui.div(c).row().grow().minW(0).px(6).gap(6).itemsCenter().clip();
        defer t.end();
        ui.icon(c, "folder.fill", .{ .size = 14, .frame = 16, .color = th.accent });
        ui.text(c, tab.title(), .{ .size = 14, .weight = .semibold, .truncate = .ellipsis });
    } else {
        ui.spacer(c); // sort, filter and "..." stay at the right
    }
    toolbar_menu.button(c, m, pane.id, .sort, "sort", "arrow.up.arrow.down", !std.meta.eql(pane.sort, .{}));
    filterField(c, m, pane, tier.filter);
    toolbar_menu.button(c, m, pane.id, .more, "more", "ellipsis", false);
    if (tier.plus and style.iconButton(c, "new-folder", "folder.badge.plus", true, false)) {
        act(c, m, pane, .{ .run_command = .file_new_folder });
    }
}

/// Queues `a` for this pane: it gets the focus first.
fn act(c: *ui.Context, m: *Model, pane: *const Pane, a: Action) void {
    style.post(c, m, .{ .focus_pane = pane.id });
    style.post(c, m, a);
}

fn filterField(c: *ui.Context, m: *Model, pane: *Pane, width: f32) void {
    const th = c.theme;
    const buf = &pane.filter.buf;
    ui.key(c, "filter");
    const box = ui.div(c).row().w(width).h(26).px(7).gap(5).itemsCenter().rounded(6).bg(th.background).border(th.border);
    defer box.end();
    ui.icon(c, "magnifyingglass", .{ .size = 11, .weight = .medium, .color = th.muted });
    if (m.view_state.focus_filter == pane.id) { // Cmd+F
        m.view_state.focus_filter = null;
        buf.want_caret = null;
        buf.want_selection = .{ 0, buf.text().len };
        buf.focus();
        style.post(c, m, .{ .focus_pane = pane.id });
    }
    const r = ui.textField(c, buf, .{ .bare = true, .width = .fill, .size = 12, .placeholder = "Filter" });
    if (r.focused) c.node(box.index).style.border = th.accent;
    if (r.changed) act(c, m, pane, .{ .apply_filter = pane.id });
    if (r.submitted) c.focus = 0; // the keyboard goes back to the list
    if (r.focused and c.shortcut(.{ .key = ui.Shortcut.escape })) {
        buf.clear();
        c.focus = 0;
        act(c, m, pane, .{ .apply_filter = pane.id });
    }
    if (buf.text().len > 0) {
        ui.key(c, "filter-clear");
        const x = ui.div(c).w(14).h(14).center().rounded(7).control();
        defer x.end();
        ui.icon(c, "xmark.circle.fill", .{ .size = 11, .color = th.muted });
        if (x.clicked()) {
            buf.clear();
            act(c, m, pane, .{ .apply_filter = pane.id });
        }
    }
}
