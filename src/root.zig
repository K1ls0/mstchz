const std = @import("std");
const testing = std.testing;
const mem = std.mem;
const log = std.log.scoped(.mustachez);
const assert = std.debug.assert;

pub const Partial = @import("Partial.zig");
pub const token = @import("token.zig");

pub const State = struct {
    exec_arena: std.heap.ArenaAllocator,

    ctx: std.json.Value,
    partials: *std.StringHashMap(Partial),

    input: []const token.DocumentStructureToken,

    pub fn init(
        allocator: mem.Allocator,
        ctx: std.json.Value,
        partials: *std.StringHashMap(Partial),
        input: []const token.DocumentStructureToken,
    ) State {
        return State{
            .exec_arena = .init(allocator),
            .ctx = ctx,
            .partials = partials,
            .input = input,
        };
    }

    pub fn deinit(self: *State) void {
        self.exec_arena.deinit();
        self.partials.deinit();
    }

    pub const RenderError = error{
        Unsupported,
        NoObject,
        NoField,
    };
    pub fn render(self: *State, writer: anytype) (RenderError || @TypeOf(writer).Error)!void {
        for (self.input) |ctoken| {
            switch (ctoken) {
                .text => |txt| try writer.writeAll(txt),
                .tag => |t| switch (t.type) {
                    .comment => {},
                    .variable => {
                        var cval = self.ctx;
                        for (t.body) |v| {
                            switch (cval) {
                                .object => |o| {
                                    cval = o.get(v) orelse {
                                        log.err("field '{s}' not available!", .{v});
                                        return error.NoField;
                                    };
                                },
                                else => {
                                    log.err("Trying to access '{s}' on value of type {s}", .{ v, @tagName(cval) });
                                    return error.NoObject;
                                },
                            }
                        }
                    },
                    else => {
                        log.err("unsupported token {s}", .{@tagName(t.type)});
                        return error.Unsupported;
                    },
                },
            }
        }
    }
};

test {
    _ = @import("token.zig");
    _ = @import("crc32.zig");
}
