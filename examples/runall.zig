pub fn main() !u8 {
    var arena_instance: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    const arena = arena_instance.allocator();
    const cmdline = try Cmdline.alloc(arena);
    var count: usize = 0;
    for (1..cmdline.len()) |arg_index| {
        const exe = cmdline.arg(arg_index);
        const name = std.fs.path.stem(exe);

        const args1 = .{exe};
        const args2 = .{ exe, "fixed" };
        const args: []const []const u8 = if (std.mem.eql(u8, name, "queryfont")) &args2 else &args1;
        std.log.info("[RUN] {s}", .{exe});
        var child: std.process.Child = .init(args, arena);
        try child.spawn();
        const term = try child.wait();
        switch (term) {
            .Exited => |code| if (code != 0) {
                std.log.err("{s} failed", .{name});
                return 0xff;
            },
            else => |sig| {
                std.log.err("{s} {s} with {}", .{ name, @tagName(sig), sig });
                return 0xff;
            },
        }
        count += 1;
    }

    std.log.info("Successfully ran all {} examples!", .{count});
    return 0;
}

const std = @import("std");
const Cmdline = @import("Cmdline.zig");
