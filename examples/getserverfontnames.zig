const std = @import("std");
const x11 = @import("x11");
const common = @import("common.zig");

pub const log_level = std.log.Level.info;

var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
const allocator = arena.allocator();

pub fn main() !void {
    try x11.wsaStartup();
    const conn = try common.connect(allocator);
    defer std.posix.shutdown(conn.sock, .both) catch {};

    {
        const pattern_string = "*";
        const pattern = x11.Slice(u16, [*]const u8){ .ptr = pattern_string, .len = pattern_string.len };
        var msg: [x11.list_fonts.getLen(pattern.len)]u8 = undefined;
        x11.list_fonts.serialize(&msg, 0xffff, pattern);
        try conn.sendNoSequencing(&msg);
    }

    {
        const msg_bytes = try x11.readOneMsgAlloc(allocator, conn.reader());
        defer allocator.free(msg_bytes);
        const msg = try common.asReply(x11.ServerMsg.ListFonts, msg_bytes);
        var it = msg.iterator();
        const writer = std.io.getStdOut().writer();
        while (try it.next()) |path| {
            try writer.print("{s}\n", .{path});
        }
    }
}
