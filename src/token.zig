const std = @import("std");
const testing = std.testing;
const mem = std.mem;
const log = std.log.scoped(.mustachez);
const assert = std.debug.assert;

const default_tag_start = "{{";
const default_tag_end = "}}";

pub const DocumentStructureTokenizer = struct {
    input: []const u8,
    alloc: mem.Allocator,
    tag_start: []const u8,
    tag_end: []const u8,

    state: DocumentStructureTokenTag,
    token_start: usize,
    brace_depth: usize,

    idx: usize,

    pub fn init(alloc: mem.Allocator, input: []const u8) DocumentStructureTokenizer {
        return .{
            .input = input,
            .alloc = alloc,
            .tag_start = default_tag_start,
            .tag_end = default_tag_end,
            .state = .text,
            .token_start = 0,
            .brace_depth = 0,
            .idx = 0,
        };
    }

    pub fn nextToken(self: *DocumentStructureTokenizer) DocumentStructureToken.ParseError!?DocumentStructureToken {
        assert(self.idx <= self.input.len);

        while (self.idx < self.input.len) {
            assert(self.tag_start.len != 0);
            assert(self.tag_end.len != 0);

            const cc = self.input[self.idx];
            switch (self.state) {
                .text => {
                    if (std.mem.startsWith(u8, self.input[self.idx..], self.tag_start)) {
                        const new = DocumentStructureToken{
                            .text = self.input[self.token_start..self.idx],
                        };
                        self.state = .tag;
                        self.idx += self.tag_start.len;
                        self.token_start = self.idx;
                        return new;
                    }
                },
                .tag => {
                    const outside_braces = self.brace_depth == 0;
                    switch (cc) {
                        '{' => self.brace_depth += 1,
                        '}' => {
                            if (self.brace_depth != 0) self.brace_depth -= 1;
                        },
                        else => {},
                    }

                    if (std.mem.startsWith(u8, self.input[self.idx..], self.tag_end) and outside_braces) {
                        const parsed_tag = try parseToken(self.alloc, self.input[self.token_start..self.idx]);
                        if (parsed_tag.type == .delimiter_change) {
                            assert(parsed_tag.body.len == 2);
                            self.tag_start = parsed_tag.body[0];
                            self.tag_end = parsed_tag.body[0];
                        }
                        const new = DocumentStructureToken{ .tag = parsed_tag };
                        self.state = .text;
                        self.idx += self.tag_end.len;
                        self.token_start = self.idx;
                        return new;
                    }
                },
            }
            self.idx += 1;
        }

        assert(self.idx <= self.input.len);

        if (self.token_start < self.input.len) switch (self.state) {
            .tag => {
                log.err("File ends on a tag, this is invalid behaviour", .{});
                return error.TagAtEOF;
            },
            .text => {
                const new = DocumentStructureToken{
                    .text = self.input[self.token_start..],
                };
                self.token_start = self.input.len;
                return new;
            },
        };
        return null;
    }
};

pub const DocumentStructureTokenTag = enum { text, tag };
pub const DocumentStructureToken = union(DocumentStructureTokenTag) {
    text: []const u8,
    tag: Token,

    pub const ParseError = error{TagAtEOF} || ParseTokenError || mem.Allocator.Error;
    pub fn parseSliceLeaky(
        alloc: mem.Allocator,
        input: []const u8,
    ) ParseError![]const DocumentStructureToken {
        var list = std.ArrayList(DocumentStructureToken).init(alloc);
        defer list.deinit();
        var state = DocumentStructureTokenizer.init(alloc, input);
        while (try state.nextToken()) |token| {
            try list.append(token);
        }
        return try list.toOwnedSlice();
    }
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
    //defer {
    //    std.debug.print("||parse token out: '{s}'||", .{trimmed});
    //}
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
        .comment => blk: {
            break :blk &.{trimmed};
        },
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
