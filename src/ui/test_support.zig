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

    /// A file of exactly `data` at `rel` (folders made as needed).
    pub fn bytes(self: *Fixture, rel: []const u8, data: []const u8) !void {
        if (std.fs.path.dirname(rel)) |d| try self.tmp.dir.createDirPath(testing.io, d);
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = rel, .data = data });
    }

    /// Whether `rel` exists under the temp folder.
    pub fn exists(self: *const Fixture, rel: []const u8) bool {
        self.tmp.dir.access(testing.io, rel, .{}) catch return false;
        return true;
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

/// Clicks the lowest drawn text `s`: a menu's or a palette's row, not a column header, a field's
/// typed words or a hint of the same name above it.
pub fn clickLowestText(t: *ui.Tester, s: []const u8) !void {
    var best: ?ui.Rect = null;
    for (t.ctx.nodes.items) |n| switch (n.content) {
        .text => |tx| if (std.mem.eql(u8, tx.str, s) and (best == null or n.rect.y > best.?.y)) {
            best = n.rect;
        },
        else => {},
    };
    const r = best orelse return error.TextNotFound;
    t.click(r.x + r.w / 2, r.y + r.h / 2);
}

/// Where the icon `symbol` drawn inside `r` is (window points).
pub fn iconIn(t: *ui.Tester, r: @import("pane_sizes.zig").Rect, symbol: []const u8) ?ui.Rect {
    for (t.ctx.nodes.items) |n| switch (n.content) {
        .icon => |ic| if (std.mem.eql(u8, ic.name, symbol) and r.contains(n.rect.x + n.rect.w / 2, n.rect.y + n.rect.h / 2)) return n.rect,
        else => {},
    };
    return null;
}

/// Clicks the middle of text `s` holding cmd and/or shift.
pub fn clickTextWith(t: *ui.Tester, s: []const u8, mods: struct { cmd: bool = false, shift: bool = false }) !void {
    const r = t.findText(s) orelse return error.TextNotFound;
    t.setMods(.{ .cmd = mods.cmd, .shift = mods.shift });
    t.click(r.x + r.w / 2, r.y + r.h / 2);
    t.setMods(.{});
}

/// A model starting in the fixture's root (also its home), with `favorites` in the sidebar. Its
/// opener is the recorder below: no test ever launches an app.
pub fn model(fx: *Fixture, favorites: []const app_view.Item) !app_view.State {
    return modelAt(fx, "", favorites);
}

/// `model`, starting in `rel` under the fixture's root (home stays the root).
pub fn modelAt(fx: *Fixture, rel: []const u8, favorites: []const app_view.Item) !app_view.State {
    const start = try fx.sub(rel);
    defer testing.allocator.free(start);
    return app_view.State.init(testing.allocator, .{
        .start_path = start,
        .home_path = fx.root,
        .favorites = favorites,
        .locations = &.{.{ .path = "/", .title = "Volume" }},
        .opener = record,
        .hooks = test_hooks,
    });
}

/// The files the recording opener was asked to open (owned; `resetOpened` frees them).
pub var opened: std.ArrayList([]u8) = .empty;

fn record(path: []const u8) bool {
    const copy = testing.allocator.dupe(u8, path) catch return false;
    opened.append(testing.allocator, copy) catch {
        testing.allocator.free(copy);
        return false;
    };
    return true;
}

pub fn resetOpened() void {
    for (opened.items) |p| testing.allocator.free(p);
    opened.deinit(testing.allocator);
    opened = .empty;
}

/// Presses a key (a `ui.Shortcut` code, `mods` held) and lets the queued action run; the view
/// must have taken it.
pub fn press(t: *ui.Tester, key: u21, mods: struct { cmd: bool = false, shift: bool = false, alt: bool = false, ctrl: bool = false }) !void {
    if (!t.shortcut(.{ .key = key, .cmd = mods.cmd, .shift = mods.shift, .alt = mods.alt, .ctrl = mods.ctrl })) return error.KeyNotTaken;
    t.settle(0.2);
}

// ---- the hooks' recorders: what the app would have put on the system clipboard or shown in
// Finder, kept in fixed buffers (nothing to free). The real pasteboard is never touched.

pub var copied_text: [4096]u8 = undefined;
pub var copied_text_len: usize = 0;
pub var revealed: [4096]u8 = undefined;
pub var revealed_len: usize = 0;
pub var mirrored: [4096]u8 = undefined;
pub var mirrored_len: usize = 0;

fn joinInto(buf: []u8, len: *usize, paths: []const []const u8) void {
    var w: std.Io.Writer = .fixed(buf);
    for (paths, 0..) |p, i| {
        if (i > 0) w.writeAll("\n") catch break;
        w.writeAll(p) catch break;
    }
    len.* = w.buffered().len;
}

fn recordText(text: []const u8) void {
    const n = @min(text.len, copied_text.len);
    @memcpy(copied_text[0..n], text[0..n]);
    copied_text_len = n;
}

fn recordReveal(paths: []const []const u8) void {
    joinInto(&revealed, &revealed_len, paths);
}

fn recordMirror(paths: []const []const u8) void {
    joinInto(&mirrored, &mirrored_len, paths);
}

pub const test_hooks: @import("hooks.zig").Hooks = .{ .copy_text = recordText, .reveal = recordReveal, .copy_files = recordMirror };

pub fn copiedText() []const u8 {
    return copied_text[0..copied_text_len];
}

pub fn revealedPaths() []const u8 {
    return revealed[0..revealed_len];
}

pub fn mirroredPaths() []const u8 {
    return mirrored[0..mirrored_len];
}

pub fn resetHooks() void {
    copied_text_len = 0;
    revealed_len = 0;
    mirrored_len = 0;
}

/// The names of the focused tab's rows, in order.
pub fn rowNames(m: *app_view.State, out: *[64][]const u8) []const []const u8 {
    const items = m.focusedTab().exp.items;
    const n = @min(items.len, out.len);
    for (items[0..n], out[0..n]) |it, *o| o.* = it.name;
    return out[0..n];
}

/// The one selected path of the focused tab, or null.
pub fn selectedOnly(m: *app_view.State) ?[]const u8 {
    const tab = m.focusedTab();
    if (tab.selection.count() != 1) return null;
    var it = tab.selection.set.keyIterator();
    return it.next().?.*;
}

/// Where the first node drawing icon `symbol` at or below `min_y` is (window points).
pub fn iconRectBelow(t: *ui.Tester, symbol: []const u8, min_y: f32) ?ui.Rect {
    for (t.ctx.nodes.items) |n| switch (n.content) {
        .icon => |ic| if (std.mem.eql(u8, ic.name, symbol) and n.rect.y >= min_y) return n.rect,
        else => {},
    };
    return null;
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

/// root/: a.txt, b.txt, dir/ (inner.txt)
pub fn tree(fx: *Fixture) !void {
    try fx.file("a.txt", 10);
    try fx.file("b.txt", 20);
    try fx.file("dir/inner.txt", 5);
}

/// How a test's palette indexes: not at all (the default), at once on the calling thread, or each
/// crawl held (`runHeld`) until the test lets it run. Never a thread, never the real home.
pub const IndexMode = enum { off, now, held };

const palette_index = @import("palette_index.zig");

/// The crawl `hold` kept.
pub var held_job: ?*palette_index.Job = null;

fn hold(job: *palette_index.Job) void {
    if (held_job) |old| old.run(); // (a newer crawl replaces an unrun one)
    held_job = job;
}

/// Lets the held crawl run now; false when none was held.
pub fn runHeld() bool {
    const job = held_job orelse return false;
    held_job = null;
    job.run();
    return true;
}

pub const Env = struct {
    fx: Fixture,
    m: app_view.State,
    t: ui.Tester,

    pub fn init(env: *Env) !void {
        return env.initWith(.{});
    }

    /// `init` with live refresh's bookkeeping on (`watch = .manual`: a test fires the changes)
    /// and/or a sidebar favorite titled "Fav" for the folder `favorite` (under the root), more
    /// `files` in the temp tree, and the palette's file index (see `IndexMode`) over the folder
    /// `index_rel` of the tree (default: all of it).
    pub fn initWith(env: *Env, o: struct {
        watch: @import("watch.zig").Mode = .off,
        favorite: ?[]const u8 = null,
        files: []const []const u8 = &.{},
        index: IndexMode = .off,
        index_rel: []const u8 = "",
        /// The mounted volumes (`volumes.zig`): a test's fake provider; none: the one fixed volume.
        volumes: ?@import("volumes.zig").Provider = null,
        /// A second favorite, titled "Fav2" (under the root).
        favorite2: ?[]const u8 = null,
    }) !void {
        env.fx = try Fixture.init();
        errdefer env.fx.deinit();
        try tree(&env.fx);
        for (o.files) |f| try env.fx.file(f, 7);
        const fav_path = if (o.favorite) |f| try env.fx.sub(f) else null;
        defer if (fav_path) |p| testing.allocator.free(p);
        const index_root = try env.fx.sub(o.index_rel);
        defer testing.allocator.free(index_root);
        const fav2_path = if (o.favorite2) |f| try env.fx.sub(f) else null;
        defer if (fav2_path) |p| testing.allocator.free(p);
        var favs: [2]app_view.Item = undefined;
        var nfavs: usize = 0;
        if (fav_path) |p| {
            favs[nfavs] = .{ .path = p, .title = "Fav" };
            nfavs += 1;
        }
        if (fav2_path) |p| {
            favs[nfavs] = .{ .path = p, .title = "Fav2" };
            nfavs += 1;
        }
        held_job = null;
        env.m = try app_view.State.init(testing.allocator, .{
            .start_path = env.fx.root,
            .home_path = env.fx.root,
            .favorites = favs[0..nfavs],
            .locations = &.{.{ .path = "/", .title = "Volume" }},
            .volumes = o.volumes,
            .opener = record,
            .hooks = test_hooks,
            .watch = o.watch,
            .index = switch (o.index) {
                .off => null,
                .now => .{ .roots = &.{index_root}, .runner = palette_index.runNow },
                .held => .{ .roots = &.{index_root}, .runner = hold },
            },
        });
        errdefer env.m.deinit();
        resetHooks();
        try open(&env.t, &env.m);
    }

    pub fn deinit(env: *Env) void {
        _ = runHeld(); // a crawl nobody ran owns a share of the index
        env.t.deinit();
        env.m.deinit();
        env.fx.deinit();
    }

    pub fn click(env: *Env, name: []const u8) !void {
        try env.t.clickText(name);
        env.t.settle(0.2);
    }

    /// Whether exactly `rel` (under the root) is selected.
    pub fn selected(env: *Env, rel: []const u8) !bool {
        const want = try env.fx.sub(rel);
        defer testing.allocator.free(want);
        const got = selectedOnly(&env.m) orelse return false;
        return std.mem.eql(u8, got, want);
    }

    pub fn noticeHas(env: *Env, needle: []const u8) bool {
        const n = env.m.notice orelse return false;
        return std.mem.indexOf(u8, n, needle) != null;
    }

    /// Types into the rename field (its text is selected) and presses Return.
    pub fn renameTo(env: *Env, name: []const u8) void {
        env.t.textOps(&.{ .{ .command = .select_all }, .{ .command = .delete_backward } });
        if (name.len > 0) env.t.typeText(name);
        env.t.key(.enter);
        env.t.settle(0.2);
    }
};
