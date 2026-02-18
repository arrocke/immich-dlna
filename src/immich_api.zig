const std = @import("std");

const Self = @This();

const log = std.log.scoped(.ImmichApi);

pub const Album = struct {
    id: []u8,
    albumName: []u8,
    updatedAt: []u8,
    assets: []Asset,

    pub fn clone(self: Album, allocator: std.mem.Allocator) !Album {
        var assets = try std.ArrayList(Asset).initCapacity(allocator, self.assets.len);

        for (self.assets) |asset| {
            assets.appendAssumeCapacity(Asset{
                .id = try allocator.dupe(u8, asset.id),
                .originalPath = if (asset.originalPath) |path| try allocator.dupe(u8, path) else null,
                .originalMimeType = if (asset.originalMimeType) |mimeType| try allocator.dupe(u8, mimeType) else null,
                .updatedAt = try allocator.dupe(u8, asset.updatedAt),
                .exifInfo = asset.exifInfo,
            });
        }

        return Album{
            .id = try allocator.dupe(u8, self.id),
            .albumName = try allocator.dupe(u8, self.albumName),
            .updatedAt = try allocator.dupe(u8, self.updatedAt),
            .assets = try assets.toOwnedSlice(allocator),
        };
    }
};

pub const Asset = struct {
    const EixfInfo = struct {
        exifImageHeight: u32,
        exifImageWidth: u32,
        fileSizeInByte: u32,
    };

    id: []u8,
    originalMimeType: ?[]u8,
    originalPath: ?[]u8,
    exifInfo: EixfInfo,
    updatedAt: []u8,

    pub fn clone(self: Asset, allocator: std.mem.Allocator) !Asset {
        return Asset{
            .id = try allocator.dupe(u8, self.id),
            .originalMimeType = if (self.originalMimeType) |mimeType| try allocator.dupe(u8, mimeType) else null,
            .originalPath = if (self.originalPath) |path| try allocator.dupe(u8, path) else null,
            .updatedAt = try allocator.dupe(u8, self.updatedAt),
            .exifInfo = self.exifInfo,
        };
    }
};

const GetRequestError = error{
    HttpRequestFailed,
    OutOfMemory,
    FailedStatusCode,
};

apiKey: []const u8,
baseUrl: []const u8,
allocator: std.mem.Allocator,

pub fn init(allocator: std.mem.Allocator, apiKey: []const u8, baseUrl: []const u8) Self {
    return .{
        .apiKey = apiKey,
        .baseUrl = baseUrl,
        .allocator = allocator,
    };
}

pub fn deinit(self: *Self) void {
    _ = self;
}

pub fn getAlbums(self: *Self) ![]const Album {
    errdefer |err| {
        log.err("GET /albums failed: {}", .{err});
    }

    const parsedAlbums = try self.get([]Album, "/albums", .{});
    defer parsedAlbums.deinit();

    const albums = try self.allocator.alloc(Album, parsedAlbums.value.len);
    for (parsedAlbums.value, 0..) |album, i| {
        albums[i] = try album.clone(self.allocator);
    }

    log.info("GET /albums", .{});

    return albums;
}

pub fn getAlbum(self: *Self, id: []const u8) !Album {
    errdefer |err| {
        log.err("GET /albums/{s} failed: {}", .{ id, err });
    }

    const parsedAlbum = try self.get(Album, "/albums/{s}", .{id});
    defer parsedAlbum.deinit();

    const album = try parsedAlbum.value.clone(self.allocator);

    log.info("GET /albums/{s}", .{id});

    return album;
}

pub fn getAsset(self: *Self, id: []const u8) !Asset {
    errdefer |err| {
        log.err("GET /assets/{s} failed: {}", .{ id, err });
    }

    const parsedAsset = try self.get(Asset, "/assets/{s}", .{id});
    defer parsedAsset.deinit();

    const asset = try parsedAsset.value.clone(self.allocator);

    log.info("GET /assets/{s}", .{id});

    return asset;
}

pub fn get(self: *Self, Response: type, comptime path: []const u8, pathArgs: anytype) GetRequestError!std.json.Parsed(Response) {
    errdefer |err| {
        log.err("GET request failed: {}", .{err});
    }

    const fullPath = try std.fmt.allocPrint(self.allocator, path, pathArgs);
    defer self.allocator.free(fullPath);

    const url = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ self.baseUrl, fullPath });
    defer self.allocator.free(url);

    var body = std.Io.Writer.Allocating.init(self.allocator);
    defer body.deinit();

    var client = std.http.Client{ .allocator = self.allocator };
    defer client.deinit();

    const response = client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .extra_headers = &[_]std.http.Header{
            .{ .name = "x-api-key", .value = self.apiKey },
        },
        .response_writer = &body.writer,
    }) catch |err| {
        log.err("Failed to fetch: {}", .{err});
        return error.HttpRequestFailed;
    };

    if (response.status != .ok) {
        log.err("Error status code: {}", .{response.status});
        return error.FailedStatusCode;
    }

    const result = std.json.parseFromSlice(
        Response,
        self.allocator,
        body.written(),
        .{ .ignore_unknown_fields = true },
    ) catch |err| {
        log.err("Failed to parse HTTP response: {}", .{err});
        return error.HttpRequestFailed;
    };

    return result;
}
