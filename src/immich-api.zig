const std = @import("std");

const Self = @This();

pub const Album = struct {
    id: []u8,
    albumName: []u8,
    updatedAt: []u8,
    assets: []Asset,
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
};

apiKey: []const u8,
baseUrl: []const u8,
allocator: std.mem.Allocator,
client: std.http.Client,

pub fn init(allocator: std.mem.Allocator, apiKey: []const u8, baseUrl: []const u8) Self {
    return .{
        .apiKey = apiKey,
        .baseUrl = baseUrl,
        .allocator = allocator,
        .client = std.http.Client{ .allocator = allocator },
    };
}

pub fn deinit(self: *Self) void {
    self.client.deinit();
}

const GetRequestError = error{
    HttpRequestFailed,
    OutOfMemory,
    FailedStatusCode,
};

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

    const response = self.client.fetch(.{
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

pub fn getAlbums(self: *Self) !std.json.Parsed([]Album) {
    return self.get([]Album, "/albums", .{});
}

pub fn getAlbum(self: *Self, id: []const u8) !std.json.Parsed(Album) {
    return self.get(Album, "/albums/{s}", .{id});
}

pub fn getAsset(self: *Self, id: []const u8) !std.json.Parsed(Asset) {
    return self.get(Asset, "/assets/{s}", .{id});
}
