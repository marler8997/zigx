const std = @import("std");
const testing = std.testing;
const x = @import("../x.zig");

// Some dummy data of 2x screens that have depths at 1, 4, 24, 32 and some visual types for each depth.
var TEST_RECEIVED_CONNECT_SETUP_BUFFER align(4) = [_]u8{
    0x90, 0xa5, 0xb8, 0x00, 0x00, 0x00, 0xa0, 0x17, 0xff, 0xff, 0x1f, 0x00, 0x00, 0x01, 0x00, 0x00, 0x14, 0x00, 0xff, 0xff, 0x02, 0x04, 0x00, 0x00, 0x20, 0x20, 0x08, 0xff, 0x00, 0x00, 0x00, 0x00, 0x54, 0x68, 0x65, 0x20, 0x58, 0x2e, 0x4f, 0x72, 0x67, 0x20, 0x46, 0x6f, 0x75, 0x6e, 0x64, 0x61, 0x74, 0x69, 0x6f, 0x6e, 0x01, 0x01, 0x20, 0x00, 0x00, 0x00, 0x00, 0x00, 0x04, 0x08, 0x20, 0x00, 0x00, 0x00, 0x00, 0x00, 0x18, 0x20, 0x20, 0x00, 0x00, 0x00, 0x00, 0x00, 0x20, 0x20, 0x20, 0x00, 0x00, 0x00, 0x00, 0x00, 0xb3, 0x07, 0x00, 0x00, 0x20, 0x00, 0x00, 0x00, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x00, 0x00, 0x3f, 0x80, 0xfa, 0x00, 0x00, 0x0f, 0x70, 0x08, 0xf7, 0x03, 0x3b, 0x02, 0x01, 0x00, 0x01, 0x00, 0x21, 0x00, 0x00, 0x00, 0x01, 0x00, 0x18, 0x04, 0x01, 0x00, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x04, 0x00, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x18, 0x00, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x21, 0x00, 0x00, 0x00, 0x04, 0x08, 0x00, 0x01, 0x00, 0x00, 0xff, 0x00, 0x00, 0xff, 0x00, 0x00, 0xff, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x93, 0x06, 0x00, 0x00, 0x04, 0x08, 0x00, 0x01, 0x00, 0x00, 0xff, 0x00, 0x00, 0xff, 0x00, 0x00, 0xff, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x9a, 0x07, 0x00, 0x00, 0x05, 0x08, 0x00, 0x01, 0x00, 0x00, 0xff, 0x00, 0x00, 0xff, 0x00, 0x00, 0xff, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x20, 0x00, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x7c, 0x00, 0x00, 0x00, 0x04, 0x08, 0x00, 0x01, 0x00, 0x00, 0xff, 0x00, 0x00, 0xff, 0x00, 0x00, 0xff, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x9b, 0x07, 0x00, 0x00, 0x04, 0x08, 0x00, 0x01, 0x00, 0x00, 0xff, 0x00, 0x00, 0xff, 0x00, 0x00, 0xff, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xb1, 0x07, 0x00, 0x00, 0x04, 0x08, 0x00, 0x01, 0x00, 0x00, 0xff, 0x00, 0x00, 0xff, 0x00, 0x00, 0xff, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xb4, 0x07, 0x00, 0x00, 0x20, 0x00, 0x00, 0x00, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x00, 0x00, 0x3f, 0x80, 0xfa, 0x00, 0x80, 0x07, 0x38, 0x04, 0xf7, 0x03, 0x3b, 0x02, 0x01, 0x00, 0x01, 0x00, 0x21, 0x00, 0x00, 0x00, 0x01, 0x00, 0x18, 0x04, 0x01, 0x00, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x04, 0x00, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x18, 0x00, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x21, 0x00, 0x00, 0x00, 0x04, 0x08, 0x00, 0x01, 0x00, 0x00, 0xff, 0x00, 0x00, 0xff, 0x00, 0x00, 0xff, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x93, 0x06, 0x00, 0x00, 0x04, 0x08, 0x00, 0x01, 0x00, 0x00, 0xff, 0x00, 0x00, 0xff, 0x00, 0x00, 0xff, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x9a, 0x07, 0x00, 0x00, 0x05, 0x08, 0x00, 0x01, 0x00, 0x00, 0xff, 0x00, 0x00, 0xff, 0x00, 0x00, 0xff, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x20, 0x00, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x7c, 0x00, 0x00, 0x00, 0x04, 0x08, 0x00, 0x01, 0x00, 0x00, 0xff, 0x00, 0x00, 0xff, 0x00, 0x00, 0xff, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x9b, 0x07, 0x00, 0x00, 0x04, 0x08, 0x00, 0x01, 0x00, 0x00, 0xff, 0x00, 0x00, 0xff, 0x00, 0x00, 0xff, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xb1, 0x07, 0x00, 0x00, 0x04, 0x08, 0x00, 0x01, 0x00, 0x00, 0xff, 0x00, 0x00, 0xff, 0x00, 0x00, 0xff, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
};

fn testParseDisplay(display: []const u8, proto: []const u8, host: []const u8, display_num: u32, screen: ?u32) !void {
    const parsed = try x.parseDisplay(display);
    try testing.expect(std.mem.eql(u8, proto, parsed.protoSlice(display.ptr)));
    try testing.expect(std.mem.eql(u8, host, parsed.hostSlice(display.ptr)));
    try testing.expectEqual(display_num, parsed.display_num);
    try testing.expectEqual(screen, parsed.preferredScreen);
}

test "parseDisplay" {
    // no need to test the empty string case, it triggers an assert and a client passing
    // one is a bug that needs to be fixed
    try testing.expectError(x.InvalidDisplayError.HasMultipleProtocols, x.parseDisplay("a//"));
    try testing.expectError(x.InvalidDisplayError.NoDisplayNumber, x.parseDisplay("0"));
    try testing.expectError(x.InvalidDisplayError.NoDisplayNumber, x.parseDisplay("0/"));
    try testing.expectError(x.InvalidDisplayError.NoDisplayNumber, x.parseDisplay("0/1"));
    try testing.expectError(x.InvalidDisplayError.NoDisplayNumber, x.parseDisplay(":"));

    try testing.expectError(x.InvalidDisplayError.BadDisplayNumber, x.parseDisplay(":a"));
    try testing.expectError(x.InvalidDisplayError.BadDisplayNumber, x.parseDisplay(":0a"));
    try testing.expectError(x.InvalidDisplayError.BadDisplayNumber, x.parseDisplay(":0a."));
    try testing.expectError(x.InvalidDisplayError.BadDisplayNumber, x.parseDisplay(":0a.0"));
    try testing.expectError(x.InvalidDisplayError.BadDisplayNumber, x.parseDisplay(":1x"));
    try testing.expectError(x.InvalidDisplayError.BadDisplayNumber, x.parseDisplay(":1x."));
    try testing.expectError(x.InvalidDisplayError.BadDisplayNumber, x.parseDisplay(":1x.10"));

    try testing.expectError(x.InvalidDisplayError.BadScreenNumber, x.parseDisplay(":1.x"));
    try testing.expectError(x.InvalidDisplayError.BadScreenNumber, x.parseDisplay(":1.0x"));
    // TODO: should this be an error or no????
    //try testing.expectError(InvalidDisplayError.BadScreenNumber, parseDisplay(":1."));

    try testParseDisplay("proto/host:123.456", "proto", "host", 123, 456);
    try testParseDisplay("host:123.456", "", "host", 123, 456);
    try testParseDisplay(":123.456", "", "", 123, 456);
    try testParseDisplay(":123", "", "", 123, null);
    try testParseDisplay("a/:43", "a", "", 43, null);
    try testParseDisplay("/", "", "/", 0, null);
    try testParseDisplay("/some/file/path/x0", "", "/some/file/path/x0", 0, null);
}

test "VisualType.findMatchingVisualType" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const connect_setup_stub = x.ConnectSetup {
        .buf = TEST_RECEIVED_CONNECT_SETUP_BUFFER[0..],
    };
    // We avoid de-initializing to keep the test buffer around for other tests
    //defer connect_setup_stub.deinit(allocator);

    var screens = try connect_setup_stub.getScreens(allocator);

    const matching_visual_type_24 = try screens[0].findMatchingVisualType(24, .direct_color, allocator);
    try testing.expectEqual(@as(u32, 1946), matching_visual_type_24.id);
    try testing.expectEqual(x.VisualType.Class.direct_color, matching_visual_type_24.class);

    const matching_visual_type_32 = try screens[0].findMatchingVisualType(32, .true_color, allocator);
    try testing.expectEqual(@as(u32, 124), matching_visual_type_32.id);
    try testing.expectEqual(x.VisualType.Class.true_color, matching_visual_type_32.class);

    const depth_that_does_not_exist: u8 = 255;
    const visual_type_not_found_result = screens[0].findMatchingVisualType(depth_that_does_not_exist, .static_color, allocator);
    try std.testing.expectError(error.VisualTypeNotFound, visual_type_not_found_result);
}

test "ConnectSetupMessage" {
    const auth_name = comptime x.slice(u16, @as([]const u8, "hello"));
    const auth_data = comptime x.slice(u16, @as([]const u8, "there"));
    const len = comptime x.connect_setup.getLen(auth_name.len, auth_data.len);
    var buf: [len]u8 = undefined;
    x.connect_setup.serialize(&buf, 1, 1, auth_name, auth_data);
}

test "Parse received ConnectSetup message" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const connect_setup_stub = x.ConnectSetup {
        .buf = TEST_RECEIVED_CONNECT_SETUP_BUFFER[0..],
    };
    // We avoid de-initializing to keep the test buffer around for other tests
    //defer connect_setup_stub.deinit(allocator);

    // Check the fixed part of the header
    // -------------------------------------------
    const fixed = connect_setup_stub.fixed();
    try testing.expectEqual(@as(u32, 12101008), fixed.release_number);
    try testing.expectEqual(@as(u32, 396361728), fixed.resource_id_base);
    try testing.expectEqual(@as(u32, 2097151), fixed.resource_id_mask);
    try testing.expectEqual(@as(u32, 256), fixed.motion_buffer_size);
    try testing.expectEqual(@as(u16, 20), fixed.vendor_len);
    try testing.expectEqual(@as(u16, 65535), fixed.max_request_len);
    try testing.expectEqual(@as(u8, 2), fixed.root_screen_count);
    try testing.expectEqual(@as(u8, 4), fixed.format_count);
    try testing.expectEqual(x.NonExhaustive(x.ImageByteOrder).lsb_first, fixed.image_byte_order);
    try testing.expectEqual(@as(u8, 0), fixed.bitmap_format_bit_order);
    try testing.expectEqual(@as(u8, 32), fixed.bitmap_format_scanline_unit);
    try testing.expectEqual(@as(u8, 32), fixed.bitmap_format_scanline_pad);
    try testing.expectEqual(@as(u8, 8), fixed.min_keycode);
    try testing.expectEqual(@as(u8, 255), fixed.max_keycode);
    try testing.expectEqual(@as(u32, 0), fixed.unused);
    try testing.expectEqualSlices(u8, "The X.Org Foundation", try connect_setup_stub.getVendorSlice(fixed.vendor_len));

    // Check over the screens
    // -------------------------------------------
    var screens = try connect_setup_stub.getScreens(allocator);
    try testing.expectEqual(@as(usize, fixed.root_screen_count), screens.len);

    // Check the first screen
    try testing.expectEqual(@as(u32, 1971), screens[0].root);
    try testing.expectEqual(@as(u32, 32), screens[0].colormap);
    try testing.expectEqual(@as(u32, 0xffffff), screens[0].white_pixel);
    try testing.expectEqual(@as(u32, 0x000000), screens[0].black_pixel);
    try testing.expectEqual(@as(u32, 16416831), screens[0].input_masks);
    try testing.expectEqual(@as(u16, 3840), screens[0].pixel_width);
    try testing.expectEqual(@as(u16, 2160), screens[0].pixel_height);
    try testing.expectEqual(@as(u16, 1015), screens[0].mm_width);
    try testing.expectEqual(@as(u16, 571), screens[0].mm_height);
    try testing.expectEqual(@as(u16, 1), screens[0].min_installed_maps);
    try testing.expectEqual(@as(u16, 1), screens[0].max_installed_maps);
    try testing.expectEqual(@as(u32, 33), screens[0].root_visual);
    try testing.expectEqual(@as(u8, 1), screens[0].backing_stores);
    try testing.expectEqual(@as(u8, 0), screens[0].save_unders);
    try testing.expectEqual(@as(u8, 24), screens[0].root_depth);
    try testing.expectEqual(@as(u8, 4), screens[0].allowed_depth_count);

    // Quick sanity of the second screen with the fields that are different from the first screen
    try testing.expectEqual(@as(u32, 1972), screens[1].root);
    try testing.expectEqual(@as(u16, 1920), screens[1].pixel_width);
    try testing.expectEqual(@as(u16, 1080), screens[1].pixel_height);

    // Check over the screen depths
    // (the depths and visual types are the same across both screens for ease of asserting during the tests)
    // -------------------------------------------
    for (screens) |screen| {
        const screen_depths = try screen.getAllowedDepths(allocator);
        try testing.expectEqual(@as(usize, screens[0].allowed_depth_count), screen_depths.len);

        try testing.expectEqual(@as(u8, 1), screen_depths[0].depth);
        try testing.expectEqual(@as(u8, 0), screen_depths[0].unused0);
        try testing.expectEqual(@as(u16, 3), screen_depths[0].visual_type_count);
        try testing.expectEqual(@as(u32, 0), screen_depths[0].unused1);

        try testing.expectEqual(@as(u8, 4), screen_depths[1].depth);
        try testing.expectEqual(@as(u8, 0), screen_depths[1].unused0);
        try testing.expectEqual(@as(u16, 3), screen_depths[1].visual_type_count);
        try testing.expectEqual(@as(u32, 0), screen_depths[1].unused1);

        try testing.expectEqual(@as(u8, 24), screen_depths[2].depth);
        try testing.expectEqual(@as(u8, 0), screen_depths[2].unused0);
        try testing.expectEqual(@as(u16, 3), screen_depths[2].visual_type_count);
        try testing.expectEqual(@as(u32, 0), screen_depths[2].unused1);

        try testing.expectEqual(@as(u8, 32), screen_depths[3].depth);
        try testing.expectEqual(@as(u8, 0), screen_depths[3].unused0);
        try testing.expectEqual(@as(u16, 3), screen_depths[3].visual_type_count);
        try testing.expectEqual(@as(u32, 0), screen_depths[3].unused1);

        for (screen_depths) |screen_depth| {
            // Check over the visual types
            // -------------------------------------------
            const visual_types = screen_depth.getVisualTypes();
            try testing.expectEqual(@as(usize, screen_depth.visual_type_count), visual_types.len);
            
            switch (screen_depth.depth) {
                1, 4 => {
                    for (visual_types) |visual_type| {
                        try testing.expectEqual(@as(u32, 0), visual_type.id);
                        try testing.expectEqual(x.VisualType.Class.static_gray, visual_type.class);
                        try testing.expectEqual(@as(u8, 0), visual_type.bits_per_rgb_value);
                        try testing.expectEqual(@as(u16, 0), visual_type.colormap_entries);
                        try testing.expectEqual(@as(u32, 0), visual_type.red_mask);
                        try testing.expectEqual(@as(u32, 0), visual_type.green_mask);
                        try testing.expectEqual(@as(u32, 0), visual_type.blue_mask);
                        try testing.expectEqual(@as(u32, 0), visual_type.unused);
                    }
                },
                24 => {
                    try testing.expectEqual(@as(u32, 33), visual_types[0].id);
                    try testing.expectEqual(x.VisualType.Class.true_color, visual_types[0].class);
                    try testing.expectEqual(@as(u8, 8), visual_types[0].bits_per_rgb_value);
                    try testing.expectEqual(@as(u16, 256), visual_types[0].colormap_entries);
                    try testing.expectEqual(@as(u32, 0xff0000), visual_types[0].red_mask);
                    try testing.expectEqual(@as(u32, 0x00ff00), visual_types[0].green_mask);
                    try testing.expectEqual(@as(u32, 0x0000ff), visual_types[0].blue_mask);
                    try testing.expectEqual(@as(u32, 0), visual_types[0].unused);

                    try testing.expectEqual(@as(u32, 1683), visual_types[1].id);

                    try testing.expectEqual(@as(u32, 1946), visual_types[2].id);
                    try testing.expectEqual(x.VisualType.Class.direct_color, visual_types[2].class);
                },
                32 => {
                    try testing.expectEqual(@as(u32, 124), visual_types[0].id);
                    try testing.expectEqual(x.VisualType.Class.true_color, visual_types[0].class);
                    try testing.expectEqual(@as(u8, 8), visual_types[0].bits_per_rgb_value);
                    try testing.expectEqual(@as(u16, 256), visual_types[0].colormap_entries);
                    try testing.expectEqual(@as(u32, 0xff0000), visual_types[0].red_mask);
                    try testing.expectEqual(@as(u32, 0x00ff00), visual_types[0].green_mask);
                    try testing.expectEqual(@as(u32, 0x0000ff), visual_types[0].blue_mask);
                    try testing.expectEqual(@as(u32, 0), visual_types[0].unused);

                    try testing.expectEqual(@as(u32, 1947), visual_types[1].id);

                    try testing.expectEqual(@as(u32, 1969), visual_types[2].id);
                },
                else => unreachable,
            }
        }
    }
}
