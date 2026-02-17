const std = @import("std");
const zeit = @import("zeit");
const ImmichApi = @import("./immich-api.zig");

const c = @cImport({
    @cInclude("upnp/upnp.h");
});

const UpnpCallbackContext = struct {
    allocator: std.mem.Allocator,
    immichBaseUrl: []const u8,
    immichApiKey: []const u8,
};

const UpnpFileCallbackContext = struct {};

const UpnpVirtualHandle = union(enum) {
    file: struct {
        file: std.fs.File,
    },
    slice: struct {
        slice: []const u8,
        pos: usize,
    },

    fn close(self: *UpnpVirtualHandle) void {
        switch (self.*) {
            .file => |fileHandle| {
                fileHandle.file.close();
            },
            .slice => {},
        }
    }

    fn read(self: *UpnpVirtualHandle, buf: []u8) !usize {
        switch (self.*) {
            .file => |fileHandle| {
                return try fileHandle.file.read(buf);
            },
            .slice => |*sliceHandle| {
                if (sliceHandle.pos >= sliceHandle.slice.len) {
                    return 0;
                }

                const bytesRead = @max(buf.len, sliceHandle.slice.len - sliceHandle.pos);
                @memcpy(buf, sliceHandle.slice[sliceHandle.pos..(sliceHandle.pos + bytesRead)]);
                sliceHandle.pos += bytesRead;
                return bytesRead;
            },
        }
    }

    fn seekBy(self: *UpnpVirtualHandle, offset: i64) !void {
        switch (self.*) {
            .file => |fileHandle| {
                return try fileHandle.file.seekBy(offset);
            },
            .slice => |*sliceHandle| {
                const newPos = sliceHandle.pos + @as(usize, @intCast(offset));
                if (newPos < 0) {
                    return std.fs.File.SeekError.Unseekable;
                } else if (newPos > sliceHandle.slice.len) {
                    return std.fs.File.SeekError.Unseekable;
                }

                sliceHandle.pos = newPos;
                return;
            },
        }
    }

    fn seekTo(self: *UpnpVirtualHandle, offset: u64) !void {
        switch (self.*) {
            .file => |fileHandle| {
                return try fileHandle.file.seekTo(offset);
            },
            .slice => |*sliceHandle| {
                if (offset > sliceHandle.slice.len) {
                    return std.fs.File.SeekError.Unseekable;
                }

                sliceHandle.pos = offset;
                return;
            },
        }
    }

    fn seekFromEnd(self: *UpnpVirtualHandle, offset: i64) !void {
        switch (self.*) {
            .file => |fileHandle| {
                return try fileHandle.file.seekFromEnd(offset);
            },
            .slice => |*sliceHandle| {
                const newPos = sliceHandle.slice.len + @as(usize, @intCast(offset));
                if (newPos < 0) {
                    return std.fs.File.SeekError.Unseekable;
                } else if (newPos > sliceHandle.slice.len) {
                    return std.fs.File.SeekError.Unseekable;
                }

                sliceHandle.pos = newPos;
                return;
            },
        }
    }
};

const deviceXml = @embedFile("device.xml");
const contentDirectoryXml: []const u8 = @embedFile("contentDirectory.xml");
const connectionManagerXml: []const u8 = @embedFile("connectionManager.xml");

fn upnpGetInfoCallback(pathCstr: [*c]const u8, fileInfo: ?*c.UpnpFileInfo, cookie: ?*const anyopaque, requestCookie: [*c]?*const anyopaque) callconv(.c) c_int {
    _ = requestCookie;
    const ctx: *UpnpCallbackContext = @ptrCast(@alignCast(@constCast(cookie)));

    const path = std.mem.span(pathCstr);

    if (std.mem.eql(u8, path, "/scpd/ContentDirectory.xml")) {
        _ = c.UpnpFileInfo_set_FileLength(fileInfo, contentDirectoryXml.len);
        _ = c.UpnpFileInfo_set_ContentType(fileInfo, "text/xml");
        _ = c.UpnpFileInfo_set_IsReadable(fileInfo, 1);
        _ = c.UpnpFileInfo_set_IsDirectory(fileInfo, 0);
        _ = c.UpnpFileInfo_set_LastModified(fileInfo, std.time.timestamp());
    } else if (std.mem.eql(u8, path, "/scpd/ConnectionManager.xml")) {
        _ = c.UpnpFileInfo_set_FileLength(fileInfo, connectionManagerXml.len);
        _ = c.UpnpFileInfo_set_ContentType(fileInfo, "text/xml");
        _ = c.UpnpFileInfo_set_IsReadable(fileInfo, 1);
        _ = c.UpnpFileInfo_set_IsDirectory(fileInfo, 0);
        _ = c.UpnpFileInfo_set_LastModified(fileInfo, std.time.timestamp());
    } else if (std.mem.startsWith(u8, path, "/assets/")) {
        var immichClient = ImmichApi.init(ctx.allocator, ctx.immichApiKey, ctx.immichBaseUrl);

        const startIndex = std.mem.lastIndexOfScalar(u8, path, '/') orelse {
            std.log.err("[upnpGetInfoCallback] asset path malformed", .{});
            return -1;
        };
        const endIndex = std.mem.lastIndexOfScalar(u8, path, '.') orelse {
            std.log.err("[upnpGetInfoCallback] asset path malformed", .{});
            return -1;
        };
        const id = path[(startIndex + 1)..endIndex];

        std.log.info("[upnpGetInfoCallback] Asset ID: {s}", .{id});

        const asset = immichClient.getAsset(id) catch {
            std.log.err("[upnpGetInfoCallback] asset not found", .{});
            return -1;
        };
        defer asset.deinit();

        std.log.debug("[upnpGetInfoCallback] found asset", .{});

        _ = c.UpnpFileInfo_set_FileLength(fileInfo, asset.value.exifInfo.fileSizeInByte);
        if (asset.value.originalMimeType) |mimeType| {
            const cstr = ctx.allocator.dupeZ(u8, mimeType) catch {
                std.log.err("[upnpGetInfoCallback] failed to create mime type", .{});
                return -1;
            };
            defer ctx.allocator.free(cstr);

            std.log.debug("[upnpGetInfoCallback] parsed mime type", .{});

            _ = c.UpnpFileInfo_set_ContentType(fileInfo, cstr);
        }
        _ = c.UpnpFileInfo_set_IsReadable(fileInfo, 1);
        _ = c.UpnpFileInfo_set_IsDirectory(fileInfo, 0);

        const updatedAt = zeit.instant(.{
            .source = .{
                .iso8601 = asset.value.updatedAt,
            },
        }) catch {
            std.log.err("[upnpGetInfoCallback] failed to parse updated at date", .{});
            return -1;
        };
        std.log.debug("[upnpGetInfoCallback] parsed updated date", .{});
        _ = c.UpnpFileInfo_set_LastModified(fileInfo, updatedAt.unixTimestamp());
    }

    return 0;
}

fn upnpOpenCallback(pathCstr: [*c]const u8, fileMode: c.enum_UpnpOpenFileMode, cookie: ?*const anyopaque, requestCookie: ?*const anyopaque) callconv(.c) ?*anyopaque {
    _ = fileMode;
    _ = requestCookie;

    const ctx: *UpnpCallbackContext = @ptrCast(@alignCast(@constCast(cookie)));

    const path = std.mem.span(pathCstr);

    if (std.mem.eql(u8, path, "/scpd/ContentDirectory.xml")) {
        const handle = ctx.allocator.create(UpnpVirtualHandle) catch {
            std.log.err("[upnpOpenCallback] failed to create virtual handle", .{});
            return null;
        };
        handle.* = .{
            .slice = .{
                .slice = contentDirectoryXml,
                .pos = 0,
            },
        };

        std.log.debug("[upnpOpenCallback] handle created", .{});

        return handle;
    } else if (std.mem.eql(u8, path, "/scpd/ConnectionManager.xml")) {
        const handle = ctx.allocator.create(UpnpVirtualHandle) catch {
            std.log.err("[upnpOpenCallback] failed to create virtual handle", .{});
            return null;
        };
        handle.* = .{
            .slice = .{
                .slice = connectionManagerXml,
                .pos = 0,
            },
        };

        std.log.debug("[upnpOpenCallback] handle created", .{});

        return handle;
    } else if (std.mem.startsWith(u8, path, "/assets/")) {
        var immichClient = ImmichApi.init(ctx.allocator, ctx.immichApiKey, ctx.immichBaseUrl);

        const startIndex = std.mem.lastIndexOfScalar(u8, path, '/') orelse {
            std.log.err("[upnpOpenCallback] asset path malformed", .{});
            return null;
        };
        const endIndex = std.mem.lastIndexOfScalar(u8, path, '.') orelse {
            std.log.err("[upnpOpenCallback] asset path malformed", .{});
            return null;
        };
        const id = path[(startIndex + 1)..endIndex];

        std.log.info("[upnpOpenCallback] Asset ID: {s}", .{id});

        const asset = immichClient.getAsset(id) catch {
            std.log.err("[upnpOpenCallback] asset not found", .{});
            return null;
        };
        defer asset.deinit();

        std.log.debug("[upnpOpenCallback] found asset", .{});

        const filePath = asset.value.originalPath orelse {
            std.log.err("[upnpOpenCallback] asset path not found", .{});
            return null;
        };

        const file = std.fs.openFileAbsolute(filePath, .{}) catch |err| {
            std.log.err("[upnpOpenCallback] failed to open file: {}", .{err});
            return null;
        };

        const handle = ctx.allocator.create(UpnpVirtualHandle) catch {
            std.log.err("[upnpOpenCallback] failed to create virtual handle", .{});
            return null;
        };
        handle.* = .{ .file = .{ .file = file } };

        std.log.debug("[upnpOpenCallback] handle created", .{});

        return handle;
    }

    return null;
}

fn upnpSeekCallback(_handle: ?*anyopaque, offset: c_long, origin: c_int, cookie: ?*const anyopaque, requestCookie: ?*const anyopaque) callconv(.c) c_int {
    _ = cookie;
    _ = requestCookie;

    const handle: *UpnpVirtualHandle = @ptrCast(@alignCast(@constCast(_handle)));

    std.log.debug("[upnpSeekCallback] starting to seek", .{});

    switch (origin) {
        c.SEEK_CUR => {
            handle.seekBy(offset) catch {
                std.log.err("[upnpSeekCallback] failed to seek", .{});
                return -1;
            };
        },
        c.SEEK_END => {
            handle.seekFromEnd(offset) catch {
                std.log.err("[upnpSeekCallback] failed to seek", .{});
                return -1;
            };
        },
        c.SEEK_SET => {
            handle.seekTo(@intCast(offset)) catch {
                std.log.err("[upnpSeekCallback] failed to seek", .{});
                return -1;
            };
        },
        else => {
            std.log.err("[upnpSeekCallback] invalid seek origin", .{});
            return -1;
        },
    }

    std.log.debug("[upnpSeekCallback] finished seeking", .{});

    return 0;
}

fn upnpReadCallback(_handle: ?*anyopaque, buf: [*c]u8, len: usize, cookie: ?*const anyopaque, requestCookie: ?*const anyopaque) callconv(.c) c_int {
    _ = cookie;
    _ = requestCookie;

    const handle: *UpnpVirtualHandle = @ptrCast(@alignCast(@constCast(_handle)));

    std.log.debug("[upnpReadCallback] starting to read", .{});

    const slice: []u8 = buf[0..len];
    const bytesRead = handle.read(slice) catch {
        std.log.err("[upnpReadCallback] failed to read file into buffer", .{});
        return 0;
    };

    std.log.debug("[upnpReadCallback] read {} bytes", .{bytesRead});

    return @intCast(bytesRead);
}

fn upnpCloseCallback(_handle: ?*anyopaque, cookie: ?*const anyopaque, requestCookie: ?*const anyopaque) callconv(.c) c_int {
    _ = requestCookie;

    const ctx: *UpnpCallbackContext = @ptrCast(@alignCast(@constCast(cookie)));

    const handle: *UpnpVirtualHandle = @ptrCast(@alignCast(@constCast(_handle)));
    handle.close();

    ctx.allocator.destroy(handle);

    std.log.debug("[upnpCloseCallback] closed file", .{});

    return 0;
}

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
                        var immichClient = ImmichApi.init(ctx.allocator, ctx.immichApiKey, ctx.immichBaseUrl);

                        var resources: std.ArrayList(BrowseReponse.Resource) = .{};
                        if (std.mem.eql(u8, action.objectId, "0")) {
                            const albums = immichClient.getAlbums() catch |err| {
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
                            const album = immichClient.getAlbum(action.objectId) catch |err| {
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
                                    .width = asset.exifInfo.exifImageWidth,
                                    .height = asset.exifInfo.exifImageHeight,
                                    .size = asset.exifInfo.fileSizeInByte,
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
                            .updateId = "1",
                        };

                        const doc = response.toIXMLDocument();

                        request.setActionResult(doc);
                    },
                },
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

        var buf: [1024]u8 = undefined;
        const countStr = std.fmt.bufPrintZ(&buf, "{d}", .{self.resources.len}) catch "";

        {
            const element = c.ixmlDocument_createElement(document, "NumberReturned");
            const text = c.ixmlDocument_createTextNode(document, countStr);
            _ = c.ixmlNode_appendChild(@ptrCast(element), @ptrCast(text));
            _ = c.ixmlNode_appendChild(@ptrCast(browseResponseElement), @ptrCast(element));
        }

        {
            const element = c.ixmlDocument_createElement(document, "TotalMatches");
            const text = c.ixmlDocument_createTextNode(document, countStr);
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
    size: u32,

    pub fn toIXMLElement(self: *const Asset, document: *c.struct__IXML_Document) [*c]c.struct__IXML_Element {
        const assetElement = c.ixmlDocument_createElement(document, "item");
        _ = c.ixmlElement_setAttribute(assetElement, "id", self.id);
        _ = c.ixmlElement_setAttribute(assetElement, "parentID", self.parentId);
        _ = c.ixmlElement_setAttribute(assetElement, "restricted", "1");

        const titleElement = c.ixmlDocument_createElement(document, "dc:title");
        const titleText = c.ixmlDocument_createTextNode(document, self.name);
        _ = c.ixmlNode_appendChild(@ptrCast(titleElement), @ptrCast(titleText));
        _ = c.ixmlNode_appendChild(@ptrCast(assetElement), @ptrCast(titleElement));

        const classElement = c.ixmlDocument_createElement(document, "upnp:class");
        const classText = c.ixmlDocument_createTextNode(document, "object.item.imageItem.photo");
        _ = c.ixmlNode_appendChild(@ptrCast(classElement), @ptrCast(classText));
        _ = c.ixmlNode_appendChild(@ptrCast(assetElement), @ptrCast(classElement));

        const resElement = c.ixmlDocument_createElement(document, "res");
        var buf: [1024]u8 = undefined;
        _ = c.ixmlElement_setAttribute(resElement, "protocolInfo", std.fmt.bufPrintZ(&buf, "http-get:*:{s}:*", .{self.mimeType}) catch "");
        _ = c.ixmlElement_setAttribute(resElement, "resolution", std.fmt.bufPrintZ(&buf, "{d}x{d}", .{ self.width, self.height }) catch "");
        _ = c.ixmlElement_setAttribute(resElement, "size", std.fmt.bufPrintZ(&buf, "{d}", .{self.size}) catch "");

        const extension = if (std.mem.eql(u8, self.mimeType, "image/jpeg")) ".jpeg" else "";

        const resText = c.ixmlDocument_createTextNode(document, std.fmt.bufPrintZ(&buf, "http://192.168.0.11:8888/assets/{s}{s}", .{ self.id, extension }) catch "");
        _ = c.ixmlNode_appendChild(@ptrCast(resElement), @ptrCast(resText));
        _ = c.ixmlNode_appendChild(@ptrCast(assetElement), @ptrCast(resElement));

        return assetElement;
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

var shutdown_requested = std.atomic.Value(bool).init(false);

fn handleSignal(sig: c_int) callconv(.c) void {
    _ = sig;
    shutdown_requested.store(true, .seq_cst);
}

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

    const allocator = std.heap.c_allocator;
    const context = UpnpCallbackContext{
        .allocator = allocator,
        .immichApiKey = "rETcQbd3iHV5UseeCxfLRknNKDTkddSocw3ESZCqiyQ",
        .immichBaseUrl = "http://localhost:2283/api",
    };

    _ = c.UpnpVirtualDir_set_GetInfoCallback(upnpGetInfoCallback);
    _ = c.UpnpVirtualDir_set_OpenCallback(upnpOpenCallback);
    _ = c.UpnpVirtualDir_set_SeekCallback(upnpSeekCallback);
    _ = c.UpnpVirtualDir_set_ReadCallback(upnpReadCallback);
    _ = c.UpnpVirtualDir_set_CloseCallback(upnpCloseCallback);

    _ = c.UpnpAddVirtualDir("assets", &context, null);
    _ = c.UpnpAddVirtualDir("scpd", &context, null);

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

    _ = c.UpnpSendAdvertisement(handle, 60);

    std.log.debug("[main] Advertisements sent", .{});

    var act = std.posix.Sigaction{
        .handler = .{ .handler = handleSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &act, null);
    std.posix.sigaction(std.posix.SIG.TERM, &act, null);

    while (!shutdown_requested.load(.seq_cst)) {
        std.Thread.sleep(1 * std.time.ns_per_s);
    }

    std.log.debug("[main] Shutting down", .{});

    _ = c.UpnpUnRegisterRootDevice(handle);
    _ = c.UpnpFinish();
}
