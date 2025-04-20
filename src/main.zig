const std = @import("std");
const mem = std.mem;
const log = std.log;
const mstchz = @import("mstchz");
const ansii = @import("ansii.zig");

const new_ckey = "include";
const new_cval: []const mstchz.token.DocToken = &.{};

pub const std_options = std.Options{
    .log_level = .debug,
    //.logFn = logFn,
};

pub fn logFn(
    comptime message_level: std.log.Level,
    comptime scope: @Type(.enum_literal),
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
    out_writer: std.fs.File.Writer,
    buf: std.ArrayList(u8),
    mutex: std.Thread.Mutex = .{},
    buffering: bool = false,

    pub fn init(
        state: *LogState,
        alloc: std.mem.Allocator,
    ) void {
        state.* = .{ .buf = .init(alloc), .out_writer = std.io.getStdErr().writer() };
    }

    pub fn deinit(self: *LogState) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.buf.deinit();
        self.buffering = false;
    }

    pub const WriteError = std.fs.File.Writer.Error || std.ArrayList(u8).Writer.Error || std.mem.Allocator.Error;

    pub fn flushIfNotBuffering(self: *LogState) WriteError!void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.buffering) return;

        //std.debug.print("-....flushing because no explicit buffering:\n'{s}'\n", .{self.buf.items});

        try self.out_writer.writeAll(self.buf.items);
        self.buf.clearRetainingCapacity();
    }

    pub fn flush(self: *LogState) WriteError!void {
        self.mutex.lock();
        defer self.mutex.unlock();

        //std.debug.print("-....flushing because always does: \n'{s}'\n", .{self.buf.items});

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

pub fn main() !void {
    var dbg_alloc = std.heap.DebugAllocator(.{ .safety = true }).init;
    defer std.debug.assert(dbg_alloc.deinit() == .ok);
    const alloc = dbg_alloc.allocator();

    {
        var v = mstchz.PartialMap.init(alloc);
        defer v.deinit();

        try v.put(new_ckey, new_cval);

        _ = v.get(new_ckey);
    }

    LogState.init(&log_state, alloc);
    defer log_state.deinit();

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    var test_arena = std.heap.ArenaAllocator.init(alloc);
    defer test_arena.deinit();

    var all_testcases: usize = 0;
    var all_fails: usize = 0;
    const pcli = parseCli(arena.allocator());
    log_state.setExplicitBuffering(false);
    for (pcli.files) |file| {
        defer _ = test_arena.reset(.retain_capacity);
        log.info("=========== {s} ===========", .{std.fs.path.basename(file)});
        log.info("=========== START ===========", .{});
        const r = try testFile(test_arena.allocator(), file);
        const res_string = if (r.fails == 0) success_str else fail_str;

        log.info("=========== END ===========", .{});
        log.info("{s} ({}/{}) succeeded", .{
            res_string,
            r.successes(),
            r.testcases,
        });
        all_testcases += r.testcases;
        all_fails += r.fails;
        try log_state.flush();
    }
    log.info("This should not be rendered!", .{});
    log_state.clear();
    log_state.setExplicitBuffering(false);

    log.info("=========== Results ===========", .{});
    log.info("Testcases: {}", .{all_testcases});
    log.info("Sucesses: {}", .{all_testcases - all_fails});
    log.info("Fails: {}", .{all_fails});
    log.info("=> {s}", .{if (all_fails == 0) success_str else fail_str});
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

fn testFile(tmp_alloc: mem.Allocator, path: []const u8) !TestFileResults {
    const cwd = std.fs.cwd();
    const file_text = try cwd.readFileAlloc(tmp_alloc, path, 1 << 24);
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
        const partials_json = if (case.get("partials")) |v|
            v.object
        else
            std.json.ObjectMap.init(tmp_alloc);

        var partials = mstchz.PartialMap.init(tmp_alloc);
        {
            var it = partials_json.iterator();
            while (it.next()) |item| {
                const parsed = try mstchz.parseSliceLeaky(tmp_alloc, item.value_ptr.string);
                try partials.put(item.key_ptr.*, parsed);
            }
        }

        log.info(ansii.fg.bright_cyan ++ "Test" ++ ansii.rst ++ ": {s} ({s})", .{ name, desc });

        log.info("\tData: {s}", .{try std.json.stringifyAlloc(tmp_alloc, data, .{ .whitespace = .indent_4 })});
        log.info("\ttemplate: `{s}`", .{template});
        log.info("\tpartials: `{s}`", .{try std.json.stringifyAlloc(tmp_alloc, std.json.Value{ .object = partials_json }, .{ .whitespace = .indent_4 })});
        //log.info("\texpected: '{s}'", .{expected_str});
        log.info("\tParsing..", .{});
        const failed = blk: {
            const doc_struct_token = mstchz.parseSliceLeaky(tmp_alloc, template) catch |e| {
                log.err("Error occured: {}", .{e});
                if (@errorReturnTrace()) |trace| std.debug.dumpStackTrace(trace.*);
                break :blk true;
            };

            log.info("Tokens:", .{});
            for (doc_struct_token) |token| switch (token) {
                .text => |d| log.info("\tTEXT '{s}'", .{d}),
                .tag => |d| {
                    log.info("\tTAG {} (prefix: '{?s}')", .{ d.type, d.standalone_line_prefix });
                    for (d.body) |item| {
                        log.info("\t\t{} '{s}'", .{ item.len, item });
                    }
                },
            };

            log.info("partial include: {any}", .{partials.get("include")});
            var vm = try mstchz.State.init(
                tmp_alloc,
                mstchz.Hash{ .inner = data },
                &partials,
                doc_struct_token,
                .{},
            );
            defer vm.deinit();

            var out_buf = std.ArrayList(u8).init(tmp_alloc);
            vm.render(out_buf.writer()) catch |e| {
                log.err("Error: {}", .{e});
                break :blk true;
            };
            log.info("\tRendered: '{s}'", .{out_buf.items});
            log.info("\tExpected: '{s}'", .{expected_str});

            if (!std.mem.eql(u8, out_buf.items, expected_str)) break :blk true;
            break :blk false;
        };

        const res_str = if (failed) blk: {
            fails += 1;
            log_state.flush() catch {};
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

fn parseCli(alloc: mem.Allocator) ParsedCli {
    var files = std.ArrayListUnmanaged([]const u8).empty;

    var it = std.process.args();
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
    _ = opts;
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
}
