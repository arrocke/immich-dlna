const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});
    const prod = b.option(bool, "prod", "Build for production") orelse false;

    const zeit = b.dependency("zeit", .{});

    const exe_mod = b.addModule("main", .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    exe_mod.addImport("zeit", zeit.module("zeit"));
    exe_mod.linkSystemLibrary("upnp", .{
        .use_pkg_config = .yes,
    });

    const options = b.addOptions();
    options.addOption(bool, "prod", prod);
    exe_mod.addImport("build_options", options.createModule());

    const exe = b.addExecutable(.{
        .name = "immich-dlna",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const run_exe = b.addRunArtifact(exe);
    const run_step = b.step("run", "Build and remount the filesystem");
    run_step.dependOn(&run_exe.step);

    const exe_check = b.addExecutable(.{
        .name = "immich-dlna-check",
        .root_module = exe_mod,
    });
    const check = b.step("check", "Check if main compiles");
    check.dependOn(&exe_check.step);
}
