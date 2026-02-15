const std = @import("std");

pub fn build(b: *std.Build) void {
    const exe = b.addExecutable(.{
        .name = "immich-dlna",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = b.graph.host,
            .link_libc = true,
        }),
    });
    exe.root_module.linkSystemLibrary("upnp", .{
        .use_pkg_config = .yes,
    });
    b.installArtifact(exe);

    const run_exe = b.addRunArtifact(exe);
    const run_step = b.step("run", "Build and remount the filesystem");
    run_step.dependOn(&run_exe.step);
}
