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

    std.log.info("[ImmichApi.getAlbums] cache miss", .{});

    self.cacheLock.unlockShared();

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

pub fn getAlbum(self: *Self, id: []const u8) !LockedResource(*Album) {
    self.cacheLock.lockShared();

    const entry = self.albumCache.getOrPut(id) catch |err| {
        self.cacheLock.unlockShared();
        return err;
    };
    if (entry.found_existing) {
        std.log.info("[ImmichApi.getAlbum] cache hit: {s}", .{id});

        return LockedResource(*Album){
            .value = entry.value_ptr,
            .lock = &self.cacheLock,
        };
    } else {
        self.cacheLock.unlockShared();

        std.log.info("[ImmichApi.getAlbum] cache miss: {s}", .{id});
        const album = try self.immichClient.getAlbum(id);

        self.cacheLock.lock();
        entry.value_ptr.* = album;
        for (album.assets) |asset| {
            self.assetCache.put(asset.id, asset) catch |err| {
                self.cacheLock.unlock();
                return err;
            };
        }
        self.cacheLock.unlock();

        self.cacheLock.lockShared();
        return LockedResource(*Album){
            .value = entry.value_ptr,
            .lock = &self.cacheLock,
        };
    }
}

pub fn getAsset(self: *Self, id: []const u8) !LockedResource(*Asset) {
    self.cacheLock.lockShared();

    const entry = self.assetCache.getOrPut(id) catch |err| {
        self.cacheLock.unlockShared();
        return err;
    };
    if (entry.found_existing) {
        std.log.info("[ImmichApi.getAsset] cache hit: {s}", .{id});
        return LockedResource(*Asset){
            .value = entry.value_ptr,
            .lock = &self.cacheLock,
        };
    } else {
        self.cacheLock.unlockShared();

        std.log.info("[ImmichApi.getAsset] cache miss: {s}", .{id});
        const asset = try self.immichClient.getAsset(id);

        self.cacheLock.lock();
        entry.value_ptr.* = asset;
        self.cacheLock.unlock();

        self.cacheLock.lockShared();
        return LockedResource(*Asset){
            .value = entry.value_ptr,
            .lock = &self.cacheLock,
        };
    }
}
