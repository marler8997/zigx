const std = @import("std");
const x11 = @import("x11");

pub const std_options: std.Options = .{ .io_vtable = .threaded };

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

pub fn main(init: std.process.Init.Minimal) !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    // only allocates on windows, no need to free
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    var arg_it = try init.args.iterateAllocator(arena.allocator());
    _ = arg_it.skip();

    var opt = Opt{};
    var maybe_cmd: ?[:0]const u8 = null;
    var cmd_arg_count: usize = 0;
    while (arg_it.next()) |arg| {
        if (!std.mem.startsWith(u8, arg, "-")) {
            if (maybe_cmd == null) {
                maybe_cmd = arg;
            } else {
                cmd_arg_count += 1;
            }
        } else if (std.mem.eql(u8, arg, "-f")) {
            opt.auth_filename = arg_it.next() orelse {
                std.log.err("missing authfilename after option -f", .{});
                std.process.exit(1);
            };
        } else {
            std.log.err("invalid option \"{s}\"", .{arg});
            std.process.exit(1);
        }
    }
    const cmd = maybe_cmd orelse {
        usage();
        return;
    };
    if (std.mem.eql(u8, cmd, "help")) {
        usage();
    } else if (std.mem.eql(u8, cmd, "list")) {
        try list(io, init.environ, opt, cmd_arg_count);
    } else {
        std.log.err("invalid command \"{s}\"", .{cmd});
        std.process.exit(1);
    }
}

fn list(io: std.Io, environ: std.process.Environ, opt: Opt, cmd_arg_count: usize) !void {
    if (cmd_arg_count != 0) {
        std.log.err("list command doesn't accept any arguments", .{});
        std.process.exit(1);
    }

    if (opt.auth_filename) |filename| {
        const file = std.Io.Dir.cwd().openFile(io, filename, .{}) catch |err| {
            std.log.err("open '{s}' failed with {s}", .{ filename, @errorName(err) });
            std.process.exit(1);
        };
        defer file.close(io);
        try list2(io, file);
    } else {
        var filename_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        for (std.meta.tags(x11.AuthFileKind)) |kind| {
            if (x11.getAuthFilename(environ, kind, &filename_buf) catch |err| {
                std.log.err("get auth filename ({s}) failed with {s}", .{ kind.context(), @errorName(err) });
                continue;
            }) |filename| {
                if (std.Io.Dir.cwd().openFile(io, filename, .{})) |file| {
                    defer file.close(io);
                    try list2(io, file);
                } else |err| {
                    std.log.info("open '{s}' failed with {s}", .{ filename, @errorName(err) });
                }
            }
        }
    }
}

fn list2(io: std.Io, file: std.Io.File) !void {
    var file_read_buf: [4096]u8 = undefined;
    var file_reader = file.reader(io, &file_read_buf);
    var reader: x11.AuthReader = .{ .reader = &file_reader.interface };
    list3(io, &reader) catch |err| return switch (err) {
        error.ReadFailed => file_reader.err orelse error.ReadFailed,
        else => |e| e,
    };
}

fn list3(io: std.Io, reader: *x11.AuthReader) !void {
    var stdout_buffer: [1000]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    var entry_index: u32 = 0;
    while (true) : (entry_index += 1) {
        const family = (try reader.takeFamily()) orelse break;
        try stdout.print("AddressFamily={f} ", .{x11.fmtEnum(family)});
        const addr_len = try reader.takeDynamicLen(.addr);
        switch (family) {
            .inet => if (addr_len == 4) {
                const a = try reader.takeDynamic(4);
                try stdout.print("{}.{}.{}.{} ", .{ a[0], a[1], a[2], a[3] });
            },
            .inet6 => {},
            .unix => {
                try stdout.writeAll("UnixAddress='");
                try reader.streamDynamic(stdout, addr_len);
                try stdout.writeAll("' ");
            },
            .wild => {},
            _ => {},
        }
        if (reader.state == .dynamic_data) {
            try stdout.print("Address({} bytes)=", .{addr_len});
            try streamHex(reader, stdout, addr_len);
            try stdout.writeAll(" ");
        }

        const display_num_len = try reader.takeDynamicLen(.display_num);
        try stdout.writeAll("DisplayNum='");
        try reader.streamDynamic(stdout, display_num_len);
        try stdout.writeAll("'");

        const name_len = try reader.takeDynamicLen(.name);
        try stdout.writeAll(" AuthName='");
        try reader.streamDynamic(stdout, name_len);
        const data_len = try reader.takeDynamicLen(.data);
        try stdout.print("' Data({} bytes)=", .{data_len});
        try streamHex(reader, stdout, data_len);
        try stdout.writeByte('\n');
    }
    try stdout.flush();
}

fn streamHex(reader: *x11.AuthReader, stdout: *std.Io.Writer, n: usize) !void {
    var remaining = n;
    while (remaining > 0) {
        const take_len = @min(remaining, reader.reader.buffer.len);
        const data = try reader.takeDynamic(take_len);
        try stdout.print("{x}", .{data});
        remaining -= take_len;
    }
    reader.finishDynamic();
}
