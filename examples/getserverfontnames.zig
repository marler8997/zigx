const std = @import("std");
const x11 = @import("x11");

pub const log_level = std.log.Level.info;

const zig_atleast_15 = @import("builtin").zig_version.order(.{ .major = 0, .minor = 15, .patch = 0 }) != .lt;

var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
const allocator = arena.allocator();

pub fn main() !void {
    try x11.wsaStartup();
    const conn = try x11.ext.connect(allocator);
    defer std.posix.shutdown(conn.sock, .both) catch {};

    {
        const pattern_string = "*";
        const pattern = x11.Slice(u16, [*]const u8){ .ptr = pattern_string, .len = pattern_string.len };
        var msg: [x11.list_fonts.getLen(pattern.len)]u8 = undefined;
        x11.list_fonts.serialize(&msg, 0xffff, pattern);
        try conn.sendNoSequencing(&msg);
    }

    {
        var reader: x11.SocketReader = .init(conn.sock);
        const msg_bytes = try x11.readOneMsgAlloc(allocator, reader.interface());
        defer allocator.free(msg_bytes);
        const msg = try x11.ext.asReply(x11.ServerMsg.ListFonts, msg_bytes);
        var it = msg.iterator();
        var buffer: [4096]u8 = undefined;
        var stdout = if (zig_atleast_15) std.fs.File.stdout().writer(&buffer) else std.io.bufferedWriter(std.io.getStdOut().writer());
        const writer = if (zig_atleast_15) &stdout.interface else stdout.writer();
        while (try it.next()) |path| {
            try writer.print("{f}\n", .{path});
        }
        if (zig_atleast_15) try writer.flush() else try stdout.flush();
    }
}
