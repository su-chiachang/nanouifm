//! Persistence through a store over a temp folder (never the real state directory): what is saved
//! and restored, the rules for folders that are gone, a corrupt file, the debounce (the frame
//! clock is driven, nothing sleeps) and the flush at quit.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const app_view = @import("../app.zig");
const persist = @import("persist.zig");
const ts = @import("test_support.zig");
const state_store = @import("../core/state_store.zig");

const testing = std.testing;
const PersistedState = state_store.PersistedState;
const PersistedPane = state_store.PersistedPane;
const PaneTree = state_store.PaneTree;
const SidebarEntry = state_store.SidebarEntry;

/// root/: a, b, c, d (folders), fav (a folder); the state directory is root/state.
const Setup = struct {
    fx: ts.Fixture,
    dir: []u8,
    store: persist.Store,
    m: app_view.State,
    t: ui.Tester,

    fn prepare(s: *Setup) !void {
        s.fx = try ts.Fixture.init();
        errdefer s.fx.deinit();
        for ([_][]const u8{ "a", "b", "c", "d", "fav" }) |n| try s.fx.dir(n);
        s.dir = try s.fx.sub("state");
        errdefer testing.allocator.free(s.dir);
        s.store = try persist.Store.init(testing.allocator, testing.io, s.dir, s.fx.root);
    }

    /// The model, restored from whatever the store holds, and a view over it.
    fn start(s: *Setup) !void {
        s.m = try app_view.State.init(testing.allocator, .{
            .start_path = s.fx.root,
            .home_path = s.fx.root,
            .locations = &.{.{ .path = "/", .title = "Volume" }},
            .opener = null,
            .hooks = ts.test_hooks,
            .store = &s.store,
        });
        errdefer s.m.deinit();
        try ts.open(&s.t, &s.m);
    }

    fn deinit(s: *Setup) void {
        s.t.deinit();
        s.m.deinit();
        s.store.deinit();
        testing.allocator.free(s.dir);
        s.fx.deinit();
    }

    fn path(s: *Setup, rel: []const u8) ![]u8 {
        return s.fx.sub(rel);
    }

    /// Saves `layout` (and the other fields) as the state file.
    fn write(s: *Setup, layout: PaneTree, o: struct { hidden: bool = false, sidebar: bool = true }) !void {
        var st: PersistedState = .{ .layout = layout, .show_hidden = o.hidden, .sidebar_visible = o.sidebar };
        defer st.deinit(testing.allocator);
        const fav = try s.path("fav");
        defer testing.allocator.free(fav);
        const b = try s.path("b");
        defer testing.allocator.free(b);
        try st.favorites.append(testing.allocator, try SidebarEntry.init(testing.allocator, testing.io, fav, "Fav One"));
        try st.pinned.append(testing.allocator, try SidebarEntry.init(testing.allocator, testing.io, b, null));
        try s.store.save(&st);
    }

    /// A one-pane layout over `rels` (folders under the root, joined here).
    fn leaf(s: *Setup, rels: []const []const u8, selected: usize, mode: state_store.ViewMode) !PaneTree {
        var paths: std.ArrayList([]u8) = .empty;
        defer {
            for (paths.items) |p| testing.allocator.free(p);
            paths.deinit(testing.allocator);
        }
        for (rels) |r| try paths.append(testing.allocator, try s.path(r));
        return .{ .leaf = try PersistedPane.init(testing.allocator, @ptrCast(paths.items), selected, mode) };
    }

    fn tabPaths(s: *Setup, pane: usize, out: *[8][]const u8) []const []const u8 {
        const p = &s.m.panes.items[pane];
        for (p.tabs.items, 0..) |*t, i| out[i] = t.path();
        return out[0..p.tabs.items.len];
    }

    fn expectTabs(s: *Setup, pane: usize, rels: []const []const u8) !void {
        var buf: [8][]const u8 = undefined;
        const got = s.tabPaths(pane, &buf);
        try testing.expectEqual(rels.len, got.len);
        for (rels, got) |r, g| {
            const want = try s.path(r);
            defer testing.allocator.free(want);
            try testing.expectEqualStrings(want, g);
        }
    }
};

/// side by side: [a, b (shown, column view)] | stacked: [c / d]
fn threePanes(s: *Setup) !PaneTree {
    const stack = try PaneTree.splitFrom(testing.allocator, .stacked, &.{ try s.leaf(&.{"c"}, 0, .list), try s.leaf(&.{"d"}, 0, .list) });
    return PaneTree.splitFrom(testing.allocator, .side_by_side, &.{ try s.leaf(&.{ "a", "b" }, 1, .column), stack });
}

test "the layout with its tabs, shown tab and view modes, the favorites, pinned and settings are restored" {
    var s: Setup = undefined;
    try s.prepare();
    defer s.deinit();
    try s.write(try threePanes(&s), .{ .hidden = true, .sidebar = false });
    try s.start();

    try testing.expectEqual(@as(usize, 3), s.m.panes.items.len);
    try ts.expectInSync(&s.m);
    try testing.expect(s.m.layout == .split and s.m.layout.split.axis == .side_by_side);
    try testing.expect(s.m.layout.split.children[1] == .split and s.m.layout.split.children[1].split.axis == .stacked);
    try s.expectTabs(0, &.{ "a", "b" });
    try testing.expectEqual(@as(usize, 1), s.m.panes.items[0].active);
    try testing.expect(s.m.panes.items[0].view_mode == .column and s.m.panes.items[1].view_mode == .list);
    try s.expectTabs(1, &.{"c"});
    try s.expectTabs(2, &.{"d"});
    try testing.expect(s.m.show_hidden and !s.m.sidebar_visible);
    const fav = s.m.sidebar.sections[1].rows.items;
    try testing.expectEqual(@as(usize, 1), fav.len);
    try testing.expectEqualStrings("Fav One", fav[0].title);
    try testing.expectEqual(@as(usize, 1), s.m.sidebar.sections[2].rows.items.len);
    try testing.expectEqualStrings("b", s.m.sidebar.sections[2].rows.items[0].title);
    // Nothing was written by starting up: the file is what it was.
    try testing.expectEqual(@as(u32, 0), s.m.persist.saves);
}

test "a changed model is saved after a pause and reads back the same" {
    var s: Setup = undefined;
    try s.prepare();
    defer s.deinit();
    try s.write(try threePanes(&s), .{});
    try s.start();

    try s.m.queue(.{ .focus_pane = s.m.panes.items[2].id });
    try s.m.queue(.new_tab);
    try s.m.queue(.{ .run_command = .view_column }); // the focused pane's view mode
    try s.m.queue(.{ .run_command = .view_hidden });
    try s.m.queue(.{ .run_command = .view_sidebar });
    s.t.advance(0.2);
    try testing.expectEqual(@as(u32, 0), s.m.persist.saves); // still waiting
    s.t.advance(0.5);
    try testing.expectEqual(@as(u32, 1), s.m.persist.saves);

    var loaded = try s.store.load();
    defer loaded.deinit(testing.allocator);
    var snap = try persist.snapshot(&s.m);
    defer snap.deinit(testing.allocator);
    try testing.expect(loaded.eql(&snap));
    try testing.expect(loaded.show_hidden and !loaded.sidebar_visible);
    const panes = try loaded.panes(testing.allocator);
    defer testing.allocator.free(panes);
    try testing.expectEqual(@as(usize, 2), panes[2].tabs.items.len);
    try testing.expect(panes[2].view_mode == .column);
    try testing.expectEqual(@as(usize, 1), panes[2].selected_tab);
}

test "changes within the pause are one write, and the deadline is a timer, not a poll" {
    var s: Setup = undefined;
    try s.prepare();
    defer s.deinit();
    try s.write(try s.leaf(&.{"a"}, 0, .list), .{});
    try s.start();
    try testing.expect(s.t.ctx.frame_in == null); // idle: no frame asked for

    try s.m.queue(.new_tab);
    s.t.frame();
    const asked = s.t.ctx.frame_in orelse return error.NoTimerAsked;
    try testing.expect(asked > 0 and asked <= persist.delay + 0.01); // (a f32)
    s.t.advance(0.3);
    try s.m.queue(.new_tab); // moves the deadline on
    s.t.advance(0.3);
    try testing.expectEqual(@as(u32, 0), s.m.persist.saves);
    try s.m.queue(.{ .run_command = .view_column }); // a pane setting persists too
    s.t.advance(0.3);
    try testing.expectEqual(@as(u32, 0), s.m.persist.saves);
    s.t.advance(0.3);
    try testing.expectEqual(@as(u32, 1), s.m.persist.saves);
    try testing.expect(s.t.ctx.frame_in == null); // nothing pending any more
    s.t.advance(2);
    try testing.expectEqual(@as(u32, 1), s.m.persist.saves);

    var loaded = try s.store.load();
    defer loaded.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), loaded.layout.leaf.tabs.items.len); // both tabs, one write
    try testing.expect(loaded.layout.leaf.view_mode == .column);
}

test "changes that are not in the state (selection, sort) write nothing; a change undone writes nothing" {
    var s: Setup = undefined;
    try s.prepare();
    defer s.deinit();
    try s.write(try s.leaf(&.{"a"}, 0, .list), .{});
    try s.start();

    try s.m.queue(.{ .sort = .size });
    try s.m.queue(.{ .nav = .{ .key = .down, .shift = false } });
    s.t.advance(1);
    try testing.expectEqual(@as(u32, 0), s.m.persist.saves);
    try s.m.queue(.{ .run_command = .view_hidden });
    s.t.advance(0.2);
    try s.m.queue(.{ .run_command = .view_hidden }); // and back: the file already says so
    s.t.advance(1);
    try testing.expectEqual(@as(u32, 0), s.m.persist.saves);
}

test "flush at quit writes at once, and only when something differs" {
    var s: Setup = undefined;
    try s.prepare();
    defer s.deinit();
    try s.write(try threePanes(&s), .{});
    try s.start();

    s.m.flushState(); // nothing changed
    try testing.expectEqual(@as(u32, 0), s.m.persist.saves);
    try s.m.queue(.{ .focus_pane = s.m.panes.items[1].id });
    try s.m.queue(.{ .close_pane = s.m.panes.items[1].id });
    s.t.advance(0.1); // far short of the pause
    try testing.expectEqual(@as(u32, 0), s.m.persist.saves);
    s.m.flushState(); // the app is quitting
    try testing.expectEqual(@as(u32, 1), s.m.persist.saves);
    s.m.flushState();
    try testing.expectEqual(@as(u32, 1), s.m.persist.saves);
    try testing.expect(s.m.persist.due == null);

    var loaded = try s.store.load();
    defer loaded.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), loaded.layout.leafCount());
}

test "folders that are gone are skipped: tabs, then panes, and the shown tab follows" {
    var s: Setup = undefined;
    try s.prepare();
    defer s.deinit();
    // [gone1, a, gone2, b (shown)] | [gone3] | [c, d] with a shown tab far out of range.
    const layout = try PaneTree.splitFrom(testing.allocator, .side_by_side, &.{
        try s.leaf(&.{ "gone1", "a", "gone2", "b" }, 3, .list),
        try s.leaf(&.{"gone3"}, 0, .column),
        try s.leaf(&.{ "c", "d" }, 9, .column),
    });
    try s.write(layout, .{});
    try s.start();

    try testing.expectEqual(@as(usize, 2), s.m.panes.items.len); // the pane with no folder is gone
    try ts.expectInSync(&s.m);
    try testing.expect(s.m.layout == .split and s.m.layout.split.children.len == 2);
    try s.expectTabs(0, &.{ "a", "b" });
    try testing.expectEqual(@as(usize, 1), s.m.panes.items[0].active); // b, which survived
    try s.expectTabs(1, &.{ "c", "d" });
    try testing.expectEqual(@as(usize, 1), s.m.panes.items[1].active); // clamped to the last
    try testing.expect(s.m.panes.items[1].view_mode == .column);

    // The shown tab itself gone: the nearest one before it that survived.
    var t2: Setup = undefined;
    try t2.prepare();
    defer t2.deinit();
    try t2.write(try t2.leaf(&.{ "a", "gone", "gone2", "b" }, 2, .list), .{});
    try t2.start();
    try t2.expectTabs(0, &.{ "a", "b" });
    try testing.expectEqual(@as(usize, 0), t2.m.panes.items[0].active);
}

test "a state with no folder left starts the default pane, keeping the rest" {
    var s: Setup = undefined;
    try s.prepare();
    defer s.deinit();
    try s.write(try PaneTree.splitFrom(testing.allocator, .stacked, &.{ try s.leaf(&.{"x1"}, 0, .column), try s.leaf(&.{"x2"}, 0, .list) }), .{ .hidden = true });
    try s.start();
    try testing.expectEqual(@as(usize, 1), s.m.panes.items.len);
    try s.expectTabs(0, &.{""}); // Config.start_path: the root
    try testing.expect(s.m.panes.items[0].view_mode == .list);
    try testing.expect(s.m.show_hidden); // the settings and the sidebar entries still came back
    try testing.expectEqualStrings("Fav One", s.m.sidebar.sections[1].rows.items[0].title);
}

test "a corrupt file, and a missing one, give the first-launch defaults" {
    var s: Setup = undefined;
    try s.prepare();
    defer s.deinit();
    for ([_][]const u8{ "Desktop", "Documents", "Downloads" }) |n| try s.fx.dir(n);
    // Missing: nothing is created by looking.
    try s.start();
    try testing.expectEqual(@as(usize, 4), s.m.panes.items.len); // the defaults' 2x2 grid
    try testing.expectEqual(@as(usize, 4), s.m.sidebar.sections[1].rows.items.len);
    try testing.expectEqualStrings("Desktop", s.m.sidebar.sections[1].rows.items[0].title);
    try testing.expect(!s.fx.exists("state"));
    s.t.deinit();
    s.m.deinit();
    // Corrupt: the same.
    try s.fx.file("state/state.json", 40); // 40 x's
    try s.start();
    try testing.expectEqual(@as(usize, 4), s.m.panes.items.len);
    try ts.expectInSync(&s.m);
    try testing.expectEqual(@as(usize, 4), s.m.sidebar.sections[1].rows.items.len);
    try testing.expect(!s.m.show_hidden and s.m.sidebar_visible);
}

test "without a store nothing is persisted" {
    var env: ts.Env = undefined;
    try env.init();
    defer env.deinit();
    try env.m.queue(.new_tab);
    env.t.advance(2);
    env.m.flushState();
    try testing.expect(env.m.persist.store == null and env.m.persist.due == null and env.m.persist.saves == 0);
}
