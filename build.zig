const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const nanoui = b.dependency("nanoui", .{ .target = target, .optimize = optimize }).module("nanoui");

    const exe = b.addExecutable(.{ .name = "nanofm", .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "nanoui", .module = nanoui }},
    }) });
    // Quick Look's panel (QuickLookUI) and the thumbnail generator (QuickLookThumbnailing): nanoui
    // links the other frameworks, these two are the app's own.
    if (target.result.os.tag == .macos) {
        for ([_][]const u8{ "QuickLookUI", "QuickLookThumbnailing" }) |f| exe.root_module.linkFramework(f, .{});
    }
    // A window of its own on Windows, without a console window beside it.
    if (target.result.os.tag == .windows) exe.subsystem = .windows;
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    b.step("run", "Run Nanofm (opens its window)").dependOn(&run.step);

    // Tests render the view offscreen with ui.Tester: no window opens. `-Dtest-filter=text` runs
    // only the tests whose names contain it.
    const filters = b.option([]const []const u8, "test-filter", "only tests whose name contains this") orelse &.{};
    const tests = b.addTest(.{ .filters = filters, .root_module = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "nanoui", .module = nanoui }},
    }) });
    if (target.result.os.tag == .macos) {
        for ([_][]const u8{ "QuickLookUI", "QuickLookThumbnailing" }) |f| tests.root_module.linkFramework(f, .{});
    }
    b.step("test", "Run the tests").dependOn(&b.addRunArtifact(tests).step);

    // Core (no UI) tests: `zig build test-core -Dcore=lister` tests src/core/lister.zig alone;
    // without -Dcore every module listed in src/core/tests.zig runs.
    const core_name = b.option([]const u8, "core", "one src/core module to test (default: all)");
    const core_path = if (core_name) |n| b.fmt("src/core/{s}.zig", .{n}) else "src/core/tests.zig";
    const core_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path(core_path),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "nanoui", .module = nanoui }},
    }) });
    b.step("test-core", "Run the core tests").dependOn(&b.addRunArtifact(core_tests).step);
}
