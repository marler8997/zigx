pub const main = if (zig_atleast_16) mainAtleast16 else mainBefore16;
fn mainAtleast16(init: std.process.Init) !u8 {
    var args_it = try init.minimal.args.iterateAllocator(init.arena.allocator());
    return mainCompat(&args_it, init.io);
}
fn mainBefore16() !u8 {
    var arena_instance = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    var args_it: std.process.ArgIterator = try .initWithAllocator(arena_instance.allocator());
    return mainCompat(&args_it, .legacy);
}
fn mainCompat(args_it: *std16.process.Args.Iterator, io: std16.Io) !u8 {
    var arena_instance: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    _ = args_it.next(); // skip program name
    var count: usize = 0;
    while (args_it.next()) |exe| {
        const name = std.fs.path.stem(exe);

        const args1 = [_][]const u8{exe};
        const args2 = [_][]const u8{ exe, "fixed" };
        const args: []const []const u8 = if (std.mem.eql(u8, name, "queryfont")) &args2 else &args1;
        std.log.info("[RUN] {s}", .{exe});
        const exit_code: u8 = if (zig_atleast_16) blk: {
            var child = try std.process.spawn(io, .{ .argv = args });
            break :blk switch (try child.wait(io)) {
                .exited => |code| code,
                else => 0xff,
            };
        } else blk: {
            var child: std.process.Child = .init(args, arena_instance.allocator());
            try child.spawn();
            break :blk switch (try child.wait()) {
                .Exited => |code| code,
                else => 0xff,
            };
        };
        if (exit_code != 0) {
            std.log.err("{s} failed", .{name});
            return 0xff;
        }
        count += 1;
    }

    std.log.info("Successfully ran all {} examples!", .{count});
    return 0;
}

const zig_atleast_16 = @import("builtin").zig_version.order(.{ .major = 0, .minor = 16, .patch = 0 }) != .lt;

const std = @import("std");
const std16 = if (zig_atleast_16) std else @import("std16");
