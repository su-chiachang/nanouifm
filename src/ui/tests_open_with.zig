//! The context menu's "Open With <App>" rows through ui.Tester (`open_with.zig`): a fake hook
//! answers with made-up apps and records what it is asked to open; no app is ever listed from the
//! system or launched. Temp folders only.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const hooks = @import("hooks.zig");
const commands = @import("commands.zig");
const ts = @import("test_support.zig");
const open_with = @import("open_with.zig");

const testing = std.testing;

var list_calls: usize = 0;
var listed: [512]u8 = undefined;
var listed_len: usize = 0;
var open_calls: usize = 0;
var opened_app: [256]u8 = undefined;
var opened_app_len: usize = 0;
var opened_file: [512]u8 = undefined;
var opened_file_len: usize = 0;
var open_ok = true;

fn reset() void {
    list_calls = 0;
    listed_len = 0;
    open_calls = 0;
    opened_app_len = 0;
    opened_file_len = 0;
    open_ok = true;
}

fn made(gpa: std.mem.Allocator, names: []const []const u8) ![]hooks.OpenApp {
    const out = try gpa.alloc(hooks.OpenApp, names.len);
    var n: usize = 0;
    errdefer {
        for (out[0..n]) |a| {
            gpa.free(a.name);
            gpa.free(a.path);
        }
        gpa.free(out);
    }
    for (names, out) |name, *o| {
        const nm = try gpa.dupe(u8, name);
        errdefer gpa.free(nm);
        const path = try std.fmt.allocPrint(gpa, "/Applications/{s}.app", .{name});
        o.* = .{ .name = nm, .path = path };
        n += 1;
    }
    return out;
}

/// ".txt": TextEdit (the default), Preview, Xcode. ".many": ten apps. Anything else: Preview.
fn fakeList(gpa: std.mem.Allocator, file: []const u8) std.mem.Allocator.Error![]hooks.OpenApp {
    list_calls += 1;
    const n = @min(file.len, listed.len);
    @memcpy(listed[0..n], file[0..n]);
    listed_len = n;
    if (std.mem.endsWith(u8, file, ".txt")) return made(gpa, &.{ "TextEdit", "Preview", "Xcode" });
    if (std.mem.endsWith(u8, file, ".many")) return made(gpa, &.{ "App0", "App1", "App2", "App3", "App4", "App5", "App6", "App7", "App8", "App9" });
    return made(gpa, &.{"Preview"});
}

fn fakeOpen(app_path: []const u8, file: []const u8) bool {
    open_calls += 1;
    opened_app_len = @min(app_path.len, opened_app.len);
    @memcpy(opened_app[0..opened_app_len], app_path[0..opened_app_len]);
    opened_file_len = @min(file.len, opened_file.len);
    @memcpy(opened_file[0..opened_file_len], file[0..opened_file_len]);
    return open_ok;
}

const fake: hooks.OpenWith = .{ .list = fakeList, .open = fakeOpen };

fn start(env: *ts.Env) !void {
    try env.initWith(.{ .files = &.{ "c.many", "pic.png" } });
    env.m.hooks.open_with = fake;
    ts.resetOpened();
    reset();
}

fn rightClick(env: *ts.Env, name: []const u8) !void {
    const r = env.t.findText(name) orelse return error.TextNotFound;
    env.t.secondaryClick(r.x + r.w / 2, r.y + r.h / 2);
    env.t.settle(0.4);
}

fn closeMenu(env: *ts.Env) void {
    env.m.view_state.ctx_menu.open = false;
    env.t.settle(0.4);
    env.t.advance(0.8);
}

test "a single file gets one row per app, the default first and marked, below Open" {
    var env: ts.Env = undefined;
    try start(&env);
    defer env.deinit();
    defer ts.resetOpened();
    try rightClick(&env, "a.txt");
    try testing.expect(env.t.hasText("Open With TextEdit (default)"));
    try testing.expect(env.t.hasText("Open With Preview"));
    try testing.expect(env.t.hasText("Open With Xcode"));
    try testing.expect(!env.t.hasText("Open With Default App")); // the apps take its place
    try testing.expect(!env.t.hasText("Open With TextEdit")); // only the default is marked, and only once
    const open_y = try ts.textY(&env.t, "Open in Split");
    const default_y = try ts.textY(&env.t, "Open With TextEdit (default)");
    const preview_y = try ts.textY(&env.t, "Open With Preview");
    try testing.expect(default_y > open_y and preview_y > default_y);
    try testing.expectEqual(@as(usize, 1), list_calls);
    try testing.expect(std.mem.endsWith(u8, listed[0..listed_len], "a.txt"));
    // The rest of the menu is still there.
    try testing.expect(env.t.hasText("Quick Look") and env.t.hasText("Move to Trash"));
}

test "choosing a row opens that file with that app through the hook, and nothing else" {
    var env: ts.Env = undefined;
    try start(&env);
    defer env.deinit();
    defer ts.resetOpened();
    try rightClick(&env, "a.txt");
    try env.t.clickText("Open With Preview");
    env.t.settle(0.4);
    try testing.expect(!env.m.view_state.ctx_menu.open);
    try testing.expectEqual(@as(usize, 1), open_calls);
    try testing.expectEqualStrings("/Applications/Preview.app", opened_app[0..opened_app_len]);
    const a = try env.fx.sub("a.txt");
    defer testing.allocator.free(a);
    try testing.expectEqualStrings(a, opened_file[0..opened_file_len]);
    try testing.expectEqual(@as(usize, 0), ts.opened.items.len); // not the default opener
    try testing.expect(env.m.notice == null);
    // The default row is the first app.
    env.t.advance(0.8);
    try rightClick(&env, "a.txt");
    try env.t.clickText("Open With TextEdit (default)");
    env.t.settle(0.4);
    try testing.expectEqualStrings("/Applications/TextEdit.app", opened_app[0..opened_app_len]);
    try testing.expectEqual(@as(usize, 2), open_calls);
}

test "a refused open raises a notice" {
    var env: ts.Env = undefined;
    try start(&env);
    defer env.deinit();
    defer ts.resetOpened();
    open_ok = false;
    try rightClick(&env, "a.txt");
    try env.t.clickText("Open With Xcode");
    env.t.settle(0.4);
    try testing.expect(env.noticeHas("Can't open \"a.txt\" with Xcode"));
}

test "the apps are asked for once per extension, not at every right-click" {
    var env: ts.Env = undefined;
    try start(&env);
    defer env.deinit();
    defer ts.resetOpened();
    try rightClick(&env, "a.txt");
    try testing.expectEqual(@as(usize, 1), list_calls);
    closeMenu(&env);
    try rightClick(&env, "b.txt"); // another .txt
    try testing.expect(env.t.hasText("Open With TextEdit (default)"));
    try testing.expectEqual(@as(usize, 1), list_calls);
    try testing.expect(std.mem.endsWith(u8, listed[0..listed_len], "a.txt"));
    closeMenu(&env);
    try rightClick(&env, "pic.png"); // another kind
    try testing.expect(env.t.hasText("Open With Preview (default)"));
    try testing.expect(!env.t.hasText("Open With TextEdit (default)"));
    try testing.expectEqual(@as(usize, 2), list_calls);
}

test "at most eight apps, whatever the system lists" {
    var env: ts.Env = undefined;
    try start(&env);
    defer env.deinit();
    defer ts.resetOpened();
    try rightClick(&env, "c.many");
    try testing.expect(env.t.hasText("Open With App0 (default)"));
    try testing.expect(env.t.hasText("Open With App7"));
    try testing.expect(!env.t.hasText("Open With App8") and !env.t.hasText("Open With App9"));
}

test "asking only notes the file; the lookup happens at the next pass" {
    var env: ts.Env = undefined;
    try start(&env);
    defer env.deinit();
    defer ts.resetOpened();
    const a = try env.fx.sub("a.txt");
    defer testing.allocator.free(a);
    try testing.expect(try open_with.ask(&env.m, a));
    try testing.expect(!try open_with.ask(&env.m, a)); // already pending
    try testing.expectEqual(@as(usize, 0), list_calls);
    try testing.expect(open_with.appsFor(&env.m, a) == null);
    _ = try env.m.applyPending(); // the start of the next pass
    try testing.expectEqual(@as(usize, 1), list_calls);
    try testing.expectEqual(@as(usize, 3), open_with.appsFor(&env.m, a).?.len);
    try testing.expect(!try open_with.ask(&env.m, a)); // known now
    // Through the menu: the first frame has the plain row, a later one the apps (no hook call
    // happens while the view draws).
    const b = try env.fx.sub("pic.png");
    defer testing.allocator.free(b);
    try testing.expect(open_with.appsFor(&env.m, b) == null);
    try rightClick(&env, "pic.png");
    try testing.expectEqual(@as(usize, 2), list_calls);
    try testing.expect(open_with.appsFor(&env.m, b) != null);
}

test "no app rows for a folder, several items, empty space, or without a hook" {
    var env: ts.Env = undefined;
    try start(&env);
    defer env.deinit();
    defer ts.resetOpened();
    // A folder.
    try rightClick(&env, "dir");
    try testing.expect(env.t.hasText("Open With Default App"));
    try testing.expect(!env.t.hasText("Open With Preview") and !env.t.hasText("Open With TextEdit (default)"));
    closeMenu(&env);
    // Several items.
    try env.click("a.txt");
    try ts.clickTextWith(&env.t, "b.txt", .{ .cmd = true });
    try rightClick(&env, "b.txt");
    try testing.expectEqual(@as(usize, 2), env.m.focusedTab().selection.count());
    try testing.expect(env.t.hasText("Open With Default App"));
    try testing.expect(!env.t.hasText("Open With Preview"));
    closeMenu(&env);
    // Empty space: the folder's menu has no Open With at all.
    const pr = try ts.paneRect(&env.t, &env.m, 0);
    env.t.secondaryClick(pr.x + pr.w / 2, pr.y + pr.h - 90);
    env.t.settle(0.4);
    try testing.expect(env.m.view_state.ctx_menu.open and !env.m.view_state.ctx_menu.on_item);
    try testing.expect(!env.t.hasText("Open With Default App") and !env.t.hasText("Open With Preview"));
    closeMenu(&env);
    try testing.expectEqual(@as(usize, 0), list_calls); // nobody asked the system
    // No hook: the single row, and the commands do nothing.
    env.m.hooks.open_with = null;
    try env.click("a.txt");
    try rightClick(&env, "a.txt");
    try testing.expect(env.t.hasText("Open With Default App"));
    try testing.expectEqual(@as(usize, 0), list_calls);
    try testing.expect(!commands.isEnabled(&env.m, commands.find(.file_open_with_0)));
}

test "the row commands are enabled only for a single file whose apps are known" {
    var env: ts.Env = undefined;
    try start(&env);
    defer env.deinit();
    defer ts.resetOpened();
    try env.click("a.txt");
    try testing.expect(!commands.isEnabled(&env.m, commands.find(.file_open_with_0))); // not asked yet
    try rightClick(&env, "a.txt");
    closeMenu(&env);
    try testing.expect(commands.isEnabled(&env.m, commands.find(.file_open_with_2)));
    try testing.expect(!commands.isEnabled(&env.m, commands.find(.file_open_with_3))); // only three apps
    try env.click("dir");
    try testing.expect(!commands.isEnabled(&env.m, commands.find(.file_open_with_0)));
    // Not in the palette or the menu bar.
    try testing.expect(!commands.find(.file_open_with_0).in_palette and !commands.find(.file_open_with_7).in_menu);
}
