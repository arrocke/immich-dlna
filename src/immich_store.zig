const std = @import("std");
const ImmichApi = @import("immich_api.zig");
pub const Album = ImmichApi.Album;
pub const Asset = ImmichApi.Asset;

const Self = @This();

const log = std.log.scoped(.ImmichStore);

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

cacheInvalidationTimeout: ?i64,
cache_timeout_seconds: u32,

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

        .cache_timeout_seconds = 30 * 60, // 30 minutes
        .cacheInvalidationTimeout = null,
        .cacheLock = std.Thread.RwLock{},
    };
}

pub fn deinit(self: *Self) void {
    self.cacheLock.lock();

    self.immichClient.deinit();

    if (self.albumsCache) |albums| {
        for (albums) |album| {
            album.deinit(self.allocator);
        }
    }
    self.albumsCache = null;

    var albumIter = self.albumCache.valueIterator();
    while (albumIter.next()) |album| {
        album.deinit(self.allocator);
    }
    self.albumCache.deinit();

    var assetIter = self.assetCache.valueIterator();
    while (assetIter.next()) |asset| {
        asset.deinit(self.allocator);
    }
    self.assetCache.deinit();

    self.cacheLock.unlock();
}

pub fn getAlbums(self: *Self) !LockedResource([]const Album) {
    self.invalidateCacheOnTimeout();

    self.cacheLock.lockShared();

    if (self.albumsCache) |cache| {
        log.debug("albums cache hit", .{});
        return LockedResource([]const Album){
            .value = cache,
            .lock = &self.cacheLock,
        };
    }

    self.cacheLock.unlockShared();

    log.debug("albums cache miss", .{});

    const albums = try self.immichClient.getAlbums();

    self.cacheAlbums(albums);

    return self.getAlbums();
}

pub fn getAlbum(self: *Self, id: []const u8) !LockedResource(Album) {
    self.invalidateCacheOnTimeout();

    self.cacheLock.lockShared();

    const cachedAlbum = self.albumCache.get(id);
    if (cachedAlbum) |album| {
        log.debug("album cache hit: {s}", .{id});

        return .{
            .value = album,
            .lock = &self.cacheLock,
        };
    }

    self.cacheLock.unlockShared();

    log.debug("album cache miss: {s}", .{id});
    const album = try self.immichClient.getAlbum(id);

    try self.cacheAlbum(album);

    return self.getAlbum(id);
}

pub fn getAsset(self: *Self, id: []const u8) !LockedResource(Asset) {
    self.invalidateCacheOnTimeout();

    self.cacheLock.lockShared();

    const cachedAsset = self.assetCache.get(id);
    if (cachedAsset) |asset| {
        log.debug("asset cache hit: {s}", .{id});

        return .{
            .value = asset,
            .lock = &self.cacheLock,
        };
    }

    self.cacheLock.unlockShared();

    log.debug("asset cache miss: {s}", .{id});
    const asset = try self.immichClient.getAsset(id);

    try self.cacheAsset(asset);

    return self.getAsset(id);
}

fn setCacheTimeout(self: *Self) void {
    if (self.cacheInvalidationTimeout != null) {
        return;
    }

    const new_timeout = std.time.timestamp() + self.cache_timeout_seconds;
    self.cacheInvalidationTimeout = new_timeout;

    log.debug("Cache timeout set to {d} ({d}s)", .{ new_timeout, self.cache_timeout_seconds });
}

fn invalidateCacheOnTimeout(self: *Self) void {
    const timeout = self.cacheInvalidationTimeout orelse return;
    if (timeout > std.time.timestamp()) {
        return;
    }

    self.cacheLock.lock();

    self.cacheInvalidationTimeout = null;

    if (self.albumsCache) |albums| {
        for (albums) |album| {
            album.deinit(self.allocator);
        }
    }
    self.albumsCache = null;

    var albumIter = self.albumCache.valueIterator();
    while (albumIter.next()) |album| {
        album.deinit(self.allocator);
    }
    self.albumCache.clearRetainingCapacity();

    var assetIter = self.assetCache.valueIterator();
    while (assetIter.next()) |asset| {
        asset.deinit(self.allocator);
    }
    self.assetCache.clearRetainingCapacity();

    self.cacheLock.unlock();

    log.debug("Cache invalidated", .{});
}

fn cacheAlbums(self: *Self, albums: []const Album) void {
    self.cacheLock.lock();
    defer self.cacheLock.unlock();

    self.albumsCache = albums;
    self.setCacheTimeout();

    log.debug("Cached albums", .{});
}

fn cacheAlbum(self: *Self, album: Album) !void {
    errdefer |err| {
        log.err("Failed caching album {s}: {}", .{ album.id, err });
    }

    self.cacheLock.lock();
    defer self.cacheLock.unlock();

    try self.albumCache.put(album.id, album);
    for (album.assets) |asset| {
        const clonedAsset = try asset.clone(self.allocator);
        try self.assetCache.put(clonedAsset.id, clonedAsset);
    }

    self.setCacheTimeout();

    log.debug("Cached album {s}", .{album.id});
}

fn cacheAsset(self: *Self, asset: Asset) !void {
    errdefer |err| {
        log.err("Failed caching asset {s}: {}", .{ asset.id, err });
    }

    self.cacheLock.lock();
    defer self.cacheLock.unlock();

    try self.assetCache.put(asset.id, asset);

    self.setCacheTimeout();

    log.debug("Cached asset {s}", .{asset.id});
}
