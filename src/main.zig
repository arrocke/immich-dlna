const std = @import("std");
const Context = @import("context.zig");
const Device = @import("device.zig");
const ImmichStore = @import("immich_store.zig");
const Config = @import("config.zig");
const virtual_fs = @import("virtual_fs.zig");

var shutdown_requested = std.atomic.Value(bool).init(false);

fn handleSignal(sig: c_int) callconv(.c) void {
    _ = sig;
    shutdown_requested.store(true, .seq_cst);
}

pub fn main() !void {
    const ip_address: ?[*:0]const u8 = null;

    const allocator = std.heap.c_allocator;

    const config = try Config.load(allocator);
    defer config.deinit();

    const context = Context{
        .allocator = allocator,
        .immichStore = ImmichStore.init(
            allocator,
            config.immich_api_key,
            config.immich_url,
            config.cache_timeout,
        ),
        .dlna_origin = config.dlna_origin,
        .port = config.port,
    };

    // Initialize and register device
    var device = try Device.init(config.port, ip_address, &context);
    defer device.deinit();

    std.log.debug("[main] Device ready, waiting for connections on port {d}", .{config.port});

    // Setup signal handlers
    var act = std.posix.Sigaction{
        .handler = .{ .handler = handleSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &act, null);
    std.posix.sigaction(std.posix.SIG.TERM, &act, null);

    // Run until shutdown
    while (!shutdown_requested.load(.seq_cst)) {
        std.Thread.sleep(1 * std.time.ns_per_s);
    }

    std.log.debug("[main] Shutting down", .{});
}
