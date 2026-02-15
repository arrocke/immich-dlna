const std = @import("std");

const c = @cImport({
    @cInclude("upnp/upnp.h");
});

pub fn main() !void {
    const port: c.ushort = 0; // auto-select port
    const ip_address: ?[*:0]const u8 = null;

    const result = c.UpnpInit2(ip_address, port);
    if (result != c.UPNP_E_SUCCESS) {
        std.log.err("Failed to initialize UPnP: {}\n", .{result});
        return;
    }

    std.log.info("UPnP initialized successfully!\n", .{});

    _ = c.UpnpFinish();
}
