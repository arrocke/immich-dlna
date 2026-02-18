const std = @import("std");
const zeit = @import("zeit");
const Context = @import("context.zig");

const c = @cImport({
    @cInclude("upnp/upnp.h");
});

const contentDirectoryXml: []const u8 = @embedFile("contentDirectory.xml");
const connectionManagerXml: []const u8 = @embedFile("connectionManager.xml");

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

pub fn initVirtualDir(context: *const Context) void {
    _ = c.UpnpVirtualDir_set_GetInfoCallback(getInfoCallback);
    _ = c.UpnpVirtualDir_set_OpenCallback(openCallback);
    _ = c.UpnpVirtualDir_set_SeekCallback(seekCallback);
    _ = c.UpnpVirtualDir_set_ReadCallback(readCallback);
    _ = c.UpnpVirtualDir_set_CloseCallback(closeCallback);

    _ = c.UpnpAddVirtualDir("assets", context, null);
    _ = c.UpnpAddVirtualDir("scpd", context, null);
}

fn getInfoCallback(pathCstr: [*c]const u8, fileInfo: ?*c.UpnpFileInfo, cookie: ?*const anyopaque, requestCookie: [*c]?*const anyopaque) callconv(.c) c_int {
    _ = requestCookie;
    const ctx: *Context = @ptrCast(@alignCast(@constCast(cookie)));

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
        const startIndex = std.mem.lastIndexOfScalar(u8, path, '/') orelse {
            std.log.err("[virtual_fs.getInfoCallback] asset path malformed", .{});
            return -1;
        };
        const endIndex = std.mem.lastIndexOfScalar(u8, path, '.') orelse {
            std.log.err("[virtual_fs.getInfoCallback] asset path malformed", .{});
            return -1;
        };
        const id = path[(startIndex + 1)..endIndex];

        std.log.info("[virtual_fs.getInfoCallback] Asset ID: {s}", .{id});

        var asset = ctx.immichStore.getAsset(id) catch {
            std.log.err("[virtual_fs.getInfoCallback] asset not found", .{});
            return -1;
        };
        defer asset.deinit();

        std.log.debug("[virtual_fs.getInfoCallback] found asset", .{});

        _ = c.UpnpFileInfo_set_FileLength(fileInfo, asset.value.exifInfo.fileSizeInByte);
        if (asset.value.originalMimeType) |mimeType| {
            const cstr = ctx.allocator.dupeZ(u8, mimeType) catch {
                std.log.err("[virtual_fs.getInfoCallback] failed to create mime type", .{});
                return -1;
            };
            defer ctx.allocator.free(cstr);

            std.log.debug("[virtual_fs.getInfoCallback] parsed mime type", .{});

            _ = c.UpnpFileInfo_set_ContentType(fileInfo, cstr);
        }
        _ = c.UpnpFileInfo_set_IsReadable(fileInfo, 1);
        _ = c.UpnpFileInfo_set_IsDirectory(fileInfo, 0);

        const updatedAt = zeit.instant(.{
            .source = .{
                .iso8601 = asset.value.updatedAt,
            },
        }) catch {
            std.log.err("[virtual_fs.getInfoCallback] failed to parse updated at date", .{});
            return -1;
        };
        std.log.debug("[virtual_fs.getInfoCallback] parsed updated date", .{});
        _ = c.UpnpFileInfo_set_LastModified(fileInfo, updatedAt.unixTimestamp());
    }

    return 0;
}

fn openCallback(pathCstr: [*c]const u8, fileMode: c.enum_UpnpOpenFileMode, cookie: ?*const anyopaque, requestCookie: ?*const anyopaque) callconv(.c) ?*anyopaque {
    _ = fileMode;
    _ = requestCookie;

    const ctx: *Context = @ptrCast(@alignCast(@constCast(cookie)));

    const path = std.mem.span(pathCstr);

    if (std.mem.eql(u8, path, "/scpd/ContentDirectory.xml")) {
        const handle = ctx.allocator.create(UpnpVirtualHandle) catch {
            std.log.err("[virtual_fs.openCallback] failed to create virtual handle", .{});
            return null;
        };
        handle.* = .{
            .slice = .{
                .slice = contentDirectoryXml,
                .pos = 0,
            },
        };

        std.log.debug("[virtual_fs.openCallback] handle created", .{});

        return handle;
    } else if (std.mem.eql(u8, path, "/scpd/ConnectionManager.xml")) {
        const handle = ctx.allocator.create(UpnpVirtualHandle) catch {
            std.log.err("[virtual_fs.openCallback] failed to create virtual handle", .{});
            return null;
        };
        handle.* = .{
            .slice = .{
                .slice = connectionManagerXml,
                .pos = 0,
            },
        };

        std.log.debug("[virtual_fs.openCallback] handle created", .{});

        return handle;
    } else if (std.mem.startsWith(u8, path, "/assets/")) {
        const startIndex = std.mem.lastIndexOfScalar(u8, path, '/') orelse {
            std.log.err("[virtual_fs.openCallback] asset path malformed", .{});
            return null;
        };
        const endIndex = std.mem.lastIndexOfScalar(u8, path, '.') orelse {
            std.log.err("[virtual_fs.openCallback] asset path malformed", .{});
            return null;
        };
        const id = path[(startIndex + 1)..endIndex];

        std.log.info("[virtual_fs.openCallback] Asset ID: {s}", .{id});

        var asset = ctx.immichStore.getAsset(id) catch {
            std.log.err("[virtual_fs.openCallback] asset not found", .{});
            return null;
        };
        defer asset.deinit();

        std.log.debug("[virtual_fs.openCallback] found asset", .{});

        const filePath = asset.value.originalPath orelse {
            std.log.err("[virtual_fs.openCallback] asset path not found", .{});
            return null;
        };

        const file = std.fs.openFileAbsolute(filePath, .{}) catch |err| {
            std.log.err("[virtual_fs.openCallback] failed to open file: {}", .{err});
            return null;
        };

        const handle = ctx.allocator.create(UpnpVirtualHandle) catch {
            std.log.err("[virtual_fs.openCallback] failed to create virtual handle", .{});
            return null;
        };
        handle.* = .{ .file = .{ .file = file } };

        std.log.debug("[virtual_fs.openCallback] handle created", .{});

        return handle;
    }

    return null;
}

fn seekCallback(_handle: ?*anyopaque, offset: c_long, origin: c_int, cookie: ?*const anyopaque, requestCookie: ?*const anyopaque) callconv(.c) c_int {
    _ = cookie;
    _ = requestCookie;

    const handle: *UpnpVirtualHandle = @ptrCast(@alignCast(@constCast(_handle)));

    std.log.debug("[virtual_fs.seekCallback] starting to seek", .{});

    switch (origin) {
        c.SEEK_CUR => {
            handle.seekBy(offset) catch {
                std.log.err("[virtual_fs.seekCallback] failed to seek", .{});
                return -1;
            };
        },
        c.SEEK_END => {
            handle.seekFromEnd(offset) catch {
                std.log.err("[virtual_fs.seekCallback] failed to seek", .{});
                return -1;
            };
        },
        c.SEEK_SET => {
            handle.seekTo(@intCast(offset)) catch {
                std.log.err("[virtual_fs.seekCallback] failed to seek", .{});
                return -1;
            };
        },
        else => {
            std.log.err("[virtual_fs.seekCallback] invalid seek origin", .{});
            return -1;
        },
    }

    std.log.debug("[virtual_fs.seekCallback] finished seeking", .{});

    return 0;
}

fn readCallback(_handle: ?*anyopaque, buf: [*c]u8, len: usize, cookie: ?*const anyopaque, requestCookie: ?*const anyopaque) callconv(.c) c_int {
    _ = cookie;
    _ = requestCookie;

    const handle: *UpnpVirtualHandle = @ptrCast(@alignCast(@constCast(_handle)));

    std.log.debug("[virtual_fs.readCallback] starting to read", .{});

    const slice: []u8 = buf[0..len];
    const bytesRead = handle.read(slice) catch {
        std.log.err("[virtual_fs.readCallback] failed to read file into buffer", .{});
        return 0;
    };

    std.log.debug("[virtual_fs.readCallback] read {} bytes", .{bytesRead});

    return @intCast(bytesRead);
}

fn closeCallback(_handle: ?*anyopaque, cookie: ?*const anyopaque, requestCookie: ?*const anyopaque) callconv(.c) c_int {
    _ = requestCookie;

    const ctx: *Context = @ptrCast(@alignCast(@constCast(cookie)));

    const handle: *UpnpVirtualHandle = @ptrCast(@alignCast(@constCast(_handle)));
    handle.close();

    ctx.allocator.destroy(handle);

    std.log.debug("[virtual_fs.closeCallback] closed file", .{});

    return 0;
}
