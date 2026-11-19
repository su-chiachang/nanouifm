//! Every core module's tests. Add `_ = @import("name.zig");` when a module lands.
test {
    _ = @import("lister.zig");
    _ = @import("fuzzy.zig");
    _ = @import("search_index.zig");
    _ = @import("state_store.zig");
    _ = @import("pane_layout.zig");
    _ = @import("file_ops.zig");
    _ = @import("dir_watcher.zig");
}
