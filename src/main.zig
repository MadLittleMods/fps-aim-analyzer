const std = @import("std");
const x = @import("x");
const common = @import("x11/x11_common.zig");
const x11_extension_utils = @import("x11//x11_extension_utils.zig");
const x_render_extension = @import("x11/x_render_extension.zig");
const render_utils = @import("render_utils.zig");

var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
const allocator = arena.allocator();

const window_dimensions = render_utils.Dimensions{
    .width = 400,
    .height = 400,
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
        var screen = conn.setup.getFirstScreenPtr(format_list_limit);
        inline for (@typeInfo(@TypeOf(screen.*)).Struct.fields) |field| {
            std.log.debug("SCREEN 0| {s}: {any}", .{ field.name, @field(screen, field.name) });
        }
        break :blk screen;
    };

    const ids = render_utils.Ids.init(
        screen.root,
        conn.setup.fixed().resource_id_base,
    );

    const depth = 32;

    const screenshot_capture_dimensions = render_utils.Dimensions{
        .width = 200,
        .height = 150,
    };
    var state = State{
        .screenshot_capture_dimensions = screenshot_capture_dimensions,
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
    _ = buffer_limit;

    // TODO: maybe need to call conn.setup.verify or something?

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
    );

    const extensions = x11_extension_utils.Extensions{
        .render = render_extension,
    };

    try render_utils.createResources(
        conn.sock,
        &buffer,
        &ids,
        screen,
        &extensions,
        depth,
        window_dimensions,
        screenshot_capture_dimensions,
    );

    // get some font information
    {
        const text_literal = [_]u16{'m'};
        const text = x.Slice(u16, [*]const u16){ .ptr = &text_literal, .len = text_literal.len };
        var message_buffer: [x.query_text_extents.getLen(text.len)]u8 = undefined;
        x.query_text_extents.serialize(&message_buffer, ids.fg_gc, text);
        try conn.send(&message_buffer);
    }
    const font_dims: FontDims = blk: {
        _ = try x.readOneMsg(conn.reader(), @alignCast(buffer.nextReadBuffer()));
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

    // Show the window. In the X11 protocol is called mapping a window, and hiding a
    // window is called unmapping. When windows are initially created, they are unmapped
    // (or hidden).
    {
        var msg: [x.map_window.len]u8 = undefined;
        x.map_window.serialize(&msg, ids.window);
        try conn.send(&msg);
    }

    const render_context = RenderContext{
        .sock = &conn.sock,
        .ids = &ids,
        .extensions = &extensions,
        .font_dims = &font_dims,
        .state = &state,
    };

    while (true) {
        {
            const recv_buf = buffer.nextReadBuffer();
            if (recv_buf.len == 0) {
                std.log.err("buffer size {} not big enough!", .{buffer.half_len});
                return 1;
            }
            const len = try x.readSock(conn.sock, recv_buf, 0);
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
                .ge_generic => |msg| {
                    std.log.info("todo: handle a GE generic event {}", .{msg});
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
                    try render_context.captureScreenshotToPixmap();
                    try render_context.render();
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

    // Clean-up
    try render_utils.cleanupResources(ids);
}

const FontDims = struct {
    width: u8,
    height: u8,
    font_left: i16, // pixels to the left of the text basepoint
    font_ascent: i16, // pixels up from the text basepoint to the top of the text
};

const State = struct {
    screenshot_capture_dimensions: render_utils.Dimensions,
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

const RenderContext = struct {
    sock: *const std.os.socket_t,
    ids: *const render_utils.Ids,
    extensions: *const x11_extension_utils.Extensions,
    font_dims: *const FontDims,
    state: *const State,

    pub fn render(self: *const @This()) !void {
        const sock = self.sock.*;
        const ids = self.ids.*;
        const extensions = self.extensions.*;
        const font_dims = self.font_dims.*;
        const state = self.state.*;

        const window_id = ids.window;
        const screenshot_capture_dimensions = state.screenshot_capture_dimensions;
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
            @divTrunc(@as(i16, @intCast(window_dimensions.width)) - @as(i16, @intCast(text_width)), 2) + font_dims.font_left,
            @divTrunc(@as(i16, @intCast(window_dimensions.height)) - @as(i16, @intCast(font_dims.height)), 2) + font_dims.font_ascent,
            "Hello X! {}",
            .{
                mouse_x,
            },
        );

        {
            var msg: [x.render.composite.len]u8 = undefined;
            x.render.composite.serialize(&msg, extensions.render.opcode, .{
                .picture_operation = .over,
                .src_picture_id = ids.picture_pixmap,
                .mask_picture_id = 0,
                .dst_picture_id = ids.picture_window,
                .src_x = 0,
                .src_y = 0,
                .mask_x = 0,
                .mask_y = 0,
                .dst_x = 200,
                .dst_y = 0,
                .width = screenshot_capture_dimensions.width,
                .height = screenshot_capture_dimensions.height,
            });
            try common.send(sock, &msg);
        }
    }

    pub fn captureScreenshotToPixmap(self: @This()) !void {
        const sock = self.sock.*;
        const ids = self.ids.*;
        const extensions = self.extensions.*;
        const state = self.state.*;

        const screenshot_capture_dimensions = state.screenshot_capture_dimensions;

        std.log.debug("captureScreenshotToPixmap", .{});
        {
            var msg: [x.render.composite.len]u8 = undefined;
            x.render.composite.serialize(&msg, extensions.render.opcode, .{
                .picture_operation = .over,
                .src_picture_id = ids.picture_root,
                .mask_picture_id = 0,
                .dst_picture_id = ids.picture_pixmap,
                .src_x = (3840 / 2) - @divExact(@as(i16, @intCast(screenshot_capture_dimensions.width)), 2),
                .src_y = (2160 / 2) - @divExact(@as(i16, @intCast(screenshot_capture_dimensions.height)), 2),
                .mask_x = 0,
                .mask_y = 0,
                .dst_x = 0,
                .dst_y = 0,
                .width = screenshot_capture_dimensions.width,
                .height = screenshot_capture_dimensions.height,
            });
            try common.send(sock, &msg);
        }
    }
};
