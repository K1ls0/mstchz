const std = @import("std");
const testing = std.testing;
const mem = std.mem;
const log = std.log.scoped(.mustachez);
const assert = std.debug.assert;

pub const token = @import("token.zig");
pub const runtime = @import("runtime.zig");
pub const Tokenizer = @import("Tokenizer.zig");
pub const parseSliceLeaky = Tokenizer.parseSliceLeaky;

pub const PartialMap = std.StringHashMap([]const token.DocToken);

pub const Hash = struct {
    inner: std.json.Value,

    pub const GetError = error{ FieldNotAccessable, FieldNotExistant, AtArrayEnd };
    pub fn getField(self: Hash, name: []const u8) GetError!Hash {
        switch (self.inner) {
            .object => |o| return if (o.get(name)) |v| .{ .inner = v } else {
                log.err("Field '{s}' does not exist!", .{name});
                return error.FieldNotExistant;
            },
            else => {
                log.err(
                    "Trying to access '{s}' on value of type {s}",
                    .{ name, @tagName(self.inner) },
                );
                return error.FieldNotAccessable;
            },
        }
    }

    pub fn interpolateBool(self: Hash) bool {
        return switch (self.inner) {
            .null => false,
            .bool => |b| b,
            .integer => |i| i != 0,
            .float => |f| f != 0.0 and f != std.math.nan(f64),
            .number_string => @panic("Unsupported BigNumbers"),
            .string => |s| s.len != 0,
            .object => |o| o.count() != 0,
            .array => |a| a.items.len != 0,
        };
    }

    pub fn indexable(self: Hash) bool {
        return switch (self.inner) {
            .object, .array => true,
            else => false,
        };
    }

    pub const IterError = error{NotIterable};

    pub fn iterator(self: Hash) IterError!Iterator {
        switch (self.inner) {
            .array => |v| return Iterator{ .val = v.items, .idx = 0 },
            else => return error.NotIterable,
        }
    }

    pub const Iterator = struct {
        val: []const std.json.Value,
        idx: usize,

        pub fn peek(self: Iterator) ?Hash {
            if (self.idx >= self.val.len) return null;
            return Hash{ .inner = self.val[self.idx] };
        }

        pub fn next(self: *Iterator) ?Hash {
            if (self.idx >= self.val.len) return null;
            defer self.idx += 1;
            return Hash{ .inner = self.val[self.idx] };
        }
    };

    pub fn stringify(self: Hash, writer: anytype) @TypeOf(writer).Error!void {
        switch (self.inner) {
            .null => {},
            .bool => |b| try writer.writeAll(if (b) "true" else "false"),
            .integer => |i| try std.fmt.formatInt(i, 10, .lower, .{}, writer),
            .float => |f| try std.fmt.format(writer, "{d}", .{f}),
            .number_string => |nr| try writer.writeAll(nr),
            .string => |s| try writer.writeAll(s), // TODO Escape html
            else => try std.json.stringify(self.inner, .{}, writer), // TODO: Escape html
        }
    }

    pub const SubResult = union(enum) {
        found: Hash,
        not_found_fully,
        not_found,
    };
    pub fn sub(self: Hash, accessors: []const []const u8) SubResult {
        var chash = self;
        var first = true;
        for (accessors) |v| {
            chash = chash.getField(v) catch {
                if (first) return .not_found;
                return .not_found_fully;
            };
            first = false;
        }
        return .{ .found = chash };
    }
};

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
        tokens: []const token.DocToken,
    ) ?[]const []const u8 {
        const start = self.start_tag orelse return null;
        assert(start < tokens.len);
        return switch (tokens[start]) {
            .text => null,
            .tag => |t| t.body,
        };
    }
};

fn accessorsEql(self: []const []const u8, other: []const []const u8) bool {
    if (self.len != other.len) return false;
    for (self, other) |cself, cother| {
        if (!std.mem.eql(u8, cself, cother)) return false;
    }
    return true;
}

pub const State = struct {
    allocator: mem.Allocator,
    exec_arena: std.heap.ArenaAllocator,

    scopes: Scopes,

    partials: *const PartialMap,
    input: []const token.DocToken,

    standalone_line_prefix: ?[]const u8,

    pub const InitOptions = struct {
        line_prefix: ?[]const u8 = null,
    };
    pub fn init(
        allocator: mem.Allocator,
        ctx: Hash,
        partials: *const PartialMap,
        input: []const token.DocToken,
        options: InitOptions,
    ) mem.Allocator.Error!State {
        var scopes = try Scopes.init(allocator);
        try scopes.push(Scope{
            .start_tag = null,
            .state = .{ .block = .{ .hash = ctx, .block_state = .run } },
        }, &.{});
        return State{
            .allocator = allocator,
            .exec_arena = .init(allocator),
            .partials = partials,
            .input = input,
            .standalone_line_prefix = options.line_prefix,
            .scopes = scopes,
        };
    }

    pub fn deinit(self: *State) void {
        self.scopes.deinit();
        self.exec_arena.deinit();
    }

    pub const RenderError = error{
        Unsupported,
        NoObject,
        NoField,
        UnclosedTag,
        PartialAcceptsOneArgument,
        PartialNotAvailable,
        EncodingError,
    } || Hash.GetError || Hash.IterError;

    pub fn render(self: *State, writer: anytype) (RenderError || mem.Allocator.Error || @TypeOf(writer).Error)!void {
        if (self.standalone_line_prefix) |prefix| try writer.writeAll(prefix);

        var token_idx: usize = 0;

        while (token_idx < self.input.len) : (token_idx += 1) {
            const ctoken = self.input[token_idx];
            log.info("ctoken: {}: {s} -> '{s}'", .{ token_idx, @tagName(ctoken), @as([]const u8, switch (ctoken) {
                .text => |t| t,
                .tag => |t| @tagName(t.type),
            }) });
            if (self.scopes.currentScope().blockState() == .skip) {
                log.info("In skipping mode:", .{});
                switch (ctoken) {
                    .text => log.info("\tText", .{}),
                    .tag => |t| log.info("\tTag: {s}", .{@tagName(t.type)}),
                }
            }

            switch (ctoken) {
                .text => |txt| {
                    if (self.scopes.currentScope().blockState() == .skip) continue;

                    var start: usize = 0;
                    if (self.standalone_line_prefix) |line_prefix| {
                        for (txt, 0..) |cc, i| {
                            if (cc == '\n') {
                                try writer.writeAll(txt[start .. i + 1]);
                                const emit_prefix = blk: {
                                    // Strip last newline of this render because apparently it is not
                                    // permitted to insert the indentation to a lagging newline.
                                    const last_token = token_idx == self.input.len - 1;
                                    const is_partial = self.standalone_line_prefix != null;
                                    const current_is_lagging = i == txt.len - 1;
                                    break :blk !(last_token and is_partial and current_is_lagging);
                                };
                                if (emit_prefix) try writer.writeAll(line_prefix);
                                start = i + 1;
                            }
                        }
                        if (start < txt.len) try writer.writeAll(txt[start..]);
                    } else try writer.writeAll(txt);
                },
                .tag => |t| switch (t.type) {
                    .comment => assert(t.body.len == 1),
                    .delimiter_change => assert(t.body.len == 2),
                    .variable, .unescaped_variable => |any_variable| {
                        self.scopes.printCurrentLookup();

                        const sub_hash = self.scopes.lookup(t.body) orelse continue;

                        if (self.scopes.currentScope().blockState() == .skip) continue;
                        switch (any_variable) {
                            .variable => {
                                var encoding_writer = runtime.escapingWriter(writer);
                                const ewriter = encoding_writer.writer();
                                try sub_hash.stringify(ewriter);
                            },
                            .unescaped_variable => try sub_hash.stringify(writer),
                            else => unreachable,
                        }
                    },
                    .section_open => {
                        const current_is_skip = self.scopes.currentScope().blockState() == .skip;

                        const sub_hash: ?Hash = self.scopes.lookup(t.body) orelse null;
                        log.info("[section open] current hash global lookup:", .{});
                        self.scopes.printCurrentLookup();

                        const new_scope = if (sub_hash) |ch| blk: {
                            // We are skipping already, but still need to keep track of tags,
                            // add this tag as a skipped block
                            if (current_is_skip) break :blk Scope{
                                .start_tag = token_idx,
                                .state = .{ .block = .{ .hash = null, .block_state = .skip } },
                            };

                            if (ch.interpolateBool()) {
                                if (ch.iterator()) |it| {
                                    break :blk Scope{ // Iterable scope
                                        .state = Scope.ScopeState{ .iter = it },
                                        .start_tag = token_idx,
                                    };
                                } else |e| { // boolean block
                                    assert(e == error.NotIterable);
                                    break :blk Scope{ .state = .{
                                        .block = .{
                                            .hash = sub_hash,
                                            .block_state = .run,
                                        },
                                    }, .start_tag = token_idx };
                                }
                            } else {
                                // Skipping block
                                break :blk Scope{ .state = .{
                                    .block = .{
                                        .hash = null,
                                        .block_state = .skip,
                                    },
                                }, .start_tag = token_idx };
                            }
                        } else Scope{ // This Block cannot be entered as it is not existent, skip it
                            .state = .{ .block = .{ .hash = null, .block_state = .skip } },
                            .start_tag = token_idx,
                        };

                        try self.scopes.push(new_scope, t.body);
                    },
                    .inverted_section_open => {
                        const current_is_skip = self.scopes.currentScope().blockState() == .skip;

                        const run_section = if (self.scopes.lookup(t.body)) |ch| blk: {
                            log.info("got hash", .{});
                            {
                                const as_str = std.json.stringifyAlloc(
                                    self.exec_arena.allocator(),
                                    ch,
                                    .{},
                                ) catch @panic("OOM");
                                log.info("[inverted] current_ctx: {s}", .{as_str});
                            }
                            break :blk !ch.interpolateBool();
                        } else blk: {
                            log.info("no hash", .{});
                            break :blk true;
                        };
                        log.info("[inverted] run_section: {any} is_skip: {}", .{ run_section, current_is_skip });

                        try self.scopes.push(Scope{
                            .state = .{ .block = .{
                                .hash = null,
                                .block_state = if (current_is_skip)
                                    .skip
                                else if (run_section) .run else .skip,
                            } },
                            .start_tag = token_idx,
                        }, t.body);
                    },
                    .section_close => {
                        const cscope = self.scopes.currentScope();
                        const start_accessor = cscope.getStartAccessor(self.input) orelse unreachable;
                        if (!accessorsEql(start_accessor, t.body)) {
                            log.err("Block not closed", .{});
                            return error.UnclosedTag;
                        }

                        log.info("[section close] current lookup", .{});
                        self.scopes.printCurrentLookup();

                        switch (cscope.state) {
                            .block => |_| _ = self.scopes.pop(t.body),
                            .iter => |*it| {
                                _ = it.next();
                                if (it.peek()) |_| {
                                    token_idx = cscope.start_tag.?;
                                } else {
                                    _ = self.scopes.pop(t.body);
                                }
                            },
                        }
                    },
                    .partial => {
                        log.info("standalone ? {}", .{t.standalone_line_prefix != null});
                        assert(t.body.len == 1);
                        if (self.scopes.currentScope().blockState() == .skip) continue;

                        const partial_name = t.body[0];
                        const chash = self.scopes.currentHash();
                        if (self.partials.*.get(partial_name)) |partial| {
                            var state = try State.init(
                                self.allocator,
                                chash,
                                self.partials,
                                partial,
                                .{ .line_prefix = t.standalone_line_prefix },
                            );
                            defer state.deinit();
                            try state.render(writer);

                            for (partial) |p| {
                                switch (p) {
                                    .text => |ct| {
                                        log.info("\tTEXT: {s}", .{ct});
                                    },
                                    .tag => |ct| {
                                        log.info("\tTAG {s}", .{@tagName(ct.type)});
                                    },
                                }
                            }
                            // TODO:
                        } else {
                            log.info("Could not find partial with name '{s}'", .{partial_name});
                        }
                    },
                    //else => {
                    //    log.err("unsupported token {s}", .{@tagName(t.type)});
                    //    return error.Unsupported;
                    //},
                },
            }
        }
    }
    fn isTextAndLaggingNewline(input: []const token.DocToken, prefix: ?[]const u8, i: usize) bool {
        return input.len != 0 and
            i == (input.len - 1) and
            prefix != null and
            input.len != 0 and
            input[i] == .text and
            input[i].text.len != 0 and
            input[i].text[input[i].text.len - 1] == '\n';
    }
};

pub const Scopes = struct {
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

    pub fn currentHash(self: Scopes) Hash {
        assert(self.stack.items.len > 0);
        assert(self.stack.items[0].state == .block);
        assert(self.stack.items[0].state.block.hash != null);

        for (0..self.stack.items.len) |u| {
            const i = self.stack.items.len - 1 - u;
            switch (self.stack.items[i].state) {
                .block => |b| if (b.hash) |h| return h,
                .iter => |*it| if (it.peek()) |h| return h,
            }
        }
        @panic("At least the root scope has to be occupied, so this should not happen " ++
            "(No valid scope hash available)");
    }

    pub fn currentScope(self: Scopes) *Scope {
        assert(self.stack.items.len > 0);
        return &self.stack.items[self.stack.items.len - 1];
    }

    fn printCurrentLookup(self: Scopes) void {
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

        pub fn next(self: *HashIterator) ?Hash {
            if (self.i >= self.stack.len) return null;

            while (self.i < self.stack.len) {
                defer self.i += 1;

                const i = self.stack.len - 1 - self.i;
                switch (self.stack[i].state) {
                    .block => |b| if (b.hash) |h| return h,
                    .iter => |*it| if (it.peek()) |h| return h,
                }
            }
            return null;
        }
    };

    fn hashIterator(self: Scopes) HashIterator {
        return HashIterator{ .i = 0, .stack = self.stack.items };
    }

    pub fn lookup(self: Scopes, accessors: []const []const u8) ?Hash {
        assert(self.stack.items.len > 0);
        assert(self.stack.items[0].state == .block);
        assert(self.stack.items[0].state.block.hash != null);

        var it = self.hashIterator();
        while (it.next()) |h| {
            switch (h.sub(accessors)) {
                .found => |v| return v,
                .not_found_fully => return null,
                .not_found => {},
            }
        }
        return null;
    }
};

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

test {
    _ = @import("token.zig");
    _ = @import("token.zig");
    _ = @import("Tokenizer.zig");
}
