const std = @import("std");
const mem = std.mem;
const log = std.log;
const mstchz = @import("mstchz");
const ansii = @import("ansii.zig");
const log_state = @import("log_state.zig");

pub const std_options = std.Options{
    .log_level = .debug,
    //.logFn = logFn,
};

const success_str = ansii.fg.bright_green ++ "passed" ++ ansii.rst;
const fail_str = ansii.fg.bright_red ++ "failed" ++ ansii.rst;

pub fn main() !void {
    var dbg_alloc = std.heap.DebugAllocator(.{ .safety = true }).init;
    defer std.debug.assert(dbg_alloc.deinit() == .ok);
    const alloc = dbg_alloc.allocator();

    log_state.init(alloc);
    defer log_state.deinit();

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    var all_testcases: usize = 0;
    var all_fails: usize = 0;
    const pcli = parseCli(arena.allocator());
    log_state.setExplicitBuffering(false);
    for (pcli.files) |file| {
        log.info("=========== {s} ===========", .{std.fs.path.basename(file)});
        log.info("=========== START ===========", .{});
        const r = try testFile(dbg_alloc.allocator(), file);
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

fn testFile(alloc: mem.Allocator, path: []const u8) !TestFileResults {
    var input_arena = std.heap.ArenaAllocator.init(alloc);
    defer input_arena.deinit();
    const tmp_alloc = input_arena.allocator();

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
        const data = &case.get("data").?;
        const template = case.get("template").?.string;
        const expected_str = case.get("expected").?.string;
        const partials_json = if (case.get("partials")) |v|
            v.object
        else
            std.json.ObjectMap.init(tmp_alloc);

        var partials = mstchz.PartialMap.init(alloc);
        defer partials.deinit();
        {
            var it = partials_json.iterator();
            while (it.next()) |item| {
                const parsed = try mstchz.parseSliceLeaky(tmp_alloc, item.value_ptr.string);
                try partials.put(item.key_ptr.*, parsed);
            }
        }

        log.info(ansii.fg.bright_cyan ++ "Test" ++ ansii.rst ++ ": {s} ({s})", .{ name, desc });

        log.info("\tData: {s}", .{try std.json.stringifyAlloc(tmp_alloc, data.*, .{ .whitespace = .indent_4 })});
        log.info("\ttemplate: `{s}`", .{template});
        log.info("\tpartials: `{s}`", .{try std.json.stringifyAlloc(tmp_alloc, std.json.Value{ .object = partials_json }, .{ .whitespace = .indent_4 })});
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

            const hash = mstchz.Hash{ .inner = @ptrCast(data) };
            var vm = try mstchz.RenderState.init(
                alloc,
                hash,
                hash_impl.vtable,
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

const hash_impl = struct {
    const vtable = mstchz.Hash.VTable{
        .getFieldFn = &getField,
        .getAtFn = &getAt,
        .interpolateBoolFn = &interpolateBool,
        .stringifyFn = &stringify,
    };

    pub fn getField(_: mstchz.Hash.Ctx, inner: *const anyopaque, name: []const u8) mstchz.Hash.GetFieldError!mstchz.Hash {
        const val: *const std.json.Value = @ptrCast(@alignCast(inner));
        switch (val.*) {
            .object => |o| return if (o.getPtr(name)) |v| mstchz.Hash{ .inner = v } else {
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

    pub fn getAt(_: mstchz.Hash.Ctx, inner: *const anyopaque, idx: usize) mstchz.Hash.GetAtError!mstchz.Hash {
        const val: *const std.json.Value = @ptrCast(@alignCast(inner));

        switch (val.*) {
            .array => |*a| {
                if (idx >= a.items.len) {
                    log.err("Field '{}' is out of bounds!", .{idx});
                    return error.OutOfBounds;
                }
                return mstchz.Hash{ .inner = &a.items[idx] };
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

    pub fn interpolateBool(_: mstchz.Hash.Ctx, inner: *const anyopaque) bool {
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

    fn stringify(_: mstchz.Hash.Ctx, inner: *const anyopaque, writer: std.io.AnyWriter) anyerror!void {
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
};

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
