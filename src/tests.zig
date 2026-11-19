//! The UI's tests: the view driven by ui.Tester, rendered offscreen, clicked by its text.
//! Every test works in a fresh temp folder; none reads the real home.
test {
    _ = @import("ui/history.zig");
    _ = @import("ui/selection.zig");
    _ = @import("ui/format.zig");
    _ = @import("ui/sidebar_model.zig");
    _ = @import("ui/path_bar.zig");
    _ = @import("ui/pane_sizes.zig");
    _ = @import("ui/tab_strip.zig");
    _ = @import("ui/tests.zig");
    _ = @import("ui/tests_tabs.zig");
    _ = @import("ui/tests_split.zig");
    _ = @import("ui/tests_snapshot.zig");
}
