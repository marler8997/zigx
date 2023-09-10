const std = @import("std");
const x = @import("x.zig");

const global = struct {
    pub var arena_instance = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    pub const arena = arena_instance.allocator();
};

const Opt = struct {
    auth_filename: ?[]const u8 = null,
};

fn usage() void {
    std.debug.print(
        \\usage: xauth [-options ...] [command arg ...]
        \\
        \\OPTIONS:
        \\  -f  authfilename    Authorization file to use. Optional, defaults to $XAUTHORITY or $HOME/.Xauthority
        \\
        \\COMMANDS:
        \\  help                Print help
        \\  list                List authorization entries
        \\
    , .{});
}

pub fn main() !void {
    const all_args = try std.process.argsAlloc(global.arena);
    // no need to free

    var opt = Opt{};
    const args = blk: {
        var new_arg_count: usize = 0;
        var arg_index: usize = 1;
        while (arg_index < all_args.len) : (arg_index += 1) {
            const arg = all_args[arg_index];
            if (!std.mem.startsWith(u8, arg, "-")) {
                all_args[new_arg_count] = arg;
                new_arg_count += 1;
            } else if (std.mem.eql(u8, arg, "-f")) {
                arg_index += 1;
                if (arg_index >= all_args.len) {
                    std.log.err("missing authfilename after option -f", .{});
                    std.process.exit(1);
                }
                opt.auth_filename = all_args[arg_index];
            } else {
                std.log.err("invalid option \"{s}\"", .{arg});
                std.process.exit(1);
            }
        }
        break :blk all_args[0..new_arg_count];
    };
    if (args.len == 0) {
        usage();
        return;
    }
    const cmd = args[0];
    const cmd_args = args[1..];

    if (std.mem.eql(u8, cmd, "help")) {
        usage();
    } else if (std.mem.eql(u8, cmd, "list")) {
        try list(opt, cmd_args);
    } else {
        std.log.err("invalid command \"{s}\"", .{cmd});
        std.process.exit(1);
    }
}

fn list(opt: Opt, cmd_args: []const [:0]const u8) !void {
    if (cmd_args.len != 0) {
        std.log.err("list command doesn't accept any arguments", .{});
        std.process.exit(1);
    }

    const auth_filename = blk: {
        if (opt.auth_filename) |f| break :blk x.AuthFilename{
            .str = f,
            .owned = false,
        };
        break :blk try x.getAuthFilename(global.arena) orelse {
            std.log.err("unable to find an Xauthority file", .{});
            std.process.exit(1);
        };
    };
    // no need to auth_filename.deinit(allocator);

    const auth_mapped = try x.MappedFile.init(auth_filename.str, .{});
    defer auth_mapped.unmap();


    const stdout_writer = std.io.getStdOut().writer();
    var buffered_writer = std.io.bufferedWriter(stdout_writer);
    const writer = buffered_writer.writer();

    var auth_it = x.AuthIterator{ .mem = auth_mapped.mem };
    while (auth_it.next() catch {
        std.log.err("auth file '{s}' is invalid", .{auth_filename.str});
        std.process.exit(1);
    }) |entry| {
        const addr = entry.addr(auth_mapped.mem);
        switch (entry.family) {
            .internet => {
                if (addr.len == 4) {
                    try writer.print("{}.{}.{}.{}", .{addr[0], addr[1], addr[2], addr[3]});
                } else {
                    try writer.print("{}/inet", .{std.fmt.fmtSliceHexLower(addr)});
                }
            },
            .local => {
                try writer.print("{s}/unix", .{entry.addr(auth_mapped.mem)});
            },
            .wild => {
                // this is just a guess
                try writer.writeAll("*");
            },
            else => |family| {
                try writer.print("{}/{}", .{
                    std.zig.fmtEscapes(entry.addr(auth_mapped.mem)),
                    family,
                });
            },
        }

        var display_buf: [40]u8 = undefined;
        const display: []const u8 = if (entry.display_num) |d| (
            std.fmt.bufPrint(&display_buf, ":{}", .{d}) catch unreachable
        ) else "";
        try writer.print("{s}  {s}  {}\n", .{
            display,
            entry.name(auth_mapped.mem),
            std.fmt.fmtSliceHexLower(entry.data(auth_mapped.mem)),
        });
    }
    try buffered_writer.flush();
}
