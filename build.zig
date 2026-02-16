const std = @import("std");

pub fn build(b: *std.Build) void {
    const upnp_mod = b.addModule("upnp", .{
        .root_source_file = b.path("src/upnp/upnp.zig"),
        .target = b.graph.host,
        .link_libc = true,
    });
    upnp_mod.linkSystemLibrary("upnp", .{
        .use_pkg_config = .yes,
    });

    const exe_mod = b.addModule("main", .{
        .root_source_file = b.path("src/main.zig"),
        .target = b.graph.host,
        .link_libc = true,
    });
    exe_mod.linkSystemLibrary("upnp", .{
        .use_pkg_config = .yes,
    });
    exe_mod.addImport("upnp", upnp_mod);

    const exe = b.addExecutable(.{
        .name = "immich-dlna",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const run_exe = b.addRunArtifact(exe);
    const run_step = b.step("run", "Build and remount the filesystem");
    run_step.dependOn(&run_exe.step);

    const exe_check = b.addExecutable(.{
        .name = "foo",
        .root_module = exe_mod,
    });
    const check = b.step("check", "Check if main compiles");
    check.dependOn(&exe_check.step);
}
