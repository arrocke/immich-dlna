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

                    const response = BrowseReponse{
                        .albums = &[_]Album{.{ .id = "1", .parentId = "0", .name = "Test Album" }},
                        .totalMatches = "1",
                        .numberReturned = "1",
                        .updateId = "1",
                    };

                    const mutableRequest: *c.UpnpActionRequest = @constCast(request);
                    const doc = response.toIXMLDocument();

                    std.log.info("Response: {s}", .{c.ixmlDocumenttoString(doc)});

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

const BrowseReponse = struct {
    albums: []const Album,
    updateId: [:0]const u8,
    numberReturned: [:0]const u8,
    totalMatches: [:0]const u8,

    pub fn toIXMLDocument(self: *const BrowseReponse) [*c]c.struct__IXML_Document {
        const didlDocument = c.ixmlDocument_createDocument();
        const didlElement = c.ixmlDocument_createElement(didlDocument, "DIDL-Lite");
        _ = c.ixmlElement_setAttribute(didlElement, "xmlns:dc", "http://purl.org/dc/elements/1.1/");
        _ = c.ixmlElement_setAttribute(didlElement, "xmlns:upnp", "urn:schemas-upnp-org:metadata-1-0/upnp/");
        _ = c.ixmlNode_appendChild(@ptrCast(didlDocument), @ptrCast(didlElement));

        for (self.albums) |album| {
            const albumElement = album.toIXMLElement(@ptrCast(didlDocument));
            _ = c.ixmlNode_appendChild(@ptrCast(didlElement), @ptrCast(albumElement));
        }

        const didlStr = c.ixmlDocumenttoString(didlDocument);

        const document = c.ixmlDocument_createDocument();
        const browseResponseElement = c.ixmlDocument_createElement(document, "u:BrowseResponse");
        _ = c.ixmlElement_setAttribute(browseResponseElement, "xmlns:u", "urn:schemas-upnp-org:service:ContentDirectory:1");
        _ = c.ixmlNode_appendChild(@ptrCast(document), @ptrCast(browseResponseElement));

        {
            const element = c.ixmlDocument_createElement(document, "Result");
            const text = c.ixmlDocument_createTextNode(document, didlStr);
            _ = c.ixmlNode_appendChild(@ptrCast(element), @ptrCast(text));
            _ = c.ixmlNode_appendChild(@ptrCast(browseResponseElement), @ptrCast(element));
        }

        {
            const element = c.ixmlDocument_createElement(document, "NumberReturned");
            const text = c.ixmlDocument_createTextNode(document, self.numberReturned);
            _ = c.ixmlNode_appendChild(@ptrCast(element), @ptrCast(text));
            _ = c.ixmlNode_appendChild(@ptrCast(browseResponseElement), @ptrCast(element));
        }

        {
            const element = c.ixmlDocument_createElement(document, "TotalMatches");
            const text = c.ixmlDocument_createTextNode(document, self.totalMatches);
            _ = c.ixmlNode_appendChild(@ptrCast(element), @ptrCast(text));
            _ = c.ixmlNode_appendChild(@ptrCast(browseResponseElement), @ptrCast(element));
        }

        {
            const element = c.ixmlDocument_createElement(document, "UpdateId");
            const text = c.ixmlDocument_createTextNode(document, self.updateId);
            _ = c.ixmlNode_appendChild(@ptrCast(element), @ptrCast(text));
            _ = c.ixmlNode_appendChild(@ptrCast(browseResponseElement), @ptrCast(element));
        }

        return document;
    }
};

const Album = struct {
    id: [:0]const u8,
    parentId: [:0]const u8,
    name: [:0]const u8,

    pub fn toIXMLElement(self: *const Album, document: *c.struct__IXML_Document) [*c]c.struct__IXML_Element {
        const albumElement = c.ixmlDocument_createElement(document, "container");
        _ = c.ixmlElement_setAttribute(albumElement, "id", self.id);
        _ = c.ixmlElement_setAttribute(albumElement, "parentID", self.parentId);
        _ = c.ixmlElement_setAttribute(albumElement, "restricted", "1");

        const titleElement = c.ixmlDocument_createElement(document, "dc:title");
        const titleText = c.ixmlDocument_createTextNode(document, self.name);
        _ = c.ixmlNode_appendChild(@ptrCast(titleElement), @ptrCast(titleText));
        _ = c.ixmlNode_appendChild(@ptrCast(albumElement), @ptrCast(titleElement));

        const classElement = c.ixmlDocument_createElement(document, "upnp:class");
        const classText = c.ixmlDocument_createTextNode(document, "object.container");
        _ = c.ixmlNode_appendChild(@ptrCast(classElement), @ptrCast(classText));
        _ = c.ixmlNode_appendChild(@ptrCast(albumElement), @ptrCast(classElement));

        return albumElement;
    }
};

const IXMLAttribute = struct {
    name: [:0]const u8,
    value: [:0]const u8,
};

const IXMLElement = union(enum) {
    element: struct {
        name: [:0]const u8,
        attributes: []const IXMLAttribute,
        children: []const IXMLElement,
    },
    text: [:0]const u8,
};

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
