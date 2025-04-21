const std = @import("std");
const mem = std.mem;
const log = std.log.scoped(.mustachez);
const assert = std.debug.assert;

const escape = @import("escape.zig");
const token = @import("token.zig");
const Token = token.Token;
pub const Hash = @import("Hash.zig");

pub const PartialMap = std.StringHashMap([]const Token);
const Scopes = @import("Scopes.zig");

const RenderState = @This();

allocator: mem.Allocator,
exec_arena: std.heap.ArenaAllocator,

scopes: Scopes,

token_idx: usize,

partials: *const PartialMap,
input: []const Token,

standalone_line_prefix: ?[]const u8,
hash_ctx: Hash.Ctx,

pub const InitOptions = struct {
    line_prefix: ?[]const u8 = null,
};
pub fn init(
    allocator: mem.Allocator,
    hash: Hash,
    hash_ctx: Hash.Ctx,
    partials: *const PartialMap,
    input: []const Token,
    options: InitOptions,
) mem.Allocator.Error!RenderState {
    var scopes = try Scopes.init(allocator);
    try scopes.push(Scopes.Scope{
        .start_tag = null,
        .state = .{ .block = .{ .hash = hash, .block_state = .run } },
    }, &.{});
    return RenderState{
        .allocator = allocator,
        .exec_arena = .init(allocator),
        .partials = partials,
        .input = input,
        .standalone_line_prefix = options.line_prefix,
        .scopes = scopes,
        .hash_ctx = hash_ctx,
        .token_idx = 0,
    };
}

pub fn deinit(self: *RenderState) void {
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
} || Hash.GetFieldError || Hash.IterError;

pub fn render(self: *RenderState, writer: anytype) (RenderError || mem.Allocator.Error || @TypeOf(writer).Error)!void {
    if (self.standalone_line_prefix) |prefix| try writer.writeAll(prefix);

    while (self.token_idx < self.input.len) : (self.token_idx += 1) {
        const ctoken = self.input[self.token_idx];

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
                                const last_token = self.token_idx == self.input.len - 1;
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
                    const sub_hash = self.scopes.lookup(self.hash_ctx, t.body) orelse continue;

                    if (self.scopes.currentScope().blockState() == .skip) continue;
                    switch (any_variable) {
                        .variable => {
                            var encoding_writer = escape.escapingWriter(writer);
                            const ewriter = encoding_writer.writer();
                            try sub_hash.stringify(self.hash_ctx, ewriter);
                        },
                        .unescaped_variable => try sub_hash.stringify(self.hash_ctx, writer),
                        else => unreachable,
                    }
                },
                .section_open => {
                    const current_is_skip = self.scopes.currentScope().blockState() == .skip;

                    const sub_hash: ?Hash = self.scopes.lookup(self.hash_ctx, t.body) orelse null;

                    const new_scope = if (sub_hash) |ch| blk: {
                        // We are skipping already, but still need to keep track of tags,
                        // add this tag as a skipped block
                        if (current_is_skip) break :blk Scopes.Scope{
                            .start_tag = self.token_idx,
                            .state = .{ .block = .{ .hash = null, .block_state = .skip } },
                        };

                        {
                            const v: *const std.json.Value = @ptrCast(@alignCast(ch.inner));
                            const r = std.json.stringifyAlloc(std.heap.smp_allocator, v.*, .{}) catch |e| std.debug.panic("{}", .{e});
                            defer std.heap.smp_allocator.free(r);
                        }
                        if (ch.interpolateBool(self.hash_ctx)) {
                            if (ch.iterator(self.hash_ctx)) |it| {
                                break :blk Scopes.Scope{ // Iterable scope
                                    .state = Scopes.Scope.ScopeState{ .iter = it },
                                    .start_tag = self.token_idx,
                                };
                            } else |e| { // boolean block
                                assert(e == error.NotIterable);
                                break :blk Scopes.Scope{ .state = .{
                                    .block = .{
                                        .hash = sub_hash,
                                        .block_state = .run,
                                    },
                                }, .start_tag = self.token_idx };
                            }
                        } else {
                            // Skipping block
                            break :blk Scopes.Scope{ .state = .{
                                .block = .{
                                    .hash = null,
                                    .block_state = .skip,
                                },
                            }, .start_tag = self.token_idx };
                        }
                    } else Scopes.Scope{ // This Block cannot be entered as it is not existent, skip it
                        .state = .{ .block = .{ .hash = null, .block_state = .skip } },
                        .start_tag = self.token_idx,
                    };

                    try self.scopes.push(new_scope, t.body);
                },
                .inverted_section_open => {
                    const current_is_skip = self.scopes.currentScope().blockState() == .skip;

                    const run_section = if (self.scopes.lookup(self.hash_ctx, t.body)) |ch| blk: {
                        break :blk !ch.interpolateBool(self.hash_ctx);
                    } else blk: {
                        break :blk true;
                    };

                    try self.scopes.push(Scopes.Scope{
                        .state = .{ .block = .{
                            .hash = null,
                            .block_state = if (current_is_skip)
                                .skip
                            else if (run_section) .run else .skip,
                        } },
                        .start_tag = self.token_idx,
                    }, t.body);
                },
                .section_close => {
                    const cscope = self.scopes.currentScope();
                    const start_accessor = cscope.getStartAccessor(self.input) orelse unreachable;
                    if (!accessorsEql(start_accessor, t.body)) {
                        log.err("Block not closed", .{});
                        return error.UnclosedTag;
                    }

                    switch (cscope.state) {
                        .block => |_| _ = self.scopes.pop(t.body),
                        .iter => |*it| {
                            _ = it.next(self.hash_ctx);
                            if (it.peek(self.hash_ctx)) |_| {
                                self.token_idx = cscope.start_tag.?;
                            } else {
                                _ = self.scopes.pop(t.body);
                            }
                        },
                    }
                },
                .partial => {
                    assert(t.body.len == 1);
                    if (self.scopes.currentScope().blockState() == .skip) continue;

                    const partial_name = t.body[0];
                    const chash = self.scopes.currentHash(self.hash_ctx);
                    if (self.partials.*.get(partial_name)) |partial| {
                        var state = try RenderState.init(
                            self.allocator,
                            chash,
                            self.hash_ctx,
                            self.partials,
                            partial,
                            .{ .line_prefix = t.standalone_line_prefix },
                        );
                        defer state.deinit();
                        try state.render(writer);
                    } else {
                        log.info("Could not find partial with name '{s}'", .{partial_name});
                    }
                },
            },
        }
    }
}

fn isTextAndLaggingNewline(input: []const Token, prefix: ?[]const u8, i: usize) bool {
    return input.len != 0 and
        i == (input.len - 1) and
        prefix != null and
        input.len != 0 and
        input[i] == .text and
        input[i].text.len != 0 and
        input[i].text[input[i].text.len - 1] == '\n';
}

fn accessorsEql(self: []const []const u8, other: []const []const u8) bool {
    if (self.len != other.len) return false;
    for (self, other) |cself, cother| {
        if (!std.mem.eql(u8, cself, cother)) return false;
    }
    return true;
}
