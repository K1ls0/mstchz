const std = @import("std");

var log_state: LogState = undefined;

pub fn init(alloc: std.mem.Allocator) void {
    LogState.init(&log_state, alloc);
}

pub fn deinit() void {
    log_state.deinit();
}

pub fn flushIfNotBuffering() WriteError!void {
    return try log_state.flushIfNotBuffering();
}

pub fn flush() WriteError!void {
    return try log_state.flush();
}

pub fn clear() void {
    return log_state.clear();
}

pub fn setExplicitBuffering(enable: bool) void {
    return log_state.setExplicitBuffering(enable);
}

pub fn getBuffering() bool {
    return log_state.getBuffering();
}

pub fn writer() Writer {
    return log_state.writer();
}

pub const LogState = struct {
    out_writer: std.fs.File.Writer,
    buf: std.ArrayList(u8),
    mutex: std.Thread.Mutex = .{},
    buffering: bool = false,

    fn init(
        state: *LogState,
        alloc: std.mem.Allocator,
    ) void {
        state.* = .{
            .buf = .init(alloc),
            .out_writer = std.io.getStdErr().writer(),
        };
    }

    fn deinit(self: *LogState) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.buf.deinit();
        self.buffering = false;
    }

    pub fn flushIfNotBuffering(self: *LogState) WriteError!void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.buffering) return;

        try self.out_writer.writeAll(self.buf.items);
        self.buf.clearRetainingCapacity();
    }

    pub fn flush(self: *LogState) WriteError!void {
        self.mutex.lock();
        defer self.mutex.unlock();

        try self.out_writer.writeAll(self.buf.items);
        self.buf.clearRetainingCapacity();
    }

    pub fn clear(self: *LogState) void {
        self.buf.clearRetainingCapacity();
    }

    pub fn setExplicitBuffering(self: *LogState, enable: bool) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.buffering = enable;
    }

    pub fn getBuffering(self: *LogState) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.buffering;
    }

    pub fn writer(self: *LogState) Writer {
        return .{ .context = self };
    }
};

pub const WriteError = std.fs.File.Writer.Error || std.ArrayList(u8).Writer.Error || std.mem.Allocator.Error;
pub const Writer = std.io.Writer(*LogState, WriteError, write);
fn write(ctx: *LogState, bytes: []const u8) WriteError!usize {
    ctx.mutex.lock();
    defer ctx.mutex.unlock();
    std.debug.lockStdErr();
    defer std.debug.unlockStdErr();

    return try ctx.buf.writer().write(bytes);
}

pub fn logFn(
    comptime message_level: std.log.Level,
    comptime scope: @Type(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    const level_txt = comptime message_level.asText();
    const prefix2 = if (scope == .default) ": " else "(" ++ @tagName(scope) ++ "): ";

    const w = log_state.writer();

    std.debug.lockStdErr();
    defer std.debug.unlockStdErr();
    nosuspend {
        w.print(level_txt ++ prefix2 ++ format ++ "\n", args) catch return;
        log_state.flushIfNotBuffering() catch return;
    }
}
