pub const Tag = struct {
    name: []const u8,
    is_closing: bool,
    self_closing: bool,
    attr_data: []const u8,

    pub fn getAttr(self: Tag, name: []const u8) ?[]const u8 {
        var p: usize = 0;
        while (p < self.attr_data.len) {
            while (p < self.attr_data.len and isWs(self.attr_data[p])) p += 1;
            if (p >= self.attr_data.len) break;
            const astart = p;
            while (p < self.attr_data.len and self.attr_data[p] != '=' and !isWs(self.attr_data[p])) p += 1;
            const aname = self.attr_data[astart..p];
            while (p < self.attr_data.len and (isWs(self.attr_data[p]) or self.attr_data[p] == '=')) p += 1;
            if (p < self.attr_data.len and (self.attr_data[p] == '"' or self.attr_data[p] == '\'')) {
                const quote = self.attr_data[p];
                p += 1;
                const vstart = p;
                while (p < self.attr_data.len and self.attr_data[p] != quote) p += 1;
                const val = self.attr_data[vstart..p];
                if (p < self.attr_data.len) p += 1;
                if (std.mem.eql(u8, aname, name)) return val;
            }
        }
        return null;
    }
};

fn isWs(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

fn isQuote(c: u8) bool {
    return c == '"' or c == '\'';
}

pub const Parser = struct {
    data: []const u8,
    pos: usize = 0,

    pub fn nextTag(self: *Parser) ?Tag {
        while (self.pos < self.data.len) {
            if (self.data[self.pos] != '<') {
                self.pos += 1;
                continue;
            }
            self.pos += 1;
            if (self.pos >= self.data.len) return null;

            // Comment
            if (self.pos + 2 < self.data.len and self.data[self.pos] == '!' and self.data[self.pos + 1] == '-' and self.data[self.pos + 2] == '-') {
                self.pos += 3;
                while (self.pos + 2 < self.data.len) {
                    if (self.data[self.pos] == '-' and self.data[self.pos + 1] == '-' and self.data[self.pos + 2] == '>') {
                        self.pos += 3;
                        break;
                    }
                    self.pos += 1;
                }
                continue;
            }

            // CDATA section
            if (self.pos + 7 < self.data.len and std.mem.eql(u8, self.data[self.pos..][0..8], "![CDATA[")) {
                self.pos += 8;
                while (self.pos + 2 < self.data.len) {
                    if (self.data[self.pos] == ']' and self.data[self.pos + 1] == ']' and self.data[self.pos + 2] == '>') {
                        self.pos += 3;
                        break;
                    }
                    self.pos += 1;
                }
                continue;
            }

            // Processing instruction
            if (self.data[self.pos] == '?') {
                while (self.pos + 1 < self.data.len) {
                    if (self.data[self.pos] == '?' and self.data[self.pos + 1] == '>') {
                        self.pos += 2;
                        break;
                    }
                    self.pos += 1;
                }
                continue;
            }

            const is_closing = self.data[self.pos] == '/';
            if (is_closing) self.pos += 1;

            const name_start = self.pos;
            while (self.pos < self.data.len and self.data[self.pos] != '>' and !isWs(self.data[self.pos]) and self.data[self.pos] != '/') {
                self.pos += 1;
            }
            const name = self.data[name_start..self.pos];

            while (self.pos < self.data.len and isWs(self.data[self.pos])) self.pos += 1;
            const attr_start = self.pos;

            var self_closing = false;
            while (self.pos < self.data.len and self.data[self.pos] != '>') {
                if (isQuote(self.data[self.pos])) {
                    const quote = self.data[self.pos];
                    self.pos += 1;
                    while (self.pos < self.data.len and self.data[self.pos] != quote) self.pos += 1;
                } else if (self.data[self.pos] == '/') {
                    self_closing = true;
                }
                if (self.pos < self.data.len) self.pos += 1;
            }
            var attr_end = self.pos;
            if (attr_end > attr_start and self.data[attr_end - 1] == '/') attr_end -= 1;
            if (self.pos < self.data.len) self.pos += 1;

            return .{
                .name = name,
                .is_closing = is_closing,
                .self_closing = self_closing or is_closing,
                .attr_data = self.data[attr_start..attr_end],
            };
        }
        return null;
    }

    /// Extract all text content until the closing tag, then return it trimmed.
    pub fn getTextUntilClose(self: *Parser, tag_name: []const u8) []const u8 {
        const start = self.pos;
        // Find the position of the closing tag's '<'
        var depth: usize = 1;
        while (self.pos < self.data.len) {
            if (self.data[self.pos] != '<') {
                self.pos += 1;
                continue;
            }
            const tag_start = self.pos;
            const tag = self.nextTag() orelse break;
            if (!std.mem.eql(u8, tag.name, tag_name)) continue;
            if (tag.is_closing) {
                depth -= 1;
                if (depth == 0) return std.mem.trim(u8, self.data[start..tag_start], " \t\n\r");
            } else if (!tag.self_closing) {
                depth += 1;
            }
        }
        return std.mem.trim(u8, self.data[start..self.pos], " \t\n\r");
    }

    pub fn skipToClose(self: *Parser, tag_name: []const u8) void {
        var depth: usize = 1;
        while (self.nextTag()) |tag| {
            if (!std.mem.eql(u8, tag.name, tag_name)) continue;
            if (tag.is_closing) {
                depth -= 1;
                if (depth == 0) return;
            } else if (!tag.self_closing) {
                depth += 1;
            }
        }
    }
};

const std = @import("std");
