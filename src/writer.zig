const zig_atleast_15 = builtin.zig_version.order(.{ .major = 0, .minor = 15, .patch = 0 }) != .lt;

const Iovlen = if (!zig_atleast_15 and builtin.cpu.arch == .x86_64)
    u32
else
    @FieldType(std.posix.msghdr_const, "iovlen");

pub const Writer = if (zig_atleast_15) std.Io.Writer else struct {
    vtable: *const VTable,
    buffer: []u8,
    end: usize = 0,

    pub const VTable = struct {
        drain: *const fn (w: *Writer, data: []const []const u8, splat: usize) Error!usize,
        flush: *const fn (w: *Writer) Error!void = defaultFlush,
    };

    pub const Error = error{
        WriteFailed,
    };

    const max_buffers_len = 8;

    pub fn flush(w: *Writer) Error!void {
        return w.vtable.flush(w);
    }
    /// Repeatedly calls `VTable.drain` until `end` is zero.
    pub fn defaultFlush(w: *Writer) Error!void {
        const drainFn = w.vtable.drain;
        while (w.end != 0) _ = try drainFn(w, &.{""}, 1);
    }

    pub fn consume(w: *Writer, n: usize) usize {
        if (n < w.end) {
            const remaining = w.buffer[n..w.end];
            std.mem.copyForwards(u8, w.buffer[0..remaining.len], remaining);
            w.end = remaining.len;
            return 0;
        }
        defer w.end = 0;
        return n - w.end;
    }

    pub fn buffered(w: *const Writer) []u8 {
        return w.buffer[0..w.end];
    }

    fn countSplat(data: []const []const u8, splat: usize) usize {
        var total: usize = 0;
        for (data[0 .. data.len - 1]) |buf| total += buf.len;
        total += data[data.len - 1].len * splat;
        return total;
    }

    pub fn writeSplat(w: *Writer, data: []const []const u8, splat: usize) Error!usize {
        assert(data.len > 0);
        const buffer = w.buffer;
        const count = countSplat(data, splat);
        if (w.end + count > buffer.len) return w.vtable.drain(w, data, splat);
        for (data[0 .. data.len - 1]) |bytes| {
            @memcpy(buffer[w.end..][0..bytes.len], bytes);
            w.end += bytes.len;
        }
        const pattern = data[data.len - 1];
        switch (pattern.len) {
            0 => {},
            1 => {
                @memset(buffer[w.end..][0..splat], pattern[0]);
                w.end += splat;
            },
            else => for (0..splat) |_| {
                @memcpy(buffer[w.end..][0..pattern.len], pattern);
                w.end += pattern.len;
            },
        }
        return count;
    }

    pub fn writeVec(w: *Writer, data: []const []const u8) Error!usize {
        return writeSplat(w, data, 1);
    }

    pub fn write(w: *Writer, bytes: []const u8) Error!usize {
        if (w.end + bytes.len <= w.buffer.len) {
            @branchHint(.likely);
            @memcpy(w.buffer[w.end..][0..bytes.len], bytes);
            w.end += bytes.len;
            return bytes.len;
        }
        return w.vtable.drain(w, &.{bytes}, 1);
    }

    pub fn writeAll(w: *Writer, bytes: []const u8) Error!void {
        var index: usize = 0;
        while (index < bytes.len) index += try w.write(bytes[index..]);
    }

    pub fn writeByte(w: *Writer, byte: u8) Error!void {
        while (w.buffer.len - w.end == 0) {
            const n = try w.vtable.drain(w, &.{&.{byte}}, 1);
            if (n > 0) return;
        } else {
            @branchHint(.likely);
            w.buffer[w.end] = byte;
            w.end += 1;
        }
    }

    pub fn splatByteAll(w: *Writer, byte: u8, n: usize) Error!void {
        var remaining: usize = n;
        while (remaining > 0) remaining -= try w.splatByte(byte, remaining);
    }

    pub fn splatByte(w: *Writer, byte: u8, n: usize) Error!usize {
        if (w.end + n <= w.buffer.len) {
            @branchHint(.likely);
            @memset(w.buffer[w.end..][0..n], byte);
            w.end += n;
            return n;
        }
        return writeSplat(w, &.{&.{byte}}, n);
    }

    pub inline fn writeInt(w: *Writer, comptime T: type, value: T, endian: std.builtin.Endian) Error!void {
        var bytes: [@divExact(@typeInfo(T).int.bits, 8)]u8 = undefined;
        std.mem.writeInt(std.math.ByteAlignedInt(@TypeOf(value)), &bytes, value, endian);
        return w.writeAll(&bytes);
    }
    pub fn writeVecAll(w: *Writer, data: [][]const u8) Error!void {
        var index: usize = 0;
        var truncate: usize = 0;
        while (index < data.len) {
            {
                const untruncated = data[index];
                data[index] = untruncated[truncate..];
                defer data[index] = untruncated;
                truncate += try w.writeVec(data[index..]);
            }
            while (index < data.len and truncate >= data[index].len) {
                truncate -= data[index].len;
                index += 1;
            }
        }
    }
};

const builtin = @import("builtin");
const std = @import("std");
const assert = std.debug.assert;
const windows = std.os.windows;
