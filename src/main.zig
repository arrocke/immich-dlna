const std = @import("std");

const c = @cImport({
    @cInclude("upnp/upnp.h");
});

fn upnpCallback(
    event_type: c.Upnp_EventType,
    event: ?*const anyopaque,
    cookie: ?*anyopaque,
) callconv(.c) c_int {
    _ = cookie;

    std.log.info("Event type: {}", .{event_type});

    switch (event_type) {
        c.UPNP_CONTROL_ACTION_REQUEST => {
            const request: *const c.UpnpActionRequest = @ptrCast(event);
            const serviceId = std.mem.span(c.UpnpActionRequest_get_ServiceID_cstr(request));
            const action = std.mem.span(c.UpnpActionRequest_get_ActionName_cstr(request));

            std.log.info("action request {s} {s}", .{ serviceId, action });

            if (std.mem.eql(u8, serviceId, "urn:upnp-org:serviceId:ContentDirectory")) {
                if (std.mem.eql(u8, action, "Browse")) {
                    const actionRequest = c.UpnpActionRequest_get_ActionRequest(request);

                    const nodes = c.ixmlDocument_getElementsByTagName(actionRequest, "ObjectID");
                    defer c.ixmlNodeList_free(nodes);
                    if (nodes == null) {
                        std.log.err("no ObjectId nodes found", .{});
                        return 0;
                    }

                    const node = c.ixmlNodeList_item(nodes, 0);
                    if (node == null) {
                        std.log.err("no ObjectId nodes found", .{});
                        return 0;
                    }

                    const objectId = std.mem.span(c.ixmlNode_getNodeValue(c.ixmlNode_getFirstChild(node)));
                    std.log.info("ObjectId: {s}", .{objectId});

                    const doc = c.ixmlDocument_createDocument();
                    const root = c.ixmlDocument_createElementNS(
                        doc,
                        "urn:schemas-upnp-org:service:ContentDirectory:1",
                        "u:BrowseResponse",
                    );
                    _ = c.ixmlElement_setAttributeNS(
                        root,
                        "urn:schemas-upnp-org:service:ContentDirectory:1",
                        "xmlns:u",
                        "urn:schemas-upnp-org:service:ContentDirectory:1",
                    );
                    _ = c.ixmlNode_appendChild(@ptrCast(doc), @ptrCast(root));

                    const didl_doc = c.ixmlDocument_createDocument();
                    const didl_root = c.ixmlDocument_createElementNS(
                        didl_doc,
                        "urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/",
                        "DIDL-Lite",
                    );
                    _ = c.ixmlElement_setAttribute(
                        didl_root,
                        "xmlns:dc",
                        "http://purl.org/dc/elements/1.1/",
                    );
                    _ = c.ixmlElement_setAttribute(
                        didl_root,
                        "xmlns:upnp",
                        "urn:schemas-upnp-org:metadata-1-0/upnp/",
                    );
                    _ = c.ixmlNode_appendChild(@ptrCast(didl_doc), @ptrCast(didl_root));

                    const container = c.ixmlDocument_createElement(didl_doc, "container");
                    _ = c.ixmlElement_setAttribute(container, "id", "1");
                    _ = c.ixmlElement_setAttribute(container, "parentID", "0");
                    _ = c.ixmlElement_setAttribute(container, "restricted", "1");

                    const dc_title = c.ixmlDocument_createElementNS(
                        didl_doc,
                        "http://purl.org/dc/elements/1.1/",
                        "dc:title",
                    );
                    const title_text = c.ixmlDocument_createTextNode(didl_doc, "Albums");
                    _ = c.ixmlNode_appendChild(@ptrCast(dc_title), @ptrCast(title_text));
                    _ = c.ixmlNode_appendChild(@ptrCast(container), @ptrCast(dc_title));

                    const upnp_class = c.ixmlDocument_createElementNS(
                        didl_doc,
                        "urn:schemas-upnp-org:metadata-1-0/upnp/",
                        "upnp:class",
                    );
                    const class_text = c.ixmlDocument_createTextNode(didl_doc, "object.container");
                    _ = c.ixmlNode_appendChild(@ptrCast(upnp_class), @ptrCast(class_text));
                    _ = c.ixmlNode_appendChild(@ptrCast(container), @ptrCast(upnp_class));

                    _ = c.ixmlNode_appendChild(@ptrCast(didl_root), @ptrCast(container));

                    const didl_string = c.ixmlDocumenttoString(didl_doc);
                    defer c.ixmlFreeDOMString(didl_string);

                    add_element(doc, root, "Result", didl_string);
                    add_element(doc, root, "NumberReturned", "1");
                    add_element(doc, root, "TotalMatches", "1");
                    add_element(doc, root, "UpdateID", "1");

                    const mutableRequest: *c.UpnpActionRequest = @constCast(request);
                    _ = c.UpnpActionRequest_set_ActionResult(mutableRequest, doc);
                }
            }
        },
        else => {
            std.log.info("Unhandled event type: {}", .{event_type});
        },
    }

    return 0;
}

fn add_element(doc: *c.IXML_Document, parent: *c.IXML_Element, name: [*c]const u8, value: [*c]const u8) void {
    const el = c.ixmlDocument_createElement(doc, name);
    const text = c.ixmlDocument_createTextNode(doc, value);

    _ = c.ixmlNode_appendChild(@ptrCast(el), @ptrCast(text));
    _ = c.ixmlNode_appendChild(@ptrCast(parent), @ptrCast(el));
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
