//! The app's own file clipboard: the paths Copy put there. Paste reads this, never the system
//! pasteboard (which `Hooks.copy_files` only mirrors, in the real app), so tests are hermetic.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Clipboard = struct {
    gpa: Allocator,
    /// The copied items (owned paths), in the order they were selected.
    paths: std.ArrayList([]const u8) = .empty,
    /// The system pasteboard's change count right after we mirrored to it (0: never).
    mirrored: isize = 0,

    pub fn init(gpa: Allocator) Clipboard {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Clipboard) void {
        self.clear();
        self.paths.deinit(self.gpa);
    }

    pub fn clear(self: *Clipboard) void {
        for (self.paths.items) |p| self.gpa.free(p);
        self.paths.clearRetainingCapacity();
    }

    /// Replaces the contents with copies of `paths`.
    pub fn set(self: *Clipboard, paths: []const []const u8) Allocator.Error!void {
        self.clear();
        try self.paths.ensureUnusedCapacity(self.gpa, paths.len);
        for (paths) |p| {
            const copy = try self.gpa.dupe(u8, p);
            self.paths.appendAssumeCapacity(copy);
        }
    }

    pub fn isEmpty(self: *const Clipboard) bool {
        return self.paths.items.len == 0;
    }
};
