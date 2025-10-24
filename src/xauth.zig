const std = @import("std");
const x11 = @import("x.zig");

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
        if (opt.auth_filename) |f| break :blk x11.AuthFilename{
            .str = f,
            .owned = false,
        };
        break :blk try x11.getAuthFilename(global.arena) orelse {
            std.log.err("unable to find an Xauthority file", .{});
            std.process.exit(1);
        };
    };
    // no need to auth_filename.deinit(allocator);

    const auth_mapped = try x11.ext.MappedFile.init(auth_filename.str, .{});
    defer auth_mapped.unmap();

    var stdout_buffer: [1000]u8 = undefined;
    var stdout_writer: x11.FileWriter = .init(x11.stdout(), &stdout_buffer);
    const stdout = &stdout_writer.interface;

    var auth_it = x11.AuthIterator{ .mem = auth_mapped.mem };
    while (auth_it.next() catch {
        std.log.err("auth file '{s}' is invalid", .{auth_filename.str});
        std.process.exit(1);
    }) |entry| {
        switch (entry.family) {
            .wild => {}, // not sure what to do, should we write "*"? nothing?
            else => {
                const addr = x11.Addr{
                    .family = entry.family,
                    .data = entry.addr(auth_mapped.mem),
                };
                if (x11.zig_atleast_15)
                    try addr.format(stdout)
                else
                    try addr.format("", .{}, stdout);
            },
        }

        var display_buf: [40]u8 = undefined;
        const display: []const u8 = if (entry.display_num) |d|
            (std.fmt.bufPrint(&display_buf, "{d}", .{@intFromEnum(d)}) catch unreachable)
        else
            "";
        try stdout.print(":{s}  {s}  {x}\n", .{
            display,
            entry.name(auth_mapped.mem),
            if (x11.zig_atleast_15) entry.data(auth_mapped.mem) else std.fmt.fmtSliceHexLower(entry.data(auth_mapped.mem)),
        });
    }
    try stdout.flush();
}
