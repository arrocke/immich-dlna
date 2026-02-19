const std = @import("std");
const ImmichStore = @import("./immich_store.zig");

const Self = @This();

allocator: std.mem.Allocator,
immichStore: ImmichStore,
port: u16,
dlna_origin: []const u8,
