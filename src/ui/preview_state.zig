//! What the previews keep between frames, in one place so the model carries one field: the
//! thumbnail cache (`thumbs.zig`), the pixel sizes read from picture headers, Quick Look's
//! bookkeeping (`quick_look.zig`) and where the Share button was pressed.
const std = @import("std");
const Allocator = std.mem.Allocator;
const thumbs = @import("thumbs.zig");
const image_info = @import("image_info.zig");
const quick_look = @import("quick_look_state.zig");
const Anchor = @import("hooks.zig").Anchor;

const DimsEntry = struct {
    path: []u8,
    mtime: i64,
    dims: ?image_info.Dims,
};

/// Header sizes already read, so the file is opened once and not at every frame. Few entries:
/// only what the inspectors show.
const DimsCache = struct {
    items: std.ArrayList(DimsEntry) = .empty,
    /// How many files were actually read (tests).
    reads: usize = 0,

    const max_items = 48;

    fn get(self: *DimsCache, gpa: Allocator, read: image_info.ReadFn, path: []const u8, mtime: i64) ?image_info.Dims {
        for (self.items.items) |e| {
            if (e.mtime == mtime and std.mem.eql(u8, e.path, path)) return e.dims;
        }
        const d = read(path);
        self.reads += 1;
        const copy = gpa.dupe(u8, path) catch return d;
        if (self.items.items.len >= max_items) {
            gpa.free(self.items.items[0].path);
            _ = self.items.orderedRemove(0);
        }
        self.items.append(gpa, .{ .path = copy, .mtime = mtime, .dims = d }) catch {
            gpa.free(copy);
            return d;
        };
        return d;
    }
};

pub const State = struct {
    thumbs: *thumbs.Shared,
    dims: DimsCache = .{},
    ql: quick_look.State = .{},
    /// The Share button last pressed: the share sheet hangs from it.
    share_anchor: ?Anchor = null,

    pub fn init(gpa: Allocator) Allocator.Error!State {
        return .{ .thumbs = try thumbs.Shared.create(gpa) };
    }

    pub fn deinit(self: *State, gpa: Allocator) void {
        self.thumbs.close();
        for (self.dims.items.items) |e| gpa.free(e.path);
        self.dims.items.deinit(gpa);
    }

    /// The pixel size of the picture at `path` (modified at `mtime`), read through `read` once.
    pub fn pixelSize(self: *State, gpa: Allocator, read: image_info.ReadFn, path: []const u8, mtime: i64) ?image_info.Dims {
        return self.dims.get(gpa, read, path, mtime);
    }
};
