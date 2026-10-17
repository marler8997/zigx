pub const std_options: std.Options = .{ .io_vtable = .threaded };

pub fn main(init: std.process.Init.Minimal) !u8 {
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    var threaded: std.Io.Threaded = .init(arena.allocator(), .{ .environ = init.environ });
    const io = threaded.io();

    var arg_it = try init.args.iterateAllocator(arena.allocator());
    _ = arg_it.skip();
    var count: usize = 0;
    while (arg_it.next()) |exe| {
        const name = std.fs.path.stem(exe);

        const args1 = .{exe};
        const args2 = .{ exe, "fixed" };
        const args: []const []const u8 = if (std.mem.eql(u8, name, "queryfont")) &args2 else &args1;
        std.log.info("[RUN] {s}", .{exe});
        var child = try std.process.spawn(io, .{ .argv = args });
        const term = try child.wait(io);
        switch (term) {
            .exited => |code| if (code != 0) {
                std.log.err("{s} failed", .{name});
                return 0xff;
            },
            else => |sig| {
                std.log.err("{s} {t} with {}", .{ name, sig, sig });
                return 0xff;
            },
        }
        count += 1;
    }

    std.log.info("Successfully ran all {} examples!", .{count});
    return 0;
}

const std = @import("std");
