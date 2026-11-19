//! Per-file-type icons in the rows, the path bar and the inspector (`file_icons.zig`, `row_icon.zig`):
//! a fake provider that holds its answers until the test lets them go. The generic symbol shows
//! first and the real icon after the delivery; one request per KEY however many rows share it
//! (ten thousand rows of one extension: one); failures are not retried; folders are one key; apps
//! are keyed by path; at most a few requests are out at once; no provider: the symbols exactly as
//! before. Temp folders only: no test touches NSWorkspace.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const lister = @import("../core/lister.zig");
const file_icons = @import("file_icons.zig");
const row_icon = @import("row_icon.zig");
const ts = @import("test_support.zig");

const testing = std.testing;

// ---- the fake provider ----

const Held = struct {
    done: ?file_icons.Done = null,
    side: u32 = 0,
    kind: std.meta.Tag(file_icons.Key) = .folder,
    text: [512]u8 = undefined,
    text_len: usize = 0,

    fn name(h: *const Held) []const u8 {
        return h.text[0..h.text_len];
    }
};

var held: [96]Held = undefined;
var asked: usize = 0;

fn reset() void {
    asked = 0;
    for (&held) |*h| h.* = .{};
}

fn holdProvider(key: file_icons.Key, side: u32, done: file_icons.Done) void {
    const h = &held[asked];
    asked += 1;
    h.* = .{ .done = done, .side = side, .kind = key };
    const text: []const u8 = switch (key) {
        .ext => |e| e,
        .path => |p| p,
        else => "",
    };
    h.text_len = @min(text.len, h.text.len);
    @memcpy(h.text[0..h.text_len], text[0..h.text_len]);
}

/// An opaque 32 x 32 square of one colour (premultiplied BGRA).
fn deliverOne(h: *Held, shade: u8) void {
    var px: [32 * 32 * 4]u8 = undefined;
    var i: usize = 0;
    while (i < px.len) : (i += 4) {
        px[i] = shade;
        px[i + 1] = 90;
        px[i + 2] = 255 - shade;
        px[i + 3] = 255;
    }
    h.done.?.finish(.{ .bgra = &px, .width = 32, .height = 32 });
    h.done = null;
}

/// Answers every request still held.
fn deliverAll() void {
    for (held[0..asked], 0..) |*h, i| if (h.done != null) deliverOne(h, @intCast(30 + i * 7));
}

fn failAll() void {
    for (held[0..asked]) |*h| if (h.done) |d| {
        d.finish(null);
        h.done = null;
    };
}

fn heldCount() usize {
    var n: usize = 0;
    for (held[0..asked]) |h| if (h.done != null) {
        n += 1;
    };
    return n;
}

/// How many requests were for `text` of kind `kind` (any size).
fn timesAsked(kind: std.meta.Tag(file_icons.Key), text: []const u8) usize {
    var n: usize = 0;
    for (held[0..asked]) |h| if (h.kind == kind and std.mem.eql(u8, h.name(), text)) {
        n += 1;
    };
    return n;
}

/// The pictures of side `w` x `w` points this frame draws.
fn imagesOf(env: *ts.Env, w: f32) usize {
    var n: usize = 0;
    for (env.t.ctx.nodes.items) |nd| switch (nd.content) {
        .image => if (nd.rect.w == w and nd.rect.h == w) {
            n += 1;
        },
        else => {},
    };
    return n;
}

/// The icons (symbols) named `symbol` this frame draws.
fn symbols(env: *ts.Env, symbol: []const u8) usize {
    var n: usize = 0;
    for (env.t.ctx.nodes.items) |nd| switch (nd.content) {
        .icon => |ic| if (std.mem.eql(u8, ic.name, symbol)) {
            n += 1;
        },
        else => {},
    };
    return n;
}

/// Ends a test: the model goes, then the answers nobody gave (a request held owns a job).
fn finish(env: *ts.Env) void {
    env.deinit();
    failAll();
}

/// Answers rounds of requests until none is out (the cap lets a few go at a time).
fn drain(env: *ts.Env) void {
    var rounds: usize = 0;
    while (heldCount() > 0 and rounds < 40) : (rounds += 1) {
        deliverAll();
        env.t.settle(0.3);
    }
}

fn hooked(env: *ts.Env, files: []const []const u8) !void {
    reset();
    try env.initWith(.{ .files = files });
    env.m.hooks.file_icon = holdProvider;
    env.t.settle(0.3);
}

// ---- keys ----

fn item(name: []const u8, o: struct { dir: bool = false, pkg: bool = false }) lister.FileItem {
    return .{
        .path = name,
        .name = name,
        .is_directory = o.dir,
        .is_package = o.pkg,
        .is_hidden = false,
        .is_symlink = false,
        .size = null,
        .modified = null,
        .created = null,
        .kind = "",
    };
}

test "a row's key: folders share one, files their lowercased extension, apps their path" {
    var b: [file_icons.max_ext]u8 = undefined;
    try testing.expect(row_icon.keyFor(item("Photos", .{ .dir = true }), &b) == .folder);
    try testing.expectEqualStrings("jpg", row_icon.keyFor(item("Holiday.JPG", .{}), &b).ext);
    try testing.expectEqualStrings("gz", row_icon.keyFor(item("a.tar.gz", .{}), &b).ext);
    try testing.expect(row_icon.keyFor(item("README", .{}), &b) == .file);
    try testing.expect(row_icon.keyFor(item(".bashrc", .{}), &b) == .file);
    try testing.expect(row_icon.keyFor(item("odd.xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx", .{}), &b) == .file);
    try testing.expectEqualStrings("/Apps/Foo.app", row_icon.keyFor(.{ .path = "/Apps/Foo.app", .name = "Foo.app", .is_directory = false, .is_package = true, .is_hidden = false, .is_symlink = false, .size = null, .modified = null, .created = null, .kind = "" }, &b).path);
    // Another package type shares its extension's icon.
    try testing.expectEqualStrings("bundle", row_icon.keyFor(item("x.bundle", .{ .pkg = true }), &b).ext);
}

// ---- the list ----

test "rows show the generic symbol first and the real icon after delivery; one request per key" {
    var env: ts.Env = undefined;
    try hooked(&env, &.{ "c.TXT", "d.png" });
    defer finish(&env);
    // a.txt, b.txt, c.TXT, d.png, dir: three keys, plus the home crumb (its own icon).
    try testing.expectEqual(@as(usize, 4), asked);
    try testing.expectEqual(@as(usize, 1), timesAsked(.ext, "txt"));
    try testing.expectEqual(@as(usize, 1), timesAsked(.ext, "png"));
    try testing.expectEqual(@as(usize, 1), timesAsked(.folder, ""));
    try testing.expectEqual(@as(usize, 1), timesAsked(.path, env.fx.root));
    try testing.expectEqual(file_icons.row_side, held[0].side);
    try testing.expectEqual(@as(usize, 0), imagesOf(&env, 16));
    try testing.expectEqual(@as(usize, 4), symbols(&env, "doc")); // the generic ones are there
    const folder_symbols = symbols(&env, "folder.fill");

    deliverAll();
    env.t.settle(0.3);
    try testing.expectEqual(@as(usize, 5), imagesOf(&env, 16)); // every row
    try testing.expectEqual(@as(usize, 1), imagesOf(&env, 14)); // the home crumb
    try testing.expectEqual(@as(usize, 0), symbols(&env, "doc"));
    try testing.expect(symbols(&env, "folder.fill") < folder_symbols);
    try testing.expectEqual(@as(usize, 4), asked); // nothing asked twice

    env.t.advance(0.5); // more frames: still nothing new
    try testing.expectEqual(@as(usize, 4), asked);
    try testing.expectEqual(@as(usize, 5), imagesOf(&env, 16));
}

test "ten thousand rows of one extension make one request, and only the visible rows draw" {
    var env: ts.Env = undefined;
    reset();
    var names: std.ArrayList([]const u8) = .empty;
    defer {
        for (names.items) |n| testing.allocator.free(n);
        names.deinit(testing.allocator);
    }
    for (0..10_000) |i| try names.append(testing.allocator, try std.fmt.allocPrint(testing.allocator, "n{d:0>5}.log", .{i}));
    try env.initWith(.{ .files = names.items });
    defer finish(&env);
    env.m.hooks.file_icon = holdProvider;
    env.t.settle(0.3);
    try testing.expectEqual(@as(usize, 1), timesAsked(.ext, "log"));
    try testing.expectEqual(@as(usize, 1), timesAsked(.ext, "txt"));
    deliverAll();
    env.t.settle(0.3);
    const shown = imagesOf(&env, 16);
    try testing.expect(shown > 5 and shown < 40); // the visible rows, not ten thousand
    const before = asked;
    for (0..8) |_| {
        env.t.scroll(500, 200, -400);
        env.t.settle(0.2);
    }
    try testing.expectEqual(before, asked); // scrolling asks for nothing new
    try testing.expect(imagesOf(&env, 16) > 5);
    try testing.expectEqual(@as(usize, 0), symbols(&env, "doc")); // every visible row has its icon
}

test "a failed icon keeps the symbol and is not asked again" {
    var env: ts.Env = undefined;
    try hooked(&env, &.{});
    defer finish(&env);
    const n = asked;
    failAll();
    env.t.settle(0.3);
    try testing.expectEqual(@as(usize, 0), imagesOf(&env, 16));
    try testing.expect(symbols(&env, "doc") >= 2);
    env.t.advance(0.5);
    try env.m.queue(.reload);
    env.t.settle(0.3);
    try testing.expectEqual(n, asked);
    try testing.expect(symbols(&env, "doc") >= 2);
}

test "folders are one key; apps and other packages: an app by its own path, others by extension" {
    var env: ts.Env = undefined;
    reset();
    try env.init();
    defer finish(&env);
    try env.fx.dir("Foo.app");
    try env.fx.dir("Bar.app");
    try env.fx.dir("Baz.bundle");
    try env.fx.dir("d2");
    try env.fx.dir("d3");
    try env.m.queue(.reload);
    env.m.hooks.file_icon = holdProvider;
    env.t.settle(0.3);
    try testing.expectEqual(@as(usize, 1), timesAsked(.folder, "")); // dir, d2, d3
    const foo = try env.fx.sub("Foo.app");
    defer testing.allocator.free(foo);
    const bar = try env.fx.sub("Bar.app");
    defer testing.allocator.free(bar);
    try testing.expectEqual(@as(usize, 1), timesAsked(.path, foo));
    try testing.expectEqual(@as(usize, 1), timesAsked(.path, bar));
    try testing.expectEqual(@as(usize, 0), timesAsked(.ext, "app"));
    try testing.expectEqual(@as(usize, 1), timesAsked(.ext, "bundle"));
}

test "no provider: the generic symbols exactly as before, nothing asked, nothing cached" {
    reset();
    var env: ts.Env = undefined;
    try env.init();
    defer finish(&env);
    env.t.settle(0.3);
    try testing.expectEqual(@as(usize, 0), imagesOf(&env, 16));
    try testing.expectEqual(@as(usize, 0), imagesOf(&env, 14));
    try testing.expect(symbols(&env, "doc") >= 2 and symbols(&env, "folder.fill") >= 1 and ts.hasIcon(&env.t, "house"));
    try testing.expectEqual(@as(usize, 0), env.m.preview.icons.requests);
    try testing.expectEqual(@as(usize, 0), env.m.preview.icons.count());
}

test "at most max_in_flight requests are out; the rest follow as they are answered, none twice" {
    var env: ts.Env = undefined;
    var names: [20][]const u8 = undefined;
    var bufs: [20][16]u8 = undefined;
    for (&names, 0..) |*n, i| n.* = try std.fmt.bufPrint(&bufs[i], "t{d}.e{d:0>2}", .{ i, i });
    try hooked(&env, &names);
    defer finish(&env);
    try testing.expectEqual(file_icons.max_in_flight, asked);
    try testing.expectEqual(file_icons.max_in_flight, heldCount());
    var rounds: usize = 0;
    while (heldCount() > 0 and rounds < 20) : (rounds += 1) {
        deliverAll();
        env.t.settle(0.3);
    }
    // The visible rows asked for their keys in several rounds, each key exactly once.
    try testing.expect(asked > file_icons.max_in_flight);
    for (held[0..asked], 0..) |h, i| for (held[0..i]) |g| {
        try testing.expect(!(g.kind == h.kind and g.side == h.side and std.mem.eql(u8, g.name(), h.name())));
    };
    try testing.expectEqual(@as(usize, 0), symbols(&env, "doc")); // every visible row has its own icon
    try testing.expect(imagesOf(&env, 16) > file_icons.max_in_flight);
}

test "a model that goes away with a request held leaves nothing behind" {
    var env: ts.Env = undefined;
    try hooked(&env, &.{});
    try testing.expect(heldCount() > 0);
    env.deinit(); // the provider still holds its answers
    deliverAll(); // late answers: the leak checker proves nothing stays
}

// ---- the inspector, the columns and the path bar ----

test "the inspector's fallback is the large icon of the file's type" {
    var env: ts.Env = undefined;
    try hooked(&env, &.{});
    defer finish(&env);
    try ts.press(&env.t, 'i', .{ .cmd = true, .alt = true });
    try env.click("a.txt");
    env.t.settle(0.3);
    var large: ?*Held = null;
    for (held[0..asked]) |*h| if (h.side == file_icons.large_side and h.kind == .ext and std.mem.eql(u8, h.name(), "txt")) {
        large = h;
    };
    try testing.expect(large != null);
    try testing.expectEqual(@as(usize, 0), imagesOf(&env, 64));
    try testing.expect(symbols(&env, "doc") >= 1); // the big symbol until then
    deliverAll();
    env.t.settle(0.3);
    try testing.expectEqual(@as(usize, 1), imagesOf(&env, 64));
    const n = asked;
    try env.click("b.txt"); // the same type: no new request
    env.t.settle(0.3);
    try testing.expectEqual(n, asked);
    try testing.expectEqual(@as(usize, 1), imagesOf(&env, 64));
}

test "column view rows and the path bar's folders get their icons too" {
    var env: ts.Env = undefined;
    try hooked(&env, &.{});
    defer finish(&env);
    env.m.focusedPane().view_mode = .column;
    env.t.settle(0.3);
    try testing.expectEqual(@as(usize, 1), timesAsked(.folder, ""));
    try testing.expect(symbols(&env, "doc") >= 2);
    drain(&env);
    // The columns start at the root of the disk: the folders above are columns too.
    try testing.expect(imagesOf(&env, 16) >= 3); // at least a.txt, b.txt, dir
    try testing.expectEqual(@as(usize, 0), symbols(&env, "doc"));
}

test "the path bar: the home crumb has its own icon, every other crumb is a plain folder" {
    var env: ts.Env = undefined;
    try hooked(&env, &.{});
    defer finish(&env);
    deliverAll();
    env.t.settle(0.3);
    try testing.expectEqual(@as(usize, 1), imagesOf(&env, 14)); // home
    const dir = try env.fx.sub("dir");
    defer testing.allocator.free(dir);
    try env.m.queue(.{ .open = dir });
    env.t.settle(0.3);
    deliverAll();
    env.t.settle(0.3);
    try testing.expectEqual(@as(usize, 2), imagesOf(&env, 14)); // home > dir
    try testing.expectEqual(@as(usize, 1), timesAsked(.folder, "")); // the rows' folder key, shared
    try testing.expectEqual(@as(usize, 1), timesAsked(.path, env.fx.root));
}
