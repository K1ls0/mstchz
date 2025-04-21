const std = @import("std");
const mem = std.mem;

pub const token = @import("token.zig");
pub const Token = token.Token;
pub const TokenType = token.TokenType;
pub const Tag = token.Tag;
pub const TagType = token.TagType;

//pub const Tokenizer = @import("Tokenizer.zig");
//pub const parseSliceLeaky = Tokenizer.parseSliceLeaky;

pub const Tokens = @import("Tokens.zig");

pub const Hash = @import("Hash.zig");
pub const RenderState = @import("RenderState.zig");
pub const PartialMap = RenderState.PartialMap;

pub const hash_impl = @import("hash_impl/hash_impl.zig");

pub const RenderTemplateError = RenderState.RenderError || mem.Allocator.Error || Tokens.ParseError;
pub fn renderTemplate(
    allocator: mem.Allocator,
    input: []const u8,
    hash: Hash,
    partials: *const PartialMap,
    writer: anytype,
    options: struct {
        hash_ctx: Hash.Ctx,
    },
) (RenderTemplateError || @TypeOf(writer).Error)!void {
    const tokens = try Tokens.parse(allocator, input);
    defer tokens.deinit();

    try renderTokens(
        allocator,
        tokens.value,
        hash,
        partials,
        writer,
        .{ .hash_ctx = options.hash_ctx },
    );
}

pub fn renderTokens(
    allocator: mem.Allocator,
    tokens: []const Token,
    hash: Hash,
    partials: *const PartialMap,
    writer: anytype,
    options: struct {
        hash_ctx: Hash.Ctx,
    },
) (RenderState.RenderError || mem.Allocator.Error || @TypeOf(writer).Error)!void {
    var state = try RenderState.init(
        allocator,
        hash,
        options.hash_ctx,
        partials,
        tokens,
        .{},
    );
    defer state.deinit();
    try state.render(writer);
}

test {
    _ = @import("Hash.zig");
    _ = @import("Tokenizer.zig");
    _ = @import("RenderState.zig");
    _ = @import("Scopes.zig");
    _ = @import("token.zig");

    _ = @import("escape.zig");
    _ = @import("inserting_writer.zig");
    _ = @import("hash_impl/json.zig");
}
