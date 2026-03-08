const std = @import("std");
const Io = std.Io;
const mem = std.mem;
const log = std.log;
const mstchz = @import("mstchz");
const ansii = @import("ansii.zig");

pub const std_options = std.Options{
    .log_level = .info,
    //.logFn = logFn,
};

pub fn logFn(
    comptime message_level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    const level_txt = comptime message_level.asText();
    const prefix2 = if (scope == .default) ": " else "(" ++ @tagName(scope) ++ "): ";

    const writer = log_state.writer();

    std.debug.lockStdErr();
    defer std.debug.unlockStdErr();
    nosuspend {
        writer.print(level_txt ++ prefix2 ++ format ++ "\n", args) catch return;
        log_state.flushIfNotBuffering() catch return;
    }
}
const LogState = struct {
    alloc: mem.Allocator,
    out_writer: std.Io.File.Writer,
    out_writer_buf: [1024]u8,
    buf: std.ArrayList(u8),
    mutex: Io.Mutex = .init,
    buffering: bool = false,

    pub fn init(
        state: *LogState,
        alloc: std.mem.Allocator,
        io: Io,
    ) void {
        const stderr_f = Io.File.stderr();
        state.* = .{
            .buf = .empty,
            .out_writer = stderr_f.writer(io, &state.out_writer_buf),
            .alloc = alloc,
            .out_writer_buf = undefined,
        };
    }

    pub fn deinit(self: *LogState, io: Io) void {
        self.mutex.lock(io) catch return;
        defer self.mutex.unlock(io);

        self.buf.deinit(self.alloc);
        self.buffering = false;
    }

    pub const WriteError = Io.Writer.Error || std.mem.Allocator.Error;

    pub fn flushIfNotBuffering(self: *LogState) WriteError!void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.buffering) return;

        //std.debug.print("-....flushing because no explicit buffering:\n'{s}'\n", .{self.buf.items});

        try self.out_writer.writeAll(self.buf.items);
        self.buf.clearRetainingCapacity();
    }

    pub fn flush(self: *LogState, io: Io) (WriteError || Io.Cancelable)!void {
        try self.mutex.lock(io);
        defer self.mutex.unlock(io);

        //std.debug.print("-....flushing because always does: \n'{s}'\n", .{self.buf.items});

        try self.out_writer.interface.writeAll(self.buf.items);
        self.buf.clearRetainingCapacity();
    }

    pub fn clear(self: *LogState) void {
        self.buf.clearRetainingCapacity();
    }

    pub fn setExplicitBuffering(self: *LogState, io: Io, enable: bool) Io.Cancelable!void {
        try self.mutex.lock(io);
        defer self.mutex.unlock(io);
        self.buffering = enable;
    }

    pub fn getBuffering(self: *LogState) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.buffering;
    }

    pub const Writer = std.io.Writer(*LogState, WriteError, write);

    fn write(ctx: *LogState, bytes: []const u8) WriteError!usize {
        ctx.mutex.lock();
        defer ctx.mutex.unlock();
        std.debug.lockStdErr();
        defer std.debug.unlockStdErr();

        //std.debug.print("==== Got here (bytes.len: {})! '{s}'\n\n", .{ bytes.len, bytes });

        return try ctx.buf.writer().write(bytes);
    }

    pub fn writer(self: *LogState) Writer {
        return .{ .context = self };
    }
};

var log_state: LogState = undefined;

const success_str = ansii.fg.bright_green ++ "passed" ++ ansii.rst;
const fail_str = ansii.fg.bright_red ++ "failed" ++ ansii.rst;

pub fn main(init: std.process.Init) !void {
    LogState.init(&log_state, init.gpa, init.io);
    defer log_state.deinit(init.io);

    var test_arena = std.heap.ArenaAllocator.init(init.gpa);
    defer test_arena.deinit();

    var all_testcases: usize = 0;
    var all_fails: usize = 0;
    const pcli = parseCli(init.arena.allocator(), init.minimal.args);
    try log_state.setExplicitBuffering(init.io, false);
    for (pcli.files) |file| {
        log.info("=========== {s} ===========", .{std.fs.path.basename(file)});
        log.info("=========== START ===========", .{});
        defer _ = test_arena.reset(.retain_capacity);
        const r = try testFile(test_arena.allocator(), init.io, file);
        const res_string = if (r.fails == 0) success_str else fail_str;

        log.info("=========== END ===========", .{});
        log.info("{s} ({}/{}) succeeded", .{
            res_string,
            r.successes(),
            r.testcases,
        });
        all_testcases += r.testcases;
        all_fails += r.fails;
        try log_state.flush(init.io);
    }
    log.info("This should not be rendered!", .{});
    log_state.clear();
    try log_state.setExplicitBuffering(init.io, false);

    log.info("=========== Results ===========", .{});
    log.info("Testcases: {}", .{all_testcases});
    log.info("Sucesses: {}", .{all_testcases - all_fails});
    log.info("Fails: {}", .{all_fails});
    log.info("===============================", .{});
}
const TestFileResults = struct {
    testcases: usize,
    fails: usize,

    pub fn successes(self: TestFileResults) usize {
        std.debug.assert(self.testcases >= self.fails);
        return self.testcases - self.fails;
    }
};

fn testFile(tmp_alloc: mem.Allocator, io: Io, path: []const u8) !TestFileResults {
    const cwd = Io.Dir.cwd();
    const file_text = try cwd.readFileAlloc(io, path, tmp_alloc, .unlimited);
    const json_file_content = try std.json.parseFromSliceLeaky(
        std.json.Value,
        tmp_alloc,
        file_text,
        .{},
    );
    const overview_txt = json_file_content.object.get("overview").?.string;
    const text_list = json_file_content.object.get("tests").?.array.items;

    log.info("{s}", .{overview_txt});

    var cases: usize = 0;
    var fails: usize = 0;
    for (text_list) |case_v| {
        cases += 1;

        const case = case_v.object;
        const name = case.get("name").?.string;
        const desc = case.get("desc").?.string;
        const data = case.get("data").?;
        const template = case.get("template").?.string;
        const expected_str = case.get("expected").?.string;
        const partials = if (case.get("partials")) |v|
            v.object
        else
            std.json.ObjectMap.init(tmp_alloc);

        _ = partials;

        log.info(ansii.fg.bright_cyan ++ "Test" ++ ansii.rst ++ ": {s} ({s})", .{ name, desc });
        log.info("\ttemplate: `{s}`", .{template});
        //log.info("\texpected: '{s}'", .{expected_str});
        log.info("\tParsing..", .{});
        const failed = blk: {
            const doc_struct_token = mstchz.token.DocumentStructureToken.parseSliceLeaky(tmp_alloc, template) catch |e| {
                log.err("Error occured: {}", .{e});
                if (@errorReturnTrace()) |trace| std.debug.dumpStackTrace(trace);
                break :blk true;
            };

            var partials_map = std.StringHashMap(mstchz.Partial).init(tmp_alloc);
            var vm = mstchz.State.init(
                tmp_alloc,
                data,
                &partials_map,
                doc_struct_token,
            );
            defer vm.deinit();

            var out_buf = Io.Writer.Allocating.init(tmp_alloc);
            vm.render(&out_buf.writer) catch |e| {
                log.err("Error: {}", .{e});
                break :blk true;
            };
            log.info("\tRendered: '{s}'", .{out_buf.written()});
            log.info("\tExpected: '{s}'", .{expected_str});

            if (!std.mem.eql(u8, out_buf.written(), expected_str)) break :blk true;
            break :blk false;
        };

        const res_str = if (failed) blk: {
            fails += 1;
            log_state.flush(io) catch {};
            break :blk fail_str;
        } else blk: {
            log_state.clear();
            break :blk success_str;
        };

        log.info("...Test {s}", .{res_str});
    }
    return .{ .testcases = cases, .fails = fails };
}

const ParsedCli = struct {
    files: []const []const u8,
};

fn parseCli(alloc: mem.Allocator, args: std.process.Args) ParsedCli {
    var files = std.ArrayListUnmanaged([]const u8).empty;

    var it = args.iterateAllocator(alloc) catch @panic("OOM");
    defer it.deinit();

    _ = it.skip();
    while (it.next()) |arg| {
        files.append(alloc, arg) catch @panic("OOM");
    }
    return ParsedCli{
        .files = if (files.items.len == 0) &.{
            "./testing/spec/specs/comments.json",
            "./testing/spec/specs/delimiters.json",
            "./testing/spec/specs/interpolation.json",
            "./testing/spec/specs/inverted.json",
            "./testing/spec/specs/partials.json",
            "./testing/spec/specs/sections.json",
            //"~dynamic-names.json",
            //"~inheritance.json",
            //"~lambdas.json",
        } else files.items,
    };
}

fn printHelpAndExit(
    comptime fmt: []const u8,
    args: anytype,
    opts: struct { code: u8 = 1 },
) noreturn {
    if (comptime fmt.len != 0) {
        std.debug.print(fmt ++ "\n\n", args);
    }

    const exec_name = blk: {
        var it = std.process.args();
        break :blk it.next() orelse "mstchz_tests";
    };
    std.debug.print(
        \\{s} <test json schema files>...
        \\
        \\
    , .{exec_name});

    std.process.exit(opts.code);
}
