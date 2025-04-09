const std = @import("std");
const mem = std.mem;
const log = std.log.scoped(.@"mustachez.ast");

pub const Node = union(enum) {};
