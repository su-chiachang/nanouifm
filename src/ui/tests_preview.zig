//! The inspector (Opt+Cmd+I, the toolbar's button) and the previews: no selection, one file, a
//! folder, a picture with its resolution (headers written to a temp folder, read by the real
//! parser, and a fake provider), several items, the thumbnail provider (a fake that holds its
//! answer until the test lets it go), the buttons, and column view's trailing preview, which is the
//! same component. Temp folders only; nothing reaches the clipboard, Finder or a share sheet.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const app_view = @import("../app.zig");
const image_info = @import("image_info.zig");
const inspector_info = @import("inspector_info.zig");
const thumbs = @import("thumbs.zig");
const hooks_mod = @import("hooks.zig");
const ts = @import("test_support.zig");
const Rect = @import("pane_sizes.zig").Rect;

const testing = std.testing;
const S = ui.Shortcut;

/// root/: a.txt (10 bytes), b.txt (20), dir/ (inner.txt) + pic.png (640x480), photo.jpg (1920x1080).
fn withPictures(env: *ts.Env) !void {
    const png = image_info.pngHeader(640, 480);
    try env.fx.bytes("pic.png", &png);
    const jpg = try image_info.jpegHeader(testing.allocator, 1920, 1080, 3000);
    defer testing.allocator.free(jpg);
    try env.fx.bytes("photo.jpg", jpg);
    try env.m.queue(.reload);
    env.t.settle(0.2);
}

/// The inspector's area in pane 0 (a list view with the inspector on).
fn panel(env: *ts.Env) !Rect {
    const r = try ts.paneRect(&env.t, &env.m, 0);
    const w = inspector_info.panelWidth(r.w);
    return .{ .x = r.x + r.w - w, .y = r.y, .w = w, .h = r.h };
}

fn inPanel(env: *ts.Env, s: []const u8) !bool {
    return ts.findTextIn(&env.t, try panel(env), s) != null;
}

fn inspectorOn(env: *ts.Env) !void {
    try ts.press(&env.t, 'i', .{ .cmd = true, .alt = true });
    try testing.expect(env.m.panes.items[0].inspector);
}

/// How many pictures this frame draws.
fn images(env: *ts.Env) usize {
    var n: usize = 0;
    for (env.t.ctx.nodes.items) |nd| switch (nd.content) {
        .image => n += 1,
        else => {},
    };
    return n;
}

// ---- fakes ----

var held: ?thumbs.Done = null;
var asked_path: [512]u8 = undefined;
var asked_len: usize = 0;
var asked_side: u32 = 0;
var asked: usize = 0;

fn reset() void {
    held = null;
    asked_len = 0;
    asked_side = 0;
    asked = 0;
}

/// A provider that keeps its answer until `deliver`.
fn holdProvider(path: []const u8, side: u32, done: thumbs.Done) void {
    asked += 1;
    asked_side = side;
    asked_len = @min(path.len, asked_path.len);
    @memcpy(asked_path[0..asked_len], path[0..asked_len]);
    held = done;
}

fn askedPath() []const u8 {
    return asked_path[0..asked_len];
}

/// An opaque gradient, 40 x 30.
fn deliver() void {
    var px: [40 * 30 * 4]u8 = undefined;
    for (0..30) |y| for (0..40) |x| {
        const o = (y * 40 + x) * 4;
        px[o] = @intCast(x * 6); // b
        px[o + 1] = @intCast(y * 8); // g
        px[o + 2] = 200; // r
        px[o + 3] = 255;
    };
    held.?.finish(.{ .bgra = &px, .width = 40, .height = 30 });
    held = null;
}

fn sevenByNine(path: []const u8) ?image_info.Dims {
    _ = path;
    return .{ .w = 7, .h = 9 };
}

// ---- the toggle ----

test "the inspector toggles from the shortcut, the toolbar button and the menu command" {
    var env: ts.Env = undefined;
    try env.init();
    defer env.deinit();
    try testing.expect(!env.t.hasText("No Selection"));

    try inspectorOn(&env);
    try testing.expect(env.t.hasText("No Selection"));
    try testing.expect(ts.hasIcon(&env.t, "doc.text.magnifyingglass"));

    try ts.clickIcon(&env.t, "sidebar.right"); // the toggle at the toolbar's right
    env.t.settle(0.2);
    try testing.expect(!env.m.panes.items[0].inspector and !env.t.hasText("No Selection"));
    try ts.clickIcon(&env.t, "sidebar.right");
    env.t.settle(0.2);
    try testing.expect(env.m.panes.items[0].inspector and env.t.hasText("No Selection"));

    try env.m.queue(.{ .run_command = .view_inspector });
    env.t.settle(0.2);
    try testing.expect(!env.m.panes.items[0].inspector);
    const cmds = @import("commands.zig");
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("Show Inspector", cmds.titleOf(&env.m, cmds.find(.view_inspector), &buf));
    try inspectorOn(&env);
    try testing.expectEqualStrings("Hide Inspector", cmds.titleOf(&env.m, cmds.find(.view_inspector), &buf));
}

test "the flag belongs to its pane; the list keeps its width for itself" {
    var env: ts.Env = undefined;
    try env.init();
    defer env.deinit();
    try ts.press(&env.t, 'd', .{ .cmd = true });
    try env.m.queue(.{ .focus_pane = env.m.panes.items[1].id });
    env.t.settle(0.2);
    try inspectorOnAt(&env, 1);
    try testing.expect(!env.m.panes.items[0].inspector);
    const r1 = try ts.paneRect(&env.t, &env.m, 1);
    try testing.expect(ts.findTextIn(&env.t, r1, "No Selection") != null);
    try testing.expect(ts.findTextIn(&env.t, try ts.paneRect(&env.t, &env.m, 0), "No Selection") == null);
    // The other pane's list is untouched.
    try testing.expect(ts.findTextIn(&env.t, try ts.paneRect(&env.t, &env.m, 0), "a.txt") != null);
    try testing.expect(ts.findTextIn(&env.t, try ts.paneRect(&env.t, &env.m, 0), "Size") != null);
}

fn inspectorOnAt(env: *ts.Env, i: usize) !void {
    try ts.press(&env.t, 'i', .{ .cmd = true, .alt = true });
    try testing.expect(env.m.panes.items[i].inspector);
}

// ---- what it shows ----

test "one file: name, path, buttons and details" {
    var env: ts.Env = undefined;
    try env.init();
    defer env.deinit();
    try inspectorOn(&env);
    try env.click("a.txt");
    try testing.expect(!try inPanel(&env, "No Selection"));
    for ([_][]const u8{ "a.txt", "Open", "Reveal", "Path", "Share", "Details", "Kind", "Size", "10 bytes", "Created", "Modified" }) |s| {
        if (!try inPanel(&env, s)) {
            std.debug.print("missing in the inspector: {s}\n", .{s});
            return error.TextNotFound;
        }
    }
    try testing.expect(!try inPanel(&env, "Resolution")); // not a picture
    // The path is abbreviated from home (the temp folder is home here).
    try testing.expect(try inPanel(&env, "~"));
    try env.click("b.txt");
    try testing.expect(try inPanel(&env, "20 bytes"));
}

test "a folder: kind Folder, no size" {
    var env: ts.Env = undefined;
    try env.init();
    defer env.deinit();
    try inspectorOn(&env);
    try env.click("dir");
    try testing.expect(try inPanel(&env, "Folder"));
    try testing.expect(try inPanel(&env, "--"));
    try testing.expect(!try inPanel(&env, "Resolution"));
    try testing.expect(ts.hasIcon(&env.t, "folder.fill"));
}

test "a picture shows its pixel size, read from the file's header; other files do not" {
    var env: ts.Env = undefined;
    try env.init();
    defer env.deinit();
    try withPictures(&env);
    try inspectorOn(&env);
    try env.click("pic.png");
    try testing.expect(try inPanel(&env, "Resolution"));
    try testing.expect(try inPanel(&env, "640 \u{00D7} 480"));
    try env.click("photo.jpg");
    try testing.expect(try inPanel(&env, "1920 \u{00D7} 1080"));
    // The header is read once per file, not at every frame.
    const reads = env.m.preview.dims.reads;
    env.t.settle(0.3);
    env.t.advance(0.2);
    try testing.expectEqual(reads, env.m.preview.dims.reads);
    try env.click("a.txt");
    try testing.expect(!try inPanel(&env, "Resolution"));
}

test "the image-size provider is injectable" {
    var env: ts.Env = undefined;
    try env.init();
    defer env.deinit();
    env.m.hooks.image_size = sevenByNine;
    try inspectorOn(&env);
    try env.click("a.txt");
    try testing.expect(try inPanel(&env, "7 \u{00D7} 9"));
}

test "several items: how many and how much; folders are said not to be counted" {
    var env: ts.Env = undefined;
    try env.init();
    defer env.deinit();
    try inspectorOn(&env);
    try env.click("a.txt");
    try ts.clickTextWith(&env.t, "b.txt", .{ .shift = true });
    try testing.expect(try inPanel(&env, "2 items"));
    try testing.expect(try inPanel(&env, "30 bytes total"));
    try testing.expect(!try inPanel(&env, "Details"));
    try ts.press(&env.t, 'a', .{ .cmd = true }); // a.txt, b.txt, dir
    try testing.expect(try inPanel(&env, "3 items"));
    try testing.expect(try inPanel(&env, "folders not counted"));
}

/// The horizontal centre of the panel's content (its left edge is a 1-point hairline).
fn panelCenter(env: *ts.Env) !f32 {
    const p = try panel(env);
    return p.x + 1 + (p.w - 1) / 2;
}

fn expectCentred(env: *ts.Env, s: []const u8) !void {
    const r = ts.findTextIn(&env.t, try panel(env), s) orelse return error.TextNotFound;
    const p = try panel(env);
    try testing.expect(r.x >= p.x and r.x + r.w <= p.x + p.w); // inside the panel
    try testing.expectApproxEqAbs(try panelCenter(env), r.x + r.w / 2, 1.5);
}

test "several items: the title, the total and the note are all centred in the panel, wide or narrow" {
    var env: ts.Env = undefined;
    try env.init();
    defer env.deinit();
    try inspectorOn(&env);
    try env.click("a.txt");
    try ts.press(&env.t, 'a', .{ .cmd = true }); // a.txt, b.txt, dir
    try expectCentred(&env, "3 items");
    try expectCentred(&env, "30 bytes total");
    try expectCentred(&env, "folders not counted");
    // The icon above them is on the same axis.
    const icon = ts.iconRectBelow(&env.t, "square.stack.3d.up", 0) orelse return error.IconNotFound;
    try testing.expectApproxEqAbs(try panelCenter(&env), icon.x + icon.w / 2, 1.5);
    // A four-column layout leaves each pane's panel at its narrowest.
    try env.m.queue(.{ .apply_preset = .four_columns });
    env.t.settle(0.3);
    const last = env.m.panes.items.len - 1;
    env.m.panes.items[last].inspector = true;
    env.m.focused = last;
    try ts.press(&env.t, 'a', .{ .cmd = true });
    const r = try ts.paneRect(&env.t, &env.m, last);
    const w = inspector_info.panelWidth(r.w);
    try testing.expect(w < 200);
    const p: Rect = .{ .x = r.x + r.w - w, .y = r.y, .w = w, .h = r.h };
    for ([_][]const u8{ "items", "total" }) |part| {
        var found = false;
        for (env.t.ctx.nodes.items) |n| switch (n.content) {
            .text => |tx| if (std.mem.indexOf(u8, tx.str, part) != null and p.contains(n.rect.x + n.rect.w / 2, n.rect.y + n.rect.h / 2)) {
                found = true;
                try testing.expectApproxEqAbs(p.x + 1 + (p.w - 1) / 2, n.rect.x + n.rect.w / 2, 1.5);
                try testing.expect(n.rect.x >= p.x and n.rect.x + n.rect.w <= p.x + p.w);
            },
            else => {},
        };
        try testing.expect(found);
    }
}

// ---- the thumbnail ----

test "the preview is the file's icon until a thumbnail arrives, then the thumbnail; never asked twice" {
    reset();
    var env: ts.Env = undefined;
    try env.init();
    defer env.deinit();
    env.m.hooks.thumbnail = holdProvider;
    try inspectorOn(&env);
    try testing.expectEqual(@as(usize, 0), asked); // nothing selected: nothing asked
    try env.click("a.txt");
    env.t.settle(0.3);
    try testing.expectEqual(@as(usize, 1), asked);
    try testing.expect(std.mem.endsWith(u8, askedPath(), "/a.txt"));
    try testing.expectEqual(inspector_info.thumb_side, asked_side);
    try testing.expectEqual(@as(usize, 0), images(&env));
    try testing.expect(ts.hasIcon(&env.t, "doc")); // the fallback

    deliver(); // the provider's callback: wakes a frame, which draws it
    env.t.settle(0.3);
    try testing.expectEqual(@as(usize, 1), images(&env));
    try testing.expectEqual(@as(usize, 1), asked);

    // Another file asks for its own; coming back to the first does not ask again.
    try env.click("b.txt");
    env.t.settle(0.2);
    try testing.expectEqual(@as(usize, 2), asked);
    try testing.expectEqual(@as(usize, 0), images(&env));
    deliver();
    env.t.settle(0.2);
    try env.click("a.txt");
    env.t.settle(0.2);
    try testing.expectEqual(@as(usize, 2), asked);
    try testing.expectEqual(@as(usize, 1), images(&env));
}

test "a failed thumbnail leaves the icon and is not retried" {
    reset();
    var env: ts.Env = undefined;
    try env.init();
    defer env.deinit();
    env.m.hooks.thumbnail = holdProvider;
    try inspectorOn(&env);
    try env.click("a.txt");
    held.?.finish(null);
    held = null;
    env.t.settle(0.3);
    try testing.expectEqual(@as(usize, 0), images(&env));
    try testing.expect(ts.hasIcon(&env.t, "doc"));
    env.t.advance(0.5);
    try testing.expectEqual(@as(usize, 1), asked);
}

test "no provider: the icon is the preview" {
    var env: ts.Env = undefined;
    try env.init();
    defer env.deinit();
    try inspectorOn(&env);
    try env.click("a.txt");
    try testing.expect(ts.hasIcon(&env.t, "doc") and images(&env) == 0);
}

// ---- the buttons ----

test "Reveal, Path and Open act on the selected file; Share needs a share sheet" {
    var env: ts.Env = undefined;
    try env.init();
    defer env.deinit();
    defer ts.resetOpened();
    try inspectorOn(&env);
    try env.click("a.txt");
    const want = try env.fx.sub("a.txt");
    defer testing.allocator.free(want);

    const p = try panel(&env);
    try ts.clickTextIn(&env.t, p, "Reveal");
    env.t.settle(0.2);
    try testing.expectEqualStrings(want, ts.revealedPaths());
    try ts.clickTextIn(&env.t, p, "Path");
    env.t.settle(0.2);
    try testing.expectEqualStrings(want, ts.copiedText());
    try ts.clickTextIn(&env.t, p, "Open");
    env.t.settle(0.2);
    try testing.expectEqual(@as(usize, 1), ts.opened.items.len);
    try testing.expectEqualStrings(want, ts.opened.items[0]);

    // No share sheet installed: a notice, not silence.
    try ts.clickTextIn(&env.t, p, "Share");
    env.t.settle(0.2);
    try testing.expect(env.noticeHas("Sharing"));
}

var shared: [512]u8 = undefined;
var shared_len: usize = 0;
var shared_anchor: hooks_mod.Anchor = .{ .x = -1, .y = -1, .w = 0, .h = 0 };

fn recordShare(paths: []const []const u8, anchor: hooks_mod.Anchor) void {
    shared_len = 0;
    for (paths) |s| {
        const n = @min(s.len, shared.len - shared_len);
        @memcpy(shared[shared_len..][0..n], s[0..n]);
        shared_len += n;
    }
    shared_anchor = anchor;
}

test "Share hands the selection and the button's place to the share hook" {
    var env: ts.Env = undefined;
    try env.init();
    defer env.deinit();
    shared_len = 0;
    env.m.hooks.share = recordShare;
    try inspectorOn(&env);
    try env.click("b.txt");
    const p = try panel(&env);
    try ts.clickTextIn(&env.t, p, "Share");
    env.t.settle(0.2);
    const want = try env.fx.sub("b.txt");
    defer testing.allocator.free(want);
    try testing.expectEqualStrings(want, shared[0..shared_len]);
    try testing.expect(p.contains(shared_anchor.x + shared_anchor.w / 2, shared_anchor.y + shared_anchor.h / 2));
    try testing.expect(shared_anchor.w > 0 and env.m.notice == null);
}

// ---- column view: the same component ----

test "column view's trailing preview is the inspector's component" {
    var env: ts.Env = undefined;
    try env.init();
    defer env.deinit();
    try withPictures(&env);
    env.m.focusedPane().view_mode = .column;
    env.t.settle(0.3);
    reset();
    env.m.hooks.thumbnail = holdProvider;
    try env.click("pic.png");
    for ([_][]const u8{ "Details", "Kind", "Size", "Resolution", "640 \u{00D7} 480", "Created", "Modified", "Open", "Reveal", "Path", "Share" }) |s| {
        if (!env.t.hasText(s)) {
            std.debug.print("missing in the preview column: {s}\n", .{s});
            return error.TextNotFound;
        }
    }
    try testing.expectEqual(@as(usize, 1), asked);
    deliver();
    env.t.settle(0.3);
    try testing.expectEqual(@as(usize, 1), images(&env));
    // No side inspector in column view, whatever the flag says.
    try testing.expect(!env.t.hasText("No Selection"));
    // A folder selected: no preview column.
    try env.click("dir");
    try testing.expect(!env.t.hasText("Details"));
}

test "the inspector does not take the list's keys" {
    var env: ts.Env = undefined;
    try env.init();
    defer env.deinit();
    try inspectorOn(&env);
    try env.click("a.txt");
    try ts.press(&env.t, S.down, .{});
    try testing.expect(try env.selected("b.txt"));
    try testing.expect(try inPanel(&env, "20 bytes"));
}
