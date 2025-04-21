const std = @import("std");
const mem = std.mem;
const log = std.log;
const testing = std.testing;

const Hash = @This();

inner: *const anyopaque,

pub const Ctx = VTable;
pub const VTable = struct {
    getFieldFn: *const fn (ctx: Ctx, data: *const anyopaque, name: []const u8) GetFieldError!Hash,
    getAtFn: *const fn (ctx: Ctx, data: *const anyopaque, idx: usize) GetAtError!Hash,
    stringifyFn: *const fn (ctx: Ctx, data: *const anyopaque, writer: std.io.AnyWriter) anyerror!void,
    interpolateBoolFn: *const fn (ctx: Ctx, data: *const anyopaque) bool,
};

pub const GetFieldError = error{ FieldNotExistant, NoObject };
pub inline fn getField(self: Hash, ctx: Ctx, name: []const u8) GetFieldError!Hash {
    return try ctx.getFieldFn(ctx, self.inner, name);
}

pub const GetAtError = error{ OutOfBounds, NoArray };
pub inline fn getAt(self: Hash, ctx: Ctx, i: usize) GetAtError!Hash {
    return try ctx.getAtFn(ctx, self.inner, i);
}

pub inline fn interpolateBool(self: Hash, ctx: Ctx) bool {
    return ctx.interpolateBoolFn(ctx, self.inner);
}
pub inline fn stringify(self: Hash, ctx: Ctx, writer: anytype) @TypeOf(writer).Error!void {
    return @errorCast(ctx.stringifyFn(ctx, self.inner, writer.any()));
}

pub fn sub(self: Hash, ctx: Ctx, accessors: []const []const u8) SubResult {
    var chash = self;
    var first = true;
    for (accessors) |v| {
        // Try to access array, if it's not working, fall back to get field of object.
        if (std.fmt.parseInt(usize, v, 10)) |i| {
            if (chash.getAt(ctx, i)) |h| {
                return .{ .found = h };
            } else |_| {}
        } else |_| {}
        chash = chash.getField(ctx, v) catch {
            if (first) return .not_found;
            return .not_found_fully;
        };
        first = false;
    }
    return .{ .found = chash };
}

test "Hash.sub.number_idx" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const hash_json = std.json.Value{
        .array = blk: {
            var a = std.json.Array.init(arena.allocator());
            try a.appendSlice(&.{
                std.json.Value{ .string = "Here 0" },
                std.json.Value{ .string = "Here 1" },
                std.json.Value{ .string = "Here 2" },
            });
            break :blk a;
        },
    };
    const hash_ctx = @import("hash_impl/json.zig").vtable;
    const hash = Hash{ .inner = @ptrCast(&hash_json) };
    {
        const got_hash = hash.sub(hash_ctx, &.{"1"});
        try testing.expect(SubResultTag.found == got_hash);
        const got: *const std.json.Value = @ptrCast(@alignCast(got_hash.found.inner));
        try testing.expectEqualDeep(std.json.Value{ .string = "Here 1" }, got.*);
    }
}

pub const SubResultTag = enum { found, not_found_fully, not_found };
pub const SubResult = union(SubResultTag) {
    found: Hash,
    not_found_fully,
    not_found,
};

pub const IterError = error{NotIterable};
pub fn iterator(self: Hash, ctx: Ctx) IterError!Iterator {
    //if (!self.vtable.iterableFn(self.ctx)) return error.NotIterable;
    _ = self.getAt(ctx, 0) catch |e| switch (e) {
        error.NoArray => return error.NotIterable,
        error.OutOfBounds => {},
    };
    return Iterator{
        .hash = self,
        .index = 0,
    };
}

pub const Iterator = struct {
    hash: Hash,
    index: usize,

    pub fn peek(self: Iterator, ctx: Ctx) ?Hash {
        return self.hash.getAt(ctx, self.index) catch |e| switch (e) {
            error.NoArray => unreachable,
            error.OutOfBounds => null,
        };
    }

    pub fn next(self: *Iterator, ctx: Ctx) ?Hash {
        const ret = self.peek(ctx) orelse return null;
        self.index += 1;
        return ret;
    }
};

//pub fn getField(self: Hash, name: []const u8) GetError!Hash {
//    switch (self.inner) {
//        .object => |o| return if (o.get(name)) |v| .{ .inner = v } else {
//            log.err("Field '{s}' does not exist!", .{name});
//            return error.FieldNotExistant;
//        },
//        else => {
//            log.err(
//                "Trying to access '{s}' on value of type {s}",
//                .{ name, @tagName(self.inner) },
//            );
//            return error.FieldNotAccessable;
//        },
//    }
//}

//pub fn interpolateBool(self: Hash) bool {
//    return switch (self.inner) {
//        .null => false,
//        .bool => |b| b,
//        .integer => |i| i != 0,
//        .float => |f| f != 0.0 and f != std.math.nan(f64),
//        .number_string => @panic("Unsupported BigNumbers"),
//        .string => |s| s.len != 0,
//        .object => |o| o.count() != 0,
//        .array => |a| a.items.len != 0,
//    };
//}

//pub fn stringify(self: Hash, writer: anytype) @TypeOf(writer).Error!void {
//    switch (self.inner) {
//        .null => {},
//        .bool => |b| try writer.writeAll(if (b) "true" else "false"),
//        .integer => |i| try std.fmt.formatInt(i, 10, .lower, .{}, writer),
//        .float => |f| try std.fmt.format(writer, "{d}", .{f}),
//        .number_string => |nr| try writer.writeAll(nr),
//        .string => |s| try writer.writeAll(s), // TODO Escape html
//        else => try std.json.stringify(self.inner, .{}, writer), // TODO: Escape html
//    }
//}

//pub fn iterator(self: Hash) IterError!Iterator {
//    switch (self.inner) {
//        .array => |v| return Iterator{ .val = v.items, .idx = 0 },
//        else => return error.NotIterable,
//    }
//}

//pub const Iterator = struct {
//    val: []const std.json.Value,
//    idx: usize,
//
//    pub fn peek(self: Iterator) ?Hash {
//        if (self.idx >= self.val.len) return null;
//        return Hash{ .inner = self.val[self.idx] };
//    }
//
//    pub fn next(self: *Iterator) ?Hash {
//        if (self.idx >= self.val.len) return null;
//        defer self.idx += 1;
//        return Hash{ .inner = self.val[self.idx] };
//    }
//};

//pub fn sub(self: Hash, accessors: []const []const u8) SubResult {
//    var chash = self;
//    var first = true;
//    for (accessors) |v| {
//        chash = chash.getField(v) catch {
//            if (first) return .not_found;
//            return .not_found_fully;
//        };
//        first = false;
//    }
//    return .{ .found = chash };
//}
