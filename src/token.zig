const std = @import("std");
const testing = std.testing;
const mem = std.mem;
const log = std.log.scoped(.mustachez);
const assert = std.debug.assert;

const default_tag_start = "{{";
const default_tag_end = "}}";

pub const Tokenizer = struct {
    pub const State = enum {
        text,
        tag,
    };
    input: []const u8,
    alloc: mem.Allocator,
    tag_start: []const u8,
    tag_end: []const u8,

    state: State,
    token_start: usize,
    prev_newline: usize,
    brace_depth: usize,

    idx: usize,

    pub fn init(alloc: mem.Allocator, input: []const u8) Tokenizer {
        return .{
            .input = input,
            .alloc = alloc,
            .tag_start = default_tag_start,
            .tag_end = default_tag_end,
            .state = .text,
            .token_start = 0,
            .prev_newline = 0,
            .brace_depth = 0,
            .idx = 0,
        };
    }

    pub fn nextToken(self: *Tokenizer) DocToken.ParseError!?DocToken {
        assert(self.idx <= self.input.len);

        while (self.idx < self.input.len) {
            assert(self.tag_start.len != 0);
            assert(self.tag_end.len != 0);
            assert(self.idx >= self.token_start);

            const cc = self.input[self.idx];
            switch (self.state) {
                .text => {
                    if (std.mem.startsWith(u8, self.input[self.idx..], self.tag_start)) {
                        const text = self.input[self.token_start..self.idx];

                        defer {
                            self.state = .tag;
                            self.idx += self.tag_start.len;
                            self.token_start = self.idx;
                        }
                        return DocToken{ .text = text };
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
                        const tag_txt = self.input[self.token_start..self.idx];
                        const parsed_tag = try parseToken(self.alloc, tag_txt);
                        const old_tag_end_len = self.tag_end.len;

                        switch (parsed_tag.type) {
                            .delimiter_change => {
                                assert(parsed_tag.body.len == 2);
                                self.tag_start = parsed_tag.body[0];
                                self.tag_end = parsed_tag.body[1];
                            },
                            else => {},
                        }

                        defer {
                            self.state = .text;
                            self.idx += old_tag_end_len;
                            self.token_start = self.idx;
                        }
                        return DocToken{ .tag = parsed_tag };
                    }
                },
            }
            self.idx += 1;
        }

        assert(self.idx <= self.input.len);

        // return final token if necessary
        if (self.token_start < self.input.len) switch (self.state) {
            .tag => {
                log.err("File ends on a tag, this is invalid behaviour", .{});
                return error.TagAtEOF;
            },
            .text => {
                defer self.token_start = self.input.len;

                return DocToken{ .text = self.input[self.token_start..] };
            },
        };
        return null;
    }
};

pub const DocTokenTag = enum { text, tag };
pub const DocToken = union(DocTokenTag) {
    text: []const u8,
    tag: Token,

    pub const ParseError = error{TagAtEOF} || ParseTokenError || mem.Allocator.Error;
    pub fn parseSliceLeaky(
        alloc: mem.Allocator,
        input: []const u8,
    ) ParseError![]const DocToken {
        var list = std.ArrayList(DocToken).init(alloc);
        defer list.deinit();
        var state = Tokenizer.init(alloc, input);
        while (try state.nextToken()) |token| {
            try list.append(token);
        }

        trimStandaloneTokens(list.items);

        return try list.toOwnedSlice();
    }

    fn trimStandaloneTokens(tokens: []DocToken) void {
        for (0..tokens.len) |ti| {
            const i = tokens.len - 1 - ti;
            if (tokens[i] == .text) continue;
            const tag = tokens[i].tag;
            switch (tag.type) {
                .variable, .unescaped_variable => continue,
                else => {},
            }

            if ((i != 0) and tokens[i - 1] == .text) {
                const old_txt = tokens[i - 1].text;
                const target_txt = &tokens[i - 1].text;
                switch (findNewline(old_txt, .backward)) {
                    .found => |v| target_txt.* = old_txt[0 .. v + 1],
                    .non_whitespace => continue,
                    .not_found => {
                        if ((i - 1) == 0) {
                            // this token is the first one, trim to the start of the file as per spec.
                            target_txt.* = "";
                        } else continue;
                    },
                }
            }

            if ((i != (tokens.len - 1)) and tokens[i + 1] == .text) {
                const old_txt = tokens[i + 1].text;
                const next_newline_idx = switch (findNewline(old_txt, .forward)) {
                    .found => |v| v,
                    .non_whitespace, .not_found => continue,
                };
                tokens[i + 1].text = old_txt[next_newline_idx + 1 ..];
            }
        }
    }

    const NewlineRes = union(enum) {
        not_found,
        non_whitespace,
        found: usize,
    };
    fn findNewline(txt: []const u8, comptime direction: enum { forward, backward }) NewlineRes {
        for (0..txt.len) |i| {
            const idx: usize = switch (direction) {
                inline .forward => i,
                inline .backward => txt.len - 1 - i,
            };
            switch (txt[idx]) {
                '\n' => return .{ .found = idx },
                else => {
                    if (!std.ascii.isWhitespace(txt[idx])) return .non_whitespace;
                },
            }
        }
        return .not_found;
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
        trimmed = if (tag == .variable) trimmed else trimmed[1..];
    }
    trimmed = std.mem.trim(u8, trimmed, &std.ascii.whitespace);

    log.info("{s} -> trimmed: '{s}' (from {s})", .{ @tagName(tag), trimmed, input });

    const body: []const []const u8 = switch (tag) {
        .delimiter_change => blk: {
            break :blk try tmp_alloc.dupe(
                []const u8,
                &try parseDelims(trimmed),
            );
        },
        .comment => try tmp_alloc.dupe([]const u8, &.{trimmed}),
        else => try parseVariable(tmp_alloc, trimmed),
    };

    return Token{
        .type = tag,
        .body = body,
    };
}

const ParseDelimsError = error{ EmptyOpeningDelimiter, EmptyClosingDelimiter };
fn parseDelims(input: []const u8) ParseDelimsError![2][]const u8 {
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
    if (closing_start == (input.len)) return error.EmptyClosingDelimiter;

    return .{ input[0..opening_end], input[closing_start..] };
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
