const std = @import("std");

const Self = @This();

pub const Album = struct {
    id: []u8,
    albumName: []u8,
    updatedAt: []u8,
    assets: []Asset,

    pub fn clone(allocator: std.mem.Allocator, original: Album) !Album {
        var assets = try std.ArrayList(Asset).initCapacity(allocator, original.assets.len);

        for (original.assets) |asset| {
            assets.appendAssumeCapacity(Asset{
                .id = try allocator.dupe(u8, asset.id),
                .originalPath = if (asset.originalPath) |path| try allocator.dupe(u8, path) else null,
                .originalMimeType = if (asset.originalMimeType) |mimeType| try allocator.dupe(u8, mimeType) else null,
                .updatedAt = try allocator.dupe(u8, asset.updatedAt),
                .exifInfo = asset.exifInfo,
            });
        }

        return Album{
            .id = try allocator.dupe(u8, original.id),
            .albumName = try allocator.dupe(u8, original.albumName),
            .updatedAt = try allocator.dupe(u8, original.updatedAt),
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

    pub fn clone(allocator: std.mem.Allocator, parsed: Asset) !Asset {
        return Asset{
            .id = try allocator.dupe(u8, parsed.id),
            .originalMimeType = if (parsed.originalMimeType) |mimeType| try allocator.dupe(u8, mimeType) else null,
            .originalPath = if (parsed.originalPath) |path| try allocator.dupe(u8, path) else null,
            .updatedAt = try allocator.dupe(u8, parsed.updatedAt),
            .exifInfo = parsed.exifInfo,
        };
    }
};

pub fn LockedResource(T: type) type {
    return struct {
        value: T,
        lock: *std.Thread.RwLock,

        pub fn deinit(self: *LockedResource(T)) void {
            self.lock.unlockShared();
        }
    };
}

apiKey: []const u8,
baseUrl: []const u8,
allocator: std.mem.Allocator,

albumsCache: ?[]const Album,
albumCache: std.hash_map.StringHashMap(Album),
assetCache: std.hash_map.StringHashMap(Asset),
cacheLock: std.Thread.RwLock,

pub fn init(allocator: std.mem.Allocator, apiKey: []const u8, baseUrl: []const u8) Self {
    return .{
        .apiKey = apiKey,
        .baseUrl = baseUrl,
        .allocator = allocator,

        .albumsCache = null,
        .albumCache = std.hash_map.StringHashMap(Album).init(allocator),
        .assetCache = std.hash_map.StringHashMap(Asset).init(allocator),
        .cacheLock = std.Thread.RwLock{},
    };
}

pub fn deinit(self: *Self) void {
    self.client.deinit();
    self.albumCache.deinit();
    self.assetCache.deinit();
}

const GetRequestError = error{
    HttpRequestFailed,
    OutOfMemory,
    FailedStatusCode,
};

pub fn getAlbums(self: *Self) !LockedResource([]const Album) {
    self.cacheLock.lockShared();

    if (self.albumsCache) |cache| {
        std.log.info("[ImmichApi.getAlbums] cache hit", .{});
        return LockedResource([]const Album){
            .value = cache,
            .lock = &self.cacheLock,
        };
    }

    std.log.info("[ImmichApi.getAlbums] cache miss", .{});

    self.cacheLock.unlockShared();

    const parsedAlbums = self.get([]Album, "/albums", .{}) catch |err| {
        self.cacheLock.unlock();
        return err;
    };
    defer parsedAlbums.deinit();

    var albums = std.ArrayList(Album).initCapacity(self.allocator, parsedAlbums.value.len) catch |err| {
        self.cacheLock.unlock();
        return err;
    };
    for (parsedAlbums.value) |album| {
        albums.appendAssumeCapacity(try Album.clone(self.allocator, album));
    }

    const albumsSlice = try albums.toOwnedSlice(self.allocator);
    self.cacheLock.lock();
    self.albumsCache = albumsSlice;
    self.cacheLock.unlock();

    self.cacheLock.lockShared();
    return LockedResource([]const Album){
        .value = self.albumsCache.?,
        .lock = &self.cacheLock,
    };
}

pub fn getAlbum(self: *Self, id: []const u8) !LockedResource(*Album) {
    self.cacheLock.lockShared();

    const entry = self.albumCache.getOrPut(id) catch |err| {
        self.cacheLock.unlockShared();
        return err;
    };
    if (entry.found_existing) {
        std.log.info("[ImmichApi.getAlbum] cache hit: {s}", .{id});
    } else {
        self.cacheLock.unlockShared();

        std.log.info("[ImmichApi.getAlbum] cache miss: {s}", .{id});
        const parsedAlbum = try self.get(Album, "/albums/{s}", .{id});
        defer parsedAlbum.deinit();

        self.cacheLock.lock();
        const album = Album.clone(self.allocator, parsedAlbum.value) catch |err| {
            self.cacheLock.unlock();
            return err;
        };
        entry.value_ptr.* = album;
        for (album.assets) |asset| {
            self.assetCache.put(asset.id, asset) catch |err| {
                self.cacheLock.unlock();
                return err;
            };
        }
        self.cacheLock.unlock();

        self.cacheLock.lockShared();
    }

    return LockedResource(*Album){
        .value = entry.value_ptr,
        .lock = &self.cacheLock,
    };
}

pub fn getAsset(self: *Self, id: []const u8) !LockedResource(*Asset) {
    self.cacheLock.lockShared();

    const entry = self.assetCache.getOrPut(id) catch |err| {
        self.cacheLock.unlockShared();
        return err;
    };
    if (entry.found_existing) {
        std.log.info("[ImmichApi.getAsset] cache hit: {s}", .{id});
    } else {
        self.cacheLock.unlockShared();

        std.log.info("[ImmichApi.getAsset] cache miss: {s}", .{id});
        const parsedAsset = try self.get(Asset, "/assets/{s}", .{id});
        defer parsedAsset.deinit();

        self.cacheLock.lock();
        entry.value_ptr.* = Asset.clone(self.allocator, parsedAsset.value) catch |err| {
            self.cacheLock.unlock();
            return err;
        };
        self.cacheLock.unlock();

        self.cacheLock.lockShared();
    }

    return LockedResource(*Asset){
        .value = entry.value_ptr,
        .lock = &self.cacheLock,
    };
}

pub fn get(self: *Self, Response: type, comptime path: []const u8, pathArgs: anytype) GetRequestError!std.json.Parsed(Response) {
    std.log.debug("[ImmichApi.get] Starting request for path: {s}", .{path});

    const fullPath = std.fmt.allocPrint(self.allocator, path, pathArgs) catch |err| {
        std.log.err("[ImmichApi.get] Failed to format URL path: {}", .{err});
        return err;
    };
    defer self.allocator.free(fullPath);

    const url = std.fmt.allocPrint(self.allocator, "{s}{s}", .{ self.baseUrl, fullPath }) catch |err| {
        std.log.err("[ImmichApi.get] Failed to format URL: {}", .{err});
        return err;
    };
    defer self.allocator.free(url);

    var body = std.Io.Writer.Allocating.init(self.allocator);
    defer body.deinit();

    std.log.info("[ImmichApi.get] {s}", .{url});

    var client = std.http.Client{ .allocator = self.allocator };
    const response = client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .extra_headers = &[_]std.http.Header{
            .{ .name = "x-api-key", .value = self.apiKey },
        },
        .response_writer = &body.writer,
    }) catch |err| {
        std.log.err("[ImmichApi.get] Get request failed: {}", .{err});
        return error.HttpRequestFailed;
    };

    if (response.status != .ok) {
        std.log.err("[ImmichApi.get] Request failed with status: {}", .{response.status});
        return error.FailedStatusCode;
    }

    const result = std.json.parseFromSlice(
        Response,
        self.allocator,
        body.written(),
        .{ .ignore_unknown_fields = true },
    ) catch |err| {
        std.log.err("[ImmichApi.get] Failed to parse response: {}", .{err});
        return error.HttpRequestFailed;
    };

    std.log.debug("[ImmichApi.get] Request succeeded", .{});

    return result;
}
