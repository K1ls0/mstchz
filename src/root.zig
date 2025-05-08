const std = @import("std");
const mem = std.mem;

const LibraryConfiguration = @import("LibraryConfiguration.zig");

pub fn Mstchz(comptime config: LibraryConfiguration) type {
    return struct {
        pub const Hash = @import("Hash.zig");
        pub const hash_impl = @import("hash_impl/hash_impl.zig");
        pub const token = @import("token.zig");
        pub const tokens = @import("tokens.zig");
        pub const tokenizer = @import("tokenizer.zig");
        pub const render_state = @import("render_state.zig");

        pub const Token = token.Token;
        pub const TokenType = token.TokenType;
        pub const Tag = token.Tag;
        pub const TagType = token.TagType;

        pub const Tokenizer = tokenizer.Tokenizer(config);
        pub const Tokens = tokens.Tokens(config);
        pub const RenderState = render_state.RenderState(config);

        pub const PartialMap = RenderState.PartialMap;

        pub const Configuration = struct {
            dynamic_names: bool = false,
        };

        pub const RenderTemplateError = RenderState.RenderError || mem.Allocator.Error || Tokens.ParseError;
        pub fn renderTemplate(
            allocator: mem.Allocator,
            input: []const u8,
            hash: Hash,
            hash_ctx: Hash.Ctx,
            partials: *const PartialMap,
            writer: anytype,
        ) (RenderTemplateError || @TypeOf(writer).Error)!void {
            const tkns = try Tokens.parse(allocator, input);
            defer tkns.deinit();

            try renderTokens(
                allocator,
                tkns.value,
                hash,
                hash_ctx,
                partials,
                writer,
            );
        }

        pub fn renderTokens(
            allocator: mem.Allocator,
            tkns: []const Token,
            hash: Hash,
            hash_ctx: Hash.Ctx,
            partials: *const PartialMap,
            writer: anytype,
        ) (RenderState.RenderError || mem.Allocator.Error || @TypeOf(writer).Error)!void {
            var state = try RenderState.init(
                allocator,
                hash,
                hash_ctx,
                partials,
                tkns,
                .{},
            );
            defer state.deinit();
            try state.render(writer);
        }
    };
}

test {
    _ = @import("Hash.zig");
    _ = @import("tokenizer.zig");
    _ = @import("render_state.zig");
    _ = @import("Scopes.zig");
    _ = @import("token.zig");

    _ = @import("escape.zig");
    _ = @import("inserting_writer.zig");
    _ = @import("hash_impl/json.zig");
}
