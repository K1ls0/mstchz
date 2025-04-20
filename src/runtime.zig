const std = @import("std");
const testing = std.testing;
const mem = std.mem;
const log = std.log.scoped(.@"mustachez.runtime");
const assert = std.debug.assert;
const token = @import("token.zig");

const mappings = .{
    .{ .code = '<', .esc = "&lt;" },
    .{ .code = '&', .esc = "&amp;" },
    .{ .code = '<', .esc = "&lt;" },
    .{ .code = '>', .esc = "&gt;" },
    .{ .code = '"', .esc = "&quot;" },
    //.{ .code = '\xA0', .esc = "&nbsp;" },
    //.{ .code = '¡', .esc = "&iexcl;" },
    //.{ .code = '¢', .esc = "&cent;" },
    //.{ .code = '£', .esc = "&pound;" },
    //.{ .code = '¤', .esc = "&curren;" },
    //.{ .code = '¥', .esc = "&yen;" },
    //.{ .code = '¦', .esc = "&brvbar;" },
    //.{ .code = '§', .esc = "&sect;" },
    //.{ .code = '¨', .esc = "&uml;" },
    //.{ .code = '©', .esc = "&copy;" },
    //.{ .code = 'ª', .esc = "&ordf;" },
    //.{ .code = '«', .esc = "&laquo;" },
    //.{ .code = '¬', .esc = "&not;" },
    //.{ .code = '­', .esc = "&shy;" },
    //.{ .code = '®', .esc = "&reg;" },
    //.{ .code = '¯', .esc = "&macr;" },
    //.{ .code = '°', .esc = "&deg;" },
    //.{ .code = '±', .esc = "&plusmn;" },
    //.{ .code = '²', .esc = "&sup2;" },
    //.{ .code = '³', .esc = "&sup3;" },
    //.{ .code = '´', .esc = "&acute;" },
    //.{ .code = 'µ', .esc = "&micro;" },
    //.{ .code = '¶', .esc = "&para;" },
    //.{ .code = '¸', .esc = "&cedil;" },
    //.{ .code = '¹', .esc = "&sup1;" },
    //.{ .code = 'º', .esc = "&ordm;" },
    //.{ .code = '»', .esc = "&raquo;" },
    //.{ .code = '¼', .esc = "&frac14;" },
    //.{ .code = '½', .esc = "&frac12;" },
    //.{ .code = '¾', .esc = "&frac34;" },
    //.{ .code = '¿', .esc = "&iquest;" },
    //.{ .code = '×', .esc = "&times;" },
    //.{ .code = '÷', .esc = "&divide;" },
    //.{ .code = '∀', .esc = "&forall;" },
    //.{ .code = '∂', .esc = "&part;" },
    //.{ .code = '∃', .esc = "&exist;" },
    //.{ .code = '∅', .esc = "&empty;" },
    //.{ .code = '∇', .esc = "&nabla;" },
    //.{ .code = '∈', .esc = "&isin;" },
    //.{ .code = '∉', .esc = "&notin;" },
    //.{ .code = '∋', .esc = "&ni;" },
    //.{ .code = '∏', .esc = "&prod;" },
    //.{ .code = '∑', .esc = "&sum;" },
    //.{ .code = '−', .esc = "&minus;" },
    //.{ .code = '∗', .esc = "&lowast;" },
    //.{ .code = '√', .esc = "&radic;" },
    //.{ .code = '∝', .esc = "&prop;" },
    //.{ .code = '∞', .esc = "&infin;" },
    //.{ .code = '∠', .esc = "&ang;" },
    //.{ .code = '∧', .esc = "&and;" },
    //.{ .code = '∨', .esc = "&or;" },
    //.{ .code = '∩', .esc = "&cap;" },
    //.{ .code = '∪', .esc = "&cup;" },
    //.{ .code = '∫', .esc = "&int;" },
    //.{ .code = '∴', .esc = "&there4;" },
    //.{ .code = '∼', .esc = "&sim;" },
    //.{ .code = '≅', .esc = "&cong;" },
    //.{ .code = '≈', .esc = "&asymp;" },
    //.{ .code = '≠', .esc = "&ne;" },
    //.{ .code = '≡', .esc = "&equiv;" },
    //.{ .code = '≤', .esc = "&le;" },
    //.{ .code = '≥', .esc = "&ge;" },
    //.{ .code = '⊂', .esc = "&sub;" },
    //.{ .code = '⊃', .esc = "&sup;" },
    //.{ .code = '⊄', .esc = "&nsub;" },
    //.{ .code = '⊆', .esc = "&sube;" },
    //.{ .code = '⊇', .esc = "&supe;" },
    //.{ .code = '⊕', .esc = "&oplus;" },
    //.{ .code = '⊗', .esc = "&otimes;" },
    //.{ .code = '⊥', .esc = "&perp;" },
    //.{ .code = '⋅', .esc = "&sdot;" },
    //.{ .code = 'Α', .esc = "&Alpha;" },
    //.{ .code = 'Β', .esc = "&Beta;" },
    //.{ .code = 'Γ', .esc = "&Gamma;" },
    //.{ .code = 'Δ', .esc = "&Delta;" },
    //.{ .code = 'Ε', .esc = "&Epsilon;" },
    //.{ .code = 'Ζ', .esc = "&Zeta;" },
    //.{ .code = 'Η', .esc = "&Eta;" },
    //.{ .code = 'Θ', .esc = "&Theta;" },
    //.{ .code = 'Ι', .esc = "&Iota;" },
    //.{ .code = 'Κ', .esc = "&Kappa;" },
    //.{ .code = 'Λ', .esc = "&Lambda;" },
    //.{ .code = 'Μ', .esc = "&Mu;" },
    //.{ .code = 'Ν', .esc = "&Nu;" },
    //.{ .code = 'Ξ', .esc = "&Xi;" },
    //.{ .code = 'Ο', .esc = "&Omicron;" },
    //.{ .code = 'Π', .esc = "&Pi;" },
    //.{ .code = 'Ρ', .esc = "&Rho;" },
    //.{ .code = 'Σ', .esc = "&Sigma;" },
    //.{ .code = 'Τ', .esc = "&Tau;" },
    //.{ .code = 'Υ', .esc = "&Upsilon;" },
    //.{ .code = 'Φ', .esc = "&Phi;" },
    //.{ .code = 'Χ', .esc = "&Chi;" },
    //.{ .code = 'Ψ', .esc = "&Psi;" },
    //.{ .code = 'Ω', .esc = "&Omega;" },
    //.{ .code = 'α', .esc = "&alpha;" },
    //.{ .code = 'β', .esc = "&beta;" },
    //.{ .code = 'γ', .esc = "&gamma;" },
    //.{ .code = 'δ', .esc = "&delta;" },
    //.{ .code = 'ε', .esc = "&epsilon;" },
    //.{ .code = 'ζ', .esc = "&zeta;" },
    //.{ .code = 'η', .esc = "&eta;" },
    //.{ .code = 'θ', .esc = "&theta;" },
    //.{ .code = 'ι', .esc = "&iota;" },
    //.{ .code = 'κ', .esc = "&kappa;" },
    //.{ .code = 'λ', .esc = "&lambda;" },
    //.{ .code = 'μ', .esc = "&mu;" },
    //.{ .code = 'ν', .esc = "&nu;" },
    //.{ .code = 'ξ', .esc = "&xi;" },
    //.{ .code = 'ο', .esc = "&omicron;" },
    //.{ .code = 'π', .esc = "&pi;" },
    //.{ .code = 'ρ', .esc = "&rho;" },
    //.{ .code = 'ς', .esc = "&sigmaf;" },
    //.{ .code = 'σ', .esc = "&sigma;" },
    //.{ .code = 'τ', .esc = "&tau;" },
    //.{ .code = 'υ', .esc = "&upsilon;" },
    //.{ .code = 'φ', .esc = "&phi;" },
    //.{ .code = 'χ', .esc = "&chi;" },
    //.{ .code = 'ψ', .esc = "&psi;" },
    //.{ .code = 'ω', .esc = "&omega;" },
    //.{ .code = 'ϑ', .esc = "&thetasym;" },
    //.{ .code = 'ϒ', .esc = "&upsih;" },
    //.{ .code = 'ϖ', .esc = "&piv;" },
    //.{ .code = 'Œ', .esc = "&OElig;" },
    //.{ .code = 'œ', .esc = "&oelig;" },
    //.{ .code = 'Š', .esc = "&Scaron;" },
    //.{ .code = 'š', .esc = "&scaron;" },
    //.{ .code = 'Ÿ', .esc = "&Yuml;" },
    //.{ .code = 'ƒ', .esc = "&fnof;" },
    //.{ .code = 'ˆ', .esc = "&circ;" },
    //.{ .code = '˜', .esc = "&tilde;" },
    //.{ .code = ' ', .esc = "&ensp;" },
    //.{ .code = ' ', .esc = "&emsp;" },
    //.{ .code = ' ', .esc = "&thinsp;" },
    //.{ .code = '‌', .esc = "&zwnj;" },
    //.{ .code = '‍', .esc = "&zwj;" },
    //.{ .code = '‎', .esc = "&lrm;" },
    //.{ .code = '‏', .esc = "&rlm;" },
    //.{ .code = '–', .esc = "&ndash;" },
    //.{ .code = '—', .esc = "&mdash;" },
    //.{ .code = '‘', .esc = "&lsquo;" },
    //.{ .code = '’', .esc = "&rsquo;" },
    //.{ .code = '‚', .esc = "&sbquo;" },
    //.{ .code = '“', .esc = "&ldquo;" },
    //.{ .code = '”', .esc = "&rdquo;" },
    //.{ .code = '„', .esc = "&bdquo;" },
    //.{ .code = '†', .esc = "&dagger;" },
    //.{ .code = '‡', .esc = "&Dagger;" },
    //.{ .code = '•', .esc = "&bull;" },
    //.{ .code = '…', .esc = "&hellip;" },
    //.{ .code = '‰', .esc = "&permil;" },
    //.{ .code = '′', .esc = "&prime;" },
    //.{ .code = '″', .esc = "&Prime;" },
    //.{ .code = '‹', .esc = "&lsaquo;" },
    //.{ .code = '›', .esc = "&rsaquo;" },
    //.{ .code = '‾', .esc = "&oline;" },
    //.{ .code = '€', .esc = "&euro;" },
    //.{ .code = '™', .esc = "&trade;" },
    //.{ .code = '←', .esc = "&larr;" },
    //.{ .code = '↑', .esc = "&uarr;" },
    //.{ .code = '→', .esc = "&rarr;" },
    //.{ .code = '↓', .esc = "&darr;" },
    //.{ .code = '↔', .esc = "&harr;" },
    //.{ .code = '↵', .esc = "&crarr;" },
    //.{ .code = '⌈', .esc = "&lceil;" },
    //.{ .code = '⌉', .esc = "&rceil;" },
    //.{ .code = '⌊', .esc = "&lfloor;" },
    //.{ .code = '⌋', .esc = "&rfloor;" },
    //.{ .code = '◊', .esc = "&loz;" },
    //.{ .code = '♠', .esc = "&spades;" },
    //.{ .code = '♣', .esc = "&clubs;" },
    //.{ .code = '♥', .esc = "&hearts;" },
    //.{ .code = '♦', .esc = "&diams;" },
};

pub fn htmlUnescapeNextChar(input: []const u8) error{NoHtmlEscapedSequence}!struct { u21, usize } {
    if (input[0] != '&') return error.NoHtmlEscapedSequence;
    inline for (mappings) |m| {
        if (std.mem.startsWith(u8, input[1..], m.esc[1..])) return m.code;
    }
}

pub fn htmlEscapeChar(codepoint: u21, writer: anytype) (@TypeOf(writer).Error || error{EncodingError})!void {
    inline for (mappings) |m| {
        if (codepoint == m.code) {
            try writer.writeAll(m.esc);
            return;
        }
    }
    {
        var buf: [8]u8 = undefined;
        const enc_len = std.unicode.utf8Encode(codepoint, &buf) catch return error.EncodingError;

        try writer.writeAll(buf[0..enc_len]);
    }
}

pub fn EscapingWriter(comptime T: type) type {
    return struct {
        const Self = @This();

        pub const Writer = std.io.GenericWriter(*Self, Error, write);
        pub const Error = T.Error || error{EncodingError};

        inner: T,
        buf: [1024]u8 = undefined,
        buf_len: usize = 0,

        pub fn write(self: *Self, bytes: []const u8) Error!usize {
            //log.info("trying to encode and write '{s}'", .{bytes});

            const old_buf_rest = self.buf_len;
            const buf_left = self.buf.len - old_buf_rest;
            //log.info("buf left: {} ({s})", .{ buf_left, self.buf[0..old_buf_rest] });
            const cbuf = if (old_buf_rest == 0) bytes else blk: {
                const cpy_len = @min(buf_left, bytes.len);
                @memcpy(self.buf[old_buf_rest..(old_buf_rest + cpy_len)], bytes[0..cpy_len]);
                break :blk self.buf[0..(old_buf_rest + cpy_len)];
            };
            //log.info("cbuf: {} '{s}'", .{ cbuf.len, cbuf });

            const view = std.unicode.Utf8View.initUnchecked(cbuf);
            var it = view.iterator();

            while (it.nextCodepoint()) |cp| {
                try htmlEscapeChar(cp, self.inner);
            }

            //log.info("Ended at position: {}", .{it.i});

            if (it.i < cbuf.len) {
                const bytes_left = cbuf.len - it.i;
                std.mem.copyForwards(
                    u8,
                    self.buf[0..bytes_left],
                    cbuf[(cbuf.len - bytes_left)..cbuf.len],
                );
                self.buf_len = bytes_left;
            } else self.buf_len = 0;

            //log.info("it.i {} old_buf_rest: {}", .{ it.i, old_buf_rest });
            if (it.i < old_buf_rest) return 0; // Not even written the rest part
            //log.info("unwritten: {}", .{old_buf_rest});
            const written_bytes = bytes.len - old_buf_rest - self.buf_len;
            //log.info("written: {}", .{written_bytes});
            return written_bytes;
        }

        pub fn writer(self: *Self) Writer {
            return Writer{ .context = self };
        }
    };
}

pub fn escapingWriter(w: anytype) EscapingWriter(@TypeOf(w)) {
    return .{ .inner = w };
}
