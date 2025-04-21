//! Json implementation for the mustache Hash access
const std = @import("std");
const log = std.log.scoped(.mstchz);
const Hash = @import("../Hash.zig");

pub const vtable = Hash.VTable{
    .getFieldFn = &getField,
    .getAtFn = &getAt,
    .interpolateBoolFn = &interpolateBool,
    .stringifyFn = &stringify,
};

pub fn getField(_: Hash.Ctx, inner: *const anyopaque, name: []const u8) Hash.GetFieldError!Hash {
    const val: *const std.json.Value = @ptrCast(@alignCast(inner));
    switch (val.*) {
        .object => |o| return if (o.getPtr(name)) |v| Hash{ .inner = v } else {
            log.err("Field '{s}' does not exist!", .{name});
            return error.FieldNotExistant;
        },
        else => {
            log.err(
                "Trying to access '{s}' on value of type {s}",
                .{ name, @tagName(val.*) },
            );
            return error.NoObject;
        },
    }
}

pub fn getAt(_: Hash.Ctx, inner: *const anyopaque, idx: usize) Hash.GetAtError!Hash {
    const val: *const std.json.Value = @ptrCast(@alignCast(inner));

    switch (val.*) {
        .array => |*a| {
            if (idx >= a.items.len) {
                log.err("Field '{}' is out of bounds!", .{idx});
                return error.OutOfBounds;
            }
            return Hash{ .inner = &a.items[idx] };
        },
        else => {
            log.err(
                "Trying to access field at position '{}' on value of type {s}",
                .{ idx, @tagName(val.*) },
            );
            return error.NoArray;
        },
    }
}

pub fn interpolateBool(_: Hash.Ctx, inner: *const anyopaque) bool {
    const val: *const std.json.Value = @ptrCast(@alignCast(inner));

    return switch (val.*) {
        .null => false,
        .bool => |b| b,
        .integer => |i| i != 0,
        .float => |f| f != 0.0 and f != std.math.nan(f64),
        .number_string => true, // This number is not recognisable (it is a big number after all) therefore it will always interpolate to be true.
        .string => |s| s.len != 0,
        .object => |*o| o.count() != 0,
        .array => |*a| a.items.len != 0,
    };
}

fn stringify(_: Hash.Ctx, inner: *const anyopaque, writer: std.io.AnyWriter) anyerror!void {
    const val: *const std.json.Value = @ptrCast(@alignCast(inner));
    switch (val.*) {
        .null => {},
        .bool => |b| try writer.writeAll(if (b) "true" else "false"),
        .integer => |i| try std.fmt.formatInt(i, 10, .lower, .{}, writer),
        .float => |f| try std.fmt.format(writer, "{d}", .{f}),
        .number_string => |nr| try writer.writeAll(nr),
        .string => |s| try writer.writeAll(s),
        else => try std.json.stringify(val, .{}, writer),
    }
}
