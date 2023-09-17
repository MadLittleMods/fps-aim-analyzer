const std = @import("std");
const x = @import("x");
const common = @import("x11common.zig");

var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
const allocator = arena.allocator();

const window_width = 400;
const window_height = 400;

pub const Ids = struct {
    const Self = @This();

    root: u32,
    base: u32,
    _current_id: u32,

    window: u32 = 0,
    colormap: u32 = 0,
    copy_from_root_gc: u32 = 0,
    bg_gc: u32 = 0,
    fg_gc: u32 = 0,
    pixmap: u32 = 0,

    pub fn init(root: u32, base: u32) Self {
        var ids = Ids{
            .root = root,
            .base = base,
            ._current_id = base,
        };

        ids.window = ids.generateMonotonicId();
        ids.colormap = ids.generateMonotonicId();
        ids.copy_from_root_gc = ids.generateMonotonicId();
        ids.bg_gc = ids.generateMonotonicId();
        ids.fg_gc = ids.generateMonotonicId();
        ids.pixmap = ids.generateMonotonicId();

        return ids;
    }

    /// Always increasing ID everytime the function is called
    fn generateMonotonicId(self: *Ids) u32 {
        const current_id = self._current_id;
        self._current_id += 1;
        return current_id;
    }
};

pub fn main() !u8 {
    try x.wsaStartup();
    const conn = try common.connect(allocator);
    defer std.os.shutdown(conn.sock, .both) catch {};

    const screen = blk: {
        const fixed = conn.setup.fixed();
        inline for (@typeInfo(@TypeOf(fixed.*)).Struct.fields) |field| {
            std.log.debug("{s}: {any}", .{ field.name, @field(fixed, field.name) });
        }
        std.log.debug("vendor: {s}", .{try conn.setup.getVendorSlice(fixed.vendor_len)});
        const format_list_offset = x.ConnectSetup.getFormatListOffset(fixed.vendor_len);
        const format_list_limit = x.ConnectSetup.getFormatListLimit(format_list_offset, fixed.format_count);
        std.log.debug("fmt list off={} limit={}", .{ format_list_offset, format_list_limit });
        const formats = try conn.setup.getFormatList(format_list_offset, format_list_limit);
        for (formats, 0..) |format, i| {
            std.log.debug("format[{}] depth={:3} bpp={:3} scanpad={:3}", .{ i, format.depth, format.bits_per_pixel, format.scanline_pad });
        }
        var screen = conn.setup.getFirstScreenPtr(format_list_limit);
        inline for (@typeInfo(@TypeOf(screen.*)).Struct.fields) |field| {
            std.log.debug("SCREEN 0| {s}: {any}", .{ field.name, @field(screen, field.name) });
        }
        break :blk screen;
    };

    // TODO: Put this back at 32-bit depth for ARGB (alpha transparency)
    const depth = 24;
    const matching_visual_type = try screen.findMatchingVisualType(depth, .true_color, allocator);
    std.log.debug("matching_visual_type {any}", .{matching_visual_type});

    const screenshot_capture_dims = ScreenshotCaptureDims{
        .width = 200,
        .height = 150,
    };
    var state = State{
        .screenshot_capture_dims = screenshot_capture_dims,
    };

    // TODO: maybe need to call conn.setup.verify or something?

    const ids = Ids.init(
        screen.root,
        conn.setup.fixed().resource_id_base,
    );
    const window_id = ids.window;
    std.log.info("window_id {0} 0x{0x}", .{window_id});
    {
        var message_buffer: [x.create_colormap.len]u8 = undefined;
        x.create_colormap.serialize(&message_buffer, .{
            .id = ids.colormap,
            .window_id = screen.root, //window_id,
            .visual_id = matching_visual_type.id,
            .alloc = .none,
        });
        try conn.send(&message_buffer);
    }
    {
        std.log.debug("Creating window", .{});
        var message_buffer: [x.create_window.max_len]u8 = undefined;
        const len = x.create_window.serialize(&message_buffer, .{
            .window_id = window_id,
            .parent_window_id = screen.root,
            // Color depth:
            // - 24 for RGB
            // - 32 for ARGB
            .depth = depth,
            // Place it in the top-right corner of the screen
            .x = screen.pixel_width - window_width,
            .y = 0,
            .width = window_width,
            .height = window_height,
            .border_width = 0, // TODO: what is this?
            .class = .input_output,
            .visual_id = matching_visual_type.id,
        }, .{
            .bg_pixmap = .none,
            // 0xAARRGGBB
            .bg_pixel = 0xaa006660,
            // .border_pixmap =
            .border_pixel = 0x00000000,
            .colormap = @enumFromInt(ids.colormap),
            //            .bit_gravity = .north_west,
            //            .win_gravity = .east,
            //            .backing_store = .when_mapped,
            //            .backing_planes = 0x1234,
            //            .backing_pixel = 0xbbeeeeff,
            //
            // Whether this window overrides structure control facilities. Basically, a
            // suggestion whether the window manager to decorate this window (false) or
            // we want to override the behavior. We set this to true to disable the
            // window controls (basically a borderless window).
            .override_redirect = true,
            //            .save_under = true,
            .event_mask = x.event.key_press | x.event.key_release | x.event.button_press | x.event.button_release | x.event.enter_window | x.event.leave_window | x.event.pointer_motion | x.event.keymap_state | x.event.exposure,
            //                | x.event.pointer_motion_hint WHAT THIS DO?
            //                | x.event.button1_motion  WHAT THIS DO?
            //                | x.event.button2_motion  WHAT THIS DO?
            //                | x.event.button3_motion  WHAT THIS DO?
            //                | x.event.button4_motion  WHAT THIS DO?
            //                | x.event.button5_motion  WHAT THIS DO?
            //                | x.event.button_motion  WHAT THIS DO?

            //            .dont_propagate = 1,
        });
        try conn.send(message_buffer[0..len]);
    }

    std.log.info("copy_from_root_gc {0} 0x{0x}", .{ids.copy_from_root_gc});
    {
        var message_buffer: [x.create_gc.max_len]u8 = undefined;
        const len = x.create_gc.serialize(&message_buffer, .{
            .gc_id = ids.copy_from_root_gc,
            .drawable_id = window_id,
        }, .{
            .background = 0xff000000,
            .foreground = 0xffffffff,
            // Include child windows when we send CopyArea (https://stackoverflow.com/a/52036063/796832).
            // Otherwise, by default, the window pixels are cropped by the sub-windows.
            .subwindow_mode = .include_inferiors,
            // prevent NoExposure events when we send CopyArea
            .graphics_exposures = false,
        });
        try conn.send(message_buffer[0..len]);
    }

    const background_graphics_context_id = ids.bg_gc;
    std.log.info("background_graphics_context_id {0} 0x{0x}", .{background_graphics_context_id});
    {
        var message_buffer: [x.create_gc.max_len]u8 = undefined;
        const len = x.create_gc.serialize(&message_buffer, .{
            .gc_id = background_graphics_context_id,
            .drawable_id = window_id,
        }, .{
            .background = 0xff000000,
            .foreground = 0xff0000ff,
            // prevent NoExposure events when we send CopyArea
            .graphics_exposures = false,
        });
        try conn.send(message_buffer[0..len]);
    }
    const foreground_graphics_context_id = ids.fg_gc;
    std.log.info("foreground_graphics_context_id {0} 0x{0x}", .{foreground_graphics_context_id});
    {
        var message_buffer: [x.create_gc.max_len]u8 = undefined;
        const len = x.create_gc.serialize(&message_buffer, .{
            .gc_id = foreground_graphics_context_id,
            .drawable_id = window_id,
        }, .{
            .background = 0xff000000,
            .foreground = 0xffffff00,
            // prevent NoExposure events when we send CopyArea
            .graphics_exposures = false,
        });
        try conn.send(message_buffer[0..len]);
    }

    // get some font information
    {
        const text_literal = [_]u16{'m'};
        const text = x.Slice(u16, [*]const u16){ .ptr = &text_literal, .len = text_literal.len };
        var msg: [x.query_text_extents.getLen(text.len)]u8 = undefined;
        x.query_text_extents.serialize(&msg, foreground_graphics_context_id, text);
        try conn.send(&msg);
    }

    const double_buf = try x.DoubleBuffer.init(
        std.mem.alignForward(usize, 1000, std.mem.page_size),
        .{ .memfd_name = "ZigX11DoubleBuffer" },
    );
    // double_buf.deinit() (not necessary)
    std.log.info("read buffer capacity is {}", .{double_buf.half_len});
    var buf = double_buf.contiguousReadBuffer();

    const font_dims: FontDims = blk: {
        _ = try x.readOneMsg(conn.reader(), @alignCast(buf.nextReadBuffer()));
        switch (x.serverMsgTaggedUnion(@alignCast(buf.double_buffer_ptr))) {
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
                std.log.err("expected a reply but got {}", .{msg});
                return 1;
            },
        }
    };

    // Create a pixmap to capture the screenshot onto
    {
        var msg: [x.create_pixmap.len]u8 = undefined;
        x.create_pixmap.serialize(&msg, .{
            .id = ids.pixmap,
            .drawable_id = ids.window,
            .depth = depth,
            .width = screenshot_capture_dims.width,
            .height = screenshot_capture_dims.height,
        });
        try common.send(conn.sock, &msg);
    }

    // Show the window. In the X11 protocol is called mapping a window, and hiding a
    // window is called unmapping. When windows are initially created, they are unmapped
    // (or hidden).
    {
        var msg: [x.map_window.len]u8 = undefined;
        x.map_window.serialize(&msg, window_id);
        try conn.send(&msg);
    }

    while (true) {
        {
            const recv_buf = buf.nextReadBuffer();
            if (recv_buf.len == 0) {
                std.log.err("buffer size {} not big enough!", .{buf.half_len});
                return 1;
            }
            const len = try x.readSock(conn.sock, recv_buf, 0);
            if (len == 0) {
                std.log.info("X server connection closed", .{});
                return 0;
            }
            buf.reserve(len);
        }
        while (true) {
            const data = buf.nextReservedBuffer();
            if (data.len < 32)
                break;
            const msg_len = x.parseMsgLen(data[0..32].*);
            if (data.len < msg_len)
                break;
            buf.release(msg_len);
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
                .key_press => |msg| {
                    std.log.info("key_press: keycode={}", .{msg.keycode});
                },
                .key_release => |msg| {
                    std.log.info("key_release: keycode={}", .{msg.keycode});
                },
                .button_press => |msg| {
                    std.log.info("button_press: {}", .{msg});
                    try captureScreenshotToPixmap(
                        conn.sock,
                        ids,
                        screenshot_capture_dims,
                    );
                    try render(
                        conn.sock,
                        ids,
                        font_dims,
                        state,
                    );
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
                    try render(conn.sock, ids, font_dims, state);
                },
                .keymap_notify => |msg| {
                    std.log.info("keymap_state: {}", .{msg});
                },
                .expose => |msg| {
                    std.log.info("expose: {}", .{msg});
                    try render(
                        conn.sock,
                        ids,
                        font_dims,
                        state,
                    );
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
                => unreachable, // did not register for these
            }
        }
    }

    {
        var msg: [x.free_pixmap.len]u8 = undefined;
        x.free_pixmap.serialize(&msg, ids.pixmap);
        try common.send(conn.sock, &msg);
    }

    {
        var msg: [x.free_colormap.len]u8 = undefined;
        x.free_colormap.serialize(&msg, ids.colormap);
        try conn.send(&msg);
    }
}

const FontDims = struct {
    width: u8,
    height: u8,
    font_left: i16, // pixels to the left of the text basepoint
    font_ascent: i16, // pixels up from the text basepoint to the top of the text
};

const ScreenshotCaptureDims = struct {
    width: u16,
    height: u16,
};

const State = struct {
    screenshot_capture_dims: ScreenshotCaptureDims,
    mouse_x: i16 = 0,
};

fn renderString(
    sock: std.os.socket_t,
    drawable_id: u32,
    fg_gc_id: u32,
    pos_x: i16,
    pos_y: i16,
    comptime fmt: []const u8,
    args: anytype,
) !void {
    var msg: [x.image_text8.max_len]u8 = undefined;
    const text_buf = msg[x.image_text8.text_offset .. x.image_text8.text_offset + 0xff];
    const text_len: u8 = @intCast((std.fmt.bufPrint(text_buf, fmt, args) catch @panic("string too long")).len);
    x.image_text8.serializeNoTextCopy(&msg, text_len, .{
        .drawable_id = drawable_id,
        .gc_id = fg_gc_id,
        .x = pos_x,
        .y = pos_y,
    });
    try common.send(sock, msg[0..x.image_text8.getLen(text_len)]);
}

fn render(
    sock: std.os.socket_t,
    ids: Ids,
    font_dims: FontDims,
    state: State,
) !void {
    const window_id = ids.window;
    const screenshot_capture_dims = state.screenshot_capture_dims;
    const mouse_x = state.mouse_x;

    {
        var msg: [x.poly_fill_rectangle.getLen(1)]u8 = undefined;
        x.poly_fill_rectangle.serialize(&msg, .{
            .drawable_id = window_id,
            .gc_id = ids.bg_gc,
        }, &[_]x.Rectangle{
            .{ .x = 100, .y = 100, .width = 200, .height = 200 },
        });
        try common.send(sock, &msg);
    }
    {
        var msg: [x.clear_area.len]u8 = undefined;
        x.clear_area.serialize(&msg, false, window_id, .{
            .x = 150,
            .y = 150,
            .width = 100,
            .height = 100,
        });
        try common.send(sock, &msg);
    }

    const text_length = 11;
    const text_width = font_dims.width * text_length;
    try renderString(
        sock,
        window_id,
        ids.fg_gc,
        @divTrunc((window_width - @as(i16, @intCast(text_width))), 2) + font_dims.font_left,
        @divTrunc((window_height - @as(i16, @intCast(font_dims.height))), 2) + font_dims.font_ascent,
        "Hello X! {}",
        .{
            mouse_x,
        },
    );
    // {
    //     const text_buf = msg[x.image_text8.text_offset .. x.image_text8.text_offset + 0xff];
    //     const text_literal: []const u8 = std.fmt.bufPrint(text_buf, "Hello X! {d}", .{mouse_x});
    //     const text = x.Slice(u8, [*]const u8){ .ptr = text_literal.ptr, .len = text_literal.len };
    //     var msg: [x.image_text8.getLen(text.len)]u8 = undefined;

    //     x.image_text8.serialize(&msg, text, .{
    //         .drawable_id = window_id,
    //         .gc_id = ids.fg_gc,
    //         .x = @divTrunc((window_width - @as(i16, @intCast(text_width))), 2) + font_dims.font_left,
    //         .y = @divTrunc((window_height - @as(i16, @intCast(font_dims.height))), 2) + font_dims.font_ascent,
    //     });
    //     try common.send(sock, &msg);
    // }

    {
        var msg: [x.copy_area.len]u8 = undefined;
        x.copy_area.serialize(&msg, .{
            .src_drawable_id = ids.pixmap,
            .dst_drawable_id = ids.window,
            .gc_id = ids.fg_gc,
            .src_x = 0,
            .src_y = 0,
            .dst_x = 200,
            .dst_y = 0,
            .width = screenshot_capture_dims.width,
            .height = screenshot_capture_dims.height,
        });
        try common.send(sock, &msg);
    }
}

fn captureScreenshotToPixmap(
    sock: std.os.socket_t,
    ids: Ids,
    screenshot_capture_dims: ScreenshotCaptureDims,
) !void {
    std.log.debug("captureScreenshotToPixmap", .{});
    // {
    //     // ~~We use copy_plane instead of copy_area because the depth of the root window
    //     // (24) and the depth of the pixmap (32) are different.~~
    //     // copy_plane creates a new pixmap where the color of the pixels in the source
    //     // match the bit_plane mask. Anywhere the mask matches, the pixmap uses the foreground
    //     // color of the graphics context, otherwise the background color.
    //     var msg: [x.copy_plane.len]u8 = undefined;
    //     x.copy_plane.serialize(&msg, .{
    //         .src_drawable_id = ids.root,
    //         .dst_drawable_id = ids.pixmap,
    //         .gc_id = ids.copy_from_root_gc,
    //         // Capture the middle of the screen
    //         // TODO: Update to use the actual window dimensions
    //         .src_x = (3840 / 2) - @divExact(@as(i16, @intCast(screenshot_capture_dims.width)), 2),
    //         .src_y = (2160 / 2) - @divExact(@as(i16, @intCast(screenshot_capture_dims.height)), 2),
    //         .dst_x = 0,
    //         .dst_y = 0,
    //         .width = screenshot_capture_dims.width,
    //         .height = screenshot_capture_dims.height,
    //         .bit_plane = 1, //0x010000, //0b000000000000000000000001,
    //     });
    //     try common.send(sock, &msg);
    // }

    {
        var msg: [x.copy_area.len]u8 = undefined;
        x.copy_area.serialize(&msg, .{
            .src_drawable_id = ids.root,
            .dst_drawable_id = ids.pixmap,
            .gc_id = ids.copy_from_root_gc,
            .src_x = (3840 / 2) - @divExact(@as(i16, @intCast(screenshot_capture_dims.width)), 2),
            .src_y = (2160 / 2) - @divExact(@as(i16, @intCast(screenshot_capture_dims.height)), 2),
            .dst_x = 0,
            .dst_y = 0,
            .width = screenshot_capture_dims.width,
            .height = screenshot_capture_dims.height,
        });
        try common.send(sock, &msg);
    }
}
