const std = @import("std");
const x = @import("x.zig");
const common = @import("common.zig");

pub const log_level = std.log.Level.info;

var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
const allocator = arena.allocator();

pub fn main() !void {
    const conn = try common.connect(allocator);
    defer std.os.shutdown(conn.sock, .both) catch {};

    {
        const pattern_string = "*";
        const pattern = x.Slice(u16, [*]const u8) { .ptr = pattern_string, .len = pattern_string.len };
        var msg: [x.list_fonts.getLen(pattern.len)]u8 = undefined;
        x.list_fonts.serialize(&msg, 0xffff, pattern);
        try conn.send(&msg);
    }

    {
        const msg_bytes = try x.readOneMsgAlloc(allocator, conn.reader());
        defer allocator.free(msg_bytes);
        const msg = try common.asReply(x.ServerMsg.ListFonts, msg_bytes);
        var it = msg.iterator();
        const writer = std.io.getStdOut().writer();
        while (try it.next()) |path| {
            try writer.print("{s}\n", .{path});
        }
    }
}
