const std = @import("std");
const x11 = @import("x11");

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

    if (opt.auth_filename) |filename| {
        const file = std.fs.cwd().openFile(filename, .{}) catch |err| {
            std.log.err("open '{s}' failed with {s}", .{ filename, @errorName(err) });
            std.process.exit(1);
        };
        defer file.close();
        try list2(file);
    } else {
        var filename_buf: [std.fs.max_path_bytes]u8 = undefined;
        for (std.enums.valuesFromFields(
            x11.AuthFileKind,
            @typeInfo(x11.AuthFileKind).@"enum".fields,
        )) |kind| {
            if (x11.getAuthFilename(kind, &filename_buf) catch |err| {
                std.log.err("get auth filename ({s}) failed with {s}", .{ kind.context(), @errorName(err) });
                continue;
            }) |filename| {
                if (std.fs.cwd().openFile(filename, .{})) |file| {
                    defer file.close();
                    try list2(file);
                } else |err| {
                    std.log.info("open '{s}' failed with {s}", .{ filename, @errorName(err) });
                }
            }
        }
    }
}

fn list2(file: std.fs.File) !void {
    var file_read_buf: [4096]u8 = undefined;
    var file_reader = x11.fileReader(file, &file_read_buf);
    var reader: x11.AuthReader = .{ .reader = &file_reader.interface };
    list3(&reader) catch |err| return switch (err) {
        error.ReadFailed => file_reader.err orelse error.ReadFailed,
        else => |e| e,
    };
}

fn list3(reader: *x11.AuthReader) !void {
    var stdout_buffer: [1000]u8 = undefined;
    var stdout_writer: x11.FileWriter = .init(x11.stdout(), &stdout_buffer);
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

fn streamHex(reader: *x11.AuthReader, stdout: *x11.Writer, n: usize) !void {
    var remaining = n;
    while (remaining > 0) {
        const take_len = @min(remaining, reader.reader.buffer.len);
        const data = try reader.takeDynamic(take_len);
        try stdout.print("{x}", .{if (x11.zig_atleast_15) data else std.fmt.fmtSliceHexLower(data)});
        remaining -= take_len;
    }
    reader.finishDynamic();
}
