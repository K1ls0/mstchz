const std = @import("std");
const mem = std.mem;
const testing = std.testing;

pub fn InsertingWriter(comptime W: type) type {
    return struct {
        const Self = @This();

        prev_byte: u8,
        marker: u8,
        to_insert: []const u8,
        w: W,

        pub const Writer = std.io.GenericWriter(*Self, W.Error, write);

        fn write(ctx: *Self, bytes: []const u8) !usize {
            if (ctx.to_insert.len == 0) return try ctx.w.write(bytes);

            var start: usize = 0;
            for (bytes, 0..) |b, i| {
                if (b == ctx.marker) {
                    try ctx.w.writeAll(bytes[start..i]);
                    try ctx.w.writeAll(ctx.to_insert);
                    start = i;
                }
                ctx.prev_byte = b;
            }
            try ctx.w.writeAll(bytes[start..]);
            return bytes.len;
        }

        pub fn writer(self: *Self) Writer {
            return Writer{ .context = self };
        }
    };
}

pub fn insertingWriter(
    writer: anytype,
    opts: struct {
        marker: u8,
        to_insert: []const u8,
        insert_at_start: bool = false,
    },
) InsertingWriter(@TypeOf(writer)) {
    return InsertingWriter(@TypeOf(writer)){
        .prev_byte = if (opts.insert_at_start) opts.marker else (opts.marker +% 1),
        .marker = opts.marker,
        .to_insert = opts.to_insert,
        .w = writer,
    };
}

fn testInsertingWriter(alloc: mem.Allocator, input: []const u8) ![]const u8 {
    var buf = std.ArrayList(u8).init(alloc);
    var inserting_writer = insertingWriter(buf.writer(), .{
        .to_insert = "|",
        .marker = '\n',
        .insert_at_start = false,
    });
    const writer = inserting_writer.writer();

    try writer.writeAll(input);

    return try buf.toOwnedSlice();
}

test "insertingWriter" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    try testing.expectEqualStrings(
        "abcdef",
        try testInsertingWriter(arena.allocator(), "abcdef"),
    );
    try testing.expectEqualStrings(
        "abc\n|def",
        try testInsertingWriter(arena.allocator(), "abc\ndef"),
    );
}
