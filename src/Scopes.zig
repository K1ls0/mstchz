const std = @import("std");
const mem = std.mem;
const assert = std.debug.assert;
const log = std.log.scoped(.mustachez);
const Hash = @import("Hash.zig");

const token = @import("token.zig");
const Token = token.Token;

const Scopes = @This();

debug_lookup: std.ArrayList([]const u8),
stack: std.ArrayList(Scope),

pub fn init(allocator: mem.Allocator) mem.Allocator.Error!Scopes {
    return Scopes{
        .debug_lookup = try .initCapacity(allocator, 16),
        .stack = try .initCapacity(allocator, 8),
    };
}

pub fn deinit(self: Scopes) void {
    self.debug_lookup.deinit();
    self.stack.deinit();
}

pub fn clone(self: Scopes) mem.Allocator.Error!Scopes {
    return Scopes{
        .debug_lookup = try self.debug_lookup.clone(),
        .stack = try self.stack.clone(),
    };
}

pub fn push(self: *Scopes, scope: Scope, accessors: []const []const u8) mem.Allocator.Error!void {
    try self.debug_lookup.appendSlice(accessors);

    try self.stack.append(scope);
}

pub fn pop(self: *Scopes, accessors: []const []const u8) Scope {
    assert(self.stack.items.len > 0);
    for (0..accessors.len) |u| {
        const i = accessors.len - 1 - u;
        assert(std.mem.eql(u8, accessors[i], self.debug_lookup.pop().?));
    }
    return self.stack.pop().?;
}

pub fn currentHash(self: Scopes, ctx: Hash.Ctx) Hash {
    assert(self.stack.items.len > 0);
    assert(self.stack.items[0].state == .block);
    assert(self.stack.items[0].state.block.hash != null);

    for (0..self.stack.items.len) |u| {
        const i = self.stack.items.len - 1 - u;
        switch (self.stack.items[i].state) {
            .block => |b| if (b.hash) |h| return h,
            .iter => |*it| if (it.peek(ctx)) |h| return h,
        }
    }
    @panic("At least the root scope has to be occupied, so this should not happen " ++
        "(No valid scope hash available)");
}

pub fn resetStarts(self: *Scopes) void {
    for (self.stack.items) |*item| item.resetStart();
}

pub fn currentScope(self: Scopes) *Scope {
    assert(self.stack.items.len > 0);
    return &self.stack.items[self.stack.items.len - 1];
}

pub fn printCurrentLookup(self: Scopes) void {
    var buf = std.ArrayList(u8).initCapacity(self.stack.allocator, 1024) catch @panic("OOM");
    defer buf.deinit();
    const writer = buf.writer();
    for (self.debug_lookup.items, 0..) |scope, i| {
        if (i != 0) writer.writeAll(":") catch @panic("OOM");
        writer.writeAll(scope) catch @panic("OOM");
    }
    log.info("lookup stack: {s}", .{buf.items});
}

const HashIterator = struct {
    i: usize,
    stack: []const Scope,

    pub fn next(self: *HashIterator, ctx: Hash.Ctx) ?Hash {
        if (self.i >= self.stack.len) return null;

        while (self.i < self.stack.len) {
            defer self.i += 1;

            const i = self.stack.len - 1 - self.i;
            switch (self.stack[i].state) {
                .block => |b| if (b.hash) |h| return h,
                .iter => |*it| if (it.peek(ctx)) |h| return h,
            }
        }
        return null;
    }
};

fn hashIterator(self: Scopes) HashIterator {
    return HashIterator{ .i = 0, .stack = self.stack.items };
}

pub fn lookup(self: Scopes, ctx: Hash.Ctx, accessors: []const []const u8) ?Hash {
    assert(self.stack.items.len > 0);
    assert(self.stack.items[0].state == .block);
    const hash = self.stack.items[0].state.block.hash;
    assert(self.stack.items[0].state.block.hash != null);
    _ = hash;

    var it = self.hashIterator();
    while (it.next(ctx)) |h| {
        switch (h.sub(ctx, accessors)) {
            .found => |v| return v,
            .not_found_fully => return null,
            .not_found => {},
        }
    }
    return null;
}

pub const Scope = struct {
    state: ScopeState,
    start_tag: ?usize,

    pub const BlockState = enum { run, skip };

    pub const ScopeState = union(enum) {
        block: struct { hash: ?Hash, block_state: BlockState },
        iter: Hash.Iterator,
    };

    pub fn blockState(self: Scope) BlockState {
        return switch (self.state) {
            .block => |b| b.block_state,
            .iter => .run,
        };
    }

    pub fn blockRunning(self: Scope) bool {
        return switch (self.state) {
            .iter => |it| if (it.peek()) |_| true else false,
            .block => |b| switch (b.block_state) {
                .run => true,
                .skip => false,
            },
        };
    }

    pub fn getStartAccessor(
        self: Scope,
        tokens: []const Token,
    ) ?[]const []const u8 {
        const start = self.start_tag orelse return null;
        assert(start < tokens.len);
        return switch (tokens[start]) {
            .text => null,
            .tag => |t| t.body,
        };
    }

    pub fn resetStart(self: *Scope) void {
        self.start_tag = null;
    }
};
