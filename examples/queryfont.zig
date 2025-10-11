const std = @import("std");
const x11 = @import("x11");

pub const log_level = std.log.Level.info;

const zig_atleast_15 = @import("builtin").zig_version.order(.{ .major = 0, .minor = 15, .patch = 0 }) != .lt;

var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
const allocator = arena.allocator();

pub fn main() !u8 {
    const all_args = try std.process.argsAlloc(allocator);
    if (all_args.len <= 1) {
        std.debug.print("Usage: queryfont FONTNAME\n", .{});
        return 1;
    }
    const cmd_args = all_args[1..];
    if (cmd_args.len != 1) {
        std.log.err("expected 1 cmd arg (FONTNAME) but got {}", .{cmd_args.len});
        return 1;
    }
    const font_name = cmd_args[0];

    try x11.wsaStartup();
    const conn = try x11.ext.connect(allocator);
    defer std.posix.shutdown(conn.sock, .both) catch {};

    const font_id = conn.setup.fixed().resource_id_base.add(0).font();
    var sequence: u16 = 0;

    {
        const font_name_slice = x11.Slice(u16, [*]const u8){ .ptr = font_name.ptr, .len = @intCast(font_name.len) };
        const msg = try allocator.alloc(u8, x11.open_font.getLen(font_name_slice.len));
        defer allocator.free(msg);
        x11.open_font.serialize(msg.ptr, font_id, font_name_slice);
        try conn.sendOne(&sequence, msg);
    }

    {
        var msg: [x11.query_font.len]u8 = undefined;
        x11.query_font.serialize(&msg, font_id.fontable());
        try conn.sendOne(&sequence, &msg);
    }

    var buffer: [4096]u8 = undefined;
    var stdout = if (zig_atleast_15) std.fs.File.stdout().writer(&buffer) else std.io.bufferedWriter(std.io.getStdOut().writer());
    const writer = if (zig_atleast_15) &stdout.interface else stdout.writer();

    {
        var reader: x11.SocketReader = .init(conn.sock);
        const msg_bytes = try x11.readOneMsgAlloc(allocator, reader.interface());
        defer allocator.free(msg_bytes);
        const msg = try x11.ext.asReply(x11.ServerMsg.QueryFont, msg_bytes);
        try writer.print("{}\n", .{msg});
        std.debug.assert(sequence == msg.sequence);
        const lists = msg.lists();
        if (!lists.inBounds(msg.*)) {
            std.log.info("malformed QueryFont reply, list counts are not in bounds of the reply", .{});
            return 1;
        }
        for (msg.properties()) |prop| {
            try writer.print("{}\n", .{prop});
        }
        for (lists.charInfos(msg)) |char_info| {
            try writer.print("{}\n", .{char_info});
        }
    }
    if (zig_atleast_15) try writer.flush() else try stdout.flush();

    return 0;
}
