const std = @import("std");
const ImmichApi = @import("./immich-api.zig");

const Self = @This();

allocator: std.mem.Allocator,
immichClient: ImmichApi,
