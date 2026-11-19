//! Undoable file operations: move, copy, duplicate, rename, createFolder, trash, undo, redo.
//! Port of FileOperationService.swift. Deleting only ever means moving to the Trash; nothing is
//! unlinked. Paths are absolute UTF-8 slices. Errors carry no payload in Zig, so the detail of the
//! last failure (kind, path, errno / NSError text) is in `failure` / `describeFailure`.
const std = @import("std");
const fs = @import("file_ops_fs.zig");
const naming = @import("file_ops_naming.zig");

const Allocator = std.mem.Allocator;

pub const Error = error{ DestinationExists, InvalidName, SourceMissing, IntoItself, Underlying, OutOfMemory };
pub const Diag = fs.Diag;
pub const default_folder_name = "untitled folder";

const Pair = struct { from: []const u8, to: []const u8 };
const Created = struct { url: []const u8, trashed: ?[]const u8 };
const Kind = union(enum) {
    moved: []Pair, // move, rename: from -> to
    created: []Created, // copy, duplicate, createFolder
    trashed: []Pair, // trash: from = original, to = Trash path
};
const Entry = struct {
    title: []const u8,
    kind: Kind,

    fn deinit(e: Entry, gpa: Allocator) void {
        gpa.free(e.title);
        switch (e.kind) {
            .moved, .trashed => |pairs| {
                for (pairs) |p| {
                    gpa.free(p.from);
                    gpa.free(p.to);
                }
                gpa.free(pairs);
            },
            .created => |items| {
                for (items) |it| {
                    gpa.free(it.url);
                    if (it.trashed) |t| gpa.free(t);
                }
                gpa.free(items);
            },
        }
    }
};

var rename_counter = std.atomic.Value(u32).init(0);

pub fn freePaths(gpa: Allocator, paths: []const []const u8) void {
    for (paths) |p| gpa.free(p);
    gpa.free(paths);
}

pub const FileOperationService = struct {
    gpa: Allocator,
    undo_stack: std.ArrayList(Entry) = .empty,
    redo_stack: std.ArrayList(Entry) = .empty,
    /// Detail of the most recent failed call.
    failure: Diag = .{},

    pub fn init(gpa: Allocator) FileOperationService {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *FileOperationService) void {
        for (self.undo_stack.items) |e| e.deinit(self.gpa);
        for (self.redo_stack.items) |e| e.deinit(self.gpa);
        self.undo_stack.deinit(self.gpa);
        self.redo_stack.deinit(self.gpa);
    }

    pub fn canUndo(self: *const FileOperationService) bool {
        return self.undo_stack.items.len > 0;
    }

    pub fn canRedo(self: *const FileOperationService) bool {
        return self.redo_stack.items.len > 0;
    }

    /// e.g. "Move of 3 Items", "Rename". Valid until the next operation.
    pub fn undoTitle(self: *const FileOperationService) ?[]const u8 {
        return if (self.undo_stack.getLastOrNull()) |e| e.title else null;
    }

    pub fn redoTitle(self: *const FileOperationService) ?[]const u8 {
        return if (self.redo_stack.getLastOrNull()) |e| e.title else null;
    }

    /// User-facing text of the last failure (same wording as the Swift app). `buf` ~1400 bytes.
    pub fn describeFailure(self: *const FileOperationService, buf: []u8) []const u8 {
        return self.failure.describe(buf);
    }

    // ------------------------------------------------------------ public operations

    /// Conflict throws DestinationExists; a folder into itself/a descendant throws IntoItself.
    /// All-or-nothing. Returns the new paths (free with `freePaths`).
    pub fn move(self: *FileOperationService, urls: []const []const u8, directory: []const u8) Error![][]const u8 {
        if (urls.len == 0) return self.gpa.alloc([]const u8, 0);
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        try self.requireDirectory(directory);
        var pairs: std.ArrayList(Pair) = .empty;
        var reserved: naming.NameList = .empty;
        for (urls) |src| {
            if (!fs.exists(src)) return self.failPath(.source_missing, src);
            if (try naming.isInside(a, directory, src)) return self.failPath(.into_itself, src);
            const dst = try naming.join(a, directory, naming.leaf(src));
            const key = try std.ascii.allocLowerString(a, naming.leaf(dst));
            for (reserved.items) |r| if (std.mem.eql(u8, r, key)) return self.failPath(.destination_exists, dst);
            try reserved.append(a, key);
            try pairs.append(a, .{ .from = src, .to = dst });
        }
        const title = try self.itemsTitle("Move of ", urls.len);
        errdefer self.gpa.free(title);
        const entry_pairs = try self.dupePairs(pairs.items);
        errdefer freePairs(self.gpa, entry_pairs);
        const out = try dupeTargets(self.gpa, pairs.items);
        errdefer freePaths(self.gpa, out);
        try self.reserveSlot();
        try self.moveBatch(a, pairs.items);
        self.push(.{ .title = title, .kind = .{ .moved = entry_pairs } });
        return out;
    }

    /// Conflicts auto-uniquify ("name 2.ext"). Folders copy recursively, symlinks are copied as
    /// links. All-or-nothing.
    pub fn copy(self: *FileOperationService, urls: []const []const u8, directory: []const u8) Error![][]const u8 {
        if (urls.len == 0) return self.gpa.alloc([]const u8, 0);
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        try self.requireDirectory(directory);
        var reserved: naming.NameList = .empty;
        var pairs: std.ArrayList(Pair) = .empty;
        for (urls) |src| {
            if (!fs.exists(src)) return self.failPath(.source_missing, src);
            if (try naming.isInside(a, directory, src)) return self.failPath(.into_itself, src);
            const dst = try naming.uniqueDestination(a, directory, src, false, &reserved);
            try pairs.append(a, .{ .from = src, .to = dst });
        }
        return self.finishCreate(a, pairs.items, "Copy of ", urls.len);
    }

    /// "name copy.ext", "name copy 2.ext", next to the original.
    pub fn duplicate(self: *FileOperationService, urls: []const []const u8) Error![][]const u8 {
        if (urls.len == 0) return self.gpa.alloc([]const u8, 0);
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        var reserved: naming.NameList = .empty; // keys are full paths, so mixed parents are fine
        var pairs: std.ArrayList(Pair) = .empty;
        for (urls) |src| {
            if (!fs.exists(src)) return self.failPath(.source_missing, src);
            const dst = try naming.uniqueDestination(a, naming.parentDir(src), src, true, &reserved);
            try pairs.append(a, .{ .from = src, .to = dst });
        }
        return self.finishCreate(a, pairs.items, "Duplicate of ", urls.len);
    }

    /// Rejects empty, "/" or ":" names and an existing sibling. Same name is a no-op (nothing
    /// pushed). Returns the new path (caller frees).
    pub fn rename(self: *FileOperationService, url: []const u8, new_name: []const u8) Error![]u8 {
        if (!naming.validName(new_name)) return self.failPath(.invalid_name, new_name);
        if (!fs.exists(url)) return self.failPath(.source_missing, url);
        if (std.mem.eql(u8, naming.leaf(url), new_name)) return self.gpa.dupe(u8, url);
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const dst = try naming.join(a, naming.parentDir(url), new_name);
        const title = try self.gpa.dupe(u8, "Rename");
        errdefer self.gpa.free(title);
        const entry_pairs = try self.dupePairs(&.{.{ .from = url, .to = dst }});
        errdefer freePairs(self.gpa, entry_pairs);
        const out = try self.gpa.dupe(u8, dst);
        errdefer self.gpa.free(out);
        try self.reserveSlot();
        try self.moveOne(a, url, dst);
        self.push(.{ .title = title, .kind = .{ .moved = entry_pairs } });
        return out;
    }

    /// Auto-uniquifies "untitled folder", "untitled folder 2", ... Returns the path (caller frees).
    pub fn createFolder(self: *FileOperationService, directory: []const u8, name: []const u8) Error![]u8 {
        if (!naming.validName(name)) return self.failPath(.invalid_name, name);
        try self.requireDirectory(directory);
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        var n: usize = 1;
        var dst = try naming.join(a, directory, name);
        while (fs.exists(dst)) {
            n += 1;
            dst = try naming.join(a, directory, try std.fmt.allocPrint(a, "{s} {d}", .{ name, n }));
        }
        const title = try self.gpa.dupe(u8, "New Folder");
        errdefer self.gpa.free(title);
        const items = try self.gpa.alloc(Created, 1);
        errdefer self.gpa.free(items);
        items[0] = .{ .url = try self.gpa.dupe(u8, dst), .trashed = null };
        errdefer self.gpa.free(items[0].url);
        const out = try self.gpa.dupe(u8, dst);
        errdefer self.gpa.free(out);
        try self.reserveSlot();
        const e = fs.makeDir(dst, 0o777);
        if (e != .SUCCESS) return self.failErrno(e, dst);
        self.push(.{ .title = title, .kind = .{ .created = items } });
        return out;
    }

    /// Moves to the Trash (never deletes); records the Trash paths for undo. Items inside another
    /// listed item are skipped. All-or-nothing.
    pub fn trash(self: *FileOperationService, urls: []const []const u8) Error!void {
        if (urls.len == 0) return;
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const targets = try naming.dropDescendants(a, urls);
        for (targets) |u| if (!fs.exists(u)) return self.failPath(.source_missing, u);
        const title = try self.gpa.dupe(u8, "Move to Trash");
        errdefer self.gpa.free(title);
        const pairs = try self.gpa.alloc(Pair, targets.len);
        var made: usize = 0;
        errdefer {
            for (pairs[0..made]) |p| self.gpa.free(p.from);
            self.gpa.free(pairs);
        }
        for (targets) |u| {
            pairs[made] = .{ .from = try self.gpa.dupe(u8, u), .to = &.{} };
            made += 1;
        }
        try self.reserveSlot();
        const trashed = try self.trashBatch(targets);
        defer self.gpa.free(trashed);
        for (pairs, trashed) |*p, t| p.to = t;
        self.push(.{ .title = title, .kind = .{ .trashed = pairs } });
    }

    /// Move -> move back; copy/duplicate/createFolder -> trash the created items; rename -> rename
    /// back; trash -> move back from the Trash. A vanished item drops the entry (SourceMissing);
    /// any other failure keeps it on the stack.
    pub fn undo(self: *FileOperationService) Error!void {
        const entry = self.undo_stack.getLastOrNull() orelse return;
        try self.redo_stack.ensureUnusedCapacity(self.gpa, 1);
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        self.undoEntry(a, entry) catch |e| {
            if (e == error.SourceMissing) {
                _ = self.undo_stack.pop();
                entry.deinit(self.gpa);
            }
            return e;
        };
        _ = self.undo_stack.pop();
        self.redo_stack.appendAssumeCapacity(entry);
    }

    /// Redo does not clear the redo stack. Same dropping rule as `undo`.
    pub fn redo(self: *FileOperationService) Error!void {
        const entry = self.redo_stack.getLastOrNull() orelse return;
        try self.undo_stack.ensureUnusedCapacity(self.gpa, 1);
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        self.redoEntry(a, entry) catch |e| {
            if (e == error.SourceMissing) {
                _ = self.redo_stack.pop();
                entry.deinit(self.gpa);
            }
            return e;
        };
        _ = self.redo_stack.pop();
        self.undo_stack.appendAssumeCapacity(entry);
    }

    fn undoEntry(self: *FileOperationService, a: Allocator, entry: Entry) Error!void {
        switch (entry.kind) {
            .moved, .trashed => |pairs| {
                const rev = try a.alloc(Pair, pairs.len);
                for (pairs, 0..) |p, i| rev[pairs.len - 1 - i] = .{ .from = p.to, .to = p.from };
                try self.moveBatch(a, rev);
            },
            .created => |items| {
                const urls = try a.alloc([]const u8, items.len);
                for (items, urls) |it, *u| u.* = it.url;
                const trashed = try self.trashBatch(urls);
                defer self.gpa.free(trashed);
                for (items, trashed) |*it, t| {
                    if (it.trashed) |old| self.gpa.free(old);
                    it.trashed = t;
                }
            },
        }
    }

    fn redoEntry(self: *FileOperationService, a: Allocator, entry: Entry) Error!void {
        switch (entry.kind) {
            .moved => |pairs| try self.moveBatch(a, pairs),
            .created => |items| {
                var back: std.ArrayList(Pair) = .empty;
                for (items) |it| if (it.trashed) |t| try back.append(a, .{ .from = t, .to = it.url });
                try self.moveBatch(a, back.items);
                for (items) |*it| {
                    if (it.trashed) |t| self.gpa.free(t);
                    it.trashed = null;
                }
            },
            .trashed => |pairs| {
                const urls = try a.alloc([]const u8, pairs.len);
                for (pairs, urls) |p, *u| u.* = p.from;
                const trashed = try self.trashBatch(urls);
                defer self.gpa.free(trashed);
                for (pairs, trashed) |*p, t| {
                    self.gpa.free(p.to);
                    p.to = t;
                }
            },
        }
    }

    // ------------------------------------------------------------ stacks

    /// Makes `push` infallible: call before touching the disk.
    fn reserveSlot(self: *FileOperationService) Error!void {
        try self.undo_stack.ensureUnusedCapacity(self.gpa, 1);
    }

    fn push(self: *FileOperationService, entry: Entry) void {
        self.undo_stack.appendAssumeCapacity(entry);
        for (self.redo_stack.items) |e| e.deinit(self.gpa);
        self.redo_stack.clearRetainingCapacity();
    }

    fn itemsTitle(self: *FileOperationService, prefix: []const u8, n: usize) Allocator.Error![]u8 {
        return std.fmt.allocPrint(self.gpa, "{s}{d} Item{s}", .{ prefix, n, if (n == 1) "" else "s" });
    }

    fn dupePairs(self: *FileOperationService, pairs: []const Pair) Allocator.Error![]Pair {
        const out = try self.gpa.alloc(Pair, pairs.len);
        var made: usize = 0;
        errdefer {
            for (out[0..made]) |p| {
                self.gpa.free(p.from);
                self.gpa.free(p.to);
            }
            self.gpa.free(out);
        }
        for (pairs, out) |p, *o| {
            const from = try self.gpa.dupe(u8, p.from);
            errdefer self.gpa.free(from);
            o.* = .{ .from = from, .to = try self.gpa.dupe(u8, p.to) };
            made += 1;
        }
        return out;
    }

    fn freePairs(gpa: Allocator, pairs: []Pair) void {
        for (pairs) |p| {
            gpa.free(p.from);
            gpa.free(p.to);
        }
        gpa.free(pairs);
    }

    fn dupeTargets(gpa: Allocator, pairs: []const Pair) Allocator.Error![][]const u8 {
        const out = try gpa.alloc([]const u8, pairs.len);
        var made: usize = 0;
        errdefer {
            for (out[0..made]) |p| gpa.free(p);
            gpa.free(out);
        }
        for (pairs, out) |p, *o| {
            o.* = try gpa.dupe(u8, p.to);
            made += 1;
        }
        return out;
    }

    /// Shared tail of copy and duplicate.
    fn finishCreate(self: *FileOperationService, a: Allocator, pairs: []const Pair, prefix: []const u8, n: usize) Error![][]const u8 {
        const title = try self.itemsTitle(prefix, n);
        errdefer self.gpa.free(title);
        const items = try self.gpa.alloc(Created, pairs.len);
        var made: usize = 0;
        errdefer {
            for (items[0..made]) |it| self.gpa.free(it.url);
            self.gpa.free(items);
        }
        for (pairs, items) |p, *it| {
            it.* = .{ .url = try self.gpa.dupe(u8, p.to), .trashed = null };
            made += 1;
        }
        const out = try dupeTargets(self.gpa, pairs);
        errdefer freePaths(self.gpa, out);
        try self.reserveSlot();
        try self.copyBatch(a, pairs);
        self.push(.{ .title = title, .kind = .{ .created = items } });
        return out;
    }

    // ------------------------------------------------------------ failures

    fn failPath(self: *FileOperationService, kind: fs.Kind, path: []const u8) Error {
        self.failure.set(kind, path);
        return switch (kind) {
            .destination_exists => error.DestinationExists,
            .invalid_name => error.InvalidName,
            .source_missing => error.SourceMissing,
            .into_itself => error.IntoItself,
            else => error.Underlying,
        };
    }

    fn failErrno(self: *FileOperationService, e: fs.E, path: []const u8) Error {
        if (e == .EXIST) return self.failPath(.destination_exists, path);
        self.failure.set(.underlying, path);
        self.failure.code = @intCast(@intFromEnum(e));
        return error.Underlying;
    }

    // ------------------------------------------------------------ batch primitives (with rollback)

    fn requireDirectory(self: *FileOperationService, dir: []const u8) Error!void {
        switch (fs.checkDirectory(dir)) {
            .directory => {},
            .missing => {
                self.failure.set(.underlying, dir);
                self.failure.code = @intFromEnum(fs.E.NOENT);
                return error.Underlying;
            },
            .not_directory => {
                self.failure.set(.underlying, dir);
                self.failure.code = @intFromEnum(fs.E.NOTDIR);
                return error.Underlying;
            },
        }
    }

    /// True when `dst` differs from `src` only by letter case and is the very same file
    /// (case-insensitive volume).
    fn isCaseOnlyRename(src: []const u8, dst: []const u8) bool {
        const sl = naming.leaf(src);
        const dl = naming.leaf(dst);
        return std.mem.eql(u8, naming.parentDir(src), naming.parentDir(dst)) and
            !std.mem.eql(u8, sl, dl) and std.ascii.eqlIgnoreCase(sl, dl) and
            fs.exists(dst) and fs.sameFile(src, dst);
    }

    /// One rename, never replacing anything; a case-only rename goes through a temporary name.
    fn moveOne(self: *FileOperationService, a: Allocator, src: []const u8, dst: []const u8) Error!void {
        if (fs.exists(dst)) {
            if (!isCaseOnlyRename(src, dst)) return self.failPath(.destination_exists, dst);
            const tmp_name = try std.fmt.allocPrint(a, ".nanofm-rename-{d}-{d}", .{
                std.c.getpid(), rename_counter.fetchAdd(1, .monotonic),
            });
            const tmp = try naming.join(a, naming.parentDir(src), tmp_name);
            const e1 = fs.moveExcl(src, tmp);
            if (e1 != .SUCCESS) return self.failErrno(e1, src);
            const e2 = fs.moveExcl(tmp, dst);
            if (e2 != .SUCCESS) {
                _ = fs.moveExcl(tmp, src);
                return self.failErrno(e2, dst);
            }
            return;
        }
        const e = fs.moveExcl(src, dst);
        if (e != .SUCCESS) return self.failErrno(e, dst); // EXDEV (other volume) is Underlying
    }

    fn moveBatch(self: *FileOperationService, a: Allocator, pairs: []const Pair) Error!void {
        for (pairs) |p| {
            if (!fs.exists(p.from)) return self.failPath(.source_missing, p.from);
            if (fs.exists(p.to) and !isCaseOnlyRename(p.from, p.to)) return self.failPath(.destination_exists, p.to);
        }
        for (pairs, 0..) |p, i| {
            self.moveOne(a, p.from, p.to) catch |e| {
                const saved = self.failure;
                var j = i;
                while (j > 0) {
                    j -= 1;
                    self.moveOne(a, pairs[j].to, pairs[j].from) catch {};
                }
                self.failure = saved;
                return e;
            };
        }
    }

    fn copyBatch(self: *FileOperationService, a: Allocator, pairs: []const Pair) Error!void {
        _ = a;
        for (pairs, 0..) |p, i| {
            const existed = fs.exists(p.to); // never discard something this call did not create
            const e = fs.copyTree(p.from, p.to);
            if (e == .SUCCESS) continue;
            const err = self.failErrno(e, p.from);
            if (!existed and fs.exists(p.to)) fs.discard(self.gpa, p.to);
            var j = i;
            while (j > 0) {
                j -= 1;
                fs.discard(self.gpa, pairs[j].to);
            }
            return err;
        }
    }

    /// Trash paths, in input order; each string and the slice are gpa-owned by the caller.
    fn trashBatch(self: *FileOperationService, urls: []const []const u8) Error![][]const u8 {
        const done = try self.gpa.alloc([]const u8, urls.len);
        var n: usize = 0;
        errdefer self.gpa.free(done);
        errdefer for (done[0..n]) |t| self.gpa.free(t);
        for (urls) |u| {
            const trashed = blk: {
                if (!fs.exists(u)) {
                    self.rollbackTrash(urls[0..n], done[0..n]);
                    return self.failPath(.source_missing, u);
                }
                break :blk fs.trashItem(self.gpa, u, &self.failure) catch |e| {
                    const saved = self.failure;
                    self.rollbackTrash(urls[0..n], done[0..n]);
                    self.failure = saved;
                    return switch (e) {
                        error.OutOfMemory => error.OutOfMemory,
                        error.Failed => error.Underlying,
                    };
                };
            };
            done[n] = trashed;
            n += 1;
        }
        return done;
    }

    /// Puts already trashed items back (best effort, never replacing anything).
    fn rollbackTrash(self: *FileOperationService, originals: []const []const u8, trashed: []const []const u8) void {
        _ = self;
        var i = originals.len;
        while (i > 0) {
            i -= 1;
            _ = fs.moveExcl(trashed[i], originals[i]);
        }
    }
};

test {
    _ = @import("file_ops_fs.zig");
    _ = @import("file_ops_naming.zig");
    _ = @import("file_ops_tests.zig");
    _ = @import("file_ops_tests2.zig");
}
