const std = @import("std");
const mem = std.mem;

const token = @import("token.zig");
const Tokenizer = @import("Tokenizer.zig");

const Tokens = @This();

allocator: mem.Allocator,
value: []const token.Token,

pub const ParseError = Tokenizer.ParseError;
pub fn parse(allocator: mem.Allocator, input: []const u8) ParseError!Tokens {
    var list = std.ArrayList(token.Token).init(allocator);
    defer list.deinit();

    var tokenizer = Tokenizer.init(allocator, input);
    while (try tokenizer.nextToken()) |ctoken| {
        try list.append(ctoken);
    }
    Tokenizer.trimStandaloneTokens(list.items);
    return .{ .allocator = allocator, .value = try list.toOwnedSlice() };
}

pub fn deinit(self: Tokens) void {
    for (self.value) |ctoken| {
        switch (ctoken) {
            .tag => |t| self.allocator.free(t.body),
            .text => {},
        }
    }
    self.allocator.free(self.value);
}
