//! Quick Look's bookkeeping on the model: whether the panel was brought up from here, and a
//! digest of the item list it was last given (so `quick_look.sync` only calls the hook when the
//! selection really changed). A leaf file, so `preview_state.zig` can hold it.
const std = @import("std");

pub const State = struct {
    /// The panel was shown by `toggle` and has not been seen closed since.
    shown: bool = false,
    /// A digest of the paths the panel was last given.
    digest: u64 = 0,
};

/// A digest of `paths` (order matters: the first is the one previewed).
pub fn digestOf(paths: []const []const u8) u64 {
    var h = std.hash.Wyhash.init(0x91c);
    for (paths) |p| {
        h.update(p);
        h.update("\x00");
    }
    return h.final();
}
