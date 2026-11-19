//! A folder's listing as the list shows it: every item the lister found, and the visible ones
//! (hidden files filtered, sorted) as a second slice that borrows the first one's strings.
const std = @import("std");
const Allocator = std.mem.Allocator;
const lister = @import("../core/lister.zig");
const FileItem = lister.FileItem;

pub const Listing = struct {
    /// Everything the lister returned, hidden items included (owned; freed with `lister.freeItems`).
    all: []FileItem = &.{},
    /// What is shown: `all` filtered and sorted. The slice is owned, the strings are `all`'s.
    visible: []FileItem = &.{},
    /// Set when the folder could not be listed; the list area shows it.
    err: ?lister.ListError = null,

    /// THE listing seam: the one place the app reads a folder from disk.
    ///
    /// NOTE: this runs synchronously on the main thread for now. A big or slow folder (network
    /// volume, ~/Library) blocks the UI while it reads. Moving it off-main later means running
    /// this function on a worker, handing the finished `[]FileItem` back through
    /// `requestFrameFromAnyThread`/`objc.dispatchMain`, and having the model apply it as a
    /// generation-checked result (see Swift's ListingCache). Everything else only sees `Listing`.
    /// Hidden files are always listed; `rebuild` filters them, so toggling them needs no re-read.
    pub fn loadFolder(gpa: Allocator, path: []const u8) lister.ListError![]FileItem {
        return lister.list(gpa, path, true);
    }

    /// The folder as a listing; one that can't be read becomes a listing with its error.
    pub fn read(gpa: Allocator, path: []const u8) Allocator.Error!Listing {
        if (loadFolder(gpa, path)) |items| return fromItems(items) else |e| switch (e) {
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

    /// Recomputes `visible` for the hidden-files setting and the order.
    pub fn rebuild(self: *Listing, gpa: Allocator, show_hidden: bool, order: lister.SortOrder) Allocator.Error!void {
        var out: std.ArrayList(FileItem) = .empty;
        errdefer out.deinit(gpa);
        for (self.all) |it| if (show_hidden or !it.is_hidden) try out.append(gpa, it);
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
