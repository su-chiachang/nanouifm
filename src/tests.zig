//! The UI's tests: the view driven by ui.Tester, rendered offscreen, clicked by its text.
//! Every test works in a fresh temp folder; none reads the real home.
const std = @import("std");

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
    _ = @import("ui/tests_columns.zig");
    _ = @import("ui/tests_list_keys.zig");
    _ = @import("ui/tests_fileops.zig");
    _ = @import("ui/tests_context.zig");
    _ = @import("ui/tests_commands.zig");
    _ = @import("ui/tests_palette.zig");
    _ = @import("ui/tests_toolbar.zig");
    _ = @import("ui/tests_watch.zig");
    _ = @import("ui/tests_drop.zig");
    _ = @import("ui/commands.zig");
    _ = @import("ui/persist.zig");
    _ = @import("ui/drag_kind.zig");
    _ = @import("ui/tests_persist.zig");
    _ = @import("ui/tests_menu.zig");
    _ = @import("ui/tests_sidebar.zig");
    // The menu bar and the real volumes are only ever wired by main.zig: compiled, never run.
    std.testing.refAllDecls(@import("ui/menu_bar.zig"));
    std.testing.refAllDecls(@import("ui/system_volumes.zig"));
    _ = @import("ui/tests_snapshot.zig");
    _ = @import("ui/tests_snapshot_ops.zig");
    _ = @import("ui/tests_snapshot_palette.zig");
    _ = @import("ui/tests_snapshot_sidebar.zig");
    _ = @import("ui/typeahead.zig");
    _ = @import("ui/column_model.zig");
}
