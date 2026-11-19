//! Shallow directory listing, Finder-like sorting and single-item stat (port of DirectoryLister).
//!
//! POSIX only (macOS first): uses libc `opendir`/`readdir`/`fstatat` directly. Hidden = dotfiles or the
//! macOS UF_HIDDEN flag. Packages (.app, ...) are not directories. Symlinks to folders behave like folders.
//! Strings in a `FileItem` are owned by the item; free a listing with `freeItems`.

const std = @import("std");
const builtin = @import("builtin");
const c = std.c;
const kinds = @import("file_kinds.zig");

pub const file_item = @import("file_item.zig");
pub const FileItem = file_item.FileItem;
pub const SortKey = file_item.SortKey;
pub const SortOrder = file_item.SortOrder;
pub const Timestamp = file_item.Timestamp;
pub const compareNames = file_item.compareNames;

pub const ListError = error{
    FileNotFound,
    NotDir,
    AccessDenied,
    NameTooLong,
    OutOfMemory,
    Unexpected,
};

const UF_HIDDEN: u32 = 0x8000;
const is_darwin = builtin.os.tag.isDarwin();

/// Shallow listing of `dir_path` (relative or absolute; a symlink to a folder is followed, children keep
/// the link's own path). Errors if unreadable. Order is the file system's; use `sort`.
/// Free with `freeItems`.
pub fn list(gpa: std.mem.Allocator, dir_path: []const u8, show_hidden: bool) ListError![]FileItem {
    var zbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dz = try toZ(&zbuf, dir_path);
    const dir = c.opendir(dz) orelse return switch (c.errno(@as(c_int, -1))) {
        .NOENT => error.FileNotFound,
        .NOTDIR => error.NotDir,
        .ACCES, .PERM => error.AccessDenied,
        .NAMETOOLONG => error.NameTooLong,
        .NOMEM => error.OutOfMemory,
        else => error.Unexpected,
    };
    defer _ = c.closedir(dir);

    var items: std.ArrayList(FileItem) = .empty;
    errdefer freeList(gpa, &items);
    while (c.readdir(dir)) |ent| {
        const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&ent.name)), 0);
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        const full = try joinPath(gpa, dir_path, name);
        defer gpa.free(full);
        const it = try makeItem(gpa, full);
        if (!show_hidden and it.is_hidden) {
            it.deinit(gpa);
            continue;
        }
        items.append(gpa, it) catch |e| {
            it.deinit(gpa);
            return e;
        };
    }
    return items.toOwnedSlice(gpa);
}

fn freeList(gpa: std.mem.Allocator, items: *std.ArrayList(FileItem)) void {
    for (items.items) |it| it.deinit(gpa);
    items.deinit(gpa);
}

/// Frees a slice returned by `list` (each item's strings, then the slice).
pub fn freeItems(gpa: std.mem.Allocator, items: []FileItem) void {
    for (items) |it| it.deinit(gpa);
    gpa.free(items);
}

/// Sorts in place with the Finder-like order: stable; folders first if requested (even when descending);
/// null sizes/dates last in both directions; ties fall back to name, then input order.
pub fn sort(items: []FileItem, order: SortOrder) void {
    std.sort.block(FileItem, items, order, file_item.lessThan);
}

/// Like Swift's `sorted`: a new slice (free with `gpa.free`, NOT `freeItems`). Its items borrow the
/// strings of `items`, which must outlive it.
pub fn sorted(gpa: std.mem.Allocator, items: []const FileItem, order: SortOrder) std.mem.Allocator.Error![]FileItem {
    const copy = try gpa.dupe(FileItem, items);
    sort(copy, order);
    return copy;
}

/// The item at `path`, or null if nothing exists there (dangling symlinks still count).
/// Free with `FileItem.deinit`.
pub fn item(gpa: std.mem.Allocator, path: []const u8) std.mem.Allocator.Error!?FileItem {
    var zbuf: [std.fs.max_path_bytes]u8 = undefined;
    const pz = toZ(&zbuf, path) catch return null;
    var st: c.Stat = undefined;
    if (c.fstatat(c.AT.FDCWD, pz, &st, c.AT.SYMLINK_NOFOLLOW) != 0) return null;
    return makeItem(gpa, path) catch |e| switch (e) {
        error.NameTooLong => null, // such a path cannot exist
        error.OutOfMemory => error.OutOfMemory,
    };
}

// ---- internals ----

fn toZ(buf: []u8, path: []const u8) error{NameTooLong}![:0]const u8 {
    if (path.len >= buf.len) return error.NameTooLong;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return buf[0..path.len :0];
}

fn joinPath(gpa: std.mem.Allocator, dir: []const u8, name: []const u8) std.mem.Allocator.Error![]u8 {
    const sep = dir.len > 0 and dir[dir.len - 1] != '/';
    const out = try gpa.alloc(u8, dir.len + @intFromBool(sep) + name.len);
    @memcpy(out[0..dir.len], dir);
    if (sep) out[dir.len] = '/';
    @memcpy(out[out.len - name.len ..], name);
    return out;
}

fn ts(t: c.timespec) Timestamp {
    return @as(i64, @intCast(t.sec)) * std.time.ns_per_s + @as(i64, @intCast(t.nsec));
}

fn isMode(mode: anytype, fmt: u32) bool {
    return (@as(u32, mode) & c.S.IFMT) == fmt;
}

fn makeItem(gpa: std.mem.Allocator, path: []const u8) (std.mem.Allocator.Error || error{NameTooLong})!FileItem {
    var zbuf: [std.fs.max_path_bytes]u8 = undefined;
    const pz = try toZ(&zbuf, path);

    var lst: c.Stat = undefined;
    const have_l = c.fstatat(c.AT.FDCWD, pz, &lst, c.AT.SYMLINK_NOFOLLOW) == 0;
    const is_symlink = have_l and isMode(lst.mode, c.S.IFLNK);

    // `st` describes what the entry shows as: the target for a symlink that resolves.
    var tst: c.Stat = undefined;
    var have_t = false;
    if (is_symlink) have_t = c.stat(pz, &tst) == 0;
    const st: c.Stat = if (have_t) tst else lst;
    const have = have_t or have_l;

    const is_dir_raw = have and isMode(st.mode, c.S.IFDIR);

    const trimmed = std.mem.trimEnd(u8, path, "/");
    const base_start = if (std.mem.lastIndexOfScalar(u8, trimmed, '/')) |i| i + 1 else 0;
    const name_end = if (trimmed.len == 0) path.len else trimmed.len;
    const name_start = if (trimmed.len == 0) 0 else base_start;
    const name_len = name_end - name_start;
    const ext = kinds.extensionOf(path[name_start..name_end]);

    const is_package = is_dir_raw and kinds.isPackageExtension(ext);
    const is_directory = is_dir_raw and !is_package;
    const is_hidden = (name_len > 0 and path[name_start] == '.') or
        (is_darwin and have_l and (lst.flags & UF_HIDDEN) != 0);

    var kind: []const u8 = undefined;
    var fallback: []const u8 = "";
    if (is_symlink) {
        kind = "Alias";
    } else if (is_package) {
        kind = kinds.packageKind(ext);
    } else if (is_directory) {
        kind = "Folder";
    } else if (kinds.fileKind(ext)) |k| {
        kind = k;
    } else if (ext.len > 0 and ext.len <= 16) {
        fallback = ext;
        kind = "";
    } else {
        kind = "Document";
    }

    // One allocation: path, then the "<EXT> file" fallback when no table entry matched.
    const total = path.len + (if (fallback.len > 0) fallback.len + " file".len else 0);
    const buf = try gpa.alloc(u8, total);
    @memcpy(buf[0..path.len], path);
    if (fallback.len > 0) {
        const up = std.ascii.upperString(buf[path.len .. path.len + fallback.len], fallback);
        @memcpy(buf[path.len + up.len ..], " file");
        kind = buf[path.len..];
    }

    const created: ?Timestamp = if (!have) null else if (@hasDecl(c.Stat, "birthtime")) ts(st.birthtime()) else null;
    return .{
        .path = buf[0..path.len],
        .name = buf[name_start..name_end],
        .is_directory = is_directory,
        .is_package = is_package,
        .is_hidden = is_hidden,
        .is_symlink = is_symlink,
        .size = if (!have or is_dir_raw) null else @as(i64, @intCast(st.size)),
        .modified = if (have) ts(st.mtime()) else null,
        .created = created,
        .kind = kind,
        .buf = buf,
    };
}

test {
    _ = @import("file_item.zig");
    _ = @import("file_kinds.zig");
    _ = @import("lister_tests.zig");
}
