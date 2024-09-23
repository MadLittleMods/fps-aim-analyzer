const std = @import("std");
const assertions = @import("utils/assertions.zig");
const assert = assertions.assert;
const x = @import("x");
const common = @import("x11/x11_common.zig");
const x11_extension_utils = @import("x11/x11_extension_utils.zig");
const x_render_extension = @import("x11/x_render_extension.zig");
const x_input_extension = @import("x11/x_input_extension.zig");
const x_test_extension = @import("x11/x_test_extension.zig");
const render_utils = @import("utils/render_utils.zig");
const image_conversion = @import("vision/image_conversion.zig");
const RGBImage = image_conversion.RGBImage;
const render = @import("screen_play/render.zig");
const AppState = @import("screen_play/app_state.zig").AppState;

const FakeInputAction = enum {
    left_click,
};

const Keyframe = struct {
    /// Timestamp in milliseconds
    timestamp_ms: u32,
    screenshot_index: ?u8 = null,
    action: ?FakeInputAction = null,
};

/// ScreenPlay: punny name for screenshot playback that we can use to mock gameplay and
/// test the aim analyzer against. This will display a series of screenshots in a window
/// and simulate mouse clicks.
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer switch (gpa.deinit()) {
        .ok => {},
        .leak => std.log.err("GPA allocator: Memory leak detected", .{}),
    };

    try x.wsaStartup();
    const conn = try common.connect(allocator);
    defer std.os.shutdown(conn.sock, .both) catch {};
    defer conn.setup.deinit(allocator);
    const conn_setup_fixed_fields = conn.setup.fixed();
    // Print out some info about the X server we connected to
    {
        inline for (@typeInfo(@TypeOf(conn_setup_fixed_fields.*)).Struct.fields) |field| {
            std.log.debug("{s}: {any}", .{ field.name, @field(conn_setup_fixed_fields, field.name) });
        }
        std.log.debug("vendor: {s}", .{try conn.setup.getVendorSlice(conn_setup_fixed_fields.vendor_len)});
    }

    const screen = common.getFirstScreenFromConnectionSetup(conn.setup);
    inline for (@typeInfo(@TypeOf(screen.*)).Struct.fields) |field| {
        std.log.debug("SCREEN 0| {s}: {any}", .{ field.name, @field(screen, field.name) });
    }

    std.log.info("root window ID {0} 0x{0x}", .{screen.root});
    const ids = render.Ids.init(
        screen.root,
        conn_setup_fixed_fields.resource_id_base,
    );

    const root_screen_dimensions = render_utils.Dimensions{
        .width = @intCast(screen.pixel_width),
        .height = @intCast(screen.pixel_height),
    };

    // Range is inclusive
    const starting_ammo_number = 36;
    const ending_ammo_number = 26;

    var state = AppState{
        .root_screen_dimensions = root_screen_dimensions,
        .num_screenshots = starting_ammo_number - ending_ammo_number + 1,
    };

    const pixmap_formats = try common.getPixmapFormatsFromConnectionSetup(conn.setup);
    const pixmap_format = try common.findMatchingPixmapFormatForDepth(
        pixmap_formats,
        state.pixmap_depth,
    );

    const image_byte_order: std.builtin.Endian = switch (conn_setup_fixed_fields.image_byte_order) {
        .lsb_first => .Little,
        .msb_first => .Big,
        else => |order| {
            std.log.err("unknown image-byte-order {}", .{order});
            return error.UnknownImageByteOrder;
        },
    };

    // Create a big buffer that we can use to read messages and replies from the X server.
    const double_buffer = try x.DoubleBuffer.init(
        std.mem.alignForward(usize, 8000, std.mem.page_size),
        .{ .memfd_name = "ZigX11DoubleBuffer" },
    );
    defer double_buffer.deinit(); // not necessary but good to test
    std.log.info("Read buffer capacity is {}", .{double_buffer.half_len});
    var buffer = double_buffer.contiguousReadBuffer();
    const buffer_limit = buffer.half_len;

    // TODO: maybe need to call conn.setup.verify or something?

    // We use the X Render extension splatting images onto our window. Useful because
    // their "composite" request works with mismatched depths between the source and
    // destinations.
    const optional_render_extension = try x11_extension_utils.getExtensionInfo(
        conn.sock,
        &buffer,
        "RENDER",
    );
    const render_extension = optional_render_extension orelse @panic("RENDER extension not found");

    try x_render_extension.ensureCompatibleVersionOfXRenderExtension(
        conn.sock,
        &buffer,
        &render_extension,
        .{
            // We arbitrarily require version 0.11 of the X Render extension just
            // because it's the latest but came out in 2009 so it's pretty much
            // ubiquitous anyway. Feature-wise, we only use "Composite" which came out
            // in 0.0.
            //
            // For more info on what's changed in each version, see the "15. Extension
            // Versioning" section of the X Render extension protocol docs,
            // https://www.x.org/releases/X11R7.5/doc/renderproto/renderproto.txt
            .major_version = 0,
            .minor_version = 11,
        },
    );

    // We use the X Test extension to simulate mouse clicks.
    const optional_test_extension = try x11_extension_utils.getExtensionInfo(
        conn.sock,
        &buffer,
        "XTEST",
    );
    const test_extension = optional_test_extension orelse @panic("XTEST extension not found");

    try x_test_extension.ensureCompatibleVersionOfXTestExtension(
        conn.sock,
        &buffer,
        &test_extension,
        .{
            // We require version 2.2 of the X Test extension because it supports raw
            // device events.
            .major_version = 2,
            .minor_version = 2,
        },
    );

    // Assemble a map of X extension info
    const extensions = x11_extension_utils.Extensions(&.{.render}){
        .render = render_extension,
        // We don't use `test_extension` in our rendering, so we don't need to include
        // it here.
    };

    try render.createResources(
        conn.sock,
        &buffer,
        &ids,
        screen,
        &extensions,
        &state,
    );

    // During tests, find the `aim_analyzer` window so we can stack our window below it.
    {
        {
            var msg_buf: [x.query_tree.len]u8 = undefined;
            x.query_tree.serialize(&msg_buf, screen.root);
            try conn.send(msg_buf[0..]);
        }
        const window_list = blk: {
            const message_length = try x.readOneMsg(conn.reader(), @alignCast(buffer.nextReadBuffer()));
            try common.checkMessageLengthFitsInBuffer(message_length, buffer_limit);
            switch (x.serverMsgTaggedUnion(@alignCast(buffer.double_buffer_ptr))) {
                .reply => |msg_reply| {
                    const msg: *x.query_tree.Reply = @ptrCast(msg_reply);
                    std.log.debug("query_tree found {d} child windows", .{msg.num_windows});

                    const owned_window_list = try allocator.alignedAlloc(u32, 4, msg.num_windows);
                    @memcpy(owned_window_list, msg.getWindowList());

                    break :blk owned_window_list;
                },
                else => |msg| {
                    std.log.err("expected a reply for `x.query_tree` but got {}", .{msg});
                    return error.ExpectedReplyForQueryTree;
                },
            }
        };
        defer allocator.free(window_list);

        // Figure out the atom for our custom application ID property
        const custom_app_id_atom = try common.intern_atom(
            conn.sock,
            &buffer,
            comptime x.Slice(u16, [*]const u8).initComptime("madlittlemods.app_id"),
        );
        // Find the matching window ID with the custom application ID property of "aim_analyzer"
        const opt_aim_analyzer_window_id = blk: {
            for (window_list) |window_id| {
                // Fetch the custom application ID property for each window
                {
                    var msg_buf: [x.get_property.len]u8 = undefined;
                    x.get_property.serialize(&msg_buf, .{
                        .window_id = window_id,
                        .property = custom_app_id_atom,
                        .type = x.Atom.STRING,
                        .offset = 0,
                        .len = 64,
                        .delete = false,
                    });
                    try conn.send(msg_buf[0..]);
                }
                const message_length = try x.readOneMsg(conn.reader(), @alignCast(buffer.nextReadBuffer()));
                try common.checkMessageLengthFitsInBuffer(message_length, buffer_limit);
                switch (x.serverMsgTaggedUnion(@alignCast(buffer.double_buffer_ptr))) {
                    .reply => |msg_reply| {
                        const msg: *x.get_property.Reply = @ptrCast(msg_reply);
                        const opt_application_id = try msg.getValueBytes();
                        if (opt_application_id) |application_id| {
                            if (std.mem.eql(u8, application_id, "aim_analyzer")) {
                                break :blk window_id;
                            }
                        }
                    },
                    else => |msg| {
                        std.log.err("expected a reply for `x.get_property` but got {}", .{msg});
                        return error.ExpectedReplyForGetProperty;
                    },
                }
            }

            break :blk null;
        };

        // Try to make this window on the bottom (below the main `aim_analyzer` in the
        // tests).
        if (opt_aim_analyzer_window_id) |aim_analyzer_window_id| {
            std.log.debug("Stacking screen_play window below aim_analyzer window ID {}", .{aim_analyzer_window_id});
            var msg: [x.configure_window.max_len]u8 = undefined;
            const len = x.configure_window.serialize(&msg, .{
                .window_id = ids.window,
            }, .{
                .stack_mode = .below,
                .sibling = aim_analyzer_window_id,
            });
            try conn.send(msg[0..len]);
        }
    }

    // Show the window. In the X11 protocol is called mapping a window, and hiding a
    // window is called unmapping. When windows are initially created, they are unmapped
    // (or hidden).
    {
        var msg: [x.map_window.len]u8 = undefined;
        x.map_window.serialize(&msg, ids.window);
        try conn.send(&msg);
    }

    var render_context = render.RenderContext{
        .sock = &conn.sock,
        .ids = &ids,
        .extensions = &extensions,
        .image_byte_order = image_byte_order,
        .pixmap_format = pixmap_format,
        .state = &state,
    };

    // Copy our screenshots to the pixmap on the x11 server so they're ready to be used
    // on the main window
    {
        var ammo_number: u32 = starting_ammo_number;
        var pixmap_index: u8 = 0;
        while (ammo_number >= ending_ammo_number) : ({
            ammo_number -= 1;
            pixmap_index += 1;
        }) {
            const screenshot_file_path = try std.fmt.allocPrint(
                allocator,
                "screenshot-data/halo-infinite/1080/default/{d} - bazaar assault rifle.png",
                .{ammo_number},
            );
            defer allocator.free(screenshot_file_path);
            const rgb_image = try RGBImage.loadImageFromFilePath(
                screenshot_file_path,
                allocator,
            );
            defer rgb_image.deinit(allocator);
            try render_context.copyImageToPixmapAtIndex(rgb_image, pixmap_index, allocator);
        }
    }

    const keyframes = [_]Keyframe{
        .{ .timestamp_ms = 0, .screenshot_index = 0 },
        .{ .timestamp_ms = 400, .action = .left_click }, // 100ms input delay
        .{ .timestamp_ms = 500, .screenshot_index = 1 },
        .{ .timestamp_ms = 900, .action = .left_click },
        .{ .timestamp_ms = 1000, .screenshot_index = 2 },
        .{ .timestamp_ms = 1150, .action = .left_click }, // 50ms input delay
        .{ .timestamp_ms = 1200, .screenshot_index = 3 },
        .{ .timestamp_ms = 1350, .action = .left_click },
        .{ .timestamp_ms = 1400, .screenshot_index = 4 },
        .{ .timestamp_ms = 1570, .action = .left_click }, // 30ms input delay
        .{ .timestamp_ms = 1600, .screenshot_index = 5 },
        .{ .timestamp_ms = 1770, .action = .left_click },
        .{ .timestamp_ms = 1800, .screenshot_index = 6 },
        .{ .timestamp_ms = 1880, .action = .left_click }, // 20ms input delay
        .{ .timestamp_ms = 1900, .screenshot_index = 7 },
        .{ .timestamp_ms = 1980, .action = .left_click },
        .{ .timestamp_ms = 2000, .screenshot_index = 8 },
        .{ .timestamp_ms = 2090, .action = .left_click }, // 10ms input delay
        .{ .timestamp_ms = 2100, .screenshot_index = 9 },
        .{ .timestamp_ms = 2198, .action = .left_click }, // 2ms input delay
        .{ .timestamp_ms = 2200, .screenshot_index = 10 },
        // Padding for the end before exiting
        .{ .timestamp_ms = 2500 },
    };

    var current_keyframe_index: u8 = 0;
    const start_time_ts = std.time.milliTimestamp();
    outer: while (true) {
        const current_ts = std.time.milliTimestamp();
        const elapsed_ms = current_ts - start_time_ts;

        while (elapsed_ms > keyframes[current_keyframe_index].timestamp_ms) {
            const keyframe = keyframes[current_keyframe_index];
            if (keyframe.action == .left_click) {
                // Press and...
                {
                    var msg: [x.testext.fake_input.len]u8 = undefined;
                    x.testext.fake_input.serialize(&msg, test_extension.opcode, .{
                        .button_press = .{
                            .event_type = x.testext.FakeEventType.button_press,
                            // Left-click
                            .detail = 1,
                            .delay_ms = 0,
                            .device_id = 1,
                        },
                    });
                    try conn.send(&msg);
                }
                // release the left mouse button
                {
                    var msg: [x.testext.fake_input.len]u8 = undefined;
                    x.testext.fake_input.serialize(&msg, test_extension.opcode, .{
                        .button_press = .{
                            .event_type = x.testext.FakeEventType.button_release,
                            // Left-click
                            .detail = 1,
                            .delay_ms = 0,
                            .device_id = 1,
                        },
                    });
                    try conn.send(&msg);
                }
            }

            // Update the displayed screenshot
            if (keyframe.screenshot_index) |screenshot_index| {
                state.screenshot_index = screenshot_index;
                // FIXME: We just assume the window was mapped by the time we reach this
                // point
                try render_context.render();
            }

            current_keyframe_index += 1;

            // We're done
            if (current_keyframe_index >= keyframes.len) {
                break :outer;
            }
        }

        // {
        //     const receive_buffer = buffer.nextReadBuffer();
        //     if (receive_buffer.len == 0) {
        //         std.log.err("buffer size {} not big enough!", .{buffer.half_len});
        //         return 1;
        //     }
        //     const len = try x.readSock(conn.sock, receive_buffer, 0);
        //     if (len == 0) {
        //         std.log.info("X server connection closed", .{});
        //         return 0;
        //     }
        //     buffer.reserve(len);
        // }

        // while (true) {
        //     const data = buffer.nextReservedBuffer();
        //     if (data.len < 32)
        //         break;
        //     const msg_len = x.parseMsgLen(data[0..32].*);
        //     if (data.len < msg_len)
        //         break;
        //     buffer.release(msg_len);
        //     //buf.resetIfEmpty();
        //     switch (x.serverMsgTaggedUnion(@alignCast(data.ptr))) {
        //         .err => |msg| {
        //             std.log.err("Received X error: {}", .{msg});
        //             return 1;
        //         },
        //         .reply => |msg| {
        //             std.log.info("todo: handle a reply message {}", .{msg});
        //             return error.TodoHandleReplyMessage;
        //         },
        //         .generic_extension_event => |msg| {
        //             std.log.info("TODO: handle a GE generic event {}", .{msg});
        //             return error.TodoHandleGenericExtensionEvent;
        //         },
        //         .key_press => |msg| {
        //             std.log.info("key_press: keycode={}", .{msg.keycode});
        //         },
        //         .key_release => |msg| {
        //             std.log.info("key_release: keycode={}", .{msg.keycode});
        //         },
        //         .button_press => |msg| {
        //             std.log.info("button_press: {}", .{msg});
        //         },
        //         .button_release => |msg| {
        //             std.log.info("button_release: {}", .{msg});
        //         },
        //         .enter_notify => |msg| {
        //             std.log.info("enter_window: {}", .{msg});
        //         },
        //         .leave_notify => |msg| {
        //             std.log.info("leave_window: {}", .{msg});
        //         },
        //         .motion_notify => |msg| {
        //             // too much logging
        //             //std.log.info("pointer_motion: {}", .{msg});
        //             _ = msg;
        //         },
        //         .keymap_notify => |msg| {
        //             std.log.info("keymap_state: {}", .{msg});
        //         },
        //         .expose => |msg| {
        //             std.log.info("expose: {}", .{msg});
        //             try render_context.render();
        //         },
        //         .mapping_notify => |msg| {
        //             std.log.info("mapping_notify: {}", .{msg});
        //         },
        //         .no_exposure => |msg| std.debug.panic("unexpected no_exposure {}", .{msg}),
        //         .unhandled => |msg| {
        //             std.log.info("todo: server msg {}", .{msg});
        //             return error.UnhandledServerMsg;
        //         },
        //         .map_notify,
        //         .reparent_notify,
        //         .configure_notify,
        //         // We did not register for these
        //         => @panic("Received unexpected event event that we did not register for"),
        //     }
        // }
    }

    // Clean-up
    try render.cleanupResources(conn.sock, &ids);

    // Exited cleanly
    return;
}
