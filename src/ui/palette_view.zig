//! The command palette drawn (Cmd+K): a panel floating over a scrim, near the top and centred,
//! with the search field, the sectioned rows, and a footer with the keys. Drawn last, over
//! everything. The keys it answers while open: Up and Down (they wrap), Return, Cmd+Return and
//! Opt+Return, Escape; everything else typed goes to the field, whose text is answered by
//! `palette_ops.requery` before the rows are drawn. The model's side is `palette_ops.zig`.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const kit = nanoui.kit;
const motion = ui.motion;
const Model = @import("model.zig").Model;
const pm = @import("palette_model.zig");
const palette_ops = @import("palette_ops.zig");
const style = @import("style.zig");

const S = ui.Shortcut;

pub const panel_width: f32 = 660;
/// Over every popover (20) and tooltip (30).
const layer_scrim = 40;
const layer_panel = 41;
const row_h: f32 = 32;
const field_h: f32 = 54;
const footer_h: f32 = 36;
const list_pad: f32 = 4;
const max_list_h: f32 = 372;

pub fn view(c: *ui.Context, m: *Model) void {
    const st = &m.view_state.palette;
    const t = kit.tokens(c);
    if (st.open and c.shortcut(.{ .key = S.escape })) {
        palette_ops.close(m);
        c.changed = true;
    }
    const f = motion.present(c, "palette", st.open, .{
        .initial = .{ .opacity = 0, .scale = 0.97, .y = -6 },
        .exit = .{ .opacity = 0, .scale = 0.98 },
        .transition = .{ .spring = motion.Spring.snappy },
    }) orelse return;
    const scrim = ui.div(c).fixed().w(c.size.w).h(c.size.h).layer(layer_scrim).bg(t.overlay.alpha(0.5)).motion(f);
    if (scrim.interaction().clicked and st.open) {
        palette_ops.close(m);
        c.changed = true;
    }
    scrim.end();

    const w = @min(panel_width, c.size.w - 32);
    const top = @min(160, c.size.h * 0.18);
    ui.key(c, "palette-panel");
    const panel = ui.div(c).fixed().offset((c.size.w - w) / 2, top).w(w).layer(layer_panel).column()
        .rounded(14).bg(t.popover).border(t.border).shadow(.{ .color = t.shadow.alpha(1), .blur = 40, .y = 16 }).clip().motion(f);
    defer panel.end();
    _ = panel.interaction(); // a click inside is not a click on the scrim

    const submitted = field(c, m);
    // The answer follows the text, and a crawl that finished.
    if (st.open and (!std.mem.eql(u8, st.buf.text(), st.query) or st.index.generation() != st.seen_generation)) {
        palette_ops.requery(m) catch {};
    }
    if (st.open) keys(c, m, submitted);
    ui.divider(c);
    list(c, m, top);
    ui.divider(c);
    footer(c, m);
}

/// The field; true when Return was pressed in it.
fn field(c: *ui.Context, m: *Model) bool {
    const t = kit.tokens(c);
    const st = &m.view_state.palette;
    const bar = ui.div(c).row().wFull().h(field_h).px(18).gap(10).itemsCenter();
    defer bar.end();
    ui.icon(c, "magnifyingglass", .{ .size = 16, .weight = .medium, .color = t.muted });
    const r = ui.textField(c, &st.buf, .{ .bare = true, .width = .fill, .size = 17, .placeholder = "Search commands, files, and folders" });
    return r.submitted and st.open;
}

fn target(c: *ui.Context) pm.OpenTarget {
    return if (c.input.cmd) .new_tab else if (c.input.alt) .split else .here;
}

/// Chooses the highlighted row; the palette closes if something was chosen.
fn pick(c: *ui.Context, m: *Model, to: pm.OpenTarget) void {
    const row = m.view_state.palette.selectedRow() orelse return;
    if (palette_ops.choose(m, row, to) catch false) {
        c.focus = 0;
        c.changed = true;
    }
}

fn keys(c: *ui.Context, m: *Model, submitted: bool) void {
    const st = &m.view_state.palette;
    if (c.shortcut(.{ .key = S.up })) st.move(-1);
    if (c.shortcut(.{ .key = S.down })) st.move(1);
    if (c.shortcut(.{ .key = S.enter, .cmd = true })) return pick(c, m, .new_tab);
    if (c.shortcut(.{ .key = S.enter, .alt = true })) return pick(c, m, .split);
    if (c.shortcut(.{ .key = S.enter })) return pick(c, m, .here);
    if (submitted) pick(c, m, .here);
}

fn list(c: *ui.Context, m: *Model, top: f32) void {
    const t = kit.tokens(c);
    const st = &m.view_state.palette;
    const rows = st.rows();
    const max_h = std.math.clamp(c.size.h - top - field_h - footer_h - 40, 96, max_list_h);
    const want_h = @as(f32, @floatFromInt(rows.len)) * row_h + 2 * list_pad;
    const area = ui.div(c).column().wFull().h(@min(max_h, @max(want_h, 64))).clip();
    defer area.end();
    if (rows.len == 0) {
        const none = ui.div(c).sizeFull().center();
        defer none.end();
        ui.text(c, "No results", .{ .size = 13, .color = t.muted });
        return;
    }
    ui.key(c, "palette-list");
    const list_id = c.peekId(null);
    var scroll_to: ?f32 = null;
    if (st.reveal) {
        st.reveal = false;
        if (st.selected) |s| scroll_to = style.revealOffset(c, list_id, s, row_h, list_pad);
        if (st.selected == null or st.selected.? == 1) scroll_to = scroll_to orelse 0; // keep the first header in sight
    }
    var lst = ui.list(c, .{ .count = rows.len, .row_height = row_h, .padding = .{ .left = 8, .right = 8, .top = list_pad, .bottom = list_pad }, .scroll_to = scroll_to });
    while (lst.next()) |i| {
        const row = rows[i];
        if (row.kind == .header) {
            header(c, row.title);
            continue;
        }
        if (rowView(c, row, st.selected == i)) {
            if (palette_ops.choose(m, row, target(c)) catch false) {
                c.focus = 0;
                c.changed = true;
            }
        }
    }
    lst.end();
}

fn header(c: *ui.Context, title: []const u8) void {
    const h = ui.div(c).row().wFull().h(row_h).px(10).pb(4).itemsEnd();
    defer h.end();
    ui.text(c, title, .{ .size = 11, .weight = .semibold, .color = c.theme.muted });
}

/// One row; true when it was clicked.
fn rowView(c: *ui.Context, row: pm.Row, selected: bool) bool {
    const th = c.theme;
    var r = ui.div(c).row().wFull().h(row_h).px(10).gap(10).itemsCenter().rounded(8).control();
    r = if (selected) r.bg(th.accent) else if (row.enabled) r.hover(th.surface_hover) else r;
    defer r.end();
    if (!row.enabled) c.node(r.index).style.opacity = 0.42;
    const fg: ui.Color = if (selected) th.accent_text else th.text;
    const dim: ui.Color = if (selected) th.accent_text.alpha(0.8) else th.muted;
    const accent: ui.Color = if (selected) th.accent_text else if (row.kind == .command) th.muted else th.accent;
    ui.icon(c, row.icon, .{ .size = 14, .frame = 20, .color = accent });
    ui.text(c, row.title, .{ .size = 13.5, .weight = .medium, .color = fg, .truncate = .ellipsis });
    {
        const sub = ui.div(c).row().grow().minW(0).clip();
        defer sub.end();
        ui.text(c, row.subtitle, .{ .size = 12, .color = dim, .truncate = .middle });
    }
    if (row.shortcut.len > 0) ui.text(c, row.shortcut, .{ .size = 11.5, .mono = true, .color = dim });
    return row.enabled and r.clicked();
}

fn footer(c: *ui.Context, m: *Model) void {
    const t = kit.tokens(c);
    const idx = &m.view_state.palette.index;
    const bar = ui.div(c).row().wFull().h(footer_h).px(16).gap(14).itemsCenter();
    defer bar.end();
    hint(c, "\u{21A9}", "Open");
    hint(c, "\u{2318}\u{21A9}", "New Tab");
    hint(c, "\u{2325}\u{21A9}", "Split");
    ui.spacer(c);
    if (idx.enabled) {
        const text = if (idx.isBuilding() and idx.entryCount() == 0) "Indexing files\u{2026}" else c.print("{d} files indexed", .{idx.entryCount()});
        ui.text(c, text, .{ .size = 11, .color = t.muted.alpha(0.8) });
    }
    hint(c, "esc", "Close");
}

fn hint(c: *ui.Context, key: []const u8, label: []const u8) void {
    const t = kit.tokens(c);
    ui.key(c, key);
    const h = ui.div(c).row().gap(6).itemsCenter();
    defer h.end();
    {
        const cap = ui.div(c).row().px(5).py(1).rounded(4).border(t.border).itemsCenter();
        defer cap.end();
        ui.text(c, key, .{ .size = 11, .weight = .medium, .color = t.muted });
    }
    ui.text(c, label, .{ .size = 11.5, .color = t.muted });
}
