const std = @import("std");
const build_options = @import("build_options");

const Self = @This();

const log = std.log.scoped(.Config);

cache_timeout: u32,
immich_api_key: []const u8,
immich_url: []const u8,
allocator: std.mem.Allocator,

const CONFIG_LOCATION = if (build_options.prod)
    "/etc/immich-dlna/immich-dlna.conf"
else
    "zig-out/immich-dlna.conf";

pub fn deinit(self: *const Self) void {
    self.allocator.free(self.immich_url);
    self.allocator.free(self.immich_api_key);
}

pub fn load(allocator: std.mem.Allocator) !Self {
    var configFile: std.fs.File = undefined;
    if (build_options.prod) {
        configFile = try std.fs.openFileAbsolute(CONFIG_LOCATION, .{});
    } else {
        configFile = try std.fs.cwd().openFile(CONFIG_LOCATION, .{});
    }
    defer configFile.close();

    var buf: [1024]u8 = undefined;
    var reader = configFile.reader(&buf);

    var settings = Self{
        .allocator = allocator,
        .cache_timeout = 30 * 60, // 30 minutes
        .immich_api_key = &[_]u8{},
        .immich_url = try allocator.dupe(u8, "http://localhost:2283"),
    };

    while (try reader.interface.takeDelimiter('\n')) |line| {
        const splitPos = std.mem.indexOfScalar(u8, line, '=') orelse {
            continue;
        };

        const key = line[0..splitPos];
        const value = line[(splitPos + 1)..];

        if (std.mem.eql(u8, key, "CACHE_TIMEOUT_SECONDS")) {
            settings.cache_timeout = std.fmt.parseInt(u32, value, 10) catch {
                log.warn("Invalid cache_timeout, falling back to {d}", .{settings.cache_timeout});
                continue;
            };
        } else if (std.mem.eql(u8, key, "IMMICH_API_KEY")) {
            settings.immich_api_key = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "IMMICH_URL")) {
            settings.immich_url = try allocator.dupe(u8, value);
        } else {
            log.debug("Ignoring unrecognized setting {s}", .{key});
        }
    }

    var env = try std.process.getEnvMap(allocator);
    defer env.deinit();

    if (env.get("IMMICH_API_KEY")) |immich_api_key| {
        log.debug("Reading IMMICH_API_KEY", .{});
        settings.immich_api_key = try allocator.dupe(u8, immich_api_key);
    }
    if (env.get("IMMICH_URL")) |immich_url| {
        log.debug("Reading IMMICH_URL", .{});
        settings.immich_url = try allocator.dupe(u8, immich_url);
    }

    if (settings.immich_api_key.len == 0 or settings.immich_url.len == 0) {
        log.err("IMMICH_API_KEY and IMMICH_URL settings required", .{});
        return error.InvalidConfig;
    }

    return settings;
}
