const zig_atleast_15 = @import("builtin").zig_version.order(.{ .major = 0, .minor = 15, .patch = 0 }) != .lt;

fn setupReply(
    // the serialized reply starting at the list of formats
    comptime serialized: []const u8,
    comptime named_ct: struct {
        vendor: []const u8,
    },
    named: struct {
        root_screen_count: u8,
        format_count: u8,
    },
) [
    @sizeOf(x11.Setup) +
        named_ct.vendor.len +
        x11.pad4Len(@truncate(named_ct.vendor.len)) +
        serialized.len
]u8 {
    var result: [
        @sizeOf(x11.Setup) +
            named_ct.vendor.len +
            x11.pad4Len(@truncate(named_ct.vendor.len)) +
            serialized.len
    ]u8 = undefined;

    {
        const setup: x11.Setup = .{
            .status = .success,
            .unused1 = undefined,
            .version_major = 11,
            .version_minor = 0,
            .word_count = @divExact(result.len - 8, 4),
            .release_number = 12101008,
            .resource_id_base = @enumFromInt(396361728),
            .resource_id_mask = 0x1fffff,
            .motion_buffer_size = 256,
            .vendor_len = @intCast(named_ct.vendor.len),
            .max_request_len = 0xffff,
            .root_screen_count = named.root_screen_count,
            .format_count = named.format_count,
            .image_byte_order = .lsb_first,
            .bitmap_format_bit_order = 0,
            .bitmap_format_scanline_unit = 32,
            .bitmap_format_scanline_pad = 32,
            .min_keycode = 8,
            .max_keycode = 255,
            .unused2 = undefined,
        };
        @memcpy(result[0..@sizeOf(x11.Setup)], std.mem.asBytes(&setup));
    }
    @memcpy(
        result[@sizeOf(x11.Setup)..][0..named_ct.vendor.len],
        named_ct.vendor,
    );
    @memcpy(
        result[@sizeOf(x11.Setup) +
            named_ct.vendor.len +
            x11.pad4Len(@truncate(named_ct.vendor.len)) ..],
        serialized,
    );
    return result;
}

// Pre-serialized setup reply data along with some of the expected
// data already deserialized.
pub const test_data = struct {
    pub const formats = [4]x11.Format{
        .{ .depth = 1, .bits_per_pixel = 1, .scanline_pad = 32, ._ = .{ 0, 0, 0, 0, 0 } },
        .{ .depth = 4, .bits_per_pixel = 8, .scanline_pad = 32, ._ = .{ 0, 0, 0, 0, 0 } },
        .{ .depth = 24, .bits_per_pixel = 32, .scanline_pad = 32, ._ = .{ 0, 0, 0, 0, 0 } },
        .{ .depth = 32, .bits_per_pixel = 32, .scanline_pad = 32, ._ = .{ 0, 0, 0, 0, 0 } },
    };
    pub const depths = [4]x11.ScreenDepth{
        .{ .depth = 1, .unused0 = 0, .visual_type_count = 3, .unused1 = 0 },
        .{ .depth = 4, .unused0 = 0, .visual_type_count = 3, .unused1 = 0 },
        .{ .depth = 24, .unused0 = 0, .visual_type_count = 3, .unused1 = 0 },
        .{ .depth = 32, .unused0 = 0, .visual_type_count = 3, .unused1 = 0 },
    };
    const serialized = [_]u8{
        0x01, 0x01, 0x20, 0x00, 0x00, 0x00, 0x00, 0x00, 0x04, 0x08, 0x20, 0x00, 0x00, 0x00, 0x00, 0x00, 0x18, 0x20, 0x20, 0x00, 0x00, 0x00, 0x00, 0x00, 0x20, 0x20, 0x20, 0x00, 0x00, 0x00, 0x00, 0x00, 0xb3, 0x07, 0x00, 0x00, 0x20, 0x00, 0x00, 0x00, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x00, 0x00, 0x3f, 0x80, 0xfa, 0x00, 0x00, 0x0f, 0x70, 0x08, 0xf7, 0x03, 0x3b, 0x02, 0x01, 0x00, 0x01, 0x00, 0x21, 0x00, 0x00, 0x00, 0x01, 0x00, 0x18, 0x04, 0x01, 0x00, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x04, 0x00, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x18, 0x00, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x21, 0x00, 0x00, 0x00, 0x04, 0x08, 0x00, 0x01, 0x00, 0x00, 0xff, 0x00, 0x00, 0xff, 0x00, 0x00, 0xff, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x93, 0x06, 0x00, 0x00, 0x04, 0x08, 0x00, 0x01, 0x00, 0x00, 0xff, 0x00, 0x00, 0xff, 0x00, 0x00, 0xff, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x9a, 0x07, 0x00, 0x00, 0x05, 0x08, 0x00, 0x01, 0x00, 0x00, 0xff, 0x00, 0x00, 0xff, 0x00, 0x00, 0xff, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x20, 0x00, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x7c, 0x00, 0x00, 0x00, 0x04, 0x08, 0x00, 0x01, 0x00, 0x00, 0xff, 0x00, 0x00, 0xff, 0x00, 0x00, 0xff, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x9b, 0x07, 0x00, 0x00, 0x04, 0x08, 0x00, 0x01, 0x00, 0x00, 0xff, 0x00, 0x00, 0xff, 0x00, 0x00, 0xff, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xb1, 0x07, 0x00, 0x00, 0x04, 0x08, 0x00, 0x01, 0x00, 0x00, 0xff, 0x00, 0x00, 0xff, 0x00, 0x00, 0xff, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xb4, 0x07, 0x00, 0x00, 0x20, 0x00, 0x00, 0x00, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x00, 0x00, 0x3f, 0x80, 0xfa, 0x00, 0x80, 0x07, 0x38, 0x04, 0xf7, 0x03, 0x3b, 0x02, 0x01, 0x00, 0x01, 0x00, 0x21, 0x00, 0x00, 0x00, 0x01, 0x00, 0x18, 0x04, 0x01, 0x00, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x04, 0x00, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x18, 0x00, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x21, 0x00, 0x00, 0x00, 0x04, 0x08, 0x00, 0x01, 0x00, 0x00, 0xff, 0x00, 0x00, 0xff, 0x00, 0x00, 0xff, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x93, 0x06, 0x00, 0x00, 0x04, 0x08, 0x00, 0x01, 0x00, 0x00, 0xff, 0x00, 0x00, 0xff, 0x00, 0x00, 0xff, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x9a, 0x07, 0x00, 0x00, 0x05, 0x08, 0x00, 0x01, 0x00, 0x00, 0xff, 0x00, 0x00, 0xff, 0x00, 0x00, 0xff, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x20, 0x00, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x7c, 0x00, 0x00, 0x00, 0x04, 0x08, 0x00, 0x01, 0x00, 0x00, 0xff, 0x00, 0x00, 0xff, 0x00, 0x00, 0xff, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x9b, 0x07, 0x00, 0x00, 0x04, 0x08, 0x00, 0x01, 0x00, 0x00, 0xff, 0x00, 0x00, 0xff, 0x00, 0x00, 0xff, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xb1, 0x07, 0x00, 0x00, 0x04, 0x08, 0x00, 0x01, 0x00, 0x00, 0xff, 0x00, 0x00, 0xff, 0x00, 0x00, 0xff, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    };
    // verifies that the given visual at the given depth/index is what's in the serialized data
    fn expectVisual(screen_depth: x11.ScreenDepth, visual_index: usize, visual: x11.VisualType) !void {
        switch (screen_depth.depth) {
            1, 4 => {
                std.debug.assert(visual_index <= 4);
                try testing.expectEqual(x11.Visual.fromInt(0), visual.id);
                try testing.expectEqual(x11.VisualType.Class.static_gray, visual.class);
                try testing.expectEqual(@as(u8, 0), visual.bits_per_rgb_value);
                try testing.expectEqual(@as(u16, 0), visual.colormap_entries);
                try testing.expectEqual(@as(u32, 0), visual.red_mask);
                try testing.expectEqual(@as(u32, 0), visual.green_mask);
                try testing.expectEqual(@as(u32, 0), visual.blue_mask);
                try testing.expectEqual(@as(u32, 0), visual.unused);
            },
            24 => switch (visual_index) {
                0 => {
                    try testing.expectEqual(x11.Visual.fromInt(33), visual.id);
                    try testing.expectEqual(x11.VisualType.Class.true_color, visual.class);
                    try testing.expectEqual(@as(u8, 8), visual.bits_per_rgb_value);
                    try testing.expectEqual(@as(u16, 256), visual.colormap_entries);
                    try testing.expectEqual(@as(u32, 0xff0000), visual.red_mask);
                    try testing.expectEqual(@as(u32, 0x00ff00), visual.green_mask);
                    try testing.expectEqual(@as(u32, 0x0000ff), visual.blue_mask);
                    try testing.expectEqual(@as(u32, 0), visual.unused);
                },
                1 => {
                    try testing.expectEqual(x11.Visual.fromInt(1683), visual.id);
                },
                2 => {
                    try testing.expectEqual(x11.Visual.fromInt(1946), visual.id);
                    try testing.expectEqual(x11.VisualType.Class.direct_color, visual.class);
                },
                else => unreachable,
            },
            32 => switch (visual_index) {
                0 => {
                    try testing.expectEqual(x11.Visual.fromInt(124), visual.id);
                    try testing.expectEqual(x11.VisualType.Class.true_color, visual.class);
                    try testing.expectEqual(@as(u8, 8), visual.bits_per_rgb_value);
                    try testing.expectEqual(@as(u16, 256), visual.colormap_entries);
                    try testing.expectEqual(@as(u32, 0xff0000), visual.red_mask);
                    try testing.expectEqual(@as(u32, 0x00ff00), visual.green_mask);
                    try testing.expectEqual(@as(u32, 0x0000ff), visual.blue_mask);
                    try testing.expectEqual(@as(u32, 0), visual.unused);
                },
                1 => {
                    try testing.expectEqual(x11.Visual.fromInt(1947), visual.id);
                },
                2 => {
                    try testing.expectEqual(x11.Visual.fromInt(1969), visual.id);
                },
                else => unreachable,
            },
            else => unreachable,
        }
    }
};

fn testParseDisplay(
    string: []const u8,
    proto: ?x11.Protocol,
    host: []const u8,
    display_num: u16,
    screen: ?u32,
) !void {
    const display: x11.Display = .{ .string = string };
    const parsed = try x11.parseDisplay(display);
    try testing.expectEqual(proto, parsed.proto);
    try testing.expectEqualSlices(u8, host, display.host(&parsed));
    try testing.expectEqual(x11.DisplayNum.fromInt(display_num), parsed.display_num);
    try testing.expectEqual(screen, parsed.preferredScreen);
}

test "parseDisplay" {
    // no need to test the empty string case, it triggers an assert and a client passing
    // one is a bug that needs to be fixed
    try testing.expectError(error.HasMultipleProtocols, x11.parseDisplay(.init("tcp//")));
    try testing.expectError(error.NoDisplayNumber, x11.parseDisplay(.init("0")));
    try testing.expectError(error.NoDisplayNumber, x11.parseDisplay(.init("unix/")));
    try testing.expectError(error.NoDisplayNumber, x11.parseDisplay(.init("inet/1")));
    try testing.expectError(error.NoDisplayNumber, x11.parseDisplay(.init(":")));

    try testing.expectError(error.BadDisplayNumber, x11.parseDisplay(.init(":a")));
    try testing.expectError(error.BadDisplayNumber, x11.parseDisplay(.init(":0a")));
    try testing.expectError(error.BadDisplayNumber, x11.parseDisplay(.init(":0a.")));
    try testing.expectError(error.BadDisplayNumber, x11.parseDisplay(.init(":0a.0")));
    try testing.expectError(error.BadDisplayNumber, x11.parseDisplay(.init(":1x")));
    try testing.expectError(error.BadDisplayNumber, x11.parseDisplay(.init(":1x11.")));
    try testing.expectError(error.BadDisplayNumber, x11.parseDisplay(.init(":1x11.10")));
    try testing.expectError(error.BadDisplayNumber, x11.parseDisplay(.init(":70000")));

    try testing.expectError(error.BadScreenNumber, x11.parseDisplay(.init(":1.x")));
    try testing.expectError(error.BadScreenNumber, x11.parseDisplay(.init(":1.0x")));
    // TODO: should this be an error or no????
    //try testing.expectError(error.BadScreenNumber, x11.parseDisplay(.init(":1.")));

    try testParseDisplay("tcp/host:123.456", .tcp, "host", 123, 456);
    try testParseDisplay("host:123.456", null, "host", 123, 456);
    try testParseDisplay(":123.456", null, "", 123, 456);
    try testParseDisplay(":123", null, "", 123, null);
    try testParseDisplay("inet6/:43", .inet6, "", 43, null);
    try testParseDisplay("/", null, "/", 0, null);
    try testParseDisplay("/some/file/path/x0", null, "/some/file/path/x0", 0, null);

    if (builtin.os.tag == .windows) {
        try testParseDisplay("w32", .w32, "", 0, null);
    } else {
        try testing.expectError(error.NoDisplayNumber, x11.parseDisplay(.init("w32")));
    }
}

const zigx_vendor = "ZigxTest";

test "parse setup reply" {
    const buffer = setupReply(&test_data.serialized, .{
        .vendor = zigx_vendor,
    }, .{
        .root_screen_count = 2,
        .format_count = 4,
    });
    var buffer_reader: x11.Reader = .fixed(&buffer);
    const setup = try x11.readSetupSuccess(&buffer_reader);
    var source: x11.Source = .initFinishSetup(&buffer_reader, &setup);
    try testing.expectEqual(@as(u32, 12101008), setup.release_number);
    try testing.expectEqual(x11.ResourceBase.fromInt(396361728), setup.resource_id_base);
    try testing.expectEqual(@as(u32, 0x1fffff), setup.resource_id_mask);
    try testing.expectEqual(@as(u32, 256), setup.motion_buffer_size);
    try testing.expectEqual(@as(u16, zigx_vendor.len), setup.vendor_len);
    try testing.expectEqual(@as(u16, 0xffff), setup.max_request_len);
    try testing.expectEqual(@as(u8, 2), setup.root_screen_count);
    try testing.expectEqual(@as(u8, test_data.formats.len), setup.format_count);
    try testing.expectEqual(x11.NonExhaustive(x11.ImageByteOrder).lsb_first, setup.image_byte_order);
    try testing.expectEqual(@as(u8, 0), setup.bitmap_format_bit_order);
    try testing.expectEqual(@as(u8, 32), setup.bitmap_format_scanline_unit);
    try testing.expectEqual(@as(u8, 32), setup.bitmap_format_scanline_pad);
    try testing.expectEqual(@as(u8, 8), setup.min_keycode);
    try testing.expectEqual(@as(u8, 255), setup.max_keycode);

    try testing.expectEqualSlices(u8, zigx_vendor, try source.takeReply(zigx_vendor.len));
    try source.replyDiscard(x11.pad4Len(@truncate(zigx_vendor.len)));

    for (test_data.formats) |expected| {
        var format: x11.Format = undefined;
        try source.readReply(std.mem.asBytes(&format));
        try testing.expectEqual(expected, format);
    }

    {
        var screen: x11.ScreenHeader = undefined;
        try source.readReply(std.mem.asBytes(&screen));
        try testing.expectEqual(x11.Window.fromInt(1971), screen.root);
        try testing.expectEqual(x11.ColorMap.fromInt(32), screen.colormap);
        try testing.expectEqual(@as(u32, 0xffffff), screen.white_pixel);
        try testing.expectEqual(@as(u32, 0x000000), screen.black_pixel);
        try testing.expectEqual(@as(u32, 16416831), screen.input_masks);
        try testing.expectEqual(@as(u16, 3840), screen.pixel_width);
        try testing.expectEqual(@as(u16, 2160), screen.pixel_height);
        try testing.expectEqual(@as(u16, 1015), screen.mm_width);
        try testing.expectEqual(@as(u16, 571), screen.mm_height);
        try testing.expectEqual(@as(u16, 1), screen.min_installed_maps);
        try testing.expectEqual(@as(u16, 1), screen.max_installed_maps);
        try testing.expectEqual(x11.Visual.fromInt(33), screen.root_visual);
        try testing.expectEqual(@as(u8, 1), screen.backing_stores);
        try testing.expectEqual(@as(u8, 0), screen.save_unders);
        try testing.expectEqual(@as(u8, 24), screen.root_depth);
        try testing.expectEqual(@as(u8, 4), screen.allowed_depth_count);
        for (0..screen.allowed_depth_count) |depth_index| {
            var depth: x11.ScreenDepth = undefined;
            try source.readReply(std.mem.asBytes(&depth));
            try testing.expectEqual(test_data.depths[depth_index], depth);
            for (0..depth.visual_type_count) |visual_index| {
                var visual: x11.VisualType = undefined;
                try source.readReply(std.mem.asBytes(&visual));
                try test_data.expectVisual(depth, visual_index, visual);
            }
        }
    }
    {
        var screen: x11.ScreenHeader = undefined;
        try source.readReply(std.mem.asBytes(&screen));
        try testing.expectEqual(x11.Window.fromInt(1972), screen.root);
        try testing.expectEqual(x11.ColorMap.fromInt(32), screen.colormap);
        try testing.expectEqual(@as(u32, 0xffffff), screen.white_pixel);
        try testing.expectEqual(@as(u32, 0x000000), screen.black_pixel);
        try testing.expectEqual(@as(u32, 16416831), screen.input_masks);
        try testing.expectEqual(@as(u16, 1920), screen.pixel_width);
        try testing.expectEqual(@as(u16, 1080), screen.pixel_height);
        try testing.expectEqual(@as(u16, 1015), screen.mm_width);
        try testing.expectEqual(@as(u16, 571), screen.mm_height);
        try testing.expectEqual(@as(u16, 1), screen.min_installed_maps);
        try testing.expectEqual(@as(u16, 1), screen.max_installed_maps);
        try testing.expectEqual(x11.Visual.fromInt(33), screen.root_visual);
        try testing.expectEqual(@as(u8, 1), screen.backing_stores);
        try testing.expectEqual(@as(u8, 0), screen.save_unders);
        try testing.expectEqual(@as(u8, 24), screen.root_depth);
        try testing.expectEqual(@as(u8, 4), screen.allowed_depth_count);
        for (0..screen.allowed_depth_count) |depth_index| {
            var depth: x11.ScreenDepth = undefined;
            try source.readReply(std.mem.asBytes(&depth));
            try testing.expectEqual(test_data.depths[depth_index], depth);
            for (0..depth.visual_type_count) |visual_index| {
                var visual: x11.VisualType = undefined;
                try source.readReply(std.mem.asBytes(&visual));
                try test_data.expectVisual(depth, visual_index, visual);
            }
        }
    }
    try testing.expectEqual(0, source.replyRemainingSize());
}

test "VisualType.findMatchingVisualType" {
    const buffer = setupReply(&test_data.serialized, .{
        .vendor = zigx_vendor,
    }, .{
        .root_screen_count = 2,
        .format_count = 4,
    });
    var buffer_reader: x11.Reader = .fixed(&buffer);
    const setup = try x11.readSetupSuccess(&buffer_reader);
    var source: x11.Source = .initFinishSetup(&buffer_reader, &setup);
    try testing.expectEqualSlices(u8, zigx_vendor, try source.takeReply(zigx_vendor.len));
    try source.replyDiscard(x11.pad4Len(@truncate(zigx_vendor.len)));
    for (0..setup.format_count) |_| {
        var format: x11.Format = undefined;
        try source.readReply(std.mem.asBytes(&format));
    }

    // const screens = try connect_setup_stub.getScreens(allocator);
    // const matching_visual_type_24 = try screens[0].findMatchingVisualType(24, .direct_color, allocator);
    // try testing.expectEqual(x11.Visual.fromInt(1946), matching_visual_type_24.id);
    // try testing.expectEqual(x11.VisualType.Class.direct_color, matching_visual_type_24.class);

    // const matching_visual_type_32 = try screens[0].findMatchingVisualType(32, .true_color, allocator);
    // try testing.expectEqual(x11.Visual.fromInt(124), matching_visual_type_32.id);
    // try testing.expectEqual(x11.VisualType.Class.true_color, matching_visual_type_32.class);

    // const depth_that_does_not_exist: u8 = 255;
    // const visual_type_not_found_result = screens[0].findMatchingVisualType(depth_that_does_not_exist, .static_color, allocator);
    // try testing.expectError(error.VisualTypeNotFound, visual_type_not_found_result);
}

fn takeXauthEntry(reader: *x11.AuthReader) error{ ReadFailed, EndOfStream }!?Auth {
    const family = (try reader.takeFamily()) orelse return null;
    const addr_len = try reader.takeDynamicLen(.addr);
    const addr = try reader.takeDynamic(addr_len);
    const display_num_len = try reader.takeDynamicLen(.display_num);
    const display_num = try reader.takeDynamic(display_num_len);
    const name_len = try reader.takeDynamicLen(.name);
    const name = try reader.takeDynamic(name_len);
    const data_len = try reader.takeDynamicLen(.data);
    const data = try reader.takeDynamic(data_len);
    return .{
        .family = family,
        .addr = addr,
        .display_num = display_num,
        .name = name,
        .data = data,
    };
}

fn testXauth(comptime entries: []const Auth) !void {
    const total_size = comptime blk: {
        var total: usize = 0;
        for (entries) |entry| {
            total += entry.size();
        }
        break :blk total;
    };
    var buffer: [total_size]u8 = undefined;
    {
        var offset: usize = 0;
        for (entries) |entry| {
            const entry_size = entry.size();
            entry.serialize(buffer[offset..][0..entry_size]);
            offset += entry_size;
        }
        std.debug.assert(offset == total_size);
    }

    var buffer_reader: x11.Reader = .fixed(&buffer);
    var reader: x11.AuthReader = .{ .reader = &buffer_reader };
    for (entries) |entry| {
        const parsed = try takeXauthEntry(&reader);
        try entry.expectEqual(parsed.?);
    }
    try testing.expectEqual(null, try takeXauthEntry(&reader));
}

const Auth = struct {
    family: x11.AuthFamily,
    addr: []const u8,
    display_num: []const u8,
    name: []const u8,
    data: []const u8,
    pub fn size(self: Auth) usize {
        return 10 + self.addr.len + self.display_num.len + self.name.len + self.data.len;
    }
    pub fn serialize(self: Auth, buf: []u8) void {
        std.debug.assert(buf.len == self.size());
        std.mem.writeInt(u16, buf[0..2], @intFromEnum(self.family), .big);
        var i: usize = 2;
        inline for (&.{ self.addr, self.display_num, self.name, self.data }) |data| {
            std.mem.writeInt(u16, buf[i..][0..2], @intCast(data.len), .big);
            i += 2;
            @memcpy(buf[i..][0..data.len], data);
            i += data.len;
        }
        std.debug.assert(i == buf.len);
    }
    pub fn expectEqual(self: Auth, other: Auth) !void {
        try std.testing.expectEqual(self.family, other.family);
        try std.testing.expectEqualSlices(u8, self.addr, other.addr);
        try std.testing.expectEqualSlices(u8, self.display_num, other.display_num);
        try std.testing.expectEqualSlices(u8, self.name, other.name);
        try std.testing.expectEqualSlices(u8, self.data, other.data);
    }
};

test "xauth reader" {
    try testXauth(&[_]Auth{ .{
        .family = .inet,
        .addr = &[_]u8{ 127, 0, 0, 1 },
        .display_num = "123",
        .name = "",
        .data = "",
    }, .{
        .family = .inet6,
        .addr = &[_]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 },
        .display_num = ":567.8",
        .name = "",
        .data = "",
    }, .{
        .family = @enumFromInt(1),
        .addr = "a random address",
        .display_num = "some kind of display num",
        .name = "just a random name to test",
        .data = "this is the good data oh yeah",
    } });
}

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const x11 = @import("../x.zig");
