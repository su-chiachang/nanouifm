//! Helpers for the UI tests: a fresh temp folder tree (under the testing tmp dir, removed
//! afterwards; the only place a test ever reads) and a Tester over a model.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const app_view = @import("../app.zig");

const testing = std.testing;

pub const Fixture = struct {
    tmp: testing.TmpDir,
    /// The real absolute path of the temp folder (no /var -> /private/var surprises).
    root: []u8,

    pub fn init() !Fixture {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const real = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
        defer testing.allocator.free(real);
        return .{ .tmp = tmp, .root = try testing.allocator.dupe(u8, real) };
    }

    pub fn deinit(self: *Fixture) void {
        testing.allocator.free(self.root);
        self.tmp.cleanup(); // own temp scaffolding only
    }

    /// A file of `size` bytes at `rel` (folders made as needed).
    pub fn file(self: *Fixture, rel: []const u8, size: usize) !void {
        if (std.fs.path.dirname(rel)) |d| try self.tmp.dir.createDirPath(testing.io, d);
        const data = try testing.allocator.alloc(u8, size);
        defer testing.allocator.free(data);
        @memset(data, 'x');
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = rel, .data = data });
    }

    pub fn dir(self: *Fixture, rel: []const u8) !void {
        try self.tmp.dir.createDirPath(testing.io, rel);
    }

    /// `rel` under the temp folder. Free with `testing.allocator`.
    pub fn sub(self: *const Fixture, rel: []const u8) ![]u8 {
        return std.fs.path.join(testing.allocator, &.{ self.root, rel });
    }
};

/// A window-less view of `m`, 900x560 points.
pub fn open(t: *ui.Tester, m: *app_view.State) !void {
    try t.init(testing.allocator, .init(m, app_view.view), .{ .width = 900, .height = 560 });
    t.settle(0.3);
}

/// The vertical center of text `s` in the last frame.
pub fn textY(t: *ui.Tester, s: []const u8) !f32 {
    const r = t.findText(s) orelse return error.TextNotFound;
    return r.y + r.h / 2;
}

/// Clicks the icon `symbol` (icon-only buttons have no text to click).
pub fn clickIcon(t: *ui.Tester, symbol: []const u8) !void {
    for (t.ctx.nodes.items) |n| switch (n.content) {
        .icon => |ic| if (std.mem.eql(u8, ic.name, symbol)) {
            t.click(n.rect.x + n.rect.w / 2, n.rect.y + n.rect.h / 2);
            return;
        },
        else => {},
    };
    return error.IconNotFound;
}

pub fn hasIcon(t: *ui.Tester, symbol: []const u8) bool {
    for (t.ctx.nodes.items) |n| switch (n.content) {
        .icon => |ic| if (std.mem.eql(u8, ic.name, symbol)) return true,
        else => {},
    };
    return false;
}

/// Clicks the middle of text `s` holding cmd and/or shift.
pub fn clickTextWith(t: *ui.Tester, s: []const u8, mods: struct { cmd: bool = false, shift: bool = false }) !void {
    const r = t.findText(s) orelse return error.TextNotFound;
    t.setMods(.{ .cmd = mods.cmd, .shift = mods.shift });
    t.click(r.x + r.w / 2, r.y + r.h / 2);
    t.setMods(.{});
}

/// A model starting in the fixture's root (also its home), with `favorites` in the sidebar.
pub fn model(fx: *Fixture, favorites: []const app_view.Item) !app_view.State {
    return app_view.State.init(testing.allocator, .{
        .start_path = fx.root,
        .home_path = fx.root,
        .favorites = favorites,
        .locations = &.{.{ .path = "/", .title = "Volume" }},
    });
}

const Rect = @import("pane_sizes.zig").Rect;

/// Where pane `index` is in the last frame's layout (window points).
pub fn paneRect(t: *ui.Tester, m: *app_view.State, index: usize) !Rect {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const fr = try @import("panes_view.zig").frame(arena.allocator(), m, t.size);
    return fr.panes[index].rect;
}

/// The tab strip of a pane at `r`.
pub fn stripOf(r: Rect) Rect {
    return .{ .x = r.x, .y = r.y, .w = r.w, .h = @import("style.zig").tab_strip_height };
}

/// The rectangle of text `s` drawn inside `r` (the same text in other panes is skipped).
pub fn findTextIn(t: *ui.Tester, r: Rect, s: []const u8) ?ui.Rect {
    for (t.ctx.nodes.items) |n| switch (n.content) {
        .text => |tx| if (std.mem.eql(u8, tx.str, s) and r.contains(n.rect.x + n.rect.w / 2, n.rect.y + n.rect.h / 2)) return n.rect,
        else => {},
    };
    return null;
}

pub fn clickTextIn(t: *ui.Tester, r: Rect, s: []const u8) !void {
    const f = findTextIn(t, r, s) orelse return error.TextNotFound;
    t.click(f.x + f.w / 2, f.y + f.h / 2);
}

pub fn clickIconIn(t: *ui.Tester, r: Rect, symbol: []const u8) !void {
    for (t.ctx.nodes.items) |n| switch (n.content) {
        .icon => |ic| if (std.mem.eql(u8, ic.name, symbol) and r.contains(n.rect.x + n.rect.w / 2, n.rect.y + n.rect.h / 2)) {
            t.click(n.rect.x + n.rect.w / 2, n.rect.y + n.rect.h / 2);
            return;
        },
        else => {},
    };
    return error.IconNotFound;
}

/// The middle of `r`.
pub fn center(r: Rect) struct { x: f32, y: f32 } {
    return .{ .x = r.x + r.w / 2, .y = r.y + r.h / 2 };
}

/// Divider `index` of the last frame's layout (window points).
pub fn dividerRect(t: *ui.Tester, m: *app_view.State, index: usize) !Rect {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const fr = try @import("panes_view.zig").frame(arena.allocator(), m, t.size);
    return fr.dividers[index].rect;
}

/// The model's invariants: `panes` is the layout's leaves in reading order, the weights have one
/// list per split, and the focus is a pane.
pub fn expectInSync(m: *app_view.State) !void {
    const leaves = try m.layout.leaves(testing.allocator);
    defer testing.allocator.free(leaves);
    try testing.expectEqual(leaves.len, m.panes.items.len);
    for (leaves, m.panes.items) |id, p| try testing.expectEqual(id, p.id);
    var splits: usize = 0;
    try countSplits(&m.layout, &splits);
    try testing.expectEqual(splits, m.sizes.weights.items.len);
    try testing.expect(m.focused < m.panes.items.len);
}

fn countSplits(node: *const @import("pane_sizes.zig").Tree, n: *usize) !void {
    switch (node.*) {
        .leaf => {},
        .split => |s| {
            n.* += 1;
            for (s.children) |*c| try countSplits(c, n);
        },
    }
}
