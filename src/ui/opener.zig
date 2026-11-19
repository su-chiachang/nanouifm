//! Opening a file in its default app, behind a function pointer the model holds, so nothing but
//! main.zig ever launches anything: the model's `opener` is null (do nothing) unless `Config`
//! names one, and tests install a recorder.
const nanoui = @import("nanoui");

/// Opens the file at an absolute path; false if it could not.
pub const OpenFn = *const fn (path: []const u8) bool;

/// The real thing: nanoui's `shell.openPath` (NSWorkspace on the Mac). For main.zig only.
pub fn system(path: []const u8) bool {
    return nanoui.shell.openPath(path);
}
