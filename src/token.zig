const std = @import("std");
const testing = std.testing;
const mem = std.mem;
const log = std.log.scoped(.mustachez);
const assert = std.debug.assert;

const TPos = struct { token: usize, position: usize };
const TRes = union(enum) {
    not_standalone,
    empty,
    pos: TPos,
};

pub const TokenType = enum { text, tag };
pub const Token = union(TokenType) {
    text: []const u8,
    tag: Tag,

    pub fn debugPrint(self: Token) void {
        switch (self) {
            .text => |txt| {
                std.debug.print("TEXT: {} '{s}'\n", .{ txt.len, txt });
            },
            .tag => |t| {
                std.debug.print("TAG: '{s}' (standalone prefix: '{?s}') body: ", .{ @tagName(t.type), t.standalone_line_prefix });
                for (t.body, 0..) |p, i| {
                    if (i != 0) std.debug.print(":", .{});
                    std.debug.print("'{s}'", .{p});
                }
                std.debug.print("\n", .{});
            },
        }
    }
};

pub const TagType = enum {
    variable,
    section_open,
    section_close,
    inverted_section_open,
    unescaped_variable,
    comment,
    partial,
    partial_dynamic,
    delimiter_change,

    pub fn fromSpecifier(c: u8) TagType {
        return switch (c) {
            '>' => .partial,
            '^' => .inverted_section_open,
            '/' => .section_close,
            '&' => .unescaped_variable,
            '#' => .section_open,
            '!' => .comment,
            else => .variable,
        };
    }
};

pub const Tag = struct {
    type: TagType,
    body: []const []const u8,
    standalone_line_prefix: ?[]const u8 = null,
};
