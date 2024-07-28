const std = @import("std");
const x = @import("x");
const common = @import("x11/x11_common.zig");
const x11_extension_utils = @import("x11/x11_extension_utils.zig");
const x_render_extension = @import("x11/x_render_extension.zig");
const x_input_extension = @import("x11/x_input_extension.zig");
const render_utils = @import("utils/render_utils.zig");
const image_conversion = @import("vision/image_conversion.zig");
const RGBImage = image_conversion.RGBImage;
const render = @import("screen_play/render.zig");
const AppState = @import("screen_play/app_state.zig").AppState;

/// ScreenPlay: punny name for screenshot playback that we can use to mock gameplay and
/// test the aim analyzer against.
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
            return 1;
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
    // const buffer_limit = buffer.half_len;

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

    // Assemble a map of X extension info
    const extensions = x11_extension_utils.Extensions(&.{.render}){
        .render = render_extension,
    };

    try render.createResources(
        conn.sock,
        &buffer,
        &ids,
        screen,
        &extensions,
        &state,
    );

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

    const rgb_image = try RGBImage.loadImageFromFilePath(
        "screenshot-data/halo-infinite/1080/default/36 - bazaar assault rifle.png",
        allocator,
    );
    defer rgb_image.deinit(allocator);
    try render_context.copyImageToPixmapAtIndex(rgb_image, 0, allocator);

    while (true) {
        {
            const receive_buffer = buffer.nextReadBuffer();
            if (receive_buffer.len == 0) {
                std.log.err("buffer size {} not big enough!", .{buffer.half_len});
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
                    std.log.info("todo: handle a reply message {}", .{msg});
                    return error.TodoHandleReplyMessage;
                },
                .generic_extension_event => |msg| {
                    std.log.info("TODO: handle a GE generic event {}", .{msg});
                    return error.TodoHandleGenericExtensionEvent;
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
                    _ = msg;
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
                    std.log.info("todo: server msg {}", .{msg});
                    return error.UnhandledServerMsg;
                },
                .map_notify,
                .reparent_notify,
                .configure_notify,
                // We did not register for these
                => @panic("Received unexpected event event that we did not register for"),
            }
        }
    }

    // Clean-up
    try render.cleanupResources(conn.sock, &ids);
}
