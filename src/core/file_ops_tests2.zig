//! file_ops tests, part 2: Trash and the undo/redo stacks.
//! Trash tests put a few tiny, uniquely named temp files in the user's Trash (accepted).
const std = @import("std");
const T = @import("file_ops_test_support.zig");
const ops = @import("file_ops.zig");
const fs = @import("file_ops_fs.zig");

const gpa = std.testing.allocator;
const expect = std.testing.expect;
const expectEqualStrings = std.testing.expectEqualStrings;

test "trash undo redo" {
    var e = try T.Env.init(gpa);
    defer e.deinit();
    const s = &e.s;
    const a = try s.file(s.dir, e.unique("a", ".txt"), "A");
    const b = try s.folder(s.dir, e.unique("b", ""));
    _ = try s.file(b, "inner.txt", "I");

    try e.svc.trash(&.{ a, b });
    try expect(!T.exists(a) and !T.exists(b));
    try e.expectTitles("Move to Trash", null);

    try e.svc.undo();
    try s.expectContents(a, "A");
    try s.expectContents(s.path(b, "inner.txt"), "I");
    try expect(e.svc.canRedo());

    try e.svc.redo();
    try expect(!T.exists(a) and !T.exists(b));
    try e.svc.undo();
    try expect(T.exists(a) and T.exists(b));
}

test "trash skips children of a trashed parent" {
    var e = try T.Env.init(gpa);
    defer e.deinit();
    const s = &e.s;
    const folder = try s.folder(s.dir, e.unique("parent", ""));
    const child = try s.file(folder, "c.txt", "C");
    try e.svc.trash(&.{ folder, child });
    try expect(!T.exists(folder));
    try e.svc.undo();
    try s.expectContents(child, "C");
}

test "trash missing source throws and trashes nothing" {
    var e = try T.Env.init(gpa);
    defer e.deinit();
    const s = &e.s;
    const a = try s.file(s.dir, e.unique("keep", ".txt"), "x");
    try std.testing.expectError(error.SourceMissing, e.svc.trash(&.{ a, s.path(s.dir, "ghost") }));
    try expect(T.exists(a)); // nothing trashed when validation fails
    try expect(!e.svc.canUndo());
}

test "trash rolls back on partial failure" {
    var e = try T.Env.init(gpa);
    defer e.deinit();
    const s = &e.s;
    const a = try s.file(s.dir, e.unique("ok", ".txt"), "A");
    const locked = try s.folder(s.dir, "locked");
    const b = try s.file(locked, e.unique("locked", ".txt"), "B");
    T.chmod(locked, 0o555);

    try std.testing.expectError(error.Underlying, e.svc.trash(&.{ a, b }));
    try s.expectContents(a, "A"); // first trashed item was put back
    try expect(T.exists(b));
    try expect(!e.svc.canUndo());
    var buf: [1400]u8 = undefined;
    try expect(e.svc.describeFailure(&buf).len > 0);
}

test "a new operation clears the redo stack" {
    var e = try T.Env.init(gpa);
    defer e.deinit();
    const s = &e.s;
    const f1 = try e.svc.createFolder(s.dir, "one");
    defer gpa.free(f1);
    try e.svc.undo();
    try expect(e.svc.canRedo());
    gpa.free(try e.svc.createFolder(s.dir, "two"));
    try expect(!e.svc.canRedo());
    try e.expectTitles("New Folder", null);
    try e.svc.redo(); // no-op
    try expect(!T.exists(f1));
}

test "a failed operation does not clear redo" {
    var e = try T.Env.init(gpa);
    defer e.deinit();
    gpa.free(try e.svc.createFolder(e.s.dir, "one"));
    try e.svc.undo();
    try std.testing.expectError(error.SourceMissing, e.svc.rename(e.s.path(e.s.dir, "ghost"), "x"));
    try expect(e.svc.canRedo());
}

test "multi-level undo and redo order" {
    var e = try T.Env.init(gpa);
    defer e.deinit();
    const s = &e.s;
    const f = try e.svc.createFolder(s.dir, "f");
    defer gpa.free(f);
    const renamed = try e.svc.rename(f, "g");
    defer gpa.free(renamed);
    const file = try s.file(s.dir, "m.txt", "x");
    const moved = try e.svc.move(&.{file}, renamed);
    defer ops.freePaths(gpa, moved);
    try e.expectTitles("Move of 1 Item", null);

    try e.svc.undo();
    try expect(T.exists(file));
    try e.expectTitles("Rename", "Move of 1 Item");
    try e.svc.undo();
    try expect(T.exists(f) and !T.exists(renamed));
    try e.expectTitles("New Folder", "Rename");
    try e.svc.undo();
    try expect(!T.exists(f));
    try expect(!e.svc.canUndo());

    try e.svc.redo();
    try e.svc.redo();
    try e.svc.redo();
    try expect(T.exists(moved[0]));
    try expect(!e.svc.canRedo());
}

test "undo failure keeps the entry on the stack" {
    var e = try T.Env.init(gpa);
    defer e.deinit();
    const s = &e.s;
    const a = try s.file(s.dir, "a.txt", "x");
    const dest = try s.folder(s.dir, "dest");
    ops.freePaths(gpa, try e.svc.move(&.{a}, dest));
    _ = try s.file(s.dir, "a.txt", "squatter"); // original location now occupied
    try std.testing.expectError(error.DestinationExists, e.svc.undo());
    try expect(e.svc.canUndo());
    try expect(!e.svc.canRedo());
    try expect(T.exists(s.path(dest, "a.txt")));
}

test "undo of a vanished item drops the entry instead of jamming the stack" {
    var e = try T.Env.init(gpa);
    defer e.deinit();
    const s = &e.s;
    const a = try s.file(s.dir, "a.txt", "x");
    const b = try e.svc.rename(a, "b.txt"); // earlier, still undoable
    defer gpa.free(b);
    const folder = try e.svc.createFolder(s.dir, "probe"); // newest entry
    defer gpa.free(folder);
    // Moved behind the service's back (own scratch dir only).
    var b1: [fs.path_max]u8 = undefined;
    var b2: [fs.path_max]u8 = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.rename(fs.z(&b1, folder).?, fs.z(&b2, s.path(s.dir, "moved-away")).?));
    try std.testing.expectError(error.SourceMissing, e.svc.undo());
    try e.expectTitles("Rename", null); // the unusable entry is dropped, the earlier one reachable
    try expect(!e.svc.canRedo());
    try e.svc.undo();
    try expect(T.exists(a) and !T.exists(b));
}

test "empty inputs are no-ops" {
    var e = try T.Env.init(gpa);
    defer e.deinit();
    const none: []const []const u8 = &.{};
    ops.freePaths(gpa, try e.svc.move(none, e.s.dir));
    ops.freePaths(gpa, try e.svc.copy(none, e.s.dir));
    ops.freePaths(gpa, try e.svc.duplicate(none));
    try e.svc.trash(none);
    try expect(!e.svc.canUndo());
}

test "undo and redo on empty stacks do nothing" {
    var e = try T.Env.init(gpa);
    defer e.deinit();
    try e.svc.undo();
    try e.svc.redo();
    var buf: [8]u8 = undefined;
    try expectEqualStrings("", e.svc.describeFailure(&buf));
}
