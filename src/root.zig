const std = @import("std");
const Io = std.Io;
const testing = std.testing;
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

            //<<<<<<< HEAD
            //    pub const RenderError = error{
            //        Unsupported,
            //        NoObject,
            //        NoField,
            //    };
            //    pub fn render(self: *State, writer: *Io.Writer) (RenderError || Io.Writer.Error)!void {
            //        for (self.input) |ctoken| {
            //            switch (ctoken) {
            //                .text => |txt| try writer.writeAll(txt),
            //                .tag => |t| switch (t.type) {
            //                    .comment => {},
            //                    .variable => {
            //                        var cval = self.ctx;
            //                        for (t.body) |v| {
            //                            switch (cval) {
            //                                .object => |o| {
            //                                    cval = o.get(v) orelse {
            //                                        log.err("field '{s}' not available!", .{v});
            //                                        return error.NoField;
            //                                    };
            //                                },
            //                                else => {
            //                                    log.err("Trying to access '{s}' on value of type {s}", .{ v, @tagName(cval) });
            //                                    return error.NoObject;
            //                                },
            //                            }
            //                        }
            //                    },
            //                    else => {
            //                        log.err("unsupported token {s}", .{@tagName(t.type)});
            //                        return error.Unsupported;
            //                    },
            //                },
            //            }
            //=======
            try renderTokens(
                allocator,
                tkns.value,
                hash,
                hash_ctx,
                partials,
                writer,
            );
            //>>>>>>> 61d4dd7012c26c49d0c2a68d56be699c46dfb922
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
