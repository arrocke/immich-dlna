const std = @import("std");
const Context = @import("context.zig");
const Device = @import("device.zig");
const virtual_fs = @import("virtual_fs.zig");

var shutdown_requested = std.atomic.Value(bool).init(false);

fn handleSignal(sig: c_int) callconv(.c) void {
    _ = sig;
    shutdown_requested.store(true, .seq_cst);
}

pub fn main() !void {
    const port: u16 = 8888;
    const ip_address: ?[*:0]const u8 = null;

    const allocator = std.heap.c_allocator;
    const context = Context{
        .allocator = allocator,
        .immichApiKey = "rETcQbd3iHV5UseeCxfLRknNKDTkddSocw3ESZCqiyQ",
        .immichBaseUrl = "http://localhost:2283/api",
    };

    // Initialize and register device
    var device = try Device.init(port, ip_address, &context);
    defer device.deinit();

    std.log.debug("[main] Device ready, waiting for connections", .{});

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
