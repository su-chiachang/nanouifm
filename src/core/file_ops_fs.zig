//! Low-level file system primitives for file_ops.zig: libc calls (lstat, renamex_np, copyfile,
//! mkdir, readdir) and the Trash through NSFileManager, reached with nanoui's `objc.msg`.
//! Nothing here ever unlinks anything: deleting means moving to the Trash.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const c = std.c;

pub const path_max = 1024;
pub const E = c.E;

extern "c" fn renamex_np(from: [*:0]const u8, to: [*:0]const u8, flags: c_uint) c_int;
extern "c" fn copyfile(from: [*:0]const u8, to: [*:0]const u8, state: ?*anyopaque, flags: u32) c_int;
extern "c" fn strerror(code: c_int) [*:0]const u8;

const RENAME_EXCL: c_uint = 0x4; // sys/stdio.h
const COPYFILE_ACL: u32 = 1 << 0; // copyfile.h
const COPYFILE_STAT: u32 = 1 << 1;
const COPYFILE_XATTR: u32 = 1 << 2;
const COPYFILE_DATA: u32 = 1 << 3;
const COPYFILE_METADATA: u32 = COPYFILE_ACL | COPYFILE_STAT | COPYFILE_XATTR;
const COPYFILE_ALL: u32 = COPYFILE_METADATA | COPYFILE_DATA;
const COPYFILE_EXCL: u32 = 1 << 17;
const COPYFILE_NOFOLLOW: u32 = (1 << 18) | (1 << 19); // _SRC | _DST

// ---------------------------------------------------------------- diagnostics

pub const Kind = enum { none, destination_exists, invalid_name, source_missing, into_itself, underlying };

/// What went wrong in the last failed operation (Zig errors carry no payload).
pub const Diag = struct {
    kind: Kind = .none,
    path_buf: [path_max]u8 = undefined,
    path_len: usize = 0,
    /// errno, or the NSError code for a Trash failure; 0 when unknown.
    code: i32 = 0,
    msg_buf: [256]u8 = undefined,
    msg_len: usize = 0,

    pub fn set(d: *Diag, kind: Kind, p: []const u8) void {
        d.kind = kind;
        d.path_len = @min(p.len, path_max);
        @memcpy(d.path_buf[0..d.path_len], p[0..d.path_len]);
        d.code = 0;
        d.msg_len = 0;
    }

    pub fn path(d: *const Diag) []const u8 {
        return d.path_buf[0..d.path_len];
    }

    pub fn message(d: *const Diag) []const u8 {
        return d.msg_buf[0..d.msg_len];
    }

    fn setMessage(d: *Diag, text: []const u8) void {
        d.msg_len = @min(text.len, d.msg_buf.len);
        @memcpy(d.msg_buf[0..d.msg_len], text[0..d.msg_len]);
    }

    /// The user-facing text (same wording as the Swift app's errorDescription). Empty for `.none`.
    /// `buf` should be about 1400 bytes; the text is cut short if it does not fit.
    pub fn describe(d: *const Diag, buf: []u8) []const u8 {
        const leaf = std.fs.path.basename(d.path());
        const text = switch (d.kind) {
            .none => return "",
            .destination_exists => std.fmt.bufPrint(buf, "An item named \u{201C}{s}\u{201D} already exists in the destination.", .{leaf}),
            .invalid_name => if (std.mem.trim(u8, d.path(), " \t\r\n").len == 0)
                std.fmt.bufPrint(buf, "The name can\u{2019}t be empty.", .{})
            else
                std.fmt.bufPrint(buf, "\u{201C}{s}\u{201D} is not a valid name. Names can\u{2019}t contain \u{201C}/\u{201D} or \u{201C}:\u{201D}.", .{d.path()}),
            .source_missing => std.fmt.bufPrint(buf, "\u{201C}{s}\u{201D} no longer exists.", .{leaf}),
            .into_itself => std.fmt.bufPrint(buf, "\u{201C}{s}\u{201D} can\u{2019}t be placed inside itself.", .{leaf}),
            .underlying => if (d.msg_len > 0)
                std.fmt.bufPrint(buf, "{s}", .{d.message()})
            else
                std.fmt.bufPrint(buf, "The operation failed ({s}).", .{std.mem.span(strerror(d.code))}),
        };
        return text catch buf;
    }
};

// ---------------------------------------------------------------- stat helpers

/// NUL-terminates `p` into `buf`; null when it does not fit.
pub fn z(buf: *[path_max]u8, p: []const u8) ?[*:0]const u8 {
    if (p.len >= path_max) return null;
    @memcpy(buf[0..p.len], p);
    buf[p.len] = 0;
    return buf[0..p.len :0].ptr;
}

fn lastErrno(rc: c_int) E {
    return c.errno(rc);
}

/// lstat (never follows a final symlink).
pub fn lstatE(path: []const u8, st: *c.Stat) E {
    var b: [path_max]u8 = undefined;
    const zp = z(&b, path) orelse return .NAMETOOLONG;
    const rc = c.fstatat(c.AT.FDCWD, zp, st, c.AT.SYMLINK_NOFOLLOW);
    return if (rc == 0) .SUCCESS else lastErrno(rc);
}

pub fn lstat(path: []const u8) ?c.Stat {
    var st: c.Stat = undefined;
    return if (lstatE(path, &st) == .SUCCESS) st else null;
}

/// True for anything on disk, including a dangling symlink.
pub fn exists(path: []const u8) bool {
    return lstat(path) != null;
}

pub const DirCheck = enum { missing, directory, not_directory };

/// Follows symlinks (a link to a folder is a usable destination).
pub fn checkDirectory(path: []const u8) DirCheck {
    var b: [path_max]u8 = undefined;
    const zp = z(&b, path) orelse return .missing;
    var st: c.Stat = undefined;
    if (c.fstatat(c.AT.FDCWD, zp, &st, 0) != 0) return .missing;
    return if (c.S.ISDIR(st.mode)) .directory else .not_directory;
}

pub fn isDirectory(st: c.Stat) bool {
    return c.S.ISDIR(st.mode);
}

pub fn sameFile(a: []const u8, b: []const u8) bool {
    const x = lstat(a) orelse return false;
    const y = lstat(b) orelse return false;
    return x.dev == y.dev and x.ino == y.ino;
}

/// A folder that is not a package (.app, .bundle, ...): the kind whose names have no extension.
pub fn isRealDirectory(path: []const u8) bool {
    const st = lstat(path) orelse return false;
    if (!isDirectory(st)) return false;
    return !isPackage(path);
}

pub fn isPackage(path: []const u8) bool {
    const pool = objc.Pool.push();
    defer pool.pop();
    const ws = objc.msg(objc.Object, objc.class("NSWorkspace"), "sharedWorkspace", .{});
    return objc.msg(objc.BOOL, ws, "isFilePackageAtPath:", .{objc.nsString(path)});
}

/// realpath(3) into `buf`; null when the path does not resolve.
pub fn realpath(buf: *[path_max]u8, path: []const u8) ?[]const u8 {
    var zb: [path_max]u8 = undefined;
    const zp = z(&zb, path) orelse return null;
    const r = c.realpath(zp, buf) orelse return null;
    return std.mem.span(r);
}

// ---------------------------------------------------------------- move / mkdir

/// Renames without ever replacing an existing destination (EEXIST instead).
pub fn moveExcl(src: []const u8, dst: []const u8) E {
    var b1: [path_max]u8 = undefined;
    var b2: [path_max]u8 = undefined;
    const zs = z(&b1, src) orelse return .NAMETOOLONG;
    const zd = z(&b2, dst) orelse return .NAMETOOLONG;
    const rc = renamex_np(zs, zd, RENAME_EXCL);
    if (rc == 0) return .SUCCESS;
    const e = lastErrno(rc);
    if (e != .OPNOTSUPP) return e; // ENOTSUP shares the code
    // A volume without RENAME_EXCL: check first, then plain rename.
    if (exists(dst)) return .EXIST;
    const rc2 = c.rename(zs, zd);
    return if (rc2 == 0) .SUCCESS else lastErrno(rc2);
}

/// Plain rename(2) for a verified case-only rename (the caller has checked same file).
pub fn renameCaseOnly(src: []const u8, dst: []const u8) E {
    var b1: [path_max]u8 = undefined;
    var b2: [path_max]u8 = undefined;
    const zs = z(&b1, src) orelse return .NAMETOOLONG;
    const zd = z(&b2, dst) orelse return .NAMETOOLONG;
    const rc = c.rename(zs, zd);
    return if (rc == 0) .SUCCESS else lastErrno(rc);
}

pub fn makeDir(path: []const u8, mode: c.mode_t) E {
    var b: [path_max]u8 = undefined;
    const zp = z(&b, path) orelse return .NAMETOOLONG;
    const rc = c.mkdir(zp, mode);
    return if (rc == 0) .SUCCESS else lastErrno(rc);
}

fn chmodPath(path: []const u8, mode: c.mode_t) E {
    var b: [path_max]u8 = undefined;
    const zp = z(&b, path) orelse return .NAMETOOLONG;
    const rc = c.chmod(zp, mode);
    return if (rc == 0) .SUCCESS else lastErrno(rc);
}

// ---------------------------------------------------------------- copy

/// Copies the item at `src` to the not yet existing `dst`: files with copyfile(3) (data, xattrs,
/// ACLs, times), folders recursively, symlinks as symlinks (never followed). Never overwrites.
/// On failure `dst` may be left partially written: the caller discards it.
pub fn copyTree(src: []const u8, dst: []const u8) E {
    var st: c.Stat = undefined;
    const se = lstatE(src, &st);
    if (se != .SUCCESS) return se;
    var b1: [path_max]u8 = undefined;
    var b2: [path_max]u8 = undefined;
    const zs = z(&b1, src) orelse return .NAMETOOLONG;
    const zd = z(&b2, dst) orelse return .NAMETOOLONG;

    if (c.S.ISLNK(st.mode)) {
        var target: [path_max]u8 = undefined;
        const n = c.readlink(zs, &target, path_max - 1);
        if (n < 0) return lastErrno(-1);
        target[@intCast(n)] = 0;
        const rc = c.symlink(@ptrCast(&target), zd);
        return if (rc == 0) .SUCCESS else lastErrno(rc);
    }
    if (c.S.ISDIR(st.mode)) return copyDir(src, dst, zs, zd, st);
    const rc = copyfile(zs, zd, null, COPYFILE_ALL | COPYFILE_EXCL | COPYFILE_NOFOLLOW);
    return if (rc == 0) .SUCCESS else lastErrno(rc);
}

fn copyDir(src: []const u8, dst: []const u8, zs: [*:0]const u8, zd: [*:0]const u8, st: c.Stat) E {
    const me = makeDir(dst, 0o700);
    if (me != .SUCCESS) return me;
    const dir = c.opendir(zs) orelse return lastErrno(-1);
    defer _ = c.closedir(dir);
    while (c.readdir(dir)) |ent| {
        const name = std.mem.sliceTo(&ent.name, 0);
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        var sb: [path_max]u8 = undefined;
        var db: [path_max]u8 = undefined;
        const cs = std.fmt.bufPrint(&sb, "{s}/{s}", .{ src, name }) catch return .NAMETOOLONG;
        const cd = std.fmt.bufPrint(&db, "{s}/{s}", .{ dst, name }) catch return .NAMETOOLONG;
        const e = copyTree(cs, cd);
        if (e != .SUCCESS) return e;
    }
    // Metadata last: a read-only source folder must not block copying its children.
    _ = copyfile(zs, zd, null, COPYFILE_METADATA | COPYFILE_NOFOLLOW);
    return chmodPath(dst, st.mode & 0o7777);
}

// ---------------------------------------------------------------- Trash

/// Moves `path` to the Trash with NSFileManager and returns where it ended up (caller frees).
/// `error.Failed` fills `diag` (kind .underlying, the NSError's code and description).
pub fn trashItem(gpa: std.mem.Allocator, path: []const u8, diag: *Diag) error{ Failed, OutOfMemory }![]u8 {
    const pool = objc.Pool.push();
    defer pool.pop();
    const url = objc.msg(objc.Object, objc.class("NSURL"), "fileURLWithPath:", .{objc.nsString(path)});
    const fm = objc.msg(objc.Object, objc.class("NSFileManager"), "defaultManager", .{});
    var result: ?objc.Object = null;
    var ns_err: ?objc.Object = null;
    const ok = objc.msg(objc.BOOL, fm, "trashItemAtURL:resultingItemURL:error:", .{ url, &result, &ns_err });
    if (!ok) {
        diag.set(.underlying, path);
        if (ns_err) |e| {
            diag.code = @intCast(objc.msg(objc.NSInteger, e, "code", .{}));
            diag.setMessage(objc.fromNSString(objc.msg(?objc.Object, e, "localizedDescription", .{})));
        }
        return error.Failed;
    }
    if (result) |r| {
        const p = objc.fromNSString(objc.msg(?objc.Object, r, "path", .{}));
        if (p.len > 0) return gpa.dupe(u8, p);
    }
    // The system did not say where: the usual place.
    const home = if (c.getenv("HOME")) |h| std.mem.span(h) else "";
    return std.fmt.allocPrint(gpa, "{s}/.Trash/{s}", .{ home, std.fs.path.basename(path) });
}

/// Best-effort rollback of something an operation itself created: into the Trash, nothing else.
pub fn discard(gpa: std.mem.Allocator, path: []const u8) void {
    var scratch: Diag = .{};
    const t = trashItem(gpa, path, &scratch) catch return;
    gpa.free(t);
}

// ---------------------------------------------------------------- tests

test "trashItem returns a Trash path that can be moved back" {
    const gpa = std.testing.allocator;
    var tmpl = "/tmp/nanofmCoreTests-XXXXXX".*;
    const base = mkdtempZ(&tmpl) orelse return error.SkipZigTest;
    var rb: [path_max]u8 = undefined;
    const dir = realpath(&rb, base) orelse return error.SkipZigTest;
    var pb: [path_max]u8 = undefined;
    const file = try std.fmt.bufPrint(&pb, "{s}/nanofm-probe-{s}.txt", .{ dir, std.fs.path.basename(dir) });
    var zb: [path_max]u8 = undefined;
    const fd = c.open(z(&zb, file).?, c.O{ .ACCMODE = .WRONLY, .CREAT = true }, @as(c_uint, 0o644));
    try std.testing.expect(fd >= 0);
    _ = c.close(fd);

    var diag: Diag = .{};
    const t = try trashItem(gpa, file, &diag);
    defer gpa.free(t);
    try std.testing.expect(!exists(file));
    try std.testing.expect(exists(t));
    try std.testing.expectEqual(E.SUCCESS, moveExcl(t, file));
    try std.testing.expect(exists(file));

    // own temp scaffolding only
    var cb: [path_max]u8 = undefined;
    _ = c.unlink(z(&cb, file).?);
    _ = c.rmdir(z(&cb, dir).?);
}

extern "c" fn mkdtemp(template: [*:0]u8) ?[*:0]u8;

fn mkdtempZ(tmpl: [:0]u8) ?[]const u8 {
    const r = mkdtemp(tmpl.ptr) orelse return null;
    return std.mem.span(r);
}
