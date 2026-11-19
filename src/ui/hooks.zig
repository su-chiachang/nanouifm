//! The few things the model asks the outside world to do, each behind a function pointer that is
//! null unless main.zig installs one (`system_hooks.zig`), so no test ever touches the system
//! clipboard, the pasteboard, Finder or the keyboard state: tests install recorders or nothing.
//! (The file opener is the same idea and lives in `opener.zig`.)
const std = @import("std");

/// The app-level chords a menu bar owns but a focused text field holds back (see `menu_link.zig`):
/// the view runs them itself, through `Hooks.app_role`.
pub const AppRole = enum { quit, hide, hide_others, minimize };

pub const Hooks = struct {
    /// Puts copied files on the system pasteboard as file URLs (Copy), so Finder and other apps
    /// can paste them. The internal clipboard is what Paste uses; this only mirrors it.
    copy_files: ?*const fn (paths: []const []const u8) void = null,
    /// Puts text on the system clipboard (Copy Path).
    copy_text: ?*const fn (text: []const u8) void = null,
    /// Shows these items selected in Finder (Reveal in Finder).
    reveal: ?*const fn (paths: []const []const u8) void = null,
    /// The files other apps put on the system pasteboard (owned: the caller frees each path
    /// and the slice with `Hooks.freePaths`); null when it holds none.
    read_files: ?*const fn (gpa: std.mem.Allocator) ?[][]u8 = null,
    /// Changes whenever anything writes to the system pasteboard: Paste uses the pasteboard's
    /// files rather than the internal clipboard only when something else wrote since Copy.
    change_count: ?*const fn () isize = null,
    /// Whether Option is held right now (dropping from Finder: a copy). Tests use the
    /// tester's modifier state instead.
    option_held: ?*const fn () bool = null,
    /// Quit, Hide, Hide Others and Minimize, the way the App and Window menus do them. Only needed
    /// while a text field has the keyboard and the menu bar's key equivalents are held back.
    app_role: ?*const fn (role: AppRole) void = null,

    pub fn freePaths(gpa: std.mem.Allocator, paths: [][]u8) void {
        for (paths) |p| gpa.free(p);
        gpa.free(paths);
    }
};
