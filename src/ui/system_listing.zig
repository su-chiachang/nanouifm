//! The real listing runner (`Config.listing`): each `Job` reads its folders on a detached thread
//! of its own, then hops to the main thread with `objc.dispatchMain`, where `deliver` puts the
//! result in the inbox and wakes a frame (`Model.applyPending` merges it at the start of the next
//! pass). For main.zig only: no test reaches it (tests pass `listing_runner.runNow` or a held
//! runner); it is compiled and linked, not run.
//!
//! What the worker thread touches: the `Job` it was handed and nothing else (see
//! `listing_runner.zig`). It never sees the model, a tab or a listing, and it never frees or
//! allocates through anything but the app's thread-safe allocator.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const Job = @import("listing_runner.zig").Job;

pub fn run(job: *Job) void {
    const t = std.Thread.spawn(.{}, work, .{job}) catch return job.run(); // no thread: read here, nothing is lost
    t.detach();
}

/// On the worker thread.
fn work(job: *Job) void {
    job.read();
    objc.dispatchMain(job, onMain);
}

/// On the main thread.
fn onMain(ctx: ?*anyopaque) callconv(.c) void {
    const job: *Job = @ptrCast(@alignCast(ctx.?));
    job.deliver();
}
