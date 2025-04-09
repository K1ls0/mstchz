const std = @import("std");
const testing = std.testing;
const mem = std.mem;
const log = std.log.scoped(.mustachez);
const assert = std.debug.assert;

pub const Partial = @import("Partial.zig");
pub const token = @import("token.zig");

pub const State = struct {
    exec_arena: std.heap.ArenaAllocator,

    data: std.json.Value = .null,
    partials: std.StringHashMap(Partial),

    pub fn init(allocator: mem.Allocator) State {
        return State{
            .exec_arena = .init(allocator),
            .partials = .init(allocator),
        };
    }

    pub fn deinit(self: *State) void {
        self.exec_arena.deinit();
        self.partials.deinit();
    }
};

test {
    _ = @import("token.zig");
    _ = @import("crc32.zig");
}
