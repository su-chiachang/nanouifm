//! file_ops tests, part 1: move, copy, duplicate, rename, createFolder.
//! Everything happens in fresh scratch dirs under the system temp directory.
const std = @import("std");
const T = @import("file_ops_test_support.zig");
const fs = @import("file_ops_fs.zig");
const ops = @import("file_ops.zig");

const gpa = std.testing.allocator;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const expect = std.testing.expect;

fn leaves(want: []const []const u8, got: []const []const u8) !void {
    try expectEqual(want.len, got.len);
    for (want, got) |w, g| try expectEqualStrings(w, std.fs.path.basename(g));
}

test "move and undo/redo" {
    var e = try T.Env.init(gpa);
    defer e.deinit();
    const s = &e.s;
    const a = try s.file(s.dir, "a.txt", "A");
    const b = try s.file(s.dir, "b.txt", "B");
    const dest = try s.folder(s.dir, "dest");
    try expect(!e.svc.canUndo() and !e.svc.canRedo());
    try e.expectTitles(null, null);

    const moved = try e.svc.move(&.{ a, b }, dest);
    defer ops.freePaths(gpa, moved);
    try expectEqualStrings(s.path(dest, "a.txt"), moved[0]);
    try expectEqualStrings(s.path(dest, "b.txt"), moved[1]);
    try expect(!T.exists(a) and !T.exists(b));
    try s.expectContents(moved[0], "A");
    try expect(e.svc.canUndo());
    try e.expectTitles("Move of 2 Items", null);

    try e.svc.undo();
    try expect(T.exists(a) and T.exists(b));
    try s.expectNames(dest, &.{});
    try expect(!e.svc.canUndo() and e.svc.canRedo());
    try e.expectTitles(null, "Move of 2 Items");

    try e.svc.redo();
    try expect(!T.exists(a));
    try s.expectNames(dest, &.{ "a.txt", "b.txt" });
    try expect(e.svc.canUndo() and !e.svc.canRedo());
}

test "move conflict throws and changes nothing" {
    var e = try T.Env.init(gpa);
    defer e.deinit();
    const s = &e.s;
    const a = try s.file(s.dir, "a.txt", "A");
    const b = try s.file(s.dir, "b.txt", "B");
    const dest = try s.folder(s.dir, "dest");
    _ = try s.file(dest, "b.txt", "OTHER");

    try std.testing.expectError(error.DestinationExists, e.svc.move(&.{ a, b }, dest));
    try e.expectFailure(.destination_exists, "b.txt");
    try expect(T.exists(a) and T.exists(b));
    try s.expectNames(dest, &.{"b.txt"});
    try expect(!e.svc.canUndo()); // failed ops are not pushed
}

test "move missing source" {
    var e = try T.Env.init(gpa);
    defer e.deinit();
    const dest = try e.s.folder(e.s.dir, "dest");
    const ghost = e.s.path(e.s.dir, "ghost.txt");
    try std.testing.expectError(error.SourceMissing, e.svc.move(&.{ghost}, dest));
    try expectEqualStrings(ghost, e.svc.failure.path());
}

test "move folder into itself or a descendant" {
    var e = try T.Env.init(gpa);
    defer e.deinit();
    const s = &e.s;
    const folder = try s.folder(s.dir, "folder");
    const child = try s.folder(folder, "child");
    for ([_][]const u8{ folder, child }) |target| {
        try std.testing.expectError(error.IntoItself, e.svc.move(&.{folder}, target));
        try expectEqualStrings(folder, e.svc.failure.path());
    }
    try std.testing.expectError(error.IntoItself, e.svc.copy(&.{folder}, child));
    try expect(T.exists(child));
    try expect(!e.svc.canUndo());
}

test "a sibling whose name starts like the folder is not inside it" {
    var e = try T.Env.init(gpa);
    defer e.deinit();
    const s = &e.s;
    const foo = try s.folder(s.dir, "foo");
    const foobar = try s.folder(s.dir, "foobar");
    const moved = try e.svc.move(&.{foo}, foobar);
    ops.freePaths(gpa, moved);
    try expect(T.isDir(s.path(foobar, "foo")));
}

test "move rolls back on partial failure" {
    var e = try T.Env.init(gpa);
    defer e.deinit();
    const s = &e.s;
    const a = try s.file(s.dir, "a.txt", "A");
    const locked = try s.folder(s.dir, "locked");
    const b = try s.file(locked, "b.txt", "B");
    const dest = try s.folder(s.dir, "dest");
    // A read-only parent folder prevents moving its child away: the 2nd item fails midway.
    T.chmod(locked, 0o555);

    try std.testing.expectError(error.Underlying, e.svc.move(&.{ a, b }, dest));
    try expect(T.exists(a)); // first item rolled back
    try s.expectContents(a, "A");
    try expect(T.exists(b));
    try s.expectNames(dest, &.{});
    try expect(!e.svc.canUndo());
}

test "copy uniquifies, undo and redo" {
    var e = try T.Env.init(gpa);
    defer e.deinit();
    const s = &e.s;
    const src = try s.folder(s.dir, "src");
    const dest = try s.folder(s.dir, "dest");
    const a = try s.file(src, "name.txt", "A");
    const no_ext = try s.file(src, "README", "R");

    const first = try e.svc.copy(&.{ a, no_ext }, dest);
    defer ops.freePaths(gpa, first);
    try leaves(&.{ "name.txt", "README" }, first);
    try expect(T.exists(a)); // copy leaves the original
    try e.expectTitles("Copy of 2 Items", null);

    const second = try e.svc.copy(&.{ a, no_ext }, dest);
    defer ops.freePaths(gpa, second);
    try leaves(&.{ "name 2.txt", "README 2" }, second);
    const third = try e.svc.copy(&.{a}, dest);
    defer ops.freePaths(gpa, third);
    try leaves(&.{"name 3.txt"}, third);
    try s.expectContents(third[0], "A");

    try e.svc.undo(); // the created item goes to the Trash
    try expect(!T.exists(third[0]));
    try s.expectNames(dest, &.{ "README", "README 2", "name 2.txt", "name.txt" });
    try e.svc.redo(); // and comes back from it
    try s.expectContents(third[0], "A");
    try s.expectNames(dest, &.{ "README", "README 2", "name 2.txt", "name 3.txt", "name.txt" });
    try e.svc.undo(); // undo again still works (re-trashes)
    try expect(!T.exists(third[0]));
    try expect(T.exists(a));
}

test "copy batch with same names uniquifies within the batch" {
    var e = try T.Env.init(gpa);
    defer e.deinit();
    const s = &e.s;
    const a1 = try s.file(try s.folder(s.dir, "d1"), "same.txt", "1");
    const a2 = try s.file(try s.folder(s.dir, "d2"), "same.txt", "2");
    const dest = try s.folder(s.dir, "dest");
    const out = try e.svc.copy(&.{ a1, a2 }, dest);
    defer ops.freePaths(gpa, out);
    try leaves(&.{ "same.txt", "same 2.txt" }, out);
    try s.expectContents(out[0], "1");
    try s.expectContents(out[1], "2");
}

test "copy folder recursively" {
    var e = try T.Env.init(gpa);
    defer e.deinit();
    const s = &e.s;
    const folder = try s.folder(s.dir, "folder.v1");
    _ = try s.file(folder, "inner/deep.txt", "deep");
    const out = try e.svc.copy(&.{folder}, s.dir);
    defer ops.freePaths(gpa, out);
    try leaves(&.{"folder.v1 2"}, out); // folders do not split on dots
    try s.expectContents(s.path(out[0], "inner/deep.txt"), "deep");
}

test "copy keeps symlinks as symlinks and never follows them" {
    var e = try T.Env.init(gpa);
    defer e.deinit();
    const s = &e.s;
    const folder = try s.folder(s.dir, "links");
    _ = try s.file(folder, "target.txt", "T");
    const outside = try s.folder(s.dir, "outside");
    _ = try s.file(outside, "big.txt", "B");
    var b1: [fs.path_max]u8 = undefined;
    var b2: [fs.path_max]u8 = undefined;
    try expectEqual(@as(c_int, 0), std.c.symlink("target.txt", fs.z(&b1, s.path(folder, "rel")).?));
    try expectEqual(@as(c_int, 0), std.c.symlink("nowhere-at-all", fs.z(&b2, s.path(folder, "dangling")).?));
    try expectEqual(@as(c_int, 0), std.c.symlink(@ptrCast(outside.ptr), fs.z(&b1, s.path(folder, "dirlink")).?));

    const out = try e.svc.copy(&.{folder}, outside);
    defer ops.freePaths(gpa, out);
    for ([_][]const u8{ "rel", "dangling", "dirlink" }) |name| {
        const p = s.path(out[0], name);
        const st = fs.lstat(p) orelse return error.TestUnexpectedResult;
        try expect(std.c.S.ISLNK(st.mode));
    }
    var tb: [fs.path_max]u8 = undefined;
    const n = std.c.readlink(fs.z(&b1, s.path(out[0], "dangling")).?, &tb, tb.len);
    try expectEqualStrings("nowhere-at-all", tb[0..@intCast(n)]);
    try s.expectContents(s.path(out[0], "target.txt"), "T");
}

test "copy rolls back on partial failure" {
    var e = try T.Env.init(gpa);
    defer e.deinit();
    const s = &e.s;
    const ok = try s.file(s.dir, "ok.txt", "ok");
    const secret = try s.file(s.dir, "secret.txt", "s");
    T.chmod(secret, 0o000);
    const dest = try s.folder(s.dir, "dest");

    try std.testing.expectError(error.Underlying, e.svc.copy(&.{ ok, secret }, dest));
    try s.expectNames(dest, &.{}); // the copy that succeeded was rolled back
    try expect(T.exists(ok));
    try expect(!e.svc.canUndo());
}

test "duplicate naming" {
    var e = try T.Env.init(gpa);
    defer e.deinit();
    const s = &e.s;
    const a = try s.file(s.dir, "photo.jpg", "P");
    const folder = try s.folder(s.dir, "stuff");

    const d1 = try e.svc.duplicate(&.{a});
    defer ops.freePaths(gpa, d1);
    try leaves(&.{"photo copy.jpg"}, d1);
    const d2 = try e.svc.duplicate(&.{a});
    defer ops.freePaths(gpa, d2);
    try leaves(&.{"photo copy 2.jpg"}, d2);
    const d3 = try e.svc.duplicate(&.{ a, folder });
    defer ops.freePaths(gpa, d3);
    try leaves(&.{ "photo copy 3.jpg", "stuff copy" }, d3);
    try e.expectTitles("Duplicate of 2 Items", null);
    try s.expectContents(d1[0], "P");

    try e.svc.undo();
    try expect(!T.exists(d3[0]) and !T.exists(d3[1]));
    try expect(T.exists(d2[0]));
    try e.svc.redo();
    try expect(T.exists(d3[0]) and T.exists(d3[1]));
}

test "duplicate same name in batch" {
    var e = try T.Env.init(gpa);
    defer e.deinit();
    const a = try e.s.file(e.s.dir, "a.txt", "x");
    const out = try e.svc.duplicate(&.{ a, a });
    defer ops.freePaths(gpa, out);
    try leaves(&.{ "a copy.txt", "a copy 2.txt" }, out);
}

test "duplicate across parents keeps each in its own folder" {
    var e = try T.Env.init(gpa);
    defer e.deinit();
    const s = &e.s;
    const a = try s.file(try s.folder(s.dir, "p1"), "x.txt", "1");
    const b = try s.file(try s.folder(s.dir, "p2"), "x.txt", "2");
    const out = try e.svc.duplicate(&.{ a, b });
    defer ops.freePaths(gpa, out);
    try leaves(&.{ "x copy.txt", "x copy.txt" }, out);
    try expect(std.mem.endsWith(u8, out[1], "p2/x copy.txt"));
}

test "rename undo redo" {
    var e = try T.Env.init(gpa);
    defer e.deinit();
    const s = &e.s;
    const a = try s.file(s.dir, "old.txt", "O");
    const renamed = try e.svc.rename(a, "new.txt");
    defer gpa.free(renamed);
    try expectEqualStrings(s.path(s.dir, "new.txt"), renamed);
    try expect(!T.exists(a));
    try s.expectContents(renamed, "O");
    try e.expectTitles("Rename", null);

    try e.svc.undo();
    try expect(T.exists(a) and !T.exists(renamed));
    try e.svc.redo();
    try expect(!T.exists(a) and T.exists(renamed));
}

test "rename rejects invalid names" {
    var e = try T.Env.init(gpa);
    defer e.deinit();
    const s = &e.s;
    const a = try s.file(s.dir, "a.txt", "x");
    _ = try s.file(s.dir, "taken.txt", "x");

    for ([_][]const u8{ "", "   ", "x/y", "x:y", ".", ".." }) |bad| {
        try std.testing.expectError(error.InvalidName, e.svc.rename(a, bad));
        try expectEqualStrings(bad, e.svc.failure.path());
    }
    var buf: [1400]u8 = undefined;
    try expect(e.svc.describeFailure(&buf).len > 0);
    try std.testing.expectError(error.DestinationExists, e.svc.rename(a, "taken.txt"));
    try e.expectFailure(.destination_exists, "taken.txt");
    try std.testing.expectError(error.SourceMissing, e.svc.rename(s.path(s.dir, "ghost"), "z"));
    try expect(T.exists(a));
    try expect(!e.svc.canUndo());
}

test "failure descriptions" {
    var e = try T.Env.init(gpa);
    defer e.deinit();
    var buf: [1400]u8 = undefined;
    _ = e.svc.rename("/nonexistent-nanofm/zz", "   ") catch {};
    try expectEqualStrings("The name can\u{2019}t be empty.", e.svc.describeFailure(&buf));
    _ = e.svc.rename("/nonexistent-nanofm/zz", "q") catch {};
    try expectEqualStrings("\u{201C}zz\u{201D} no longer exists.", e.svc.describeFailure(&buf));
}

test "rename to the same name is a no-op" {
    var e = try T.Env.init(gpa);
    defer e.deinit();
    const a = try e.s.file(e.s.dir, "a.txt", "x");
    const out = try e.svc.rename(a, "a.txt");
    defer gpa.free(out);
    try expectEqualStrings(a, out);
    try expect(!e.svc.canUndo());
}

test "case-only rename" {
    var e = try T.Env.init(gpa);
    defer e.deinit();
    const s = &e.s;
    const a = try s.file(s.dir, "readme.txt", "R");
    const out = try e.svc.rename(a, "README.txt");
    defer gpa.free(out);
    try s.expectNames(s.dir, &.{"README.txt"});
    try s.expectContents(out, "R");
    try e.svc.undo();
    try s.expectNames(s.dir, &.{"readme.txt"});
}

test "createFolder uniquifies and undo" {
    var e = try T.Env.init(gpa);
    defer e.deinit();
    const s = &e.s;
    const f1 = try e.svc.createFolder(s.dir, ops.default_folder_name);
    defer gpa.free(f1);
    const f2 = try e.svc.createFolder(s.dir, ops.default_folder_name);
    defer gpa.free(f2);
    const f3 = try e.svc.createFolder(s.dir, "custom");
    defer gpa.free(f3);
    const f4 = try e.svc.createFolder(s.dir, "custom");
    defer gpa.free(f4);
    try leaves(&.{ "untitled folder", "untitled folder 2", "custom", "custom 2" }, &.{ f1, f2, f3, f4 });
    try e.expectTitles("New Folder", null);
    try std.testing.expectError(error.InvalidName, e.svc.createFolder(s.dir, "a/b"));
    try std.testing.expectError(error.InvalidName, e.svc.createFolder(s.dir, ""));

    try e.svc.undo();
    try expect(!T.exists(f4) and T.exists(f3));
    try e.svc.redo();
    try expect(T.isDir(f4));
}
