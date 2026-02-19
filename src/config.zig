const std = @import("std");
const build_options = @import("build_options");

const Self = @This();

const log = std.log.scoped(.Config);

cache_timeout: u32,
immich_api_key: []const u8,
immich_url: []const u8,
dlna_origin: []const u8,
port: u16,
allocator: std.mem.Allocator,

const CONFIG_LOCATION = if (build_options.prod)
    "/etc/immich-dlna/immich-dlna.conf"
else
    "zig-out/immich-dlna.conf";

pub fn deinit(self: *const Self) void {
    self.allocator.free(self.immich_url);
    self.allocator.free(self.immich_api_key);
}

fn readConfigFile(self: *Self) !void {
    var configFile: std.fs.File = undefined;
    if (build_options.prod) {
        configFile = std.fs.openFileAbsolute(CONFIG_LOCATION, .{}) catch |err| {
            if (err == std.fs.File.OpenError.FileNotFound) {
                return;
            }
            return err;
        };
    } else {
        configFile = std.fs.cwd().openFile(CONFIG_LOCATION, .{}) catch |err| {
            if (err == std.fs.File.OpenError.FileNotFound) {
                return;
            }
            return err;
        };
    }
    defer configFile.close();

    var buf: [1024]u8 = undefined;
    var reader = configFile.reader(&buf);

    while (try reader.interface.takeDelimiter('\n')) |line| {
        const splitPos = std.mem.indexOfScalar(u8, line, '=') orelse {
            continue;
        };

        const key = line[0..splitPos];
        const value = line[(splitPos + 1)..];

        if (std.mem.eql(u8, key, "CACHE_TIMEOUT_SECONDS")) {
            self.cache_timeout = std.fmt.parseInt(u32, value, 10) catch {
                log.warn("Invalid cache_timeout, falling back to {d}", .{self.cache_timeout});
                continue;
            };
        } else if (std.mem.eql(u8, key, "IMMICH_API_KEY")) {
            self.immich_api_key = try self.allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "IMMICH_URL")) {
            self.immich_url = try self.allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "PORT")) {
            self.port = std.fmt.parseInt(u16, value, 10) catch blk: {
                log.warn("Invalid port, falling back to {d}", .{self.port});
                break :blk self.port;
            };
        } else if (std.mem.eql(u8, key, "DLNA_ORIGIN")) {
            self.dlna_origin = try self.allocator.dupe(u8, value);
        } else {
            log.debug("Ignoring unrecognized setting {s}", .{key});
        }
    }
}

fn readEnvVars(self: *Self) !void {
    var env = try std.process.getEnvMap(self.allocator);
    defer env.deinit();

    if (env.get("IMMICH_API_KEY")) |immich_api_key| {
        log.debug("Reading IMMICH_API_KEY", .{});
        self.immich_api_key = try self.allocator.dupe(u8, immich_api_key);
    }
    if (env.get("IMMICH_URL")) |immich_url| {
        log.debug("Reading IMMICH_URL", .{});
        self.immich_url = try self.allocator.dupe(u8, immich_url);
    }
    if (env.get("PORT")) |portStr| {
        log.debug("Reading PORT", .{});
        self.port = std.fmt.parseInt(u16, portStr, 10) catch blk: {
            log.warn("Invalid port, falling back to {d}", .{self.port});
            break :blk self.port;
        };
    }
    if (env.get("DLNA_ORIGIN")) |origin| {
        log.debug("Reading DLNA_ORIGIN", .{});
        self.dlna_origin = try self.allocator.dupe(u8, origin);
    }
}

pub fn validate(self: *Self) !void {
    var invalid_config = false;
    if (self.immich_api_key.len == 0) {
        log.err("IMMICH_API_KEY required", .{});
        invalid_config = true;
    }
    if (self.immich_url.len == 0) {
        log.err("IMMICH_URL required", .{});
        invalid_config = true;
    }

    if (self.dlna_origin.len == 0) {
        const origin = try std.fmt.allocPrint(self.allocator, "http://localhost:{d}", .{self.port});
        log.warn("Missing DLNA origin, falling back to {s}", .{origin});
        self.dlna_origin = origin;
    }

    if (invalid_config) {
        return error.InvalidConfig;
    }
}

pub fn load(allocator: std.mem.Allocator) !Self {
    var settings = Self{
        .allocator = allocator,
        .cache_timeout = 30 * 60, // 30 minutes
        .immich_api_key = &[_]u8{},
        .immich_url = try allocator.dupe(u8, "http://localhost:2283"),
        .port = 8200,
        .dlna_origin = "",
    };

    try settings.readConfigFile();
    try settings.readEnvVars();

    try settings.validate();

    return settings;
}
