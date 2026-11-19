//! "Open With <App>" in the context menu: the apps that can open the selected file, asked of the
//! injected `Hooks.open_with` and kept per file extension (a file without one: per path), so the
//! system is asked once for all the ".txt" files of a session, not at every right-click.
//!
//! The menu never waits for the answer: while it is up, `context_menu.view` calls `ask`, which only
//! notes the path and asks for another frame; `service` (the start of `Model.applyPending`) does
//! the lookup, and the next frame draws the rows. Opening is a registry command per row
//! (`file_open_with_0` ... `_7`, hidden from the menu bar and the palette), so it runs from
//! `applyPending` like every other command. Nothing here runs without a hook (tests install fakes).
const std = @import("std");
const Allocator = std.mem.Allocator;
const hooks = @import("hooks.zig");
const Model = @import("model.zig").Model;
const FileItem = @import("../core/lister.zig").FileItem;
const target = @import("file_target.zig");

pub const App = hooks.OpenApp;
/// How many app rows the menu offers (the registry has this many `file_open_with_N` commands).
pub const max_apps = 8;
/// Extensions kept before the oldest is forgotten.
const max_cached = 24;

const Entry = struct {
    /// ".txt" (lower case), or the whole path for a file without an extension.
    key: []u8,
    apps: []App,
};

pub const State = struct {
    /// The file the menu wants apps for, until `service` looks them up (owned).
    request: ?[]u8 = null,
    cache: std.ArrayList(Entry) = .empty,
    /// How many times the hook was asked (tests count).
    lookups: usize = 0,

    pub fn deinit(self: *State, gpa: Allocator) void {
        if (self.request) |r| gpa.free(r);
        for (self.cache.items) |e| {
            gpa.free(e.key);
            hooks.Hooks.freeApps(gpa, e.apps);
        }
        self.cache.deinit(gpa);
    }

    fn find(self: *const State, key: []const u8) ?usize {
        for (self.cache.items, 0..) |e, i| if (std.mem.eql(u8, e.key, key)) return i;
        return null;
    }
};

/// The cache key of `path`: its lower-cased extension with the dot, or the path itself.
fn keyOf(buf: []u8, path: []const u8) []const u8 {
    const ext = std.fs.path.extension(path);
    if (ext.len < 2 or ext.len > buf.len) return path;
    return std.ascii.lowerString(buf[0..ext.len], ext);
}

/// The apps for `file` if they are known (the default one first, at most `max_apps`); null while
/// they are not (or without a hook).
pub fn appsFor(m: *const Model, file: []const u8) ?[]const App {
    if (m.hooks.open_with == null) return null;
    var kb: [64]u8 = undefined;
    const i = m.open_with.find(keyOf(&kb, file)) orelse return null;
    const apps = m.open_with.cache.items[i].apps;
    return apps[0..@min(apps.len, max_apps)];
}

/// Notes that the menu wants the apps for `file` (a no-op when known or already asked for); true
/// when a lookup is now pending, so the view should ask for another frame.
pub fn ask(m: *Model, file: []const u8) Allocator.Error!bool {
    if (m.hooks.open_with == null) return false;
    var kb: [64]u8 = undefined;
    if (m.open_with.find(keyOf(&kb, file)) != null) return false;
    if (m.open_with.request) |r| if (std.mem.eql(u8, r, file)) return false;
    const copy = try m.gpa.dupe(u8, file);
    if (m.open_with.request) |r| m.gpa.free(r);
    m.open_with.request = copy;
    return true;
}

/// Looks up what `ask` noted: true if the cache changed.
pub fn service(m: *Model) Allocator.Error!bool {
    const file = m.open_with.request orelse return false;
    defer {
        m.gpa.free(file);
        m.open_with.request = null;
    }
    const hook = m.hooks.open_with orelse return false;
    const st = &m.open_with;
    var kb: [64]u8 = undefined;
    const key = keyOf(&kb, file);
    if (st.find(key) != null) return false;
    st.lookups += 1;
    const apps = try hook.list(m.gpa, file);
    errdefer hooks.Hooks.freeApps(m.gpa, apps);
    const owned_key = try m.gpa.dupe(u8, key);
    errdefer m.gpa.free(owned_key);
    try st.cache.ensureUnusedCapacity(m.gpa, 1);
    if (st.cache.items.len >= max_cached) {
        const old = st.cache.orderedRemove(0);
        m.gpa.free(old.key);
        hooks.Hooks.freeApps(m.gpa, old.apps);
    }
    st.cache.appendAssumeCapacity(.{ .key = owned_key, .apps = apps });
    return true;
}

/// The one selected item of the focused pane when it is a file (a package such as an .app is not
/// `is_directory`: it opens like a file).
pub fn selectedFile(m: *Model) ?FileItem {
    const it = target.single(m.focusedPane()) orelse return null;
    return if (it.is_directory) null else it;
}

/// Whether row `n` of the menu has an app to open the selection with.
pub fn canOpen(m: *Model, n: usize) bool {
    const it = selectedFile(m) orelse return false;
    const apps = appsFor(m, it.path) orelse return false;
    return n < apps.len;
}

/// Opens the selected file with app `n`; a failure raises a notice.
pub fn openWith(m: *Model, n: usize) Allocator.Error!void {
    const hook = m.hooks.open_with orelse return;
    const it = selectedFile(m) orelse return;
    const apps = appsFor(m, it.path) orelse return;
    if (n >= apps.len) return;
    if (hook.open(apps[n].path, it.path)) return;
    var buf: [600]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "Can't open \"{s}\" with {s}.", .{ std.fs.path.basename(it.path), apps[n].name }) catch "Can't open the file.";
    try m.raise(msg);
}
