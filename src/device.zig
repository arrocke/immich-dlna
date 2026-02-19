const std = @import("std");
const virtual_fs = @import("./virtual_fs.zig");
const ImmichStore = @import("immich_store.zig");
const Context = @import("context.zig");

const c = @cImport({
    @cInclude("upnp.h");
});

const Self = @This();

const deviceXml = @embedFile("device.xml");

handle: c.UpnpDevice_Handle,
context: *const Context,

pub fn init(port: c.ushort, ipAddress: ?[*:0]const u8, context: *const Context) !Self {
    const result = c.UpnpInit2(ipAddress, port);
    if (result != c.UPNP_E_SUCCESS) {
        std.log.err("[device.init] Failed to initialize UPnP: {}", .{result});
        return error.UpnpInitFailed;
    }

    std.log.debug("[device.init] UPnP initialized successfully", .{});

    virtual_fs.initVirtualDir(context);

    var handle: c.UpnpDevice_Handle = 0;

    const rc = c.UpnpRegisterRootDevice2(
        c.UPNPREG_BUF_DESC,
        deviceXml,
        deviceXml.len,
        1,
        eventCallback,
        context,
        &handle,
    );

    if (rc != c.UPNP_E_SUCCESS) {
        std.log.err("[device.init] RegisterRootDevice2 failed: {}", .{rc});
        return error.RegisterFailed;
    }

    std.log.debug("[device.init] Root device registered", .{});

    _ = c.UpnpSendAdvertisement(handle, 60);
    std.log.debug("[device.sendAdvertisement] Advertisements sent with TTL: {}", .{60});

    return Self{
        .handle = handle,
        .context = context,
    };
}

pub fn deinit(self: *Self) void {
    _ = c.UpnpUnRegisterRootDevice(self.handle);
    _ = c.UpnpFinish();
    std.log.debug("[device.deinit] Device unregistered and cleaned up", .{});
}

fn eventCallback(
    event_type: c.Upnp_EventType,
    event: ?*const anyopaque,
    cookie: ?*anyopaque,
) callconv(.c) c_int {
    const ctx: *Context = @ptrCast(@alignCast(cookie));

    std.log.info("[device.eventCallback] Event type: {}", .{event_type});

    switch (event_type) {
        c.UPNP_CONTROL_ACTION_REQUEST => {
            var request = ActionRequest.initFromEvent(@ptrCast(@constCast(event))) catch {
                std.log.err("[device.eventCallback] Failed to parse action request", .{});
                return 0;
            };

            switch (request.service) {
                .contentDirectory => |serviceAction| switch (serviceAction) {
                    .browse => |action| {
                        if (std.mem.eql(u8, action.objectId, "0")) {
                            var albums = ctx.immichStore.getAlbums() catch |err| {
                                std.log.err("[device.eventCallback] Failed to fetch albums: {}", .{err});
                                return 0;
                            };
                            defer albums.deinit();

                            const response = BrowseReponse{
                                .parentId = action.objectId,
                                .albums = albums.value,
                                .updateId = 1,
                                .count = @intCast(albums.value.len),
                                .origin = ctx.dlna_origin,
                                .allocator = ctx.allocator,
                            };

                            const document = response.toIXMLDocument() catch |err| {
                                std.log.err("[device.eventCallback] Failed to build browse response document: {}", .{err});
                                return 0;
                            };
                            request.setActionResult(document);
                        } else {
                            var album = ctx.immichStore.getAlbum(action.objectId) catch |err| {
                                std.log.err("[device.eventCallback] Failed to fetch albums: {}", .{err});
                                return 0;
                            };
                            defer album.deinit();

                            const response = BrowseReponse{
                                .parentId = action.objectId,
                                .assets = album.value.assets,
                                .updateId = 1,
                                .count = @intCast(album.value.assets.len),
                                .origin = ctx.dlna_origin,
                                .allocator = ctx.allocator,
                            };

                            const document = response.toIXMLDocument() catch |err| {
                                std.log.err("[device.eventCallback] Failed to build browse response document: {}", .{err});
                                return 0;
                            };
                            request.setActionResult(document);
                        }
                    },
                },
            }
        },
        else => {
            std.log.info("[device.eventCallback] Unhandled event type: {}", .{event_type});
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
            std.log.err("[device.ContentDirectoryBrowseAction.initFromIXMLDocument] no ObjectId nodes found", .{});
            return error.InvalidMessage;
        }

        const node = c.ixmlNodeList_item(nodes, 0);
        if (node == null) {
            std.log.err("[device.ContentDirectoryBrowseAction.initFromIXMLDocument] no ObjectId nodes found", .{});
            return error.InvalidMessage;
        }

        const objectId = std.mem.span(
            c.ixmlNode_getNodeValue(c.ixmlNode_getFirstChild(node)),
        );
        std.log.debug("[device.ContentDirectoryBrowseAction.initFromIXMLDocument] ObjectId: {s}", .{objectId});

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

        std.log.debug("[device.ActionRequest.initFromEvent] serviceId: {s}, actionName: {s}", .{ serviceId, actionName });

        var service: Service = undefined;
        if (std.mem.eql(u8, serviceId, "urn:upnp-org:serviceId:ContentDirectory")) {
            if (std.mem.eql(u8, actionName, "Browse")) {
                service = Service{
                    .contentDirectory = .{
                        .browse = try ContentDirectoryBrowseAction.initFromIXMLDocument(requestDocument),
                    },
                };
            } else {
                std.log.err("[device.ActionRequest.initFromEvent] Unsupported ContentDirectory action: {s}", .{actionName});
                return error.UnsupportAction;
            }
        } else {
            std.log.err("[device.ActionRequest.initFromEvent] Unsupported service: {s}", .{serviceId});
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
    albums: []const ImmichStore.Album = &[_]ImmichStore.Album{},
    assets: []const ImmichStore.Asset = &[_]ImmichStore.Asset{},
    count: u32,
    parentId: []const u8,
    updateId: u32,
    origin: []const u8,

    allocator: std.mem.Allocator,

    pub fn toIXMLDocument(self: BrowseReponse) ![*c]c.struct__IXML_Document {
        const didlDocument = c.ixmlDocument_createDocument();
        const didlElement = c.ixmlDocument_createElement(didlDocument, "DIDL-Lite");
        _ = c.ixmlElement_setAttribute(didlElement, "xmlns", "urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/");
        _ = c.ixmlElement_setAttribute(didlElement, "xmlns:dc", "http://purl.org/dc/elements/1.1/");
        _ = c.ixmlElement_setAttribute(didlElement, "xmlns:upnp", "urn:schemas-upnp-org:metadata-1-0/upnp/");
        _ = c.ixmlElement_setAttribute(didlElement, "xmlns:dlna", "urn:schemas-dlna-org:metadata-1-0/");
        _ = c.ixmlNode_appendChild(@ptrCast(didlDocument), @ptrCast(didlElement));

        for (self.albums) |asset| {
            const albumElement = try self.albumToIXMLElement(@ptrCast(didlDocument), asset, self.parentId);
            _ = c.ixmlNode_appendChild(@ptrCast(didlElement), @ptrCast(albumElement));
        }

        for (self.assets) |asset| {
            const assetElement = try self.assetToIXMLElement(@ptrCast(didlDocument), asset, self.parentId);
            _ = c.ixmlNode_appendChild(@ptrCast(didlElement), @ptrCast(assetElement));
        }

        const didlStr = c.ixmlNodetoString(@ptrCast(didlElement));

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
            const element = try self.create_text_element_fmt(document, "NumberReturned", "{d}", .{self.albums.len + self.assets.len});
            _ = c.ixmlNode_appendChild(@ptrCast(browseResponseElement), @ptrCast(element));
        }
        {
            const element = try self.create_text_element_fmt(document, "TotalMatches", "{d}", .{self.count});
            _ = c.ixmlNode_appendChild(@ptrCast(browseResponseElement), @ptrCast(element));
        }
        {
            const element = try self.create_text_element_fmt(document, "UpdateId", "{d}", .{self.updateId});
            _ = c.ixmlNode_appendChild(@ptrCast(browseResponseElement), @ptrCast(element));
        }

        return document;
    }

    pub fn albumToIXMLElement(self: BrowseReponse, document: *c.struct__IXML_Document, album: ImmichStore.Album, parentId: []const u8) ![*c]c.struct__IXML_Element {
        const albumElement = c.ixmlDocument_createElement(document, "container");
        try self.create_attribute(albumElement, "id", album.id);
        try self.create_attribute(albumElement, "parentID", parentId);
        try self.create_attribute(albumElement, "restricted", "1");

        const titleElement = try self.create_text_element(document, "dc:title", album.albumName);
        _ = c.ixmlNode_appendChild(@ptrCast(albumElement), @ptrCast(titleElement));

        const classElement = try self.create_text_element(document, "upnp:class", "object.container");
        _ = c.ixmlNode_appendChild(@ptrCast(albumElement), @ptrCast(classElement));

        return albumElement;
    }

    pub fn assetToIXMLElement(self: BrowseReponse, document: *c.struct__IXML_Document, asset: ImmichStore.Asset, parentId: []const u8) ![*c]c.struct__IXML_Element {
        const assetElement = c.ixmlDocument_createElement(document, "item");
        try self.create_attribute(assetElement, "id", asset.id);
        try self.create_attribute(assetElement, "parentID", parentId);
        try self.create_attribute(assetElement, "restricted", "1");

        const titleElement = try self.create_text_element(document, "dc:title", asset.id);
        _ = c.ixmlNode_appendChild(@ptrCast(assetElement), @ptrCast(titleElement));

        const classElement = try self.create_text_element(
            document,
            "upnp:class",
            "object.item.imageItem.photo",
        );
        _ = c.ixmlNode_appendChild(@ptrCast(assetElement), @ptrCast(classElement));

        const resElement = try self.create_text_element_fmt(
            document,
            "res",
            "{s}/assets/{s}{s}",
            .{ self.origin, asset.id, if (asset.mimeType) |mimeType| mimeType.toExtension() else "" },
        );
        try self.create_attribute_fmt(
            resElement,
            "protocolInfo",
            "http-get:*:{s}:*",
            .{if (asset.mimeType) |mimeType| mimeType.toString() else ""},
        );
        try self.create_attribute_fmt(
            resElement,
            "resolution",
            "{d}x{d}",
            .{ asset.width, asset.height },
        );
        try self.create_attribute_fmt(resElement, "size", "{d}", .{asset.size});

        _ = c.ixmlNode_appendChild(@ptrCast(assetElement), @ptrCast(resElement));

        return assetElement;
    }

    pub fn create_text_element(self: BrowseReponse, document: *c.struct__IXML_Document, name: [*c]const u8, text: []const u8) ![*c]c.struct__IXML_Element {
        const textCstr = try self.allocator.dupeZ(u8, text);
        defer self.allocator.free(textCstr);

        const element = c.ixmlDocument_createElement(document, name);
        const textNode = c.ixmlDocument_createTextNode(document, textCstr);
        _ = c.ixmlNode_appendChild(@ptrCast(element), @ptrCast(textNode));

        return element;
    }

    pub fn create_text_element_fmt(self: BrowseReponse, document: *c.struct__IXML_Document, name: [*c]const u8, comptime fmt: []const u8, args: anytype) ![*c]c.struct__IXML_Element {
        const textCstr = try std.fmt.allocPrintSentinel(self.allocator, fmt, args, 0);
        defer self.allocator.free(textCstr);

        const element = c.ixmlDocument_createElement(document, name);
        const textNode = c.ixmlDocument_createTextNode(document, textCstr);
        _ = c.ixmlNode_appendChild(@ptrCast(element), @ptrCast(textNode));

        return element;
    }

    pub fn create_attribute(self: BrowseReponse, element: *c.struct__IXML_Element, name: [*c]const u8, value: []const u8) !void {
        const valueCstr = try self.allocator.dupeZ(u8, value);
        defer self.allocator.free(valueCstr);

        _ = c.ixmlElement_setAttribute(element, name, valueCstr);
    }

    pub fn create_attribute_fmt(self: BrowseReponse, element: *c.struct__IXML_Element, name: [*c]const u8, comptime fmt: []const u8, args: anytype) !void {
        const valueCstr = try std.fmt.allocPrintSentinel(self.allocator, fmt, args, 0);
        defer self.allocator.free(valueCstr);

        _ = c.ixmlElement_setAttribute(element, name, valueCstr);
    }
};
