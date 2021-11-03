const std = @import("std");
const x = @import("x.zig");
const common = @import("common.zig");

pub const log_level = std.log.Level.info;

var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
const allocator = &arena.allocator;

pub fn main() !void {
    const conn = try common.connect(allocator);
    defer std.os.shutdown(conn.sock, .both) catch {};

    {
        var msg: [x.get_font_path.len]u8 = undefined;
        x.get_font_path.serialize(&msg);
        try conn.send(&msg);
    }

    {
        const msg_bytes = try x.readOneMsgAlloc(allocator, conn.reader());
        defer allocator.free(msg_bytes);
        const msg = try common.asReply(x.ServerMsg.GetFontPath, msg_bytes);
        var it = msg.iterator();
        const writer = std.io.getStdOut().writer();
        while (try it.next()) |path| {
            try writer.print("{s}\n", .{path});
        }
    }
}
