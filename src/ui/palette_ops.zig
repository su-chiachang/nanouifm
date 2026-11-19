//! The model's side of the command palette: opening and closing it (Cmd+K), answering the field's
//! text, keeping the file index in step with the sidebar's folders, and choosing a row. Run from
//! the command registry and `Model.applyPending` (the view only draws and asks).
const std = @import("std");
const Allocator = std.mem.Allocator;
const Model = @import("model.zig").Model;
const pm = @import("palette_model.zig");
const palette_rows = @import("palette_rows.zig");
const sidebar_model = @import("sidebar_model.zig");

/// Favorites' and Pinned's folders (in `a`): the index's roots beside the config's.
fn sidebarFolders(m: *Model, a: Allocator) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for ([_]sidebar_model.SectionKind{ .favorites, .pinned }) |kind| {
        for (m.sidebar.sections[@backingInt(kind)].rows.items) |r| try out.append(a, r.path);
    }
    return out.items;
}

fn refreshIndex(m: *Model, if_stale: bool) Allocator.Error!void {
    const idx = &m.view_state.palette.index;
    if (!idx.enabled) return;
    var arena = std.heap.ArenaAllocator.init(m.gpa);
    defer arena.deinit();
    try idx.refresh(try sidebarFolders(m, arena.allocator()), m.sidebar.revision, m.clock, if_stale);
}

/// The end of each pass: a new favorite or pin means new roots, crawled in the background.
pub fn sync(m: *Model) void {
    const idx = &m.view_state.palette.index;
    if (!idx.enabled or (idx.revision != null and idx.revision.? == m.sidebar.revision)) return;
    refreshIndex(m, false) catch {};
}

/// Opens the palette on an empty query (the index is crawled again if it is old).
pub fn show(m: *Model) Allocator.Error!void {
    const st = &m.view_state.palette;
    st.open = true;
    st.buf.clear();
    st.buf.focus();
    try refreshIndex(m, true);
    try requery(m);
}

pub fn close(m: *Model) void {
    m.view_state.palette.open = false;
}

pub fn toggle(m: *Model) Allocator.Error!void {
    if (m.view_state.palette.open) close(m) else try show(m);
}

/// Answers the field's text now (the old answer is retired, see `palette_model.zig`).
pub fn requery(m: *Model) Allocator.Error!void {
    const st = &m.view_state.palette;
    var fresh = try palette_rows.build(m, st.buf.text());
    errdefer fresh.deinit();
    try st.adopt(m.gpa, st.buf.text(), fresh);
    st.seen_generation = st.index.generation();
}

/// Return, Cmd+Return, Opt+Return or a click on row `row`: a command is queued like any other, a
/// folder or file goes to the focused pane (`target`). Closes the palette and returns true;
/// a header or a command that doesn't apply now does nothing and returns false.
pub fn choose(m: *Model, row: pm.Row, target: pm.OpenTarget) Allocator.Error!bool {
    if (!row.selectable()) return false;
    switch (row.kind) {
        .header => return false,
        .command => try m.queue(.{ .run_command = row.command.? }),
        .location, .file => try m.queue(.{ .palette_open = .{ .path = row.path, .is_dir = row.is_dir, .target = target } }),
    }
    close(m);
    return true;
}
