const std = @import("std");
const zeit = @import("zeit");

const Self = @This();

const log = std.log.scoped(.ImmichApi);

const JsonAlbum = struct {
    id: []u8,
    albumName: []u8,
    updatedAt: []u8,
    assets: []JsonAsset,
};

const JsonAsset = struct {
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
};

pub const Album = struct {
    id: []u8,
    albumName: []u8,
    updatedAt: i64,
    assets: []const Asset,

    pub fn deinit(self: *const Album, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.albumName);

        for (self.assets) |asset| {
            asset.deinit(allocator);
        }
        allocator.free(self.assets);
    }

    fn fromJson(allocator: std.mem.Allocator, json: JsonAlbum) !Album {
        const assets = try allocator.alloc(Asset, json.assets.len);
        for (json.assets, 0..) |asset, i| {
            assets[i] = try Asset.fromJson(allocator, asset);
        }

        const updatedAt = try zeit.instant(.{
            .source = .{
                .iso8601 = json.updatedAt,
            },
        });

        return Album{
            .id = try allocator.dupe(u8, json.id),
            .albumName = try allocator.dupe(u8, json.albumName),
            .updatedAt = updatedAt.unixTimestamp(),
            .assets = assets,
        };
    }
};

pub const Asset = struct {
    const MimeType = enum {
        jpeg,
        png,

        pub fn fromString(maybeStr: ?[]const u8) ?MimeType {
            if (maybeStr) |str| {
                if (std.mem.eql(u8, "image/jpeg", str)) {
                    return .jpeg;
                } else if (std.mem.eql(u8, "image/png", str)) {
                    return .png;
                }
            }

            return null;
        }

        pub fn toExtension(self: MimeType) []const u8 {
            switch (self) {
                .jpeg => return ".jpg",
                .png => return ".png",
            }
        }

        pub fn toString(self: MimeType) []const u8 {
            switch (self) {
                .jpeg => return "image/jpeg",
                .png => return "image/png",
            }
        }
    };

    id: []const u8,
    width: u32,
    height: u32,
    size: u64,
    mimeType: ?MimeType,
    path: ?[]const u8,
    updatedAt: i64,

    pub fn deinit(self: *const Asset, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        if (self.path) |path| {
            allocator.free(path);
        }
    }

    pub fn clone(self: *const Asset, allocator: std.mem.Allocator) !Asset {
        return Asset{
            .id = try allocator.dupe(u8, self.id),
            .mimeType = self.mimeType,
            .path = if (self.path) |path| try allocator.dupe(u8, path) else null,
            .updatedAt = self.updatedAt,
            .width = self.width,
            .height = self.height,
            .size = self.size,
        };
    }

    pub fn fromJson(allocator: std.mem.Allocator, json: JsonAsset) !Asset {
        const updatedAt = try zeit.instant(.{
            .source = .{
                .iso8601 = json.updatedAt,
            },
        });

        return Asset{
            .id = try allocator.dupe(u8, json.id),
            .mimeType = MimeType.fromString(json.originalMimeType),
            .path = if (json.originalPath) |path| try allocator.dupe(u8, path) else null,
            .updatedAt = updatedAt.unixTimestamp(),
            .width = json.exifInfo.exifImageWidth,
            .height = json.exifInfo.exifImageHeight,
            .size = json.exifInfo.fileSizeInByte,
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

    const parsedAlbums = try self.get([]JsonAlbum, "/albums", .{});
    defer parsedAlbums.deinit();

    const albums = try self.allocator.alloc(Album, parsedAlbums.value.len);
    for (parsedAlbums.value, 0..) |album, i| {
        albums[i] = try Album.fromJson(self.allocator, album);
    }

    log.info("GET /albums", .{});

    return albums;
}

pub fn getAlbum(self: *Self, id: []const u8) !Album {
    errdefer |err| {
        log.err("GET /albums/{s} failed: {}", .{ id, err });
    }

    const parsedAlbum = try self.get(JsonAlbum, "/albums/{s}", .{id});
    defer parsedAlbum.deinit();

    const album = try Album.fromJson(self.allocator, parsedAlbum.value);

    log.info("GET /albums/{s}", .{id});

    return album;
}

pub fn getAsset(self: *Self, id: []const u8) !Asset {
    errdefer |err| {
        log.err("GET /assets/{s} failed: {}", .{ id, err });
    }

    const parsedAsset = try self.get(JsonAsset, "/assets/{s}", .{id});
    defer parsedAsset.deinit();

    const asset = try Asset.fromJson(self.allocator, parsedAsset.value);

    log.info("GET /assets/{s}", .{id});

    return asset;
}

pub fn get(self: *Self, Response: type, comptime path: []const u8, pathArgs: anytype) GetRequestError!std.json.Parsed(Response) {
    errdefer |err| {
        log.err("GET request failed: {}", .{err});
    }

    const fullPath = try std.fmt.allocPrint(self.allocator, path, pathArgs);
    defer self.allocator.free(fullPath);

    const url = try std.fmt.allocPrint(self.allocator, "{s}/api{s}", .{ self.baseUrl, fullPath });
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
