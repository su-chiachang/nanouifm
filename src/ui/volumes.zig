//! The mounted volumes (the sidebar's Locations), behind a provider the model is given:
//! main.zig installs the system's (`system_volumes.zig`: NSFileManager, NSWorkspace), tests a fake
//! list they change as they like, so no test ever reads the real volumes. A change in the
//! system's volumes (a mount, an unmount, a rename, the app coming forward) marks a `Signal`;
//! the model reads the list again at the start of its next pass and wakes the window to run one.
const std = @import("std");
const Allocator = std.mem.Allocator;
const watch = @import("watch.zig");

pub const Volume = struct {
    path: []const u8,
    /// The volume's name ("Macintosh HD").
    title: []const u8,
    /// Has an eject button (not the startup volume, not a plain internal disk).
    ejectable: bool = false,
};

pub const Provider = struct {
    /// The mounted volumes, in the order to show them; the slice and the strings are owned by
    /// the caller (`freeList`).
    list: *const fn (gpa: Allocator) Allocator.Error![]Volume,
    /// Unmounts and ejects the volume at `path`; false when it could not be.
    eject: ?*const fn (path: []const u8) bool = null,

    pub fn freeList(gpa: Allocator, vols: []Volume) void {
        for (vols) |v| {
            gpa.free(v.path);
            gpa.free(v.title);
        }
        gpa.free(vols);
    }
};

/// "Something changed": set from the system's notifications (the main thread) or a test, read by
/// the model. On the heap, so its address outlives moves of the model.
pub const Signal = struct {
    dirty: bool = false,
    waker: ?watch.Waker = null,

    pub fn mark(self: *Signal) void {
        self.dirty = true;
        if (self.waker) |w| w.wake(w.ctx);
    }

    pub fn take(self: *Signal) bool {
        defer self.dirty = false;
        return self.dirty;
    }
};
