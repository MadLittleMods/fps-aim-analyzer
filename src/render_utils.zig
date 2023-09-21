const std = @import("std");
const x = @import("x");
const common = @import("x11/x11_common.zig");
const x11_extension_utils = @import("x11/x11_extension_utils.zig");
const buffer_utils = @import("buffer_utils.zig");

pub const Dimensions = struct {
    width: u16,
    height: u16,
};

pub const Ids = struct {
    const Self = @This();

    root: u32,
    base: u32,
    _current_id: u32,

    window: u32 = 0,
    colormap: u32 = 0,
    bg_gc: u32 = 0,
    fg_gc: u32 = 0,
    pixmap: u32 = 0,
    // For use with the X Render extension
    picture_root: u32 = 0,
    picture_window: u32 = 0,
    picture_pixmap: u32 = 0,

    pub fn init(root: u32, base: u32) Self {
        var ids = Ids{
            .root = root,
            .base = base,
            ._current_id = base,
        };

        ids.window = ids.generateMonotonicId();
        ids.colormap = ids.generateMonotonicId();
        ids.bg_gc = ids.generateMonotonicId();
        ids.fg_gc = ids.generateMonotonicId();
        ids.pixmap = ids.generateMonotonicId();
        ids.picture_root = ids.generateMonotonicId();
        ids.picture_window = ids.generateMonotonicId();
        ids.picture_pixmap = ids.generateMonotonicId();

        return ids;
    }

    /// Always increasing ID everytime the function is called
    fn generateMonotonicId(self: *Ids) u32 {
        const current_id = self._current_id;
        self._current_id += 1;
        return current_id;
    }
};

pub fn findMatchingPictureFormat(formats: []const x.render.PictureFormatInfo, desired_depth: u8) !x.render.PictureFormatInfo {
    for (formats) |format| {
        if (format.depth != desired_depth) continue;
        return format;
    }
    return error.PictureFormatNotFound;
}

pub fn createResources(
    sock: std.os.socket_t,
    buffer: *x.ContiguousReadBuffer,
    ids: *const Ids,
    screen: *align(4) x.Screen,
    extensions: *const x11_extension_utils.Extensions,
    depth: u8,
    window_dimensions: Dimensions,
    screenshot_capture_dimensions: Dimensions,
) !void {
    const reader = common.SocketReader{ .context = sock };
    const buffer_limit = buffer.half_len;

    var arena_allocator = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_allocator.deinit();
    const allocator = arena_allocator.allocator();
    //
    const matching_visual_type = try screen.findMatchingVisualType(
        depth,
        .true_color,
        allocator,
    );
    std.log.debug("matching_visual_type {any}", .{matching_visual_type});

    // We just need some colormap to provide when creating the window in order to avoid
    // a "bad" `match` error when working with a 32-bit depth.
    {
        std.log.debug("Creating colormap {0} 0x{0x}", .{ids.colormap});
        var message_buffer: [x.create_colormap.len]u8 = undefined;
        x.create_colormap.serialize(&message_buffer, .{
            .id = ids.colormap,
            .window_id = ids.root,
            .visual_id = matching_visual_type.id,
            .alloc = .none,
        });
        try common.send(sock, &message_buffer);
    }
    {
        std.log.debug("Creating window_id {0} 0x{0x}", .{ids.window});
        var message_buffer: [x.create_window.max_len]u8 = undefined;
        const len = x.create_window.serialize(&message_buffer, .{
            .window_id = ids.window,
            .parent_window_id = ids.root,
            // Color depth:
            // - 24 for RGB
            // - 32 for ARGB
            .depth = depth,
            // Place it in the top-right corner of the screen
            .x = screen.pixel_width - window_dimensions.width,
            .y = 0,
            .width = window_dimensions.width,
            .height = window_dimensions.height,
            // It's unclear what this is for, but we just need to set it to something
            // since it's one of the arguments.
            .border_width = 0,
            .class = .input_output,
            .visual_id = matching_visual_type.id,
        }, .{
            .bg_pixmap = .none,
            // 0xAARRGGBB
            // Required when `depth` is set to 32
            .bg_pixel = 0xaa006660,
            // .border_pixmap =
            // Required when `depth` is set to 32
            .border_pixel = 0x00000000,
            // Required when `depth` is set to 32
            .colormap = @enumFromInt(ids.colormap),
            // .bit_gravity = .north_west,
            // .win_gravity = .east,
            // .backing_store = .when_mapped,
            // .backing_planes = 0x1234,
            // .backing_pixel = 0xbbeeeeff,
            //
            // Whether this window overrides structure control facilities. Basically, a
            // suggestion whether the window manager to decorate this window (false) or
            // we want to override the behavior. We set this to true to disable the
            // window controls (basically a borderless window).
            .override_redirect = true,
            // .save_under = true,
            .event_mask = x.event.key_press | x.event.key_release | x.event.button_press | x.event.button_release | x.event.enter_window | x.event.leave_window | x.event.pointer_motion | x.event.keymap_state | x.event.exposure,
            // .dont_propagate = 1,
        });
        try common.send(sock, message_buffer[0..len]);
    }

    {
        std.log.info("background_graphics_context_id {0} 0x{0x}", .{ids.bg_gc});
        var message_buffer: [x.create_gc.max_len]u8 = undefined;
        const len = x.create_gc.serialize(&message_buffer, .{
            .gc_id = ids.bg_gc,
            .drawable_id = ids.window,
        }, .{
            .background = 0xff000000,
            .foreground = 0xff0000ff,
            // prevent NoExposure events when we send CopyArea
            .graphics_exposures = false,
        });
        try common.send(sock, message_buffer[0..len]);
    }
    {
        std.log.info("foreground_graphics_context_id {0} 0x{0x}", .{ids.fg_gc});
        var message_buffer: [x.create_gc.max_len]u8 = undefined;
        const len = x.create_gc.serialize(&message_buffer, .{
            .gc_id = ids.fg_gc,
            .drawable_id = ids.window,
        }, .{
            .background = 0xff000000,
            .foreground = 0xffffff00,
            // prevent NoExposure events when we send CopyArea
            .graphics_exposures = false,
        });
        try common.send(sock, message_buffer[0..len]);
    }

    // Create a pixmap drawable to capture the screenshot onto
    {
        var message_buffer: [x.create_pixmap.len]u8 = undefined;
        x.create_pixmap.serialize(&message_buffer, .{
            .id = ids.pixmap,
            .drawable_id = ids.window,
            .depth = depth,
            .width = screenshot_capture_dimensions.width,
            .height = screenshot_capture_dimensions.height,
        });
        try common.send(sock, &message_buffer);
    }

    // Find some compatible picture formats for use with the X Render extension. We want
    // to find a 24-bit depth format for use with the root window and a 32-bit depth
    // format for use with our window.
    {
        var message_buffer: [x.render.query_pict_formats.len]u8 = undefined;
        x.render.query_pict_formats.serialize(&message_buffer, extensions.render.opcode);
        try common.send(sock, &message_buffer);
    }
    const message_length = try x.readOneMsg(reader, @alignCast(buffer.nextReadBuffer()));
    try buffer_utils.checkMessageLengthFitsInBuffer(message_length, buffer_limit);
    const optional_picture_formats_data: ?struct { matching_picture_format_24: x.render.PictureFormatInfo, matching_picture_format_32: x.render.PictureFormatInfo } = blk: {
        switch (x.serverMsgTaggedUnion(@alignCast(buffer.double_buffer_ptr))) {
            .reply => |msg_reply| {
                const msg: *x.render.query_pict_formats.Reply = @ptrCast(msg_reply);
                std.log.info("RENDER extension: pict formats num_formats={}, num_screens={}, num_depths={}, num_visuals={}", .{
                    msg.num_formats,
                    msg.num_screens,
                    msg.num_depths,
                    msg.num_visuals,
                });
                for (msg.getPictureFormats(), 0..) |format, i| {
                    std.log.info("RENDER extension: pict format ({}) {any}", .{
                        i,
                        format,
                    });
                }
                break :blk .{
                    .matching_picture_format_24 = try findMatchingPictureFormat(msg.getPictureFormats()[0..], 24),
                    .matching_picture_format_32 = try findMatchingPictureFormat(msg.getPictureFormats()[0..], 32),
                };
            },
            else => |msg| {
                std.log.err("expected a reply for `x.render.query_pict_formats` but got {}", .{msg});
                return error.ExpectedReplyButGotSomethingElse;
            },
        }
    };
    const picture_formats_data = optional_picture_formats_data orelse @panic("Matching picture formats not found");
    const matching_picture_format = switch (depth) {
        24 => picture_formats_data.matching_picture_format_24,
        32 => picture_formats_data.matching_picture_format_32,
        else => |captured_depth| {
            std.log.err("Matching picture format not found for depth {}", .{captured_depth});
            @panic("Matching picture format not found for depth");
        },
    };

    // We need to create a picture for every drawable that we want to use with the X
    // Render extension
    // =============================================================================
    //
    // Create a picture for the root window that we will use to capture the screenshot from
    {
        var message_buffer: [x.render.create_picture.max_len]u8 = undefined;
        const len = x.render.create_picture.serialize(&message_buffer, extensions.render.opcode, .{
            .picture_id = ids.picture_root,
            .drawable_id = screen.root,
            // The root window is always 24-bit depth
            .format_id = picture_formats_data.matching_picture_format_24.picture_format_id,
            .options = .{
                .subwindow_mode = .include_inferiors,
            },
        });
        try common.send(sock, message_buffer[0..len]);
    }

    // Create a picture for the our window that we can copy and composite things onto
    {
        var message_buffer: [x.render.create_picture.max_len]u8 = undefined;
        const len = x.render.create_picture.serialize(&message_buffer, extensions.render.opcode, .{
            .picture_id = ids.picture_window,
            .drawable_id = ids.window,
            .format_id = matching_picture_format.picture_format_id,
            .options = .{},
        });
        try common.send(sock, message_buffer[0..len]);
    }

    // Create a picture for the pixmap that we store screenshots in
    {
        var message_buffer: [x.render.create_picture.max_len]u8 = undefined;
        const len = x.render.create_picture.serialize(&message_buffer, extensions.render.opcode, .{
            .picture_id = ids.picture_pixmap,
            .drawable_id = ids.pixmap,
            .format_id = matching_picture_format.picture_format_id,
            .options = .{},
        });
        try common.send(sock, message_buffer[0..len]);
    }
}

pub fn cleanupResources(
    sock: std.os.socket_t,
    ids: *const Ids,
) !void {
    {
        var message_buffer: [x.free_pixmap.len]u8 = undefined;
        x.free_pixmap.serialize(&message_buffer, ids.pixmap);
        try common.send(sock, &message_buffer);
    }

    {
        var message_buffer: [x.free_colormap.len]u8 = undefined;
        x.free_colormap.serialize(&message_buffer, ids.colormap);
        try common.send(sock, &message_buffer);
    }

    // TODO: free_gc

    // TODO: x.render.free_picture
}
