//! The rows the palette shows for a query. Empty: the sidebar's Favorites, then Pinned, then
//! every palette command in menu order. Typed: the Favorites and Pinned whose names fuzzy-match,
//! the commands whose titles do (best first, ties in menu order), then the indexed files and
//! folders (the index's own order, which is by score), sectioned and without repeats. Commands that
//! don't apply now are listed too, flagged `enabled = false`. Everything is copied into the
//! answer's arena, so it is freed in one go (see `palette_model.zig`).
const std = @import("std");
const Allocator = std.mem.Allocator;
const Model = @import("model.zig").Model;
const commands = @import("commands.zig");
const fuzzy = @import("../core/fuzzy.zig");
const search_index = @import("../core/search_index.zig");
const sidebar_model = @import("sidebar_model.zig");
const pm = @import("palette_model.zig");
const Row = pm.Row;

/// Most command rows a typed query shows.
pub const max_commands: usize = 20;

/// "~/Documents" for a path under Home, else the path itself (in `a`).
pub fn abbreviate(a: Allocator, home: []const u8, path: []const u8) Allocator.Error![]const u8 {
    if (std.mem.eql(u8, path, home)) return "~";
    if (home.len > 0 and std.mem.startsWith(u8, path, home) and path.len > home.len and path[home.len] == '/') {
        return std.mem.concat(a, u8, &.{ "~", path[home.len..] });
    }
    return path;
}

fn parentOf(path: []const u8) []const u8 {
    return std.fs.path.dirname(path) orelse path;
}

const Builder = struct {
    m: *Model,
    a: Allocator,
    rows: std.ArrayList(Row) = .empty,

    fn header(b: *Builder, title: []const u8) Allocator.Error!void {
        try b.rows.append(b.a, .{ .kind = .header, .title = title });
    }

    fn place(b: *Builder, r: sidebar_model.Row) Allocator.Error!void {
        const path = try b.a.dupe(u8, r.path);
        try b.rows.append(b.a, .{
            .kind = .location,
            .title = try b.a.dupe(u8, r.title),
            .subtitle = try abbreviate(b.a, b.m.home, parentOf(path)),
            .path = path,
            .icon = r.icon,
            .is_dir = true,
        });
    }

    fn command(b: *Builder, cmd: *const commands.Command) Allocator.Error!void {
        var tbuf: [128]u8 = undefined;
        var sbuf: [32]u8 = undefined;
        try b.rows.append(b.a, .{
            .kind = .command,
            .title = try b.a.dupe(u8, commands.titleOf(b.m, cmd, &tbuf)),
            .subtitle = categoryName(cmd.category),
            .shortcut = if (cmd.shortcut) |s| try b.a.dupe(u8, commands.shortcutLabel(&sbuf, s)) else "",
            .icon = if (cmd.symbol.len > 0) cmd.symbol else "command",
            .command = cmd.id,
            .enabled = commands.isEnabled(b.m, cmd),
        });
    }

    fn hit(b: *Builder, h: search_index.SearchHit) Allocator.Error!void {
        const path = try b.a.dupe(u8, h.path);
        try b.rows.append(b.a, .{
            .kind = .file,
            .title = path[path.len - h.name.len ..],
            .subtitle = try abbreviate(b.a, b.m.home, parentOf(path)),
            .path = path,
            .icon = if (h.is_directory) "folder.fill" else "doc",
            .is_dir = h.is_directory,
        });
    }
};

fn categoryName(c: commands.Category) []const u8 {
    return switch (c) {
        .file => "File",
        .edit => "Edit",
        .view => "View",
        .go => "Go",
        .window => "Window",
    };
}

const Scored = struct { score: i64, index: usize };

fn byScore(_: void, x: Scored, y: Scored) bool {
    return x.score > y.score;
}

/// The sidebar's Favorites rows, then Pinned.
fn sidebarPlaces(m: *Model, a: Allocator) Allocator.Error![]const sidebar_model.Row {
    const fav = m.sidebar.sections[@backingInt(sidebar_model.SectionKind.favorites)].rows.items;
    const pin = m.sidebar.sections[@backingInt(sidebar_model.SectionKind.pinned)].rows.items;
    return std.mem.concat(a, sidebar_model.Row, &.{ fav, pin });
}

/// The answer to `query_in` (trimmed). Free with `Results.deinit`, or hand to `State.adopt`.
pub fn build(m: *Model, query_in: []const u8) Allocator.Error!pm.Results {
    const query = std.mem.trim(u8, query_in, " \t");
    var arena = std.heap.ArenaAllocator.init(m.gpa);
    errdefer arena.deinit();
    var b: Builder = .{ .m = m, .a = arena.allocator() };
    if (query.len == 0) {
        try emptyQuery(&b);
    } else {
        try typed(&b, query);
    }
    return .{ .arena = arena, .rows = b.rows.items };
}

fn emptyQuery(b: *Builder) Allocator.Error!void {
    const secs = &b.m.sidebar.sections;
    const fav = secs[@backingInt(sidebar_model.SectionKind.favorites)].rows.items;
    const pin = secs[@backingInt(sidebar_model.SectionKind.pinned)].rows.items;
    if (fav.len > 0) try b.header("Favorites");
    for (fav) |r| try b.place(r);
    if (pin.len > 0) try b.header("Pinned");
    for (pin) |r| try b.place(r);
    try b.header("Commands");
    for (&commands.all) |*cmd| if (cmd.in_palette) try b.command(cmd);
}

fn typed(b: *Builder, query: []const u8) Allocator.Error!void {
    const m = b.m;
    const a = b.a;
    // Favorites and Pinned, by name.
    const places = try sidebarPlaces(m, a);
    var found: std.ArrayList(Scored) = .empty;
    for (places, 0..) |r, i| {
        if (fuzzy.score(query, r.title)) |s| try found.append(a, .{ .score = s, .index = i });
    }
    std.sort.block(Scored, found.items, {}, byScore);
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var first = true;
    for (found.items) |sc| {
        const r = places[sc.index];
        if ((try seen.getOrPut(a, r.path)).found_existing) continue;
        if (first) try b.header("Favorites & Pinned");
        first = false;
        try b.place(r);
    }
    // Commands, by title.
    found.clearRetainingCapacity();
    var tbuf: [128]u8 = undefined;
    for (&commands.all, 0..) |*cmd, i| {
        if (!cmd.in_palette) continue;
        if (fuzzy.score(query, commands.titleOf(m, cmd, &tbuf))) |s| try found.append(a, .{ .score = s, .index = i });
    }
    std.sort.block(Scored, found.items, {}, byScore);
    if (found.items.len > 0) try b.header("Commands");
    for (found.items[0..@min(found.items.len, max_commands)]) |sc| try b.command(&commands.all[sc.index]);
    // Files and folders from the index.
    const hits = try m.view_state.palette.index.search(m.gpa, query);
    defer search_index.freeHits(m.gpa, hits);
    var head = true;
    for (hits) |h| {
        if ((try seen.getOrPut(a, h.path)).found_existing) continue;
        if (head) try b.header("Files & Folders");
        head = false;
        try b.hit(h);
    }
}
