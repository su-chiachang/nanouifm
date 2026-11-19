//! Tests for lister.zig. Every test works only inside a fresh `std.testing.tmpDir`.

const std = @import("std");
const builtin = @import("builtin");
const lister = @import("lister.zig");
const testing = std.testing;
const FileItem = lister.FileItem;
const SortOrder = lister.SortOrder;

const Scratch = struct {
    tmp: testing.TmpDir,
    path: []u8,

    fn init() !Scratch {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const path = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ testing.TmpDir.parent_dir_path, tmp.sub_path });
        return .{ .tmp = tmp, .path = path };
    }

    fn deinit(self: *Scratch) void {
        testing.allocator.free(self.path);
        self.tmp.cleanup(); // own temp scaffolding only
    }

    fn file(self: *Scratch, rel: []const u8, data: []const u8) !void {
        if (std.fs.path.dirname(rel)) |d| try self.tmp.dir.createDirPath(testing.io, d);
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = rel, .data = data });
    }

    fn dir(self: *Scratch, rel: []const u8) !void {
        try self.tmp.dir.createDirPath(testing.io, rel);
    }

    fn link(self: *Scratch, target: []const u8, rel: []const u8) !void {
        try self.tmp.dir.symLink(testing.io, target, rel, .{});
    }

    /// `rel` under the scratch dir, as a path the lister can open. Caller frees.
    fn sub(self: *Scratch, rel: []const u8) ![]u8 {
        return std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ self.path, rel });
    }
};

fn find(items: []const FileItem, name: []const u8) ?FileItem {
    for (items) |it| if (std.mem.eql(u8, it.name, name)) return it;
    return null;
}

fn expectNames(items: []const FileItem, expected: []const []const u8) !void {
    try testing.expectEqual(expected.len, items.len);
    for (expected, items) |e, it| try testing.expectEqualStrings(e, it.name);
}

fn expectNameSet(items: []const FileItem, expected: []const []const u8) !void {
    try testing.expectEqual(expected.len, items.len);
    for (expected) |e| try testing.expect(find(items, e) != null);
}

test "listing and hidden filter" {
    var s = try Scratch.init();
    defer s.deinit();
    try s.file("visible.txt", "hello");
    try s.file(".dotfile", "x");
    try s.dir("folder");
    try s.dir(".hiddenfolder");

    const shown = try lister.list(testing.allocator, s.path, false);
    defer lister.freeItems(testing.allocator, shown);
    try expectNameSet(shown, &.{ "visible.txt", "folder" });

    const all = try lister.list(testing.allocator, s.path, true);
    defer lister.freeItems(testing.allocator, all);
    try expectNameSet(all, &.{ "visible.txt", "folder", ".dotfile", ".hiddenfolder" });
    try testing.expect(find(all, ".dotfile").?.is_hidden);
    try testing.expect(!find(all, "visible.txt").?.is_hidden);

    const file = find(all, "visible.txt").?;
    try testing.expect(!file.is_directory);
    try testing.expectEqual(@as(?i64, 5), file.size);
    try testing.expect(file.modified != null);
    if (builtin.os.tag.isDarwin()) try testing.expect(file.created != null);
    try testing.expect(std.mem.endsWith(u8, file.path, "/visible.txt"));
    try testing.expectEqualStrings("Plain text document", file.kind);

    const folder = find(all, "folder").?;
    try testing.expect(folder.is_directory);
    try testing.expectEqual(@as(?i64, null), folder.size);
    try testing.expectEqualStrings("Folder", folder.kind);
    try testing.expect(!std.mem.eql(u8, folder.kind, file.kind));
}

test "kind fallbacks" {
    var s = try Scratch.init();
    defer s.deinit();
    try s.file("a.jpg", "x");
    try s.file("b.qqz", "x");
    try s.file("noext", "x");
    const items = try lister.list(testing.allocator, s.path, false);
    defer lister.freeItems(testing.allocator, items);
    try testing.expectEqualStrings("JPEG image", find(items, "a.jpg").?.kind);
    try testing.expectEqualStrings("QQZ file", find(items, "b.qqz").?.kind);
    try testing.expectEqualStrings("Document", find(items, "noext").?.kind);
}

test "UF_HIDDEN flag marks an item hidden" {
    if (!builtin.os.tag.isDarwin()) return error.SkipZigTest;
    const chflags = struct {
        extern "c" fn chflags(path: [*:0]const u8, flags: c_uint) c_int;
    }.chflags;
    var s = try Scratch.init();
    defer s.deinit();
    try s.file("flagged.txt", "x");
    try s.file("plain.txt", "x");
    const p = try s.sub("flagged.txt");
    defer testing.allocator.free(p);
    const pz = try testing.allocator.dupeSentinel(u8, p, 0);
    defer testing.allocator.free(pz);
    try testing.expectEqual(@as(c_int, 0), chflags(pz, 0x8000));

    const shown = try lister.list(testing.allocator, s.path, false);
    defer lister.freeItems(testing.allocator, shown);
    try testing.expect(find(shown, "flagged.txt") == null);
    try testing.expect(find(shown, "plain.txt") != null);
    const all = try lister.list(testing.allocator, s.path, true);
    defer lister.freeItems(testing.allocator, all);
    try testing.expect(find(all, "flagged.txt").?.is_hidden);
}

test "unreadable directory errors" {
    var s = try Scratch.init();
    defer s.deinit();
    const missing = try s.sub("missing");
    defer testing.allocator.free(missing);
    try testing.expectError(error.FileNotFound, lister.list(testing.allocator, missing, false));
    try s.file("plain", "x");
    const plain = try s.sub("plain");
    defer testing.allocator.free(plain);
    try testing.expectError(error.NotDir, lister.list(testing.allocator, plain, false));
}

test "packages and symlinks" {
    var s = try Scratch.init();
    defer s.deinit();
    try s.file("Thing.app/Contents/Info.txt", "x");
    try s.dir("target");
    try s.link("target", "link");
    try s.file("real.txt", "x");
    try s.link("real.txt", "filelink");

    const items = try lister.list(testing.allocator, s.path, false);
    defer lister.freeItems(testing.allocator, items);
    const app = find(items, "Thing.app").?;
    try testing.expect(app.is_package);
    try testing.expect(!app.is_directory); // packages are not directories
    try testing.expectEqualStrings("Application", app.kind);
    const l = find(items, "link").?;
    try testing.expect(l.is_symlink);
    try testing.expect(l.is_directory); // symlink to a folder behaves like a folder
    const fl = find(items, "filelink").?;
    try testing.expect(fl.is_symlink);
    try testing.expect(!fl.is_directory);
    try testing.expectEqual(@as(?i64, 1), fl.size);
}

test "listing through a symlinked folder" {
    var s = try Scratch.init();
    defer s.deinit();
    try s.file("target/inside.txt", "x");
    try s.link("target", "link");
    const link = try s.sub("link");
    defer testing.allocator.free(link);
    const items = try lister.list(testing.allocator, link, false);
    defer lister.freeItems(testing.allocator, items);
    try expectNames(items, &.{"inside.txt"});
    const want = try s.sub("link/inside.txt");
    defer testing.allocator.free(want);
    try testing.expectEqualStrings(want, items[0].path); // children stay under the link's own path
    try testing.expectEqual(@as(?i64, 1), items[0].size);

    // A dangling link reports an error rather than an empty folder.
    try s.link("/nonexistent-nanofm-target", "dangling");
    const dangling = try s.sub("dangling");
    defer testing.allocator.free(dangling);
    try testing.expectError(error.FileNotFound, lister.list(testing.allocator, dangling, false));
}

test "item at" {
    var s = try Scratch.init();
    defer s.deinit();
    try s.file("a.txt", "abc");
    try s.link("/nonexistent-nanofm-target", "dangling");
    const f = try s.sub("a.txt");
    defer testing.allocator.free(f);
    const it = (try lister.item(testing.allocator, f)).?;
    defer it.deinit(testing.allocator);
    try testing.expectEqualStrings("a.txt", it.name);
    try testing.expectEqual(@as(?i64, 3), it.size);

    const nope = try s.sub("nope");
    defer testing.allocator.free(nope);
    try testing.expect((try lister.item(testing.allocator, nope)) == null);

    const dl = try s.sub("dangling");
    defer testing.allocator.free(dl);
    const d = (try lister.item(testing.allocator, dl)).?; // dangling links still count
    defer d.deinit(testing.allocator);
    try testing.expect(d.is_symlink);
    try testing.expect(!d.is_directory);
}

// ---- Sorting ----

const Opts = struct {
    dir: bool = false,
    size: ?i64 = null,
    modified: ?i64 = null,
    created: ?i64 = null,
    kind: []const u8 = "Document",
};

fn mk(name: []const u8, o: Opts) FileItem {
    return .{
        .path = name, .name = name, .is_directory = o.dir, .is_package = false, .is_hidden = false,
        .is_symlink = false, .size = if (o.dir) null else o.size, .modified = o.modified,
        .created = o.created, .kind = if (o.dir) "Folder" else o.kind,
    };
}

fn sortedNames(items: []const FileItem, order: SortOrder, expected: []const []const u8) !void {
    const out = try lister.sorted(testing.allocator, items, order);
    defer testing.allocator.free(out);
    try expectNames(out, expected);
}

test "sort by name is Finder-like" {
    const items = [_]FileItem{ mk("file10.txt", .{}), mk("File2.txt", .{}), mk("file1.txt", .{}), mk("Zeta", .{}), mk("alpha", .{}) };
    try sortedNames(&items, .{ .key = .name, .ascending = true, .folders_first = false }, &.{ "alpha", "file1.txt", "File2.txt", "file10.txt", "Zeta" });
    try sortedNames(&items, .{ .key = .name, .ascending = false, .folders_first = false }, &.{ "Zeta", "file10.txt", "File2.txt", "file1.txt", "alpha" });
}

test "folders first toggle" {
    const items = [_]FileItem{ mk("b.txt", .{}), mk("zdir", .{ .dir = true }), mk("a.txt", .{}), mk("adir", .{ .dir = true }) };
    try sortedNames(&items, .{ .ascending = true, .folders_first = true }, &.{ "adir", "zdir", "a.txt", "b.txt" });
    try sortedNames(&items, .{ .ascending = false, .folders_first = true }, &.{ "zdir", "adir", "b.txt", "a.txt" });
    try sortedNames(&items, .{ .ascending = true, .folders_first = false }, &.{ "a.txt", "adir", "b.txt", "zdir" });
}

test "sort by size puts null last in both directions" {
    const items = [_]FileItem{ mk("mid", .{ .size = 50 }), mk("dir", .{ .dir = true }), mk("big", .{ .size = 500 }), mk("small", .{ .size = 5 }) };
    try sortedNames(&items, .{ .key = .size, .ascending = true, .folders_first = false }, &.{ "small", "mid", "big", "dir" });
    try sortedNames(&items, .{ .key = .size, .ascending = false, .folders_first = false }, &.{ "big", "mid", "small", "dir" });
}

test "sort by dates" {
    const t: i64 = 1_000_000;
    const items = [_]FileItem{
        mk("old", .{ .modified = t, .created = t + 300 }),
        mk("new", .{ .modified = t + 200, .created = t }),
        mk("none", .{}),
        mk("mid", .{ .modified = t + 100, .created = t + 100 }),
    };
    try sortedNames(&items, .{ .key = .modified, .folders_first = false }, &.{ "old", "mid", "new", "none" });
    try sortedNames(&items, .{ .key = .modified, .ascending = false, .folders_first = false }, &.{ "new", "mid", "old", "none" });
    try sortedNames(&items, .{ .key = .created, .folders_first = false }, &.{ "new", "mid", "old", "none" });
}

test "sort by kind then name, and stability" {
    const items = [_]FileItem{ mk("b.png", .{ .kind = "PNG image" }), mk("a.txt", .{ .kind = "Text" }), mk("a.png", .{ .kind = "PNG image" }), mk("dir", .{ .dir = true }) };
    try sortedNames(&items, .{ .key = .kind, .folders_first = false }, &.{ "dir", "a.png", "b.png", "a.txt" });

    // identical keys keep input order
    var same = [_]FileItem{ mk("x", .{ .size = 1 }), mk("x", .{ .size = 1 }) };
    same[0].path = "/v/0";
    same[1].path = "/v/1";
    lister.sort(&same, .{ .key = .size });
    try testing.expectEqualStrings("/v/0", same[0].path);
    try testing.expectEqualStrings("/v/1", same[1].path);
}

test "freeItems on an empty listing" {
    var s = try Scratch.init();
    defer s.deinit();
    const items = try lister.list(testing.allocator, s.path, true);
    defer lister.freeItems(testing.allocator, items);
    try testing.expectEqual(@as(usize, 0), items.len);
}
