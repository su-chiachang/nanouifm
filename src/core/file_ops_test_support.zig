//! Test helpers for file_ops: a scratch directory (made fresh, removed afterwards; only ever
//! under the system temp dir and named nanofmCoreTests-*) and tiny file helpers on libc.
const std = @import("std");
const fs = @import("file_ops_fs.zig");
const ops = @import("file_ops.zig");
const c = std.c;

extern "c" fn mkdtemp(template: [*:0]u8) ?[*:0]u8;

pub const Scratch = struct {
    arena: std.heap.ArenaAllocator,
    /// Resolved (no /var -> /private/var surprises).
    dir: []const u8,

    pub fn init(gpa: std.mem.Allocator) !Scratch {
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();
        const tmp = if (c.getenv("TMPDIR")) |t| std.mem.trimEnd(u8, std.mem.span(t), "/") else "/tmp";
        const tmpl = try std.fmt.allocPrintSentinel(a, "{s}/nanofmCoreTests-XXXXXX", .{tmp}, 0);
        const made = mkdtemp(tmpl.ptr) orelse return error.MkdtempFailed;
        var rb: [fs.path_max]u8 = undefined;
        const real = fs.realpath(&rb, std.mem.span(made)) orelse return error.RealpathFailed;
        return .{ .arena = arena, .dir = try a.dupe(u8, real) };
    }

    /// Restores permissions on everything under the scratch dir, then removes it (own scaffolding only).
    pub fn deinit(self: *Scratch) void {
        std.debug.assert(std.mem.indexOf(u8, self.dir, "/nanofmCoreTests-") != null);
        restorePermissions(self.dir);
        std.Io.Dir.cwd().deleteTree(std.testing.io, self.dir) catch {};
        self.arena.deinit();
    }

    pub fn alloc(self: *Scratch) std.mem.Allocator {
        return self.arena.allocator();
    }

    pub fn path(self: *Scratch, parent: []const u8, name: []const u8) []const u8 {
        return std.fs.path.join(self.alloc(), &.{ parent, name }) catch @panic("oom");
    }

    /// Creates `parent/name` (with missing intermediate folders) holding `contents`.
    pub fn file(self: *Scratch, parent: []const u8, name: []const u8, contents: []const u8) ![]const u8 {
        const p = self.path(parent, name);
        if (std.fs.path.dirname(p)) |d| try mkdirAll(d);
        var b: [fs.path_max]u8 = undefined;
        const fd = c.open(fs.z(&b, p).?, c.O{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(c_uint, 0o644));
        if (fd < 0) return error.CreateFailed;
        defer _ = c.close(fd);
        if (contents.len > 0 and c.write(fd, contents.ptr, contents.len) != @as(isize, @intCast(contents.len))) return error.WriteFailed;
        return p;
    }

    pub fn folder(self: *Scratch, parent: []const u8, name: []const u8) ![]const u8 {
        const p = self.path(parent, name);
        try mkdirAll(p);
        return p;
    }

    pub fn read(self: *Scratch, p: []const u8) ?[]const u8 {
        var b: [fs.path_max]u8 = undefined;
        const fd = c.open(fs.z(&b, p) orelse return null, c.O{}, @as(c_uint, 0));
        if (fd < 0) return null;
        defer _ = c.close(fd);
        var buf: [4096]u8 = undefined;
        const n = c.read(fd, &buf, buf.len);
        if (n < 0) return null;
        return self.alloc().dupe(u8, buf[0..@intCast(n)]) catch null;
    }

    /// Sorted entry names of `dir` (byte order, like Swift's sorted() for ASCII).
    pub fn names(self: *Scratch, dir: []const u8) ![]const []const u8 {
        var b: [fs.path_max]u8 = undefined;
        const d = c.opendir(fs.z(&b, dir) orelse return error.NameTooLong) orelse return error.OpenFailed;
        defer _ = c.closedir(d);
        var list: std.ArrayList([]const u8) = .empty;
        while (c.readdir(d)) |ent| {
            const n = std.mem.sliceTo(&ent.name, 0);
            if (std.mem.eql(u8, n, ".") or std.mem.eql(u8, n, "..")) continue;
            try list.append(self.alloc(), try self.alloc().dupe(u8, n));
        }
        std.mem.sort([]const u8, list.items, {}, struct {
            fn lt(_: void, x: []const u8, y: []const u8) bool {
                return std.mem.lessThan(u8, x, y);
            }
        }.lt);
        return list.items;
    }

    pub fn expectNames(self: *Scratch, dir: []const u8, want: []const []const u8) !void {
        const got = try self.names(dir);
        try std.testing.expectEqual(want.len, got.len);
        for (want, got) |w, g| try std.testing.expectEqualStrings(w, g);
    }

    pub fn expectContents(self: *Scratch, p: []const u8, want: []const u8) !void {
        const got = self.read(p) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings(want, got);
    }
};

pub fn exists(p: []const u8) bool {
    return fs.exists(p);
}

pub fn isDir(p: []const u8) bool {
    return if (fs.lstat(p)) |st| fs.isDirectory(st) else false;
}

pub fn chmod(p: []const u8, mode: c.mode_t) void {
    var b: [fs.path_max]u8 = undefined;
    _ = c.chmod(fs.z(&b, p).?, mode);
}

fn mkdirAll(p: []const u8) !void {
    if (fs.exists(p)) return;
    if (std.fs.path.dirname(p)) |d| if (d.len > 1) try mkdirAll(d);
    const e = fs.makeDir(p, 0o755);
    if (e != .SUCCESS and e != .EXIST) return error.MkdirFailed;
}

fn restorePermissions(dir: []const u8) void {
    chmod(dir, 0o755);
    var b: [fs.path_max]u8 = undefined;
    const d = c.opendir(fs.z(&b, dir) orelse return) orelse return;
    defer _ = c.closedir(d);
    while (c.readdir(d)) |ent| {
        const n = std.mem.sliceTo(&ent.name, 0);
        if (std.mem.eql(u8, n, ".") or std.mem.eql(u8, n, "..")) continue;
        var pb: [fs.path_max]u8 = undefined;
        const p = std.fmt.bufPrint(&pb, "{s}/{s}", .{ dir, n }) catch continue;
        const st = fs.lstat(p) orelse continue;
        if (fs.isDirectory(st)) {
            restorePermissions(p);
        } else if (!c.S.ISLNK(st.mode)) {
            chmod(p, 0o644);
        }
    }
}

/// Frees a returned path list when the test is done with it.
pub fn free(svc: *ops.FileOperationService, paths: []const []const u8) void {
    ops.freePaths(svc.gpa, paths);
}

/// A scratch dir plus a service, torn down together.
pub const Env = struct {
    s: Scratch,
    svc: ops.FileOperationService,

    pub fn init(gpa: std.mem.Allocator) !Env {
        return .{ .s = try Scratch.init(gpa), .svc = ops.FileOperationService.init(gpa) };
    }

    pub fn deinit(e: *Env) void {
        e.svc.deinit();
        e.s.deinit();
    }

    pub fn expectFailure(e: *const Env, kind: fs.Kind, leaf: ?[]const u8) !void {
        try std.testing.expectEqual(kind, e.svc.failure.kind);
        if (leaf) |l| try std.testing.expectEqualStrings(l, std.fs.path.basename(e.svc.failure.path()));
    }

    pub fn expectTitles(e: *const Env, undo: ?[]const u8, redo: ?[]const u8) !void {
        inline for (.{ .{ e.svc.undoTitle(), undo }, .{ e.svc.redoTitle(), redo } }) |pair| {
            if (pair[1]) |want| {
                try std.testing.expectEqualStrings(want, pair[0] orelse return error.TestUnexpectedResult);
            } else try std.testing.expect(pair[0] == null);
        }
    }

    /// Fresh Trash-safe leaf name: unique per run (the scratch dir's random suffix).
    pub fn unique(e: *Env, prefix: []const u8, suffix: []const u8) []const u8 {
        return std.fmt.allocPrint(e.s.alloc(), "nanofm-test-{s}-{s}{s}", .{ prefix, std.fs.path.basename(e.s.dir), suffix }) catch @panic("oom");
    }
};
