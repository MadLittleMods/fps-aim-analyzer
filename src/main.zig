const std = @import("std");
const x = @import("x");
const common = @import("x11common.zig");

var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
const allocator = arena.allocator();

const window_width = 400;
const window_height = 400;

pub const Ids = struct {
    base: u32,
    pub fn window(self: Ids) u32 {
        return self.base;
    }
    pub fn bg_gc(self: Ids) u32 {
        return self.base + 1;
    }
    pub fn fg_gc(self: Ids) u32 {
        return self.base + 2;
    }
    pub fn pixmap(self: Ids) u32 {
        return self.base + 3;
    }
    pub fn colormap(self: Ids) u32 {
        return self.base + 4;
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

    // TODO: maybe need to call conn.setup.verify or something?

    const ids = Ids{ .base = conn.setup.fixed().resource_id_base };
    const window_id = ids.window();
    std.log.info("window_id {0} 0x{0x}", .{window_id});
    std.log.info("screen.root_visual visual_id {0} 0x{0x}", .{screen.root_visual});
    // {
    //     var message_buffer: [x.create_colormap.len]u8 = undefined;
    //     x.create_colormap.serialize(&message_buffer, .{
    //         .id = ids.colormap(),
    //         .visual_id = screen.root_visual,
    //         .window_id = window_id,
    //         .alloc = .none,
    //     });
    //     try conn.send(&message_buffer);
    // }
    {
        var message_buffer: [x.create_window.max_len]u8 = undefined;
        const len = x.create_window.serialize(&message_buffer, .{
            .window_id = window_id,
            .parent_window_id = screen.root,
            // Color depth:
            // - 24 for RGB
            // - 32 for RGBA
            .depth = 24,
            // Place it in the top-right corner of the screen
            .x = screen.pixel_width - window_width,
            .y = 0,
            .width = window_width,
            .height = window_height,
            .border_width = 0, // TODO: what is this?
            .class = .input_output,
            .visual_id = screen.root_visual,
        }, .{
            .bg_pixmap = .none,
            .bg_pixel = 0x0000aa80,
            //            //.border_pixmap =
            .border_pixel = 0x000000ff,
            // .colormap = @enumFromInt(ids.colormap()),
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

    const background_graphics_context_id = ids.bg_gc();
    {
        var message_buffer: [x.create_gc.max_len]u8 = undefined;
        const len = x.create_gc.serialize(&message_buffer, .{
            .gc_id = background_graphics_context_id,
            .drawable_id = screen.root,
        }, .{
            .background = 0x0000ff00,
            .foreground = 0x000000ff,
        });
        try conn.send(message_buffer[0..len]);
    }
    const foreground_graphics_context_id = ids.fg_gc();
    {
        var message_buffer: [x.create_gc.max_len]u8 = undefined;
        const len = x.create_gc.serialize(&message_buffer, .{
            .gc_id = foreground_graphics_context_id,
            .drawable_id = screen.root,
        }, .{
            .background = screen.black_pixel,
            .foreground = 0x00ffff00,
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
                    std.log.err("{}", .{msg});
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
                    _ = msg;
                    //std.log.info("pointer_motion: {}", .{msg});
                },
                .keymap_notify => |msg| {
                    std.log.info("keymap_state: {}", .{msg});
                },
                .expose => |msg| {
                    std.log.info("expose: {}", .{msg});
                    try render(
                        conn.sock,
                        window_id,
                        background_graphics_context_id,
                        foreground_graphics_context_id,
                        font_dims,
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

    // {
    //     var msg: [x.free_colormap.len]u8 = undefined;
    //     x.free_colormap.serialize(&msg, ids.colormap());
    //     try conn.send(&msg);
    // }
}

const FontDims = struct {
    width: u8,
    height: u8,
    font_left: i16, // pixels to the left of the text basepoint
    font_ascent: i16, // pixels up from the text basepoint to the top of the text
};

fn render(
    sock: std.os.socket_t,
    drawable_id: u32,
    background_graphics_context_id: u32,
    foreground_graphics_context_id: u32,
    font_dims: FontDims,
) !void {
    {
        var msg: [x.poly_fill_rectangle.getLen(1)]u8 = undefined;
        x.poly_fill_rectangle.serialize(&msg, .{
            .drawable_id = drawable_id,
            .gc_id = background_graphics_context_id,
        }, &[_]x.Rectangle{
            .{ .x = 100, .y = 100, .width = 200, .height = 200 },
        });
        try common.send(sock, &msg);
    }
    {
        var msg: [x.clear_area.len]u8 = undefined;
        x.clear_area.serialize(&msg, false, drawable_id, .{
            .x = 150,
            .y = 150,
            .width = 100,
            .height = 100,
        });
        try common.send(sock, &msg);
    }
    {
        const text_literal: []const u8 = "Hello X!";
        const text = x.Slice(u8, [*]const u8){ .ptr = text_literal.ptr, .len = text_literal.len };
        var msg: [x.image_text8.getLen(text.len)]u8 = undefined;

        const text_width = font_dims.width * text_literal.len;

        x.image_text8.serialize(&msg, text, .{
            .drawable_id = drawable_id,
            .gc_id = foreground_graphics_context_id,
            .x = @divTrunc((window_width - @as(i16, @intCast(text_width))), 2) + font_dims.font_left,
            .y = @divTrunc((window_height - @as(i16, @intCast(font_dims.height))), 2) + font_dims.font_ascent,
        });
        try common.send(sock, &msg);
    }
}
