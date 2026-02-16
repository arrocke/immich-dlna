const std = @import("std");
const ImmichApi = @import("./immich-api.zig");

const c = @cImport({
    @cInclude("upnp/upnp.h");
});

const UpnpCallbackContext = struct {
    allocator: std.mem.Allocator,
    immichClient: ImmichApi,
};

fn upnpCallback(
    event_type: c.Upnp_EventType,
    event: ?*const anyopaque,
    cookie: ?*anyopaque,
) callconv(.c) c_int {
    const ctx: *UpnpCallbackContext = @ptrCast(@alignCast(cookie));

    std.log.info("Event type: {}", .{event_type});

    switch (event_type) {
        c.UPNP_CONTROL_ACTION_REQUEST => {
            var request = ActionRequest.initFromEvent(@ptrCast(@constCast(event))) catch {
                std.log.err("[upnpCallback] Failed to parse action request", .{});
                return 0;
            };

            switch (request.service) {
                .contentDirectory => |serviceAction| switch (serviceAction) {
                    .browse => |action| {
                        var resources: std.ArrayList(BrowseReponse.Resource) = .{};
                        if (std.mem.eql(u8, action.objectId, "0")) {
                            const albums = ctx.immichClient.getAlbums() catch |err| {
                                std.log.err("[upnpCallback] Failed to fetch albums {}", .{err});
                                return 0;
                            };
                            defer albums.deinit();

                            for (albums.value) |album| {
                                resources.append(ctx.allocator, .{ .album = Album{
                                    .id = ctx.allocator.dupeZ(u8, album.id) catch {
                                        std.log.err("[upnpCallback] Failed to allocate memory", .{});
                                        return 0;
                                    },
                                    .name = ctx.allocator.dupeZ(u8, album.albumName) catch {
                                        std.log.err("[upnpCallback] Failed to allocate memory", .{});
                                        return 0;
                                    },
                                    .parentId = "1",
                                } }) catch {
                                    std.log.err("[upnpCallback] Failed to allocate memory", .{});
                                    return 0;
                                };
                            }
                        } else {
                            const album = ctx.immichClient.getAlbum(action.objectId) catch |err| {
                                std.log.err("[upnpCallback] Failed to fetch albums {}", .{err});
                                return 0;
                            };
                            defer album.deinit();

                            for (album.value.assets) |asset| {
                                resources.append(ctx.allocator, .{ .asset = Asset{
                                    .id = ctx.allocator.dupeZ(u8, asset.id) catch {
                                        std.log.err("[upnpCallback] Failed to allocate memory", .{});
                                        return 0;
                                    },
                                    .name = ctx.allocator.dupeZ(u8, asset.id) catch {
                                        std.log.err("[upnpCallback] Failed to allocate memory", .{});
                                        return 0;
                                    },
                                    .parentId = ctx.allocator.dupeZ(u8, album.value.id) catch {
                                        std.log.err("[upnpCallback] Failed to allocate memory", .{});
                                        return 0;
                                    },
                                    .width = 0,
                                    .height = 0,
                                    .mimeType = ctx.allocator.dupeZ(u8, asset.originalMimeType orelse "") catch {
                                        std.log.err("[upnpCallback] Failed to allocate memory", .{});
                                        return 0;
                                    },
                                } }) catch {
                                    std.log.err("[upnpCallback] Failed to allocate memory", .{});
                                    return 0;
                                };
                            }
                        }

                        const response = BrowseReponse{
                            .resources = resources.toOwnedSlice(ctx.allocator) catch {
                                std.log.err("[upnpCallback] Failed to allocate memory", .{});
                                return 0;
                            },
                            .totalMatches = "1",
                            .numberReturned = "1",
                            .updateId = "1",
                        };

                        const doc = response.toIXMLDocument();

                        request.setActionResult(doc);
                    },
                },
            }

            if (std.mem.eql(u8, request.serviceId, "urn:upnp-org:serviceId:ContentDirectory")) {
                if (std.mem.eql(u8, request.actionName, "Browse")) {}
            }
        },
        else => {
            std.log.info("[upnpCallback] Unhandled event type: {}", .{event_type});
        },
    }

    return 0;
}

const ContentDirectoryBrowseAction = struct {
    objectId: [:0]const u8,

    pub fn initFromIXMLDocument(document: *c.struct__IXML_Document) !ContentDirectoryBrowseAction {
        const nodes = c.ixmlDocument_getElementsByTagName(document, "ObjectID");
        defer c.ixmlNodeList_free(nodes);
        if (nodes == null) {
            std.log.err("[ContentDirectoryBrowseAction.initFromIXMLDocument] no ObjectId nodes found", .{});
            return error.InvalidMessage;
        }

        const node = c.ixmlNodeList_item(nodes, 0);
        if (node == null) {
            std.log.err("[ContentDirectoryBrowseAction.initFromIXMLDocument] no ObjectId nodes found", .{});
            return error.InvalidMessage;
        }

        const objectId = std.mem.span(
            c.ixmlNode_getNodeValue(c.ixmlNode_getFirstChild(node)),
        );
        std.log.debug("[ContentDirectoryBrowseAction.initFromIXMLDocument] ObjectId: {s}", .{objectId});

        return ContentDirectoryBrowseAction{ .objectId = objectId };
    }
};

const ActionRequest = struct {
    rawRequest: *c.UpnpActionRequest,
    serviceId: [:0]const u8,
    actionName: [:0]const u8,
    requestDocument: *c.struct__IXML_Document,
    service: Service,

    pub fn initFromEvent(request: *c.UpnpActionRequest) !ActionRequest {
        const serviceId = std.mem.span(c.UpnpActionRequest_get_ServiceID_cstr(request));
        const actionName = std.mem.span(c.UpnpActionRequest_get_ActionName_cstr(request));
        const requestDocument = c.UpnpActionRequest_get_ActionRequest(request);

        std.log.debug("[ActionRequest.initFromEvent] serviceId: {s}, actionName: {s}", .{ serviceId, actionName });

        var service: Service = undefined;
        if (std.mem.eql(u8, serviceId, "urn:upnp-org:serviceId:ContentDirectory")) {
            if (std.mem.eql(u8, actionName, "Browse")) {
                service = Service{
                    .contentDirectory = .{
                        .browse = try ContentDirectoryBrowseAction.initFromIXMLDocument(requestDocument),
                    },
                };
            } else {
                std.log.err("[ActionRequest.initFromEvent] Unsupported ContentDirectory action: {s}", .{actionName});
                return error.UnsupportAction;
            }
        } else {
            std.log.err("[ActionRequest.initFromEvent] Unsupported service: {s}", .{serviceId});
            return error.UnsupportService;
        }

        return ActionRequest{
            .rawRequest = request,
            .serviceId = serviceId,
            .actionName = actionName,
            .requestDocument = requestDocument,
            .service = service,
        };
    }

    pub fn setActionResult(self: *ActionRequest, document: *c.struct__IXML_Document) void {
        std.log.debug("[ActionRequest.setActionResult] Response: {s}", .{c.ixmlDocumenttoString(document)});
        _ = c.UpnpActionRequest_set_ActionResult(self.rawRequest, document);
    }

    const Service = union(enum) {
        contentDirectory: ContentDirectory,

        const ContentDirectory = union(enum) {
            browse: ContentDirectoryBrowseAction,
        };
    };
};

const BrowseReponse = struct {
    const Resource = union(enum) {
        album: Album,
        asset: Asset,
    };

    resources: []const Resource,
    updateId: [:0]const u8,
    numberReturned: [:0]const u8,
    totalMatches: [:0]const u8,

    pub fn toIXMLDocument(self: *const BrowseReponse) [*c]c.struct__IXML_Document {
        const didlDocument = c.ixmlDocument_createDocument();
        const didlElement = c.ixmlDocument_createElement(didlDocument, "DIDL-Lite");
        _ = c.ixmlElement_setAttribute(didlElement, "xmlns", "urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/");
        _ = c.ixmlElement_setAttribute(didlElement, "xmlns:dc", "http://purl.org/dc/elements/1.1/");
        _ = c.ixmlElement_setAttribute(didlElement, "xmlns:upnp", "urn:schemas-upnp-org:metadata-1-0/upnp/");
        _ = c.ixmlElement_setAttribute(didlElement, "xmlns:dlna", "urn:schemas-dlna-org:metadata-1-0/");
        _ = c.ixmlNode_appendChild(@ptrCast(didlDocument), @ptrCast(didlElement));

        for (self.resources) |resource| {
            switch (resource) {
                .album => |album| {
                    const albumElement = album.toIXMLElement(@ptrCast(didlDocument));
                    _ = c.ixmlNode_appendChild(@ptrCast(didlElement), @ptrCast(albumElement));
                },
                .asset => |asset| {
                    const assetElement = asset.toIXMLElement(@ptrCast(didlDocument));
                    _ = c.ixmlNode_appendChild(@ptrCast(didlElement), @ptrCast(assetElement));
                },
            }
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

const Asset = struct {
    id: [:0]const u8,
    parentId: [:0]const u8,
    name: [:0]const u8,
    mimeType: [:0]const u8,
    width: u32,
    height: u32,

    pub fn toIXMLElement(self: *const Asset, document: *c.struct__IXML_Document) [*c]c.struct__IXML_Element {
        const albumElement = c.ixmlDocument_createElement(document, "item");
        _ = c.ixmlElement_setAttribute(albumElement, "id", self.id);
        _ = c.ixmlElement_setAttribute(albumElement, "parentID", self.parentId);
        _ = c.ixmlElement_setAttribute(albumElement, "restricted", "1");

        const titleElement = c.ixmlDocument_createElement(document, "dc:title");
        const titleText = c.ixmlDocument_createTextNode(document, self.name);
        _ = c.ixmlNode_appendChild(@ptrCast(titleElement), @ptrCast(titleText));
        _ = c.ixmlNode_appendChild(@ptrCast(albumElement), @ptrCast(titleElement));

        const classElement = c.ixmlDocument_createElement(document, "upnp:class");
        const classText = c.ixmlDocument_createTextNode(document, "object.item.imageItem.photo");
        _ = c.ixmlNode_appendChild(@ptrCast(classElement), @ptrCast(classText));
        _ = c.ixmlNode_appendChild(@ptrCast(albumElement), @ptrCast(classElement));

        const resElement = c.ixmlDocument_createElement(document, "res");
        var buf: [1024]u8 = undefined;
        _ = c.ixmlElement_setAttribute(albumElement, "protocolInfo", std.fmt.bufPrintZ(&buf, "http-get:*:{s}:DLNA.ORG_OP=01;DLNA.ORG_CI=0", .{self.mimeType}) catch "");
        _ = c.ixmlElement_setAttribute(albumElement, "resolution", std.fmt.bufPrintZ(&buf, "{d}x{d}", .{ self.width, self.height }) catch "");
        _ = c.ixmlElement_setAttribute(albumElement, "size", std.fmt.bufPrintZ(&buf, "{d}", .{0}) catch "");
        const resText = c.ixmlDocument_createTextNode(document, "https://picsum.photos/200/300");
        _ = c.ixmlNode_appendChild(@ptrCast(resElement), @ptrCast(resText));
        _ = c.ixmlNode_appendChild(@ptrCast(albumElement), @ptrCast(resElement));

        return albumElement;
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

const deviceXml = @embedFile("device.xml");

pub fn main() !void {
    const port: c.ushort = 8888; // auto-select port
    const ip_address: ?[*:0]const u8 = null;

    const result = c.UpnpInit2(ip_address, port);
    if (result != c.UPNP_E_SUCCESS) {
        std.log.err("[main] Failed to initialize UPnP: {}", .{result});
        return;
    }

    std.log.debug("[main] UPnP initialized successfully!", .{});

    var handle: c.UpnpDevice_Handle = 0;

    var gpa = std.heap.GeneralPurposeAllocator(.{}).init;
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) std.testing.expect(false) catch @panic("TEST FAIL");
    }

    const allocator = gpa.allocator();
    const context = UpnpCallbackContext{
        .allocator = allocator,
        .immichClient = ImmichApi.init(
            allocator,
            "rETcQbd3iHV5UseeCxfLRknNKDTkddSocw3ESZCqiyQ",
            "http://localhost:2283/api",
        ),
    };

    const rc = c.UpnpRegisterRootDevice2(
        c.UPNPREG_BUF_DESC,
        deviceXml,
        deviceXml.len,
        1,
        upnpCallback,
        &context,
        &handle,
    );
    if (rc != c.UPNP_E_SUCCESS) {
        std.log.err("[main] RegisterRootDevice2 failed: {}", .{rc});
        return error.RegisterFailed;
    }

    std.log.debug("[main] Root device registered", .{});

    // Advertise every 60 seconds
    _ = c.UpnpSendAdvertisement(handle, 60);

    std.log.debug("[main] Advertisements sent", .{});

    // Keep process alive
    std.Thread.sleep(300 * std.time.ns_per_s);

    _ = c.UpnpUnRegisterRootDevice(handle);
    _ = c.UpnpFinish();
}
