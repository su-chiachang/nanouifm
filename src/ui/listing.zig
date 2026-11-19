//! A folder's listing as the list shows it: every item the lister found, and the visible ones
//! (hidden files filtered, sorted) as a second slice that borrows the first one's strings.
const std = @import("std");
const Allocator = std.mem.Allocator;
const lister = @import("../core/lister.zig");
const FileItem = lister.FileItem;
pub const Preloaded = @import("listing_inbox.zig").Preloaded;

pub const Listing = struct {
    /// Everything the lister returned, hidden items included (owned; freed with `lister.freeItems`).
    all: []FileItem = &.{},
    /// What is shown: `all` filtered and sorted. The slice is owned, the strings are `all`'s.
    visible: []FileItem = &.{},
    /// Set when the folder could not be listed; the list area shows it.
    err: ?lister.ListError = null,

    /// THE listing seam: the one place the app reads a folder from disk. It blocks, so with an
    /// asynchronous listing runner (`Config.listing`) it only ever runs on a worker thread, from
    /// `listing_runner.Job.read`; the model's own code asks the loader (`listing_loader.zig`) for
    /// folders and finds them already read (`fetch`). Without a runner (tests) the model reads
    /// here, inline. Hidden files are always listed; `rebuild` filters them, so toggling them
    /// needs no re-read.
    pub fn loadFolder(gpa: Allocator, path: []const u8) lister.ListError![]FileItem {
        return lister.list(gpa, path, true);
    }

    /// `loadFolder`, unless the request that landed (`pre`) already read `path`.
    pub fn fetch(gpa: Allocator, path: []const u8, pre: ?*Preloaded) lister.ListError![]FileItem {
        if (pre) |p| {
            if (p.take(path)) |r| return switch (r) {
                .items => |items| items,
                .err => |e| e,
            };
            p.misses += 1;
        }
        return loadFolder(gpa, path);
    }

    /// The folder as a listing; one that can't be read becomes a listing with its error.
    pub fn read(gpa: Allocator, path: []const u8) Allocator.Error!Listing {
        return readVia(gpa, path, null);
    }

    /// `read` through a landing request's preloaded folders.
    pub fn readVia(gpa: Allocator, path: []const u8, pre: ?*Preloaded) Allocator.Error!Listing {
        if (fetch(gpa, path, pre)) |items| return fromItems(items) else |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return failed(e),
        }
    }

    /// Takes ownership of `items`.
    pub fn fromItems(items: []FileItem) Listing {
        return .{ .all = items };
    }

    pub fn failed(e: lister.ListError) Listing {
        return .{ .err = e };
    }

    pub fn deinit(self: *Listing, gpa: Allocator) void {
        gpa.free(self.visible);
        lister.freeItems(gpa, self.all);
        self.* = .{};
    }

    /// Recomputes `visible` for the hidden-files setting, the toolbar's name filter ("" shows
    /// everything) and the order.
    pub fn rebuild(self: *Listing, gpa: Allocator, show_hidden: bool, order: lister.SortOrder, filter: []const u8) Allocator.Error!void {
        var out: std.ArrayList(FileItem) = .empty;
        errdefer out.deinit(gpa);
        for (self.all) |it| {
            if ((show_hidden or !it.is_hidden) and nameMatches(it.name, filter)) try out.append(gpa, it);
        }
        const fresh = try out.toOwnedSlice(gpa);
        lister.sort(fresh, order);
        gpa.free(self.visible);
        self.visible = fresh;
    }

    /// The index in `visible` of the item at `path`.
    pub fn indexOf(self: *const Listing, path: []const u8) ?usize {
        for (self.visible, 0..) |it, i| if (std.mem.eql(u8, it.path, path)) return i;
        return null;
    }
};

/// Whether `name` contains `filter` ignoring case (an empty filter matches everything), as
/// Swift's `localizedCaseInsensitiveContains` does for the toolbar's field.
pub fn nameMatches(name: []const u8, filter: []const u8) bool {
    if (filter.len == 0) return true;
    if (filter.len > name.len) return false;
    var i: usize = 0;
    while (i + filter.len <= name.len) : (i += 1) {
        if (std.ascii.startsWithIgnoreCase(name[i..], filter)) return true;
    }
    return false;
}

/// What a lister error says, for the banner.
pub fn errorText(e: lister.ListError) []const u8 {
    return switch (e) {
        error.FileNotFound => "The folder doesn't exist.",
        error.NotDir => "It isn't a folder.",
        error.AccessDenied => "You don't have permission to open it.",
        error.NameTooLong => "The path is too long.",
        error.OutOfMemory => "Out of memory.",
        error.Unexpected => "It couldn't be read.",
    };
}
