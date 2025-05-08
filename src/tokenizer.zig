const std = @import("std");
const mem = std.mem;
const log = std.log.scoped(.zmstch);
const assert = std.debug.assert;
const testing = std.testing;

const LibraryConfiguration = @import("LibraryConfiguration.zig");
const token = @import("token.zig");
const Token = token.Token;
const Tag = token.Tag;
const TagType = token.TagType;

const default_tag_start = "{{";
const default_tag_end = "}}";

pub const State = enum {
    text,
    tag,
};

pub fn Tokenizer(comptime config: LibraryConfiguration) type {
    return struct {
        const Self = @This();

        input: []const u8,
        alloc: mem.Allocator,
        tag_start: []const u8,
        tag_end: []const u8,

        state: State,
        token_start: usize,
        prev_newline: usize,
        brace_depth: usize,
        standalone_range: ?struct { start: usize, len: usize },

        idx: usize,

        pub fn init(alloc: mem.Allocator, input: []const u8) Self {
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
                .standalone_range = .{ .start = 0, .len = 0 },
            };
        }

        pub const ParseError = error{TagAtEOF} || ParseTokenError || mem.Allocator.Error;
        pub fn nextToken(self: *Self) ParseError!?Token {
            assert(self.idx <= self.input.len);

            while (self.idx < self.input.len) {
                assert(self.tag_start.len != 0);
                assert(self.tag_end.len != 0);
                assert(self.idx >= self.token_start);

                const cc = self.input[self.idx];
                switch (self.state) {
                    .text => {
                        if (cc == '\n') {
                            // Newline, old token ends here (for convenience),
                            const next_start = self.idx + 1;
                            self.standalone_range = .{ .start = next_start, .len = 0 };

                            const txt = self.input[self.token_start .. self.idx + 1];
                            self.state = .text;
                            self.idx += 1;
                            self.token_start = next_start;
                            if (txt.len != 0) return Token{ .text = txt };
                        }

                        if (std.mem.startsWith(u8, self.input[self.idx..], self.tag_start)) {
                            // Start new tag and set standalone prefix bounds
                            if (self.standalone_range) |*s| s.len = self.idx - s.start;

                            const txt = self.input[self.token_start..self.idx];
                            self.state = .tag;
                            self.token_start = self.idx;
                            self.idx += self.tag_start.len;
                            return Token{ .text = txt };
                        }
                        if (!std.ascii.isWhitespace(cc) and self.state == .text) {
                            // this is not a whitespace, reset to non-standalone
                            self.standalone_range = null;
                        }
                    },
                    .tag => {
                        switch (cc) {
                            '{' => {
                                self.brace_depth += 1;
                                self.idx += 1;
                                continue;
                            },
                            '}' => {
                                if (self.brace_depth != 0) {
                                    self.brace_depth -= 1;
                                    self.idx += 1;
                                    continue;
                                }
                            },
                            else => {},
                        }

                        const reached_end_tag = std.mem.startsWith(u8, self.input[self.idx..], self.tag_end);
                        if (self.brace_depth == 0 and reached_end_tag) {
                            const tag_end_idx = self.idx + self.tag_end.len;
                            const tag_txt = self.input[self.token_start + self.tag_start.len .. self.idx];
                            var parsed_tag = try parseToken(self.alloc, tag_txt);

                            // previous token was a standalone token
                            if (self.standalone_range) |*standalone_range| {
                                const standalone_end_found = switch (self.lookAheadToNewlineOrEnd(tag_end_idx)) {
                                    .newline, .end => true,
                                    .non_whitespace => false,
                                };

                                if (standalone_end_found) {
                                    const start = standalone_range.start;
                                    const len = standalone_range.len;
                                    parsed_tag.standalone_line_prefix = self.input[start .. start + len];
                                }
                            }

                            if (parsed_tag.type == .delimiter_change) {
                                assert(parsed_tag.body.len == 2);

                                self.tag_start = parsed_tag.body[0];
                                self.tag_end = parsed_tag.body[1];
                            }

                            const ctoken = Token{ .tag = parsed_tag };
                            self.standalone_range = null;
                            self.state = .text;
                            self.idx = tag_end_idx;
                            self.token_start = self.idx;
                            return ctoken;
                        }
                    },
                }
                self.idx += 1;
            }

            assert(self.idx <= self.input.len);

            // return final token if necessary
            if (self.token_start < self.input.len) switch (self.state) {
                .tag => {
                    log.err("File ends on a tag, this is not allowed", .{});
                    return error.TagAtEOF;
                },
                .text => {
                    defer self.token_start = self.input.len;

                    return Token{ .text = self.input[self.token_start..] };
                },
            };
            return null;
        }

        fn lookAheadToNewlineOrEnd(self: Self, start: usize) union(enum) {
            newline: usize,
            end,
            non_whitespace: usize,
        } {
            for (self.input[start..], 0..) |cc, i| {
                if (cc == '\n') return .{ .newline = i };
                if (!std.ascii.isWhitespace(cc)) return .{ .non_whitespace = i };
            }
            return .end;
        }

        pub const ParseTokenError = error{
            EmptyToken,
        } || ParseDelimsError || ParseVariableError || mem.Allocator.Error;

        pub fn parseToken(
            alloc: mem.Allocator,
            input: []const u8,
        ) ParseTokenError!Tag {
            var trimmed = std.mem.trimRight(u8, input, &std.ascii.whitespace);
            if (trimmed.len == 0) return error.EmptyToken;

            var tag: TagType = .variable;
            if ((trimmed[0] == '{') and (trimmed[trimmed.len - 1] == '}')) {
                tag = .unescaped_variable;
                trimmed = trimmed[1..(trimmed.len - 1)];
            } else if ((trimmed[0] == '=') and (trimmed[trimmed.len - 1] == '=')) {
                tag = .delimiter_change;
                trimmed = trimmed[1..(trimmed.len - 1)];
            } else {
                tag = TagType.fromSpecifier(input[0]);
                trimmed = switch (tag) {
                    .variable => trimmed,
                    else => trimmed[1..],
                };
            }
            trimmed = std.mem.trim(u8, trimmed, &std.ascii.whitespace);
            if (comptime config.with_dynamic_partials) { // dynamic partials
                if (trimmed.len > 0) switch (trimmed[0]) {
                    '*' => {
                        tag = .partial_dynamic;
                        trimmed = std.mem.trimLeft(u8, trimmed[1..], &std.ascii.whitespace);
                    },
                    else => {},
                };
            }

            const body: []const []const u8 = switch (tag) {
                .delimiter_change => blk: {
                    break :blk try alloc.dupe(
                        []const u8,
                        &try parseDelims(trimmed),
                    );
                },
                .comment => try alloc.dupe([]const u8, &.{trimmed}),
                else => try parseVariable(alloc, trimmed),
            };

            return Tag{
                .type = tag,
                .body = body,
            };
        }

        pub fn trimStandaloneTokens(tokens: []Token) void {
            for (tokens, 0..) |*ctoken, i| {
                if (ctoken.* != .tag or ctoken.tag.standalone_line_prefix == null) continue;
                switch (ctoken.tag.type) {
                    .variable, .unescaped_variable => continue,
                    else => {},
                }

                const prefix = ctoken.tag.standalone_line_prefix.?;

                // Current tag is a standalone tag
                if (i != 0 and tokens[i - 1] == .text) {
                    const prev_is_prefix = std.mem.eql(u8, tokens[i - 1].text, prefix);
                    if (prev_is_prefix) tokens[i - 1].text = "";
                }
                if (i != tokens.len - 1 and tokens[i + 1] == .text) {
                    tokens[i + 1].text = "";
                }
            }
        }

        const ParseDelimsError = error{ EmptyOpeningDelimiter, EmptyClosingDelimiter, UnsupportedDelimiter };
        fn parseDelims(input: []const u8) ParseDelimsError![2][]const u8 {
            assert(input.len > 0);

            var state: enum { opening, whitespace } = .opening;
            var opening_end: usize = 0;
            var closing_start: usize = input.len - 1;
            loop_blk: for (input, 0..) |cc, i| {
                switch (state) {
                    .opening => {
                        if (cc == '=') return error.UnsupportedDelimiter;
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
            defer list.deinit(alloc);

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
    };
}

fn testTokenizer(
    input: []const u8,
    expected: []const Token,
) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var tokenizer = Tokenizer.init(arena.allocator(), input);
    for (expected) |exp_token| {
        const res_token = try tokenizer.nextToken() orelse return error.TooFewTokens;
        //std.debug.print("----------------\n", .{});
        //res_token.debugPrint();
        //std.debug.print("----------------\n", .{});
        try testing.expectEqualDeep(exp_token, res_token);
    }

    if (try tokenizer.nextToken() != null) return error.TooManyTokens;
}

test "Tokenizer.simple_middle" {
    try testTokenizer(
        \\this
        \\  {{>partial}}  
        \\  ldskfslfd
        \\
    , &.{
        Token{ .text = "this\n" },
        Token{ .text = "  " },
        Token{ .tag = Tag{
            .type = .partial,
            .body = &.{"partial"},
            .standalone_line_prefix = "  ",
        } },
        Token{ .text = "  \n" },
        Token{ .text = "  ldskfslfd\n" },
    });
}

test "Tokenizer.simple_start" {
    try testTokenizer(
        \\  {{>partial}}  
        \\  ldskfslfd
        \\
    , &.{
        Token{ .text = "  " },
        Token{ .tag = Tag{
            .type = .partial,
            .body = &.{"partial"},
            .standalone_line_prefix = "  ",
        } },
        Token{ .text = "  \n" },
        Token{ .text = "  ldskfslfd\n" },
    });
}

test "Tokenizer.simple_end" {
    try testTokenizer(
        \\this
        \\  {{>partial}}  
    , &.{
        Token{ .text = "this\n" },
        Token{ .text = "  " },
        Token{ .tag = Tag{
            .type = .partial,
            .body = &.{"partial"},
            .standalone_line_prefix = "  ",
        } },
        Token{ .text = "  " },
    });
}

//test "Tokenizer.first_all" {
//    try testTokenizer(
//        \\{{>partial}}
//        \\  ldskfslfd
//    , &.{
//        Token{ .tag = Tag{
//            .type = .partial,
//            .body = &.{"partial"},
//            .standalone_line_prefix = "",
//        } },
//        Token{ .text = "" },
//        Token{ .text = "  ldskfslfd" },
//    });
//}

test "Tokenizer.end_all" {
    try testTokenizer(
        \\  ldskfslfd
        \\ {{>partial}}
    , &.{
        Token{ .text = "  ldskfslfd\n" },
        Token{ .text = " " },
        Token{ .tag = Tag{
            .type = .partial,
            .body = &.{"partial"},
            .standalone_line_prefix = " ",
        } },
    });
}

test "Tokenizer.end_all_newline" {
    try testTokenizer(
        \\  ldskfslfd
        \\ {{>partial}}
        \\
    , &.{
        Token{ .text = "  ldskfslfd\n" },
        Token{ .text = " " },
        Token{ .tag = Tag{
            .type = .partial,
            .body = &.{"partial"},
            .standalone_line_prefix = " ",
        } },
        Token{ .text = "\n" },
    });
}

//test "Tokenizer.standalone_only_at_line" {
//    try testTokenizer(
//        \\  ldskfslfd
//        \\{{>partial}}
//        \\
//    , &.{
//        Token{ .text = "  ldskfslfd\n" },
//        Token{ .tag = Tag{
//            .type = .partial,
//            .body = &.{"partial"},
//            .standalone_line_prefix = "",
//        } },
//        Token{ .text = "\n" },
//    });
//}

test "Tokenizer.standalone_only_without_endline" {
    try testTokenizer(
        \\  ldskfslfd
        \\{{>partial}}
    , &.{
        Token{ .text = "  ldskfslfd\n" },
        Token{ .text = "" },
        Token{ .tag = Tag{
            .type = .partial,
            .body = &.{"partial"},
            .standalone_line_prefix = "",
        } },
    });
}

//test "Tokenizer.tripple_unescaped_name" {
//    try testTokenizer(
//        \\"{{{person.name}}}" == "{{#person}}{{{name}}}{{/person}}"
//    , &.{
//        Token{ .text = "\"" },
//        Token{ .tag = Tag{
//            .type = .unescaped_variable,
//            .body = &.{ "person", "name" },
//            .standalone_line_prefix = null,
//        } },
//        Token{ .text = "\" == \"" },
//        Token{ .tag = Tag{
//            .type = .section_open,
//            .body = &.{"person"},
//        } },
//        Token{ .tag = Tag{
//            .type = .unescaped_variable,
//            .body = &.{"name"},
//            .standalone_line_prefix = null,
//        } },
//        Token{ .tag = Tag{
//            .type = .section_close,
//            .body = &.{"person"},
//        } },
//        Token{ .text = "\"" },
//    });
//}
