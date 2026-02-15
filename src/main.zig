const std = @import("std");

const c = @cImport({
    @cInclude("upnp/upnp.h");
});

fn upnpCallback(
    event_type: c.Upnp_EventType,
    event: ?*const anyopaque,
    cookie: ?*anyopaque,
) callconv(.c) c_int {
    _ = event;
    _ = cookie;

    std.log.info("Event type: {}", .{event_type});

    return 0;
}

const deviceXml = @embedFile("device.xml");
const contentDirectoryXml = @embedFile("contentDirectory.xml");
const connectionManagerXml = @embedFile("connectionManager.xml");

pub fn main() !void {
    const port: c.ushort = 8888; // auto-select port
    const ip_address: ?[*:0]const u8 = null;

    const result = c.UpnpInit2(ip_address, port);
    if (result != c.UPNP_E_SUCCESS) {
        std.log.err("Failed to initialize UPnP: {}\n", .{result});
        return;
    }

    std.log.info("UPnP initialized successfully!\n", .{});

    var handle: c.UpnpDevice_Handle = 0;

    const rc = c.UpnpRegisterRootDevice2(
        c.UPNPREG_BUF_DESC,
        deviceXml,
        deviceXml.len,
        1,
        upnpCallback,
        null,
        &handle,
    );
    if (rc != c.UPNP_E_SUCCESS) {
        std.log.err("RegisterRootDevice2 failed: {}", .{rc});
        return error.RegisterFailed;
    }

    std.log.info("Root device registered", .{});

    // Advertise every 60 seconds
    _ = c.UpnpSendAdvertisement(handle, 60);

    std.log.info("Advertisements sent", .{});

    // Keep process alive
    std.Thread.sleep(300 * std.time.ns_per_s);

    _ = c.UpnpUnRegisterRootDevice(handle);
    _ = c.UpnpFinish();
}
