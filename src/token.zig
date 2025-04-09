const std = @import("std");
const testing = std.testing;
const mem = std.mem;
const log = std.log.scoped(.mustachez);
const assert = std.debug.assert;

const default_tag_start = "{{";
const default_tag_end = "}}";

pub const DocumentStructureToken = struct {
    pub const Tag = enum { text, tag };
    tag: Tag,
    body: Body,

    pub const ParseError = error{TagAtEOF} || ParseTokenError || mem.Allocator.Error;
    pub fn parseSliceLeaky(
        alloc: mem.Allocator,
        input: []const u8,
    ) ParseError![]const DocumentStructureToken {
        var doc_struct_tokens = std.ArrayListUnmanaged(DocumentStructureToken).empty;
        if (input.len == 0) return doc_struct_tokens.items;

        var tag_start: []const u8 = default_tag_start;
        var tag_end: []const u8 = default_tag_end;

        //var text_state: enum { text, tag } = .text;

        var state: Tag = .text;
        var token_start: usize = 0;
        var brace_depth: usize = 0;

        var idx: usize = 0;
        while (idx < input.len) {
            assert(tag_start.len != 0);
            assert(tag_end.len != 0);

            const cc = input[idx];
            switch (state) {
                .text => {
                    if (std.mem.startsWith(u8, input[idx..], tag_start)) {
                        try doc_struct_tokens.append(alloc, DocumentStructureToken{
                            .tag = .text,
                            .body = .{ .s = input[token_start..idx] },
                        });
                        state = .tag;
                        idx += tag_start.len;
                        token_start = idx;
                        continue; // Don't increment at the end
                    }
                },
                .tag => {
                    const outside_braces = brace_depth == 0;
                    switch (cc) {
                        '{' => brace_depth += 1,
                        '}' => {
                            if (brace_depth != 0) brace_depth -= 1;
                        },
                        else => {},
                    }

                    if (std.mem.startsWith(u8, input[idx..], tag_end) and outside_braces) {
                        const parsed_tag = try parseToken(alloc, input[token_start..idx]);
                        if (parsed_tag.type == .delimiter_change) {
                            assert(parsed_tag.body.len == 2);
                            tag_start = parsed_tag.body[0];
                            tag_end = parsed_tag.body[0];
                        }
                        try doc_struct_tokens.append(alloc, DocumentStructureToken{
                            .tag = .tag,
                            .body = .{ .t = parsed_tag },
                        });
                        //try doc_struct_tokens.append(alloc, DocumentStructureToken{
                        //    .tag = state,
                        //    .s = input[token_start..idx],
                        //});
                        state = .text;
                        idx += tag_end.len;
                        token_start = idx;
                        continue; // Don't increment at the end
                    }
                },
            }
            idx += 1;
        }

        if (token_start < input.len) switch (state) {
            .tag => {
                log.err("File ends on a tag, this is invalid behaviour", .{});
                return error.TagAtEOF;
            },
            .text => {
                try doc_struct_tokens.append(alloc, DocumentStructureToken{
                    .tag = state,
                    .body = .{ .s = input[token_start..] },
                });
                token_start = input.len;
            },
        };

        return try doc_struct_tokens.toOwnedSlice(alloc);
    }

    pub const Body = union {
        s: []const u8,
        t: Token,
    };
};

pub const TokenTag = enum {
    variable,
    section_open,
    section_close,
    inverted_section_open,
    unescaped_variable,
    comment,
    partial,
    delimiter_change,

    pub fn fromSpecifier(c: u8) TokenTag {
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

pub const Token = struct {
    type: TokenTag,
    body: []const []const u8,
};

pub const ParseTokenError = ParseDelimsError || ParseVariableError || mem.Allocator.Error;

pub fn parseToken(tmp_alloc: mem.Allocator, input: []const u8) ParseTokenError!Token {
    var trimmed = std.mem.trimRight(u8, input, &std.ascii.whitespace);
    assert(trimmed.len > 0);
    var tag: TokenTag = .variable;
    if ((trimmed[0] == '{') and (trimmed[trimmed.len - 1] == '}')) {
        tag = .unescaped_variable;
        trimmed = trimmed[1..(trimmed.len - 1)];
    } else if ((trimmed[0] == '=') and (trimmed[trimmed.len - 1] == '=')) {
        tag = .delimiter_change;
        trimmed = trimmed[1..(trimmed.len - 1)];
    } else {
        tag = TokenTag.fromSpecifier(input[0]);
        trimmed = trimmed[1..];
    }
    trimmed = std.mem.trim(u8, trimmed, &std.ascii.whitespace);

    log.debug("{s} -> trimmed: '{s}'", .{ @tagName(tag), trimmed });

    const body: []const []const u8 = switch (tag) {
        .delimiter_change => try parseDelims(trimmed),
        .comment => &.{trimmed},
        else => try parseVariable(tmp_alloc, trimmed),
    };

    return Token{
        .type = tag,
        .body = body,
    };
}

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
