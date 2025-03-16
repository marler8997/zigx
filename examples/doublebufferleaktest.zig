const builtin = @import("builtin");
const std = @import("std");
const x = @import("x");

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();

    if (builtin.os.tag == .linux) {
        try stdout.writeAll("monitor memory with this command:\n");
        try stdout.print("    watch sudo pmap {}\n", .{std.os.linux.getpid()});
    }

    var i: usize = 0;
    while (true) : (i += 1) {
        if ((i % 1000000) == 0) {
            try stdout.print("i={}\n", .{i});
        }
        const b = try x.DoubleBuffer.init(std.heap.page_size_min * 1000, .{});
        defer b.deinit();
        b.ptr[0] = 0;
        try std.testing.expectEqual(@as(u8, 0), b.ptr[b.half_len]);
        b.ptr[0] = 0xff;
        try std.testing.expectEqual(@as(u8, 0xff), b.ptr[b.half_len]);
    }
}
