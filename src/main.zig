const std = @import("std");
const x = @import("x");
const zigimg = @import("zigimg");
const common = @import("x11/x11_common.zig");
const x11_extension_utils = @import("x11//x11_extension_utils.zig");
const x_render_extension = @import("x11/x_render_extension.zig");
const x_input_extension = @import("x11/x_input_extension.zig");
const render = @import("render.zig");
const AppState = @import("app_state.zig").AppState;
const buffer_utils = @import("utils/buffer_utils.zig");
const render_utils = @import("utils/render_utils.zig");
const Dimensions = render_utils.Dimensions;
const BoundingClientRect = render_utils.BoundingClientRect;
const image_conversion = @import("vision/image_conversion.zig");
const RGBImage = image_conversion.RGBImage;
const halo_text_vision = @import("vision/halo_text_vision.zig");
const ScreenshotRegion = halo_text_vision.ScreenshotRegion;
const Screenshot = halo_text_vision.Screenshot;
const CharacterRecognition = @import("vision/ocr/character_recognition.zig").CharacterRecognition;
const save_load_utils = @import("vision/ocr/save_load_utils.zig");

fn projectSrcPath() []const u8 {
    const file_source_path = std.fs.path.dirname(@src().file) orelse ".";

    return file_source_path;
}

pub fn main() !u8 {
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

    const screen = render.getFirstScreenFromConnectionSetup(conn.setup);
    inline for (@typeInfo(@TypeOf(screen.*)).Struct.fields) |field| {
        std.log.debug("SCREEN 0| {s}: {any}", .{ field.name, @field(screen, field.name) });
    }

    const pixmap_formats = try render.getPixmapFormatsFromConnectionSetup(conn.setup);
    const root_window_pixmap_format = try render.findMatchingPixmapFormatForDepth(
        pixmap_formats,
        screen.root_depth,
    );

    const image_byte_order: std.builtin.Endian = switch (conn_setup_fixed_fields.image_byte_order) {
        .lsb_first => .Little,
        .msb_first => .Big,
        else => |order| {
            std.log.err("unknown image-byte-order {}", .{order});
            return 1;
        },
    };

    const ids = render.Ids.init(
        screen.root,
        conn_setup_fixed_fields.resource_id_base,
    );

    const depth = 32;

    const root_screen_dimensions = Dimensions{
        .width = @intCast(screen.pixel_width),
        .height = @intCast(screen.pixel_height),
    };

    const screenshot_capture_scale = 20;
    const screenshot_capture_dimensions = Dimensions{
        .width = @intCast(@divTrunc(screen.pixel_width, screenshot_capture_scale)),
        .height = @intCast(@divTrunc(screen.pixel_height, screenshot_capture_scale)),
    };

    // Start out with the bottom-right corner of the screen
    const ammo_counter_screenshot_region = ScreenshotRegion.bottom_right_quadrant;
    const ammo_counter_bounding_box_width: i16 = @intCast(@divTrunc(screen.pixel_width, 2));
    const ammo_counter_bounding_box_height: i16 = @intCast(@divTrunc(screen.pixel_height, 2));
    const ammo_counter_bounding_box = BoundingClientRect(i16){
        .x = @as(i16, @intCast(screen.pixel_width)) - ammo_counter_bounding_box_width,
        .y = @as(i16, @intCast(screen.pixel_height)) - ammo_counter_bounding_box_height,
        .width = ammo_counter_bounding_box_width,
        .height = ammo_counter_bounding_box_height,
    };

    const max_screenshots_shown = 6;
    const margin = 20;
    const padding = 10;
    const window_dimensions = Dimensions{
        .width = screenshot_capture_dimensions.width + (2 * padding),
        .height = (max_screenshots_shown * (screenshot_capture_dimensions.height + padding)) + padding,
    };

    var state = AppState{
        .root_screen_dimensions = root_screen_dimensions,
        .window_dimensions = window_dimensions,
        .screenshot_capture_dimensions = screenshot_capture_dimensions,
        .ammo_counter_bounding_box = ammo_counter_bounding_box,
        // We start out capturing the bottom-right corner of the screen
        .ammo_counter_screenshot_region = ammo_counter_screenshot_region,
        .max_screenshots_shown = max_screenshots_shown,
        .margin = margin,
        .padding = padding,
    };

    // Create a big buffer that we can use to read messages and replies from the X server.
    const double_buffer = try x.DoubleBuffer.init(
        std.mem.alignForward(usize, std.math.pow(usize, 2, 32), std.mem.page_size),
        .{ .memfd_name = "ZigX11DoubleBuffer" },
    );
    defer double_buffer.deinit(); // not necessary but good to test
    std.log.info("Read buffer capacity is {}", .{double_buffer.half_len});
    var buffer = double_buffer.contiguousReadBuffer();
    const buffer_limit = buffer.half_len;

    // TODO: maybe need to call conn.setup.verify or something?

    // We use the X Render extension for capturing screenshots and splatting them onto
    // our window. Useful because their "composite" request works with mismatched depths
    // between the source and destinations.
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

    // We use the X Input extension to detect clicks on the game window (or whatever
    // window) they happen to be on. Useful because we can detect clicks even when our
    // window is not focused and doesn't have to be directly clicked.
    const optional_input_extension = try x11_extension_utils.getExtensionInfo(
        conn.sock,
        &buffer,
        "XInputExtension",
    );
    const input_extension = optional_input_extension orelse @panic("XInputExtension extension not found");

    try x_input_extension.ensureCompatibleVersionOfXInputExtension(
        conn.sock,
        &buffer,
        &input_extension,
        .{
            // We arbitrarily require version 2.3 of the X Input extension
            // because that's the latest version and is sufficiently old
            // and ubiquitous.
            .major_version = 2,
            .minor_version = 3,
        },
    );

    // Assemble a map of X extension info
    const extensions = x11_extension_utils.Extensions{
        .render = render_extension,
        .input = input_extension,
    };

    try render.createResources(
        conn.sock,
        &buffer,
        &ids,
        screen,
        &extensions,
        depth,
        &state,
        allocator,
    );

    // Register for events from the X Input extension for when the mouse is clicked
    {
        var event_masks = [_]x.inputext.EventMask{.{
            .device_id = .all_master,
            .mask = x.inputext.event.raw_button_press,
        }};
        var message_buffer: [x.inputext.select_events.getLen(@as(u16, @intCast(event_masks.len)))]u8 = undefined;
        const len = x.inputext.select_events.serialize(&message_buffer, extensions.input.opcode, .{
            .window_id = ids.root,
            .masks = event_masks[0..],
        });
        try conn.send(message_buffer[0..len]);
    }

    // Get some font information
    {
        const text_literal = [_]u16{'m'};
        const text = x.Slice(u16, [*]const u16){ .ptr = &text_literal, .len = text_literal.len };
        var message_buffer: [x.query_text_extents.getLen(text.len)]u8 = undefined;
        x.query_text_extents.serialize(&message_buffer, ids.fg_gc, text);
        try conn.send(&message_buffer);
    }
    const font_dims: render.FontDims = blk: {
        const message_length = try x.readOneMsg(conn.reader(), @alignCast(buffer.nextReadBuffer()));
        try buffer_utils.checkMessageLengthFitsInBuffer(message_length, buffer_limit);
        switch (x.serverMsgTaggedUnion(@alignCast(buffer.double_buffer_ptr))) {
            .reply => |msg_reply| {
                const msg: *x.ServerMsg.QueryTextExtents = @ptrCast(msg_reply);
                break :blk .{
                    .width = @intCast(msg.overall_width),
                    .height = @intCast(msg.font_ascent + msg.font_descent),
                    .font_left = @intCast(msg.overall_left),
                    .font_ascent = msg.font_ascent,
                };
            },
            else => |msg| {
                std.log.err("expected a reply for `x.query_text_extents` but got {}", .{msg});
                return 1;
            },
        }
    };

    // Show the window. In the X11 protocol, this is called mapping a window, and hiding
    // a window is called unmapping. When windows are initially created, they are
    // unmapped (or hidden).
    {
        var msg: [x.map_window.len]u8 = undefined;
        x.map_window.serialize(&msg, ids.window);
        try conn.send(&msg);
    }

    // Assemble a file path to the neural network model file
    const neural_network_file_path = try std.fmt.allocPrint(
        allocator,
        "{s}/{s}",
        .{
            // Prepend the project directory path
            projectSrcPath(),
            // And the latest file name
            "neural_network_checkpoint_epoch_440.json",
        },
    );
    defer allocator.free(neural_network_file_path);
    // Load the neural network and get ready to recognize characters
    var character_recognition = try CharacterRecognition.init(
        neural_network_file_path,
        allocator,
    );

    var render_context = render.RenderContext{
        .sock = &conn.sock,
        .ids = &ids,
        .root_screen_depth = screen.root_depth,
        .extensions = &extensions,
        .font_dims = &font_dims,
        .image_byte_order = image_byte_order,
        .root_window_pixmap_format = root_window_pixmap_format,
        .state = &state,
        .character_recognition = &character_recognition,
    };

    while (true) {
        {
            const receive_buffer = buffer.nextReadBuffer();
            if (receive_buffer.len == 0) {
                std.log.err("buffer size {} not big enough to fit the bytes we received!", .{
                    buffer.half_len,
                });
                return 1;
            }
            const len = try x.readSock(conn.sock, receive_buffer, 0);
            if (len == 0) {
                std.log.info("X server connection closed", .{});
                return 0;
            }
            buffer.reserve(len);
        }

        while (true) {
            const data = buffer.nextReservedBuffer();
            if (data.len < 32)
                break;
            const msg_len = x.parseMsgLen(data[0..32].*);
            if (data.len < msg_len)
                break;
            buffer.release(msg_len);
            //buf.resetIfEmpty();
            switch (x.serverMsgTaggedUnion(@alignCast(data.ptr))) {
                .err => |msg| {
                    std.log.err("Received X error: {}", .{msg});
                    return 1;
                },
                .reply => |msg| {
                    // Note: We assume any reply here will be to the `get_image` request
                    // but normally you would want some state machine sequencer to match
                    // up requests with replies.
                    const get_image_reply: *x.get_image.Reply = @ptrCast(msg);

                    const rgb_image = try render_context.convertXGetImageReplyToRGBImage(get_image_reply, allocator);
                    defer rgb_image.deinit(allocator);
                    const screenshot: Screenshot(RGBImage) = .{
                        .image = rgb_image,
                        .crop_region = state.ammo_counter_screenshot_region,
                        .crop_region_x = @intCast(ammo_counter_bounding_box.x),
                        .crop_region_y = @intCast(ammo_counter_bounding_box.y),
                        .pre_crop_width = screen.pixel_width,
                        .pre_crop_height = screen.pixel_height,
                        // We assume the game is being rendered 1:1 (100%), so the game
                        // resolution is the same as the image resolution
                        .game_resolution_width = screen.pixel_width,
                        .game_resolution_height = screen.pixel_height,
                    };

                    try render_context.analyzeScreenCapture(screenshot, allocator);
                },
                .generic_extension_event => |msg| {
                    if (msg.ext_opcode == extensions.input.opcode) {
                        switch (x.inputext.genericExtensionEventTaggedUnion(@alignCast(data.ptr))) {
                            .raw_button_press => |extension_message| {
                                std.log.info("raw_button_press {}", .{extension_message});
                                if (extension_message.detail == 1) {
                                    try render_context.captureScreenshotToPixmap();
                                    try render_context.render();
                                }
                            },
                            // We did not register for these events so we should not see them
                            else => @panic("Received unexpected generic extension " ++
                                "event that we did not register for"),
                        }
                    } else {
                        std.log.info("TODO: handle a GE generic event {}", .{msg});
                        return error.TodoHandleGenericExtensionEvent;
                    }
                },
                .key_press => |msg| {
                    std.log.info("key_press: keycode={}", .{msg.keycode});
                },
                .key_release => |msg| {
                    std.log.info("key_release: keycode={}", .{msg.keycode});
                },
                .button_press => |msg| {
                    std.log.info("button_press: {}", .{msg});
                },
                .button_release => |msg| {
                    std.log.info("button_release: {}", .{msg});
                },
                .enter_notify => |msg| {
                    std.log.info("enter_window: {}", .{msg});
                },
                .leave_notify => |msg| {
                    std.log.info("leave_window: {}", .{msg});
                },
                .motion_notify => |msg| {
                    // too much logging
                    //std.log.info("pointer_motion: {}", .{msg});
                    state.mouse_x = msg.event_x;
                    try render_context.render();
                },
                .keymap_notify => |msg| {
                    std.log.info("keymap_state: {}", .{msg});
                },
                .expose => |msg| {
                    std.log.info("expose: {}", .{msg});
                    try render_context.render();
                },
                .mapping_notify => |msg| {
                    std.log.info("mapping_notify: {}", .{msg});
                },
                .no_exposure => |msg| std.debug.panic("unexpected no_exposure {}", .{msg}),
                .unhandled => |msg| {
                    std.log.info("todo: unhandled server msg {}", .{msg});
                    return error.UnhandledServerMsg;
                },
                .map_notify,
                .reparent_notify,
                .configure_notify,
                // We did not register for these
                => @panic("Received unexpected event event that we did not register for"),
            }
        }

        {
            var get_image_msg: [x.get_image.len]u8 = undefined;
            x.get_image.serialize(&get_image_msg, .{
                .format = .z_pixmap,
                .drawable_id = ids.root,
                .x = @intCast(ammo_counter_bounding_box.x),
                .y = @intCast(ammo_counter_bounding_box.y),
                .width = @intCast(ammo_counter_bounding_box.width),
                .height = @intCast(ammo_counter_bounding_box.height),
                .plane_mask = 0xffffffff,
            });
            // We handle the reply to this request above (see `analyzeScreenCapture`)
            try common.send(conn.sock, &get_image_msg);
        }
    }

    // Clean-up
    try render.cleanupResources(conn.sock, &ids);
}

test {
    _ = @import("utils/render_utils.zig");
    _ = @import("utils/print_utils.zig");
    _ = @import("vision/vision.zig");
}
