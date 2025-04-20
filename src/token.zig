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

pub const DocTokenTag = enum { text, tag };
pub const DocToken = union(DocTokenTag) {
    text: []const u8,
    tag: Token,

    pub fn debugPrint(self: DocToken) void {
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

    fn trimStandaloneTokensAndPopulatePrefix(allocator: mem.Allocator, tokens: []DocToken) void {
        for (0..tokens.len) |ti| {
            const i = tokens.len - 1 - ti;
            if (tokens[i] == .text) continue;
            const tag = tokens[i].tag;
            switch (tag.type) {
                .variable, .unescaped_variable => continue,
                else => {},
            }

            var extract_line_pos = false;
            var prev_target_pos: TRes = .not_standalone;
            var next_target_pos: TRes = .not_standalone;

            if (i == 0) {
                prev_target_pos = .empty;
            } else if (tokens[i - 1] == .text) {
                switch (scanTokens(tokens, i - 1, .backward)) {
                    .found => |p| prev_target_pos = p,
                    .not_found => {
                        prev_target_pos = .not_standalone;
                        extract_line_pos = true;
                    },
                }
            }

            if (i == (tokens.len - 1)) {
                next_target_pos = .empty;
            } else if (tokens[i + 1] == .text) {
                switch (scanTokens(tokens, i + 1, .forward)) {
                    .found => |p| next_target_pos = .{ .pos = p },
                    .not_found => prev_target_pos = .not_standalone,
                }
            }

            // This tag is a standalone tag
            if (prev_target_pos != .not_standalone and next_target_pos != .not_standalone) {
                var buf = std.ArrayList(u8).init(allocator);
                defer buf.deinit();
                if (prev_target_pos == .pos) {
                    trimTokens();
                }
            }
            switch (prev_target_pos) {
                .not_standalone => {},
                .empty => {},
            }
        }
    }
};

const Direction = enum { forward, backward };
const TokenScanResult = union(enum) {
    not_found,
    found: TPos,
};

fn scanTokens(
    tokens: []const DocToken,
    start: usize,
    comptime direction: Direction,
) TokenScanResult {
    const C = struct {
        fn scanTokensForwards(
            tokens_inner: []const DocToken,
            start_inner: usize,
        ) TokenScanResult {
            for (start_inner..tokens_inner.len) |i| {
                switch (tokens_inner[i]) {
                    .text => |txt| switch (findNewline(txt, .forward)) {
                        .found => |pos| return .{ .found = .{ .token = i, .position = pos } },
                        .non_whitespace => return .not_found,
                        .not_found => {},
                    },
                    .tag => return .not_found,
                }
            }
            return .not_found;
        }

        fn scanTokensBackwards(
            tokens_inner: []const DocToken,
            start_inner: usize,
        ) TokenScanResult {
            for (0..start_inner + 1) |u| {
                const i = start_inner - u;
                switch (tokens_inner[i]) {
                    .text => |txt| switch (findNewline(txt, .forward)) {
                        .found => |pos| return .{ .found = .{ .token = i, .position = pos } },
                        .non_whitespace => return .not_found,
                        .not_found => {},
                    },
                    .tag => return .not_found,
                }
            }
            return .not_found;
        }
    };

    return switch (direction) {
        inline .forward => C.scanTokensForwards(tokens, start),
        inline .backward => C.scanTokensBackwards(tokens, start),
    };
}

//test "scanTokens.backward" {
//    const tokens = .{
//        DocToken{
//            .text = "\n ",
//        },
//        DocToken{
//            .text = "   ",
//        },
//        DocToken{
//            .tag = Token{
//                .type = .comment,
//                .body = &.{"This is some test!"},
//                .standalone_line_prefix = null,
//            },
//        },
//        DocToken{
//            .text = " \t ",
//        },
//        DocToken{
//            .text = " \t ",
//        },
//    };
//
//    try testing.expectEqualDeep(
//        TokenScanResult{ .found = .{ .token = 0, .position = 0 } },
//        scanTokens(&tokens, 1, .backward),
//    );
//}
//
//test "scanTokens.forward.positive" {
//    const tokens = .{
//        DocToken{
//            .text = " \n  ",
//        },
//        DocToken{
//            .tag = Token{
//                .type = .comment,
//                .body = &.{"This is some test!"},
//                .standalone_line_prefix = null,
//            },
//        },
//        DocToken{
//            .text = "  ",
//        },
//        DocToken{
//            .text = "  \n  ",
//        },
//    };
//
//    try testing.expectEqualDeep(
//        TokenScanResult{ .found = .{ .token = 3, .position = 2 } },
//        scanTokens(&tokens, 2, .forward),
//    );
//
//    try testing.expectEqualDeep(
//        TokenScanResult{ .found = .{ .token = 0, .position = 1 } },
//        scanTokens(&tokens, 0, .forward),
//    );
//}
//
//test "scanTokens.forward.negative" {
//    const tokens = .{
//        DocToken{
//            .text = "   ",
//        },
//        DocToken{
//            .tag = Token{
//                .type = .comment,
//                .body = &.{"This is some test!"},
//                .standalone_line_prefix = null,
//            },
//        },
//        DocToken{
//            .text = "  ",
//        },
//        DocToken{
//            .text = "    ",
//        },
//    };
//
//    try testing.expectEqualDeep(
//        TokenScanResult.non_whitespace,
//        scanTokens(&tokens, 2, .forward),
//    );
//
//    try testing.expectEqualDeep(
//        TokenScanResult.non_whitespace,
//        scanTokens(&tokens, 0, .forward),
//    );
//}

fn findNewline(
    txt: []const u8,
    comptime direction: Direction,
) union(enum) {
    not_found,
    non_whitespace,
    found: usize,
} {
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

fn TrimTokensError(comptime W: type) type {
    return if (@TypeOf(W) == void) error{} else @TypeOf(W).Error;
}
// if writer is passed as void ({}) nothing will be written (extracted)
fn trimTokens(
    tokens: []DocToken,
    start: usize,
    start_i: usize,
    end: usize,
    end_i: usize,
    writer: anytype,
) TrimTokensError(@TypeOf(writer))!void {
    assert(start < tokens.len);
    assert(end < tokens.len);
    assert(start <= end);

    const writer_is_active = @TypeOf(writer) == void;

    if (start == end) {
        assert(start_i == 0 or end_i == (tokens[start].text.len - 1));
        const txt = tokens[start].text[start_i .. end_i + 1];
        tokens[start].text = if (start_i == 0)
            tokens[start].text[end_i..]
        else if (end_i == (tokens[start].text.len - 1))
            tokens[start].text[0..start_i]
        else
            unreachable;
        return txt;
    }

    //var buf = if (comptime writer_is_active)
    //    try std.ArrayList(u8).initCapacity(allocator, 32)
    //else {};
    //defer buf.deinit();

    {
        const first = &tokens[start];
        assert(first.* == .text);
        if (comptime writer_is_active) try writer.writeAll(first.text[start_i..]);
        first.*.text = first.text[0..start_i];
    }

    for (start + 1..end) |i| {
        assert(tokens[i] == .text);
        if (comptime writer_is_active) try writer.writeAll(tokens[i].text);
        tokens[i].text = "";
    }
    {
        const last = &tokens[end];
        assert(last.* == .text);
        if (comptime writer_is_active) try writer.writeAll(last.text[0..(end_i + 1)]);
        last.*.text = last.text[(end_i + 1)..];
    }
}

//test "trimAndExtract" {
//    var tokens = [_]DocToken{
//        DocToken{ .text = "|   " },
//        DocToken{ .text = "   " },
//        DocToken{ .text = "  " },
//    };
//    {
//        var out_buf = std.ArrayList(testing.allocator).init();
//        defer out_buf.deinit();
//        try trimTokens(&tokens, 0, 1, 2, 0, out_buf.writer());
//
//        try testing.expectEqualStrings("       ", out_buf.items);
//        try testing.expectEqualDeep([_]DocToken{
//            DocToken{ .text = "|" },
//            DocToken{ .text = "" },
//            DocToken{ .text = " " },
//        }, tokens);
//    }
//}

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
    standalone_line_prefix: ?[]const u8 = null,
};
