const std = @import("std");

const Self = @This();

allocator: std.mem.Allocator,
immichBaseUrl: []const u8,
immichApiKey: []const u8,
