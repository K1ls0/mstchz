const std = @import("std");
const mem = std.mem;
const log = std.log.scoped(.@"mustachez.Partial");

const token = @import("token.zig");

const Partial = @This();

tokens: []const token.DocToken,

pub fn initFromSliceLeaky(alloc: mem.Allocator, input: []const u8) token.ParseTokenError!Partial {
    const tokens = try token.DocToken.parseSliceLeaky(alloc, input);

    return Partial{ .tokens = tokens };
}

pub fn deinit(self: *Partial) void {
    self.arena.deinit();
}
