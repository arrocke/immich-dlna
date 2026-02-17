const std = @import("std");

const Self = @This();

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

pub fn getAlbums(self: *Self) !std.json.Parsed([]Album) {
    var body = std.Io.Writer.Allocating.init(self.allocator);
    defer body.deinit();

    const url = try std.fmt.allocPrint(self.allocator, "{s}/albums", .{self.baseUrl});
    defer self.allocator.free(url);

    const response = try self.client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .extra_headers = &[_]std.http.Header{
            .{ .name = "x-api-key", .value = self.apiKey },
        },
        .response_writer = &body.writer,
    });

    if (response.status != .ok) {
        std.log.err("Request failed with status: {}\n", .{response.status});
        return error.HttpRequestFailed;
    }

    const albums: std.json.Parsed([]Album) = try std.json.parseFromSlice([]Album, self.allocator, body.written(), .{ .ignore_unknown_fields = true });

    return albums;
}

pub fn getAlbum(self: *Self, id: []const u8) !std.json.Parsed(Album) {
    var body = std.Io.Writer.Allocating.init(self.allocator);
    defer body.deinit();

    const url = try std.fmt.allocPrint(self.allocator, "{s}/albums/{s}", .{ self.baseUrl, id });
    defer self.allocator.free(url);

    const response = try self.client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .extra_headers = &[_]std.http.Header{
            .{ .name = "x-api-key", .value = self.apiKey },
        },
        .response_writer = &body.writer,
    });

    if (response.status != .ok) {
        std.log.err("Request failed with status: {}\n", .{response.status});
        return error.HttpRequestFailed;
    }

    const album: std.json.Parsed(Album) = try std.json.parseFromSlice(Album, self.allocator, body.written(), .{ .ignore_unknown_fields = true });

    return album;
}

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
    exifInfo: EixfInfo,
};
