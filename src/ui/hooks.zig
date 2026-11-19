//! The few things the model asks the outside world to do, each behind a function pointer that is
//! null unless main.zig installs one (`system_hooks.zig`), so no test ever touches the system
//! clipboard, the pasteboard, Finder or the keyboard state: tests install recorders or nothing.
//! (The file opener is the same idea and lives in `opener.zig`.)
const std = @import("std");
const thumbs = @import("thumbs.zig");
const image_info = @import("image_info.zig");

/// The app-level chords a menu bar owns but a focused text field holds back (see `menu_link.zig`):
/// the view runs them itself, through `Hooks.app_role`.
pub const AppRole = enum { quit, hide, hide_others, minimize };

/// Where a button is in the window (points, top left origin): what a share sheet hangs from.
pub const Anchor = struct { x: f32, y: f32, w: f32, h: f32 };

/// The system's Quick Look panel (`system_quick_look.zig`). Tests install a recorder.
pub const QuickLook = struct {
    /// Shows the panel on `paths` (the selection, in row order), or hides it if it is up.
    toggle: *const fn (paths: []const []const u8) void,
    /// The panel is up: it should show `paths` now (the selection changed).
    update: *const fn (paths: []const []const u8) void,
    /// Whether the panel is on screen (the user may have closed it with its own button).
    is_open: *const fn () bool,
};

/// A window's frame in points with the origin at the screen's top left and y down (nanoui's
/// `Window.frame` convention). `window_growth.zig` converts to the core's bottom-left origin.
pub const Frame = struct { x: f64, y: f64, w: f64, h: f64 };

/// The window itself (`system_window.zig`), for growing it when a layout needs room. Tests install
/// a recorder over a fake frame; none: the window is never resized.
pub const WindowFrame = struct {
    /// The window's frame now (null: unknown, nothing is done).
    get: *const fn () ?Frame,
    /// Makes this the window's frame. Called from `Model.applyPending`; the real one defers the
    /// resize to the next turn of the main loop rather than resizing under a running frame.
    set: *const fn (Frame) void,
    /// The visible frame of the window's screen (menu bar and Dock left out): the limit.
    visible: *const fn () ?Frame,
};

/// An app that can open a file (`OpenWith`).
pub const OpenApp = struct {
    /// "Preview" (the bundle's display name, without ".app").
    name: []const u8,
    /// The app bundle's absolute path.
    path: []const u8,
};

/// The context menu's "Open With" rows (`system_open_with.zig`).
pub const OpenWith = struct {
    /// The apps that can open `file`, the default app first (the caller keeps the first few). The
    /// result and every string in it are allocated with `gpa` (free with `Hooks.freeApps`).
    list: *const fn (gpa: std.mem.Allocator, file: []const u8) std.mem.Allocator.Error![]OpenApp,
    /// Opens `file` with the app at `app_path`; false if that failed.
    open: *const fn (app_path: []const u8, file: []const u8) bool,
};

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
    /// Quick Look (Space, Cmd+Y). Null: the command does nothing.
    quick_look: ?QuickLook = null,
    /// The share sheet for these files, hanging from the Share button. Null: a notice says
    /// sharing is not available.
    share: ?*const fn (paths: []const []const u8, anchor: Anchor) void = null,
    /// Thumbnails for the inspector's preview, made asynchronously (see `thumbs.zig`). Null: the
    /// file's icon is all the preview there is.
    thumbnail: ?thumbs.Provider = null,
    /// A picture's size in pixels for the inspector's Resolution row: by default its header is
    /// read from the file (a PNG, JPEG or GIF).
    image_size: image_info.ReadFn = image_info.fromFile,

    /// The window's frame, for growing it with a layout. Null: the window is left alone.
    window_frame: ?WindowFrame = null,
    /// Apps that can open a file, and opening with one. Null: no "Open With <App>" rows.
    open_with: ?OpenWith = null,

    pub fn freeApps(gpa: std.mem.Allocator, apps: []OpenApp) void {
        for (apps) |a| {
            gpa.free(a.name);
            gpa.free(a.path);
        }
        gpa.free(apps);
    }

    pub fn freePaths(gpa: std.mem.Allocator, paths: [][]u8) void {
        for (paths) |p| gpa.free(p);
        gpa.free(paths);
    }
};
