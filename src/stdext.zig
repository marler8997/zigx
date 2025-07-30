pub const enums = struct {
    /// Returns true if `enum_value` has a name. This function always returns true
    /// for exhaustive enums.  It will return false if the enum is non-exhaustive
    /// and the value does not have a corresponding name.
    pub fn hasName(enum_value: anytype) bool {
        const T = @TypeOf(enum_value);
        const enum_info = switch (@typeInfo(T)) {
            .Enum => |enum_info| enum_info,
            else => @compileError("hasName requires an enum value but got " ++ @typeName(T)),
        };
        if (enum_info.is_exhaustive)
            return true;

        @setEvalBranchQuota(3 * enum_info.fields.len);
        inline for (enum_info.fields) |enum_field| {
            if (@intFromEnum(enum_value) == enum_field.value)
                return true;
        }

        return false;
    }
};

pub const net = struct {
    // copied from std because it doesn't support setting the nonblocking flag
    pub fn tcpConnectToAddress(address: std.net.Address, nonblocking: bool) std.net.TcpConnectToAddressError!std.net.Stream {
        const sock_flags = posix.SOCK.STREAM | @as(u32, if (nonblocking) posix.SOCK.NONBLOCK else 0) |
            (if (native_os == .windows) 0 else posix.SOCK.CLOEXEC);
        const sockfd = try posix.socket(address.any.family, sock_flags, posix.IPPROTO.TCP);
        errdefer std.net.Stream.close(.{ .handle = sockfd });

        try posix.connect(sockfd, &address.any, address.getOsSockLen());

        return std.net.Stream{ .handle = sockfd };
    }
};

const builtin = @import("builtin");
const std = @import("std");
const posix = std.posix;
const native_os = builtin.os.tag;
