const std = @import("std");
const x = @import("x.zig");
const common = @import("common.zig");

pub const log_level = std.log.Level.info;

var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
const allocator = &arena.allocator;

pub fn main() !void {
    const conn = try common.connect(allocator);
    defer std.os.shutdown(conn.sock, .both) catch {};

    const font_id = conn.setup.fixed().resource_id_base;

    const font_name = "fixed";

    {
        const font_name_slice = x.Slice(u16, [*]const u8) { .ptr = font_name, .len = font_name.len };
        const msg = try allocator.alloc(u8, x.open_font.getLen(font_name_slice.len));
        defer allocator.free(msg);
        x.open_font.serialize(msg.ptr, font_id, font_name_slice);
        try conn.send(msg);
    }

    {
        var msg: [x.query_font.len]u8 = undefined;
        x.query_font.serialize(&msg, font_id);
        try conn.send(&msg);
    }

    {
        const msg_bytes = try x.readOneMsgAlloc(allocator, conn.reader());
        defer allocator.free(msg_bytes);
        //const msg = try common.asReply(x.ServerMsg.OpenFont, msg_bytes);
        // TODO: 
    }
}
