const std = @import("std");
const mem = std.mem;
const log = std.log.scoped(.zmstch);
const assert = std.debug.assert;
const testing = std.testing;

const token = @import("token.zig");
const DocToken = token.DocToken;
const Token = token.Token;
const TokenTag = token.TokenTag;

const Tokenizer = @This();

const default_tag_start = "{{";
const default_tag_end = "}}";

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
standalone_range: ?struct { start: usize, len: usize },

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
        .standalone_range = .{ .start = 0, .len = 0 },
    };
}

pub fn nextToken(self: *Tokenizer) ParseError!?DocToken {
    assert(self.idx <= self.input.len);

    while (self.idx < self.input.len) {
        assert(self.tag_start.len != 0);
        assert(self.tag_end.len != 0);
        assert(self.idx >= self.token_start);

        const cc = self.input[self.idx];
        //std.debug.print("[{}] '{c}' start: {?any}\n", .{ self.idx, cc, self.standalone_range });
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
                    if (txt.len != 0) return DocToken{ .text = txt };
                }

                if (std.mem.startsWith(u8, self.input[self.idx..], self.tag_start)) {
                    // Start new tag and set standalone prefix bounds
                    log.info("starts with tag start '{s}' (idx: {})\n", .{ self.tag_start, self.idx });
                    if (self.standalone_range) |*s| s.len = self.idx - s.start;

                    const txt = self.input[self.token_start..self.idx];
                    self.state = .tag;
                    self.token_start = self.idx;
                    self.idx += self.tag_start.len;
                    return DocToken{ .text = txt };
                }
                if (!std.ascii.isWhitespace(cc) and self.state == .text) {
                    // this is not a whitespace, reset to non-standalone
                    self.standalone_range = null;
                }
            },
            .tag => {
                log.info("[tag][{}][{c}] brace depth: {}", .{ self.idx, self.input[self.idx], self.brace_depth });
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
                    log.info("tag with end: '{s}'", .{self.input[self.idx..(@min(self.idx + 20, self.input.len))]});
                    const tag_end_idx = self.idx + self.tag_end.len;
                    const tag_txt = self.input[self.token_start + self.tag_start.len .. self.idx];
                    var parsed_tag = try parseToken(self.alloc, tag_txt);

                    // previous token was a standalone token
                    if (self.standalone_range) |*standalone_range| {
                        //std.debug.print("standalone start at: {} (starting from {} ({c}))\n", .{
                        //    start_i,
                        //    tag_end_idx + 1,
                        //    self.input[tag_end_idx + 1],
                        //});
                        const standalone_end_found = switch (self.lookAheadToNewlineOrEnd(tag_end_idx)) {
                            .newline, .end => true,
                            .non_whitespace => false,
                        };
                        //std.debug.print("standalone stop at: {?} {?c}\n", .{
                        //    standalone_end_idx,
                        //    if (standalone_end_idx) |si| self.input[si] else null,
                        //});

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
                        log.info("[delimiter change] after skipping parsed delimiter change: '{s}' '{s}'", .{ parsed_tag.body[0], parsed_tag.body[1] });
                        log.info("[delimiter change] idx: {} '{s}'", .{
                            self.idx,
                            self.input[self.idx..@min(self.idx + 10, self.input.len)],
                        });
                    }

                    const ctoken = DocToken{ .tag = parsed_tag };
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

fn lookAheadToNewlineOrEnd(self: Tokenizer, start: usize) union(enum) {
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

pub const ParseTokenError = ParseDelimsError || ParseVariableError || mem.Allocator.Error;

pub fn parseToken(tmp_alloc: mem.Allocator, input: []const u8) ParseTokenError!Token {
    log.info("[parseToken] input: '{s}'", .{input});
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

fn trimStandaloneTokens(tokens: []DocToken) void {
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

pub const ParseError = error{TagAtEOF} || ParseTokenError || mem.Allocator.Error;
pub fn parseSliceLeaky(
    alloc: mem.Allocator,
    input: []const u8,
) ParseError![]const DocToken {
    var list = std.ArrayList(DocToken).init(alloc);
    defer list.deinit();
    var state = Tokenizer.init(alloc, input);
    while (try state.nextToken()) |ctoken| {
        try list.append(ctoken);
    }

    trimStandaloneTokens(list.items);

    return try list.toOwnedSlice();
}

const ParseDelimsError = error{ EmptyOpeningDelimiter, EmptyClosingDelimiter, UnsupportedDelimiter };
fn parseDelims(input: []const u8) ParseDelimsError![2][]const u8 {
    assert(input.len > 0);
    log.debug("Trying to parse delimiters from: '{s}'", .{input});

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

fn testTokenizer(
    input: []const u8,
    expected: []const DocToken,
) !void {
    //std.debug.print("input: ====================\n'{s}'\n====================\n", .{input});
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var tokenizer = Tokenizer.init(arena.allocator(), input);
    for (expected) |exp_token| {
        const res_token = try tokenizer.nextToken() orelse return error.TooFewTokens;
        //std.debug.print("token {}: ", .{i});
        res_token.debugPrint();
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
        DocToken{ .text = "this\n" },
        DocToken{ .text = "  " },
        DocToken{ .tag = Token{
            .type = .partial,
            .body = &.{"partial"},
            .standalone_line_prefix = "  ",
        } },
        DocToken{ .text = "  \n" },
        DocToken{ .text = "  ldskfslfd\n" },
    });
}

test "Tokenizer.simple_start" {
    try testTokenizer(
        \\  {{>partial}}  
        \\  ldskfslfd
        \\
    , &.{
        DocToken{ .text = "  " },
        DocToken{ .tag = Token{
            .type = .partial,
            .body = &.{"partial"},
            .standalone_line_prefix = "  ",
        } },
        DocToken{ .text = "  \n" },
        DocToken{ .text = "  ldskfslfd\n" },
    });
}

test "Tokenizer.simple_end" {
    try testTokenizer(
        \\this
        \\  {{>partial}}  
    , &.{
        DocToken{ .text = "this\n" },
        DocToken{ .text = "  " },
        DocToken{ .tag = Token{
            .type = .partial,
            .body = &.{"partial"},
            .standalone_line_prefix = "  ",
        } },
        DocToken{ .text = "  " },
    });
}

test "Tokenizer.first_all" {
    try testTokenizer(
        \\{{>partial}} 
        \\  ldskfslfd
    , &.{
        DocToken{ .tag = Token{
            .type = .partial,
            .body = &.{"partial"},
            .standalone_line_prefix = "",
        } },
        DocToken{ .text = " \n" },
        DocToken{ .text = "  ldskfslfd" },
    });
}

test "Tokenizer.end_all" {
    try testTokenizer(
        \\  ldskfslfd
        \\ {{>partial}}
    , &.{
        DocToken{ .text = "  ldskfslfd\n" },
        DocToken{ .text = " " },
        DocToken{ .tag = Token{
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
        DocToken{ .text = "  ldskfslfd\n" },
        DocToken{ .text = " " },
        DocToken{ .tag = Token{
            .type = .partial,
            .body = &.{"partial"},
            .standalone_line_prefix = " ",
        } },
        DocToken{ .text = "\n" },
    });
}

test "Tokenizer.standalone_only_at_line" {
    try testTokenizer(
        \\  ldskfslfd
        \\{{>partial}}
        \\
    , &.{
        DocToken{ .text = "  ldskfslfd\n" },
        DocToken{ .tag = Token{
            .type = .partial,
            .body = &.{"partial"},
            .standalone_line_prefix = "",
        } },
        DocToken{ .text = "\n" },
    });
}

test "Tokenizer.standalone_only_without_endline" {
    try testTokenizer(
        \\  ldskfslfd
        \\{{>partial}}
    , &.{
        DocToken{ .text = "  ldskfslfd\n" },
        DocToken{ .tag = Token{
            .type = .partial,
            .body = &.{"partial"},
            .standalone_line_prefix = "",
        } },
    });
}

test "Tokenizer.tripple_unescaped_name" {
    try testTokenizer(
        \\"{{{person.name}}}" == "{{#person}}{{{name}}}{{/person}}"
    , &.{
        DocToken{ .text = "\"" },
        DocToken{ .tag = Token{
            .type = .unescaped_variable,
            .body = &.{ "person", "name" },
            .standalone_line_prefix = null,
        } },
        DocToken{ .text = "\" == \"" },
        DocToken{ .tag = Token{
            .type = .section_open,
            .body = &.{"person"},
        } },
        DocToken{ .tag = Token{
            .type = .unescaped_variable,
            .body = &.{"name"},
            .standalone_line_prefix = null,
        } },
        DocToken{ .tag = Token{
            .type = .section_close,
            .body = &.{"person"},
        } },
        DocToken{ .text = "\"" },
    });
}
