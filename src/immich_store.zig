const std = @import("std");

const ImmichApi = @import("immich_api.zig");
pub const Album = ImmichApi.Album;
pub const Asset = ImmichApi.Asset;

const Self = @This();
pub fn LockedResource(T: type) type {
    return struct {
        value: T,
        lock: *std.Thread.RwLock,

        pub fn deinit(self: *LockedResource(T)) void {
            self.lock.unlockShared();
        }
    };
}

allocator: std.mem.Allocator,
immichClient: ImmichApi,

albumsCache: ?[]const Album,
albumCache: std.hash_map.StringHashMap(Album),
assetCache: std.hash_map.StringHashMap(Asset),
cacheLock: std.Thread.RwLock,

pub fn init(allocator: std.mem.Allocator, apiKey: []const u8, baseUrl: []const u8) Self {
    return .{
        .allocator = allocator,
        .immichClient = ImmichApi.init(allocator, apiKey, baseUrl),

        .albumsCache = null,
        .albumCache = std.hash_map.StringHashMap(Album).init(allocator),
        .assetCache = std.hash_map.StringHashMap(Asset).init(allocator),
        .cacheLock = std.Thread.RwLock{},
    };
}

pub fn deinit(self: *Self) void {
    self.immichClient.deinit();
    self.albumCache.deinit();
    self.assetCache.deinit();
}

pub fn getAlbums(self: *Self) !LockedResource([]const Album) {
    self.cacheLock.lockShared();

    if (self.albumsCache) |cache| {
        std.log.info("[ImmichApi.getAlbums] cache hit", .{});
        return LockedResource([]const Album){
            .value = cache,
            .lock = &self.cacheLock,
        };
    }

    self.cacheLock.unlockShared();

    std.log.info("[ImmichApi.getAlbums] cache miss", .{});

    const albums = try self.immichClient.getAlbums();

    self.cacheLock.lock();
    self.albumsCache = albums;
    self.cacheLock.unlock();

    self.cacheLock.lockShared();
    return LockedResource([]const Album){
        .value = self.albumsCache.?,
        .lock = &self.cacheLock,
    };
}

pub fn getAlbum(self: *Self, id: []const u8) !LockedResource(Album) {
    self.cacheLock.lockShared();

    const cachedAlbum = self.albumCache.get(id);
    if (cachedAlbum) |album| {
        std.log.info("[ImmichApi.getAlbum] cache hit: {s}", .{id});

        return .{
            .value = album,
            .lock = &self.cacheLock,
        };
    }

    self.cacheLock.unlockShared();

    std.log.info("[ImmichApi.getAlbum] cache miss: {s}", .{id});
    const album = try self.immichClient.getAlbum(id);

    try self.cacheAlbum(album);

    self.cacheLock.lockShared();
    return .{
        .value = album,
        .lock = &self.cacheLock,
    };
}

pub fn getAsset(self: *Self, id: []const u8) !LockedResource(Asset) {
    self.cacheLock.lockShared();

    const cachedAsset = self.assetCache.get(id);
    if (cachedAsset) |asset| {
        std.log.info("[ImmichApi.getAsset] cache hit: {s}", .{id});

        return .{
            .value = asset,
            .lock = &self.cacheLock,
        };
    }

    self.cacheLock.unlockShared();

    std.log.info("[ImmichApi.getAsset] cache miss: {s}", .{id});
    const asset = try self.immichClient.getAsset(id);

    try self.cacheAsset(asset);

    self.cacheLock.lockShared();
    return .{
        .value = asset,
        .lock = &self.cacheLock,
    };
}

fn cacheAlbum(self: *Self, album: Album) !void {
    self.cacheLock.lock();
    defer self.cacheLock.unlock();

    try self.albumCache.put(album.id, album);
    for (album.assets) |asset| {
        try self.assetCache.put(asset.id, asset);
    }
}

fn cacheAsset(self: *Self, asset: Asset) !void {
    self.cacheLock.lock();
    defer self.cacheLock.unlock();

    try self.assetCache.put(asset.id, asset);
}
