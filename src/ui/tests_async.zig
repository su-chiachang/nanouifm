//! Asynchronous folder listing through ui.Tester with a HELD runner: every read waits until the
//! test releases it (`ts.releaseListing`), so the test decides when a result arrives, and in
//! which order. Nothing reads on another thread; the jobs run on the test's thread. What lands is
//! merged at the next pass, exactly as in the app (`listing_apply.zig`).
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const app_view = @import("../app.zig");
const ts = @import("test_support.zig");
const refresh = @import("file_refresh.zig");
const file_actions = @import("file_actions.zig");

const testing = std.testing;
const loading_text = "Loading\u{2026}";

/// `n` empty files in `rel` under the fixture's root.
fn manyFiles(env: *ts.Env, rel: []const u8, n: usize) !void {
    try env.fx.dir(rel);
    var buf: [64]u8 = undefined;
    for (0..n) |i| {
        const name = try std.fmt.bufPrint(&buf, "{s}/f{d:0>5}.txt", .{ rel, i });
        try env.fx.tmp.dir.writeFile(testing.io, .{ .sub_path = name, .data = "" });
    }
}

fn open(env: *ts.Env, rel: []const u8) !void {
    const p = try env.fx.sub(rel);
    defer testing.allocator.free(p);
    try env.m.queue(.{ .open = p });
    env.t.settle(0.2);
}

fn expectPath(env: *ts.Env, rel: []const u8) !void {
    const p = try env.fx.sub(rel);
    defer testing.allocator.free(p);
    try testing.expectEqualStrings(p, env.m.focusedTab().path());
}

test "10,000 files: the frame completes with the old listing, then the result lands" {
    var env: ts.Env = undefined;
    try env.initWith(.{ .listing = .held });
    defer env.deinit();
    try manyFiles(&env, "big", 10_000);

    try open(&env, "big");
    // The request is out; nothing changed yet: old rows, old folder, history untouched.
    try testing.expectEqual(@as(usize, 1), ts.held_listing.items.len);
    try testing.expect(env.t.hasText("a.txt") and env.t.hasText("dir"));
    try testing.expect(env.t.hasText(loading_text));
    try expectPath(&env, "");
    try testing.expect(!env.m.focusedTab().canBack());
    try testing.expectEqual(@as(usize, 1), env.m.focusedTab().history.entries.items.len);
    // Input is not blocked: a click still selects a row of the old listing.
    try env.click("b.txt");
    try testing.expect(try env.selected("b.txt"));

    ts.releaseListing(0);
    env.t.settle(0.3);
    try expectPath(&env, "big");
    try testing.expect(env.m.focusedTab().canBack());
    try testing.expectEqual(@as(usize, 10_000), env.m.focusedTab().listing.visible.len);
    try testing.expect(env.t.hasText("f00000.txt") and !env.t.hasText("a.txt"));
    try testing.expect(env.t.hasText("10000 items") and !env.t.hasText(loading_text));
    try testing.expectEqual(@as(u32, 0), env.m.loader.fallbacks); // nothing was read on the main thread
    // Back to the folder we left (a history move, itself asynchronous).
    try env.m.queue(.back);
    env.t.settle(0.2);
    try expectPath(&env, "big"); // still: history moves only when the read lands
    ts.releaseListing(0);
    env.t.settle(0.2);
    try expectPath(&env, "");
    try testing.expect(env.t.hasText("a.txt") and !env.m.focusedTab().canBack() and env.m.focusedTab().canForward());
}

test "a late result of an older navigation is ignored" {
    var env: ts.Env = undefined;
    try env.initWith(.{ .listing = .held, .files = &.{"other/o.txt"} });
    defer env.deinit();

    try open(&env, "dir"); // A
    try open(&env, "other"); // B, asked before A came back
    try testing.expectEqual(@as(usize, 2), ts.held_listing.items.len);
    ts.releaseListing(1); // B arrives first
    env.t.settle(0.2);
    try expectPath(&env, "other");
    try testing.expect(env.t.hasText("o.txt"));
    ts.releaseListing(0); // A, late: dropped and freed
    env.t.settle(0.2);
    try expectPath(&env, "other");
    try testing.expect(env.t.hasText("o.txt") and !env.t.hasText("inner.txt"));
    try testing.expectEqual(@as(u32, 1), env.m.loader.dropped);
    try testing.expectEqual(@as(usize, 2), env.m.focusedTab().history.entries.items.len); // root, other: A never happened

    // The other order: A is delivered first and ignored because B replaced it.
    try open(&env, "dir");
    try open(&env, "");
    ts.releaseListing(0);
    env.t.settle(0.2);
    try expectPath(&env, "other");
    ts.releaseListing(0);
    env.t.settle(0.2);
    try expectPath(&env, "");
    try testing.expect(env.t.hasText("a.txt"));
}

test "quick repeated navigation does not pile up work" {
    var env: ts.Env = undefined;
    try env.initWith(.{ .listing = .held, .files = &.{"other/o.txt"} });
    defer env.deinit();
    for (0..30) |i| try open(&env, if (i % 2 == 0) "dir" else "other");
    try testing.expect(ts.held_listing.items.len <= 4); // jobs in flight are capped
    try testing.expectEqual(@as(usize, 1), env.m.loader.pending.items.len); // one waiting request, the newest
    try expectPath(&env, "");
    // Letting the old ones come back starts the newest, which is the one that lands.
    while (ts.held_listing.items.len > 0) {
        ts.releaseListing(0);
        env.t.settle(0.2);
    }
    try testing.expectEqual(@as(usize, 0), env.m.loader.pending.items.len);
    try expectPath(&env, "other"); // the last request (the 30th) was "other"
}

test "a folder that can't be listed raises the notice and changes nothing" {
    var env: ts.Env = undefined;
    try env.initWith(.{ .listing = .held });
    defer env.deinit();

    try open(&env, "dir");
    ts.releaseListing(0);
    env.t.settle(0.2);
    try expectPath(&env, "dir");
    const entries = env.m.focusedTab().history.entries.items.len;

    try open(&env, "gone");
    try testing.expect(env.m.notice == null); // nothing is said until the read fails
    try testing.expect(env.t.hasText("inner.txt"));
    ts.releaseListing(0);
    env.t.settle(0.2);
    try testing.expect(env.noticeHas("Can't open \"gone\""));
    try expectPath(&env, "dir"); // location and history untouched, the old rows still there
    try testing.expectEqual(entries, env.m.focusedTab().history.entries.items.len);
    try testing.expect(env.t.hasText("inner.txt") and !env.t.hasText(loading_text));
    // A file is not a folder either.
    try open(&env, "a.txt");
    ts.releaseListing(0);
    env.t.settle(0.2);
    try testing.expect(env.noticeHas("Can't open \"a.txt\""));
    try expectPath(&env, "dir");
}

test "a watcher reload keeps the selection and the scroll while it is read off-main" {
    var env: ts.Env = undefined;
    try env.initWith(.{ .watch = .manual, .listing = .held });
    defer env.deinit();
    var name: [32]u8 = undefined;
    for (0..60) |i| try env.fx.file(try std.fmt.bufPrint(&name, "f{d:0>3}.txt", .{i}), 1);
    try env.m.queue(.reload);
    env.t.settle(0.2);
    ts.releaseListing(0);
    env.t.settle(0.2);
    try testing.expect(env.t.hasText("a.txt"));

    try env.click("a.txt");
    const r = try ts.paneRect(&env.t, &env.m, 0);
    env.t.scroll(r.x + 200, r.y + 200, -400);
    env.t.settle(0.3);
    try testing.expect(!env.t.hasText("a.txt"));
    const probe_name: []const u8 = if (env.t.hasText("f040.txt")) "f040.txt" else "f030.txt";
    const probe = env.t.findText(probe_name) orelse return error.TextNotFound;

    try env.fx.file("zzz-new.txt", 1);
    const root = try env.fx.sub("");
    defer testing.allocator.free(root);
    try env.m.watch.fire(root);
    env.t.frame();
    env.t.settle(0.2);
    // The read is out: the rows are the old ones and nothing flickers into "Loading".
    try testing.expectEqual(@as(usize, 1), ts.held_listing.items.len);
    const zzz = try env.fx.sub("zzz-new.txt");
    defer testing.allocator.free(zzz);
    try testing.expect(env.m.focusedTab().listing.indexOf(zzz) == null);
    try testing.expect(!env.t.hasText(loading_text));
    try testing.expectEqual(probe.y, env.t.findText(probe_name).?.y);

    ts.releaseListing(0);
    env.t.settle(0.2);
    try testing.expect(env.m.focusedTab().listing.indexOf(zzz) != null);
    const a = try env.fx.sub("a.txt");
    defer testing.allocator.free(a);
    try testing.expect(env.m.focusedTab().selection.contains(a)); // selection survived
    try testing.expectEqual(probe.y, (env.t.findText(probe_name) orelse return error.TextNotFound).y);
    try testing.expect(!env.m.focusedTab().scroll_reset);
    try testing.expectEqual(@as(u32, 0), env.m.loader.fallbacks);
}

test "a folder opened in place is read off-main and opens when it lands" {
    var env: ts.Env = undefined;
    try env.initWith(.{ .listing = .held });
    defer env.deinit();
    const dir = try env.fx.sub("dir");
    defer testing.allocator.free(dir);
    try env.m.queue(.{ .toggle_expand = .{ .pane = env.m.focusedPane().id, .path = dir } });
    env.t.settle(0.2);
    try testing.expectEqual(@as(usize, 1), ts.held_listing.items.len);
    try testing.expect(!env.t.hasText("inner.txt") and !env.m.focusedTab().exp.isExpanded(dir));
    try testing.expect(env.t.hasText(loading_text));
    ts.releaseListing(0);
    env.t.settle(0.2);
    try testing.expect(env.t.hasText("inner.txt") and env.m.focusedTab().exp.isExpanded(dir));
    try testing.expect(!env.t.hasText(loading_text));
    // A reload keeps it open: the open folder is read with the tab's.
    try env.fx.file("dir/second.txt", 1);
    try env.m.queue(.reload);
    env.t.settle(0.2);
    try testing.expect(!env.t.hasText("second.txt"));
    ts.releaseListing(0);
    env.t.settle(0.2);
    try testing.expect(env.t.hasText("second.txt") and env.m.focusedTab().exp.isExpanded(dir));
    try testing.expectEqual(@as(u32, 0), env.m.loader.fallbacks);
}

test "column view: the stack, a drilled folder and the tab's folder arrive when read" {
    var fx = try ts.Fixture.init();
    defer fx.deinit();
    try fx.file("alpha/beta/gamma/deep.txt", 5);
    try fx.file("alpha/beta/note.md", 40);
    try fx.file("alpha/a1.txt", 7);
    ts.held_listing = .empty;
    const start = try fx.sub("alpha/beta");
    defer testing.allocator.free(start);
    var m = try app_view.State.init(testing.allocator, .{
        .start_path = start,
        .home_path = fx.root,
        .locations = &.{.{ .path = "/", .title = "Volume" }},
        .hooks = ts.test_hooks,
        .listing = .{ .runner = ts.holdListing },
    });
    defer {
        m.deinit();
        ts.releaseAllListing();
    }
    m.focusedPane().view_mode = .column;
    var t: ui.Tester = undefined;
    try ts.open(&t, &m);
    defer t.deinit();

    // The stack is asked for, one request however many frames pass; nothing is drawn yet.
    try testing.expectEqual(@as(usize, 1), ts.held_listing.items.len);
    t.settle(0.2);
    try testing.expectEqual(@as(usize, 1), ts.held_listing.items.len);
    try testing.expectEqual(@as(usize, 0), m.focusedTab().col.columns.items.len);
    ts.releaseListing(0);
    t.settle(0.2);
    try testing.expectEqual(@as(usize, 2), m.focusedTab().col.columns.items.len);
    try testing.expect(t.hasText("gamma") and t.hasText("note.md"));

    // Clicking a folder selects it at once; its column and the tab's folder follow the read.
    try t.clickText("gamma");
    t.settle(0.2);
    try testing.expectEqual(@as(usize, 1), ts.held_listing.items.len);
    try testing.expectEqual(@as(usize, 2), m.focusedTab().col.columns.items.len);
    try testing.expect(!t.hasText("deep.txt") and t.hasText(loading_text));
    ts.releaseListing(0);
    t.settle(0.2);
    try testing.expectEqual(@as(usize, 3), m.focusedTab().col.columns.items.len);
    try testing.expect(t.hasText("deep.txt") and !t.hasText(loading_text));
    const gamma = try fx.sub("alpha/beta/gamma");
    defer testing.allocator.free(gamma);
    try testing.expectEqualStrings(gamma, m.focusedTab().path());
    try testing.expectEqual(@as(u32, 0), m.loader.fallbacks);
}

test "a tab, a pane or a model that went away before the answer leaves nothing behind" {
    var env: ts.Env = undefined;
    try env.initWith(.{ .listing = .held });
    defer env.deinit();
    const dir = try env.fx.sub("dir");
    defer testing.allocator.free(dir);

    // A new tab asks for its listing; it is closed before the answer comes.
    try env.m.queue(.{ .open_in_new_tab = dir });
    env.t.settle(0.2);
    try testing.expectEqual(@as(usize, 2), env.m.focusedPane().tabs.items.len);
    try testing.expect(env.t.hasText(loading_text) and !env.t.hasText("inner.txt"));
    try env.m.queue(.close_active_tab);
    env.t.settle(0.2);
    ts.releaseListing(0);
    env.t.settle(0.2);
    try testing.expectEqual(@as(u32, 1), env.m.loader.dropped);
    try testing.expect(!env.t.hasText("inner.txt"));

    // A split pane likewise.
    try env.m.queue(.{ .split = .side_by_side });
    env.t.settle(0.2);
    try testing.expectEqual(@as(usize, 2), env.m.panes.items.len);
    const id = env.m.panes.items[1].id;
    try env.m.queue(.{ .close_pane = id });
    env.t.settle(0.2);
    ts.releaseListing(0);
    env.t.settle(0.2);
    try testing.expectEqual(@as(u32, 2), env.m.loader.dropped);

    // A result delivered but never merged, and a read never delivered: `Env.deinit` takes the
    // model down first, then lets the second job finish into a dead model.
    try open(&env, "dir");
    try open(&env, "");
    ts.releaseListing(0); // the first, stale one: delivered into the inbox, never merged
    try testing.expectEqual(@as(usize, 1), ts.held_listing.items.len);
}

test "a new tab shows its listing when it lands, and back and forward wait for theirs" {
    var env: ts.Env = undefined;
    try env.initWith(.{ .listing = .held });
    defer env.deinit();
    const dir = try env.fx.sub("dir");
    defer testing.allocator.free(dir);
    try env.m.queue(.{ .open_in_new_tab = dir });
    env.t.settle(0.2);
    try testing.expect(!env.m.focusedTab().listed);
    ts.releaseListing(0);
    env.t.settle(0.2);
    try testing.expect(env.m.focusedTab().listed and env.t.hasText("inner.txt"));

    try open(&env, "");
    ts.releaseListing(0);
    env.t.settle(0.2);
    try testing.expect(env.t.hasText("a.txt") and env.m.focusedTab().canBack());
    try env.m.queue(.back);
    env.t.settle(0.2);
    try testing.expect(env.m.focusedTab().canBack() and env.t.hasText("a.txt")); // not moved yet
    ts.releaseListing(0);
    env.t.settle(0.2);
    try testing.expect(!env.m.focusedTab().canBack() and env.m.focusedTab().canForward() and env.t.hasText("inner.txt"));
}

test "with a runner that finishes at once the result lands in the same pass" {
    var env: ts.Env = undefined;
    try env.initWith(.{ .listing = .now });
    defer env.deinit();
    const dir = try env.fx.sub("dir");
    defer testing.allocator.free(dir);
    try env.m.queue(.{ .open = dir });
    _ = try env.m.applyPending();
    try testing.expectEqualStrings(dir, env.m.focusedTab().path());
    try testing.expectEqual(@as(usize, 1), env.m.focusedTab().listing.visible.len);
    try testing.expectEqual(@as(u32, 0), env.m.loader.fallbacks);
}

test "a read that lands during a rename waits until the rename ends" {
    var env: ts.Env = undefined;
    try env.initWith(.{ .watch = .manual, .listing = .held });
    defer env.deinit();
    try env.fx.file("arrived.txt", 1);
    const root = try env.fx.sub("");
    defer testing.allocator.free(root);
    try env.m.watch.fire(root);
    env.t.frame();
    env.t.settle(0.2);
    try testing.expectEqual(@as(usize, 1), ts.held_listing.items.len);

    try env.click("a.txt");
    try ts.press(&env.t, ui.Shortcut.enter, .{}); // the inline rename opens
    try testing.expect(env.m.rename != null);
    ts.releaseListing(0);
    env.t.settle(0.2);
    try testing.expect(env.m.rename != null and !env.t.hasText("arrived.txt")); // the rows under the field stay put
    env.t.key(.escape);
    env.t.settle(0.3);
    try testing.expectEqual(@as(usize, 1), ts.held_listing.items.len); // read again once the rename is over
    ts.releaseListing(0);
    env.t.settle(0.2);
    try testing.expect(env.t.hasText("arrived.txt"));
}

test "revealing a file in a tab that is still being read selects it when it lands" {
    var env: ts.Env = undefined;
    try env.initWith(.{ .listing = .held });
    defer env.deinit();
    const dir = try env.fx.sub("dir");
    defer testing.allocator.free(dir);
    const inner = try env.fx.sub("dir/inner.txt");
    defer testing.allocator.free(inner);
    try env.m.queue(.{ .open_in_new_tab = dir });
    env.t.settle(0.2);
    try refresh.select(&env.m, env.m.focused, &.{inner});
    try testing.expectEqual(@as(usize, 0), env.m.focusedTab().selection.count()); // no rows yet
    ts.releaseListing(0);
    env.t.settle(0.2);
    try testing.expect(env.m.focusedTab().selection.contains(inner));
}

test "file operations still refresh at once, and an older read in flight goes stale" {
    var env: ts.Env = undefined;
    try env.initWith(.{ .watch = .manual, .listing = .held });
    defer env.deinit();
    const root = try env.fx.sub("");
    defer testing.allocator.free(root);
    try env.m.watch.fire(root);
    env.t.frame();
    env.t.settle(0.2);
    try testing.expectEqual(@as(usize, 1), ts.held_listing.items.len); // a watcher reload, out

    try file_actions.newFolder(&env.m); // needs its row now: it reads inline and starts the rename
    try testing.expect(env.m.rename != null);
    try testing.expect(env.m.focusedTab().listing.indexOf(env.m.rename.?.path) != null);
    try testing.expect(!env.m.loader.has(env.m.focusedTab().id, .reload)); // the older read was forgotten
    ts.releaseListing(0);
    env.t.settle(0.2);
    try testing.expectEqual(@as(u32, 1), env.m.loader.dropped);
    try testing.expect(env.m.focusedTab().listing.indexOf(env.m.rename.?.path) != null);
}

test "a new tab or pane is read once, not again when the watcher first sees it" {
    var env: ts.Env = undefined;
    try env.initWith(.{ .watch = .manual, .listing = .held });
    defer env.deinit();
    const dir = try env.fx.sub("dir");
    defer testing.allocator.free(dir);
    try env.m.queue(.{ .open_in_new_tab = dir });
    env.t.settle(0.3);
    try testing.expectEqual(@as(usize, 1), ts.held_listing.items.len); // one read, not a read and a re-read
    ts.releaseListing(0);
    env.t.settle(0.2);
    try testing.expect(env.t.hasText("inner.txt"));
    try testing.expectEqual(@as(u32, 0), env.m.loader.dropped);

    try env.m.queue(.{ .split = .side_by_side });
    env.t.settle(0.3);
    try testing.expectEqual(@as(usize, 1), ts.held_listing.items.len);
    ts.releaseListing(0);
    env.t.settle(0.2);
    try testing.expectEqual(@as(u32, 0), env.m.loader.dropped);
    try testing.expectEqual(@as(u32, 0), env.m.loader.fallbacks);
}
