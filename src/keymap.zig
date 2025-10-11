const std = @import("std");
const x11 = @import("x.zig");

pub const Full = struct {
    array: [248][4]x11.charset.Combined,
    pub fn initVoid() Full {
        var result: Full = undefined;
        for (&result.array) |*entry_ref| {
            // TODO: initialize to VoidSymbol instead of 0
            entry_ref.* = [1]x11.charset.Combined{@enumFromInt(0)} ** 4;
        }
        return result;
    }

    pub fn initSynchronous(
        sink: *x11.RequestSink,
        source: *x11.Source,
        keycode_range: x11.KeycodeRange,
    ) !Full {
        const keycode_count = keycode_range.count();
        try sink.GetKeyboardMapping(keycode_range.min, keycode_count);
        try sink.writer.flush();
        const reply = try source.readSynchronousReply1(sink.sequence);
        try source.replyDiscard(24);
        {
            const expected_size = @as(u35, keycode_count) * @as(u35, reply.flexible) * 4;
            const remaining_size = source.replyRemainingSize();
            if (remaining_size != expected_size) {
                x11.log.err("expected keyboard mapping reply to be {} bytes but got {}", .{ expected_size, remaining_size });
                return error.UnexpectedMessage;
            }
        }
        var keymap: Full = .initVoid();
        for (keycode_range.min..@as(usize, keycode_range.max) + 1) |keycode| {
            for (0..reply.flexible) |index| {
                const keysym_u32 = try source.takeReplyInt(u32);
                if (index < 4) {
                    keymap.array[keycode - 8][index] = @enumFromInt(@as(u16, @truncate(keysym_u32)));
                }
            }
        }
        std.debug.assert(source.replyRemainingSize() == 0);
        return keymap;
    }

    pub fn getKeysym(self: Full, keycode: u8, mod: x11.KeycodeMod) error{KeycodeTooSmall}!x11.charset.Combined {
        if (keycode < 8) return error.KeycodeTooSmall;
        return self.array[keycode - 8][@intFromEnum(mod)];
    }
};
