const std = @import("std");
const mem = std.mem;

const tokenizer = @import("tokenizer.zig");
const token = @import("token.zig");

const LibraryConfiguration = @import("LibraryConfiguration.zig");

pub fn Tokens(comptime config: LibraryConfiguration) type {
    return struct {
        const Self = @This();

        const Tokenizer = tokenizer.Tokenizer(config);

        allocator: mem.Allocator,
        value: []const token.Token,

        pub const ParseError = Tokenizer.ParseError;
        pub fn parse(allocator: mem.Allocator, input: []const u8) ParseError!Self {
            var list = std.ArrayList(token.Token).empty;
            defer list.deinit(allocator);

            var tknizer = Tokenizer.init(allocator, input);
            while (try tknizer.nextToken()) |ctoken| {
                try list.append(allocator, ctoken);
            }
            Tokenizer.trimStandaloneTokens(list.items);
            return .{ .allocator = allocator, .value = try list.toOwnedSlice(allocator) };
        }

        pub fn deinit(self: Self) void {
            for (self.value) |ctoken| {
                switch (ctoken) {
                    .tag => |t| self.allocator.free(t.body),
                    .text => {},
                }
            }
            self.allocator.free(self.value);
        }
    };
}
