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

    pub const ParseError = error{TagAtEOF} || ParseTokenError || mem.Allocator.Error;
    //pub fn parseSliceLeaky(
    //    alloc: mem.Allocator,
    //    input: []const u8,
    //) ParseError![]const DocumentStructureToken {
    //    var list = std.ArrayList(DocumentStructureToken).empty;
    //    defer list.deinit(alloc);
    //    var state = DocumentStructureTokenizer.init(alloc, input);
    //    while (try state.nextToken()) |token| {
    //        try list.append(alloc, token);
    //    }
    //    return try list.toOwnedSlice(alloc);
    //}

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

pub const ParseTokenError = ParseDelimsError || ParseVariableError || mem.Allocator.Error;

//pub fn parseToken(tmp_alloc: mem.Allocator, input: []const u8) ParseTokenError!Token {
//    var trimmed = std.mem.trimEnd(u8, input, &std.ascii.whitespace);
//    //defer {
//    //    std.debug.print("||parse token out: '{s}'||", .{trimmed});
//    //}
//    assert(trimmed.len > 0);
//    var tag: TokenTag = .variable;
//    if ((trimmed[0] == '{') and (trimmed[trimmed.len - 1] == '}')) {
//        tag = .unescaped_variable;
//        trimmed = trimmed[1..(trimmed.len - 1)];
//    } else if ((trimmed[0] == '=') and (trimmed[trimmed.len - 1] == '=')) {
//        tag = .delimiter_change;
//        trimmed = trimmed[1..(trimmed.len - 1)];
//    } else {
//        tag = TokenTag.fromSpecifier(input[0]);
//        trimmed = trimmed[1..];
//    }
//    trimmed = std.mem.trim(u8, trimmed, &std.ascii.whitespace);
//
//    log.debug("{s} -> trimmed: '{s}'", .{ @tagName(tag), trimmed });
//
//    const body: []const []const u8 = switch (tag) {
//        .delimiter_change => try parseDelims(trimmed),
//        .comment => blk: {
//            break :blk &.{trimmed};
//        },
//        else => try parseVariable(tmp_alloc, trimmed),
//    };
//
//    return Token{
//        .type = tag,
//        .body = body,
//    };
//}

const ParseDelimsError = error{ EmptyOpeningDelimiter, EmptyClosingDelimiter };
fn parseDelims(input: []const u8) ParseDelimsError!*const [2][]const u8 {
    assert(input.len > 0);
    log.debug("Trying to parse delimiters from: '{s}'", .{input});

    var state: enum { opening, whitespace } = .opening;
    var opening_end: usize = 0;
    var closing_start: usize = input.len - 1;
    loop_blk: for (input, 0..) |cc, i| {
        switch (state) {
            .opening => {
                if (std.ascii.isWhitespace(cc)) {
                    if (i == 0) return error.EmptyOpeningDelimiter;
                    opening_end = i;
                    state = .whitespace;
                }
            },
            .whitespace => {
                if (!std.ascii.isWhitespace(cc)) {
                    closing_start = i;
                    break :loop_blk;
                }
            },
        }
    }
    if (closing_start == (input.len - 1)) return error.EmptyClosingDelimiter;

    return &.{ input[0..opening_end], input[closing_start..] };
}

const ParseVariableError = error{ WhitespaceInVariable, ZeroLenVariable } || mem.Allocator.Error;

fn parseVariable(alloc: mem.Allocator, input: []const u8) ParseVariableError![]const []const u8 {
    var list = std.ArrayListUnmanaged([]const u8).empty;

    if (input.len == 1 and input[0] == '.') return &.{}; // Special case: current

    var cstart: usize = 0;
    for (input, 0..) |cc, i| {
        switch (cc) {
            '.' => {
                const var_name = input[cstart..i];
                if (var_name.len == 0) return error.ZeroLenVariable;
                try list.append(alloc, var_name);
                cstart = i + 1;
            },
            else => {
                if (std.ascii.isWhitespace(cc)) return error.WhitespaceInVariable;
            },
        }
    }
    {
        const var_name = input[cstart..input.len];
        if (var_name.len == 0) return error.ZeroLenVariable;
        try list.append(alloc, var_name);
    }
    return try list.toOwnedSlice(alloc);
}
test "Token.parse.simple" {
    //parseToken();
}
