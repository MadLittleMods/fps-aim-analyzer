const std = @import("std");
const x = @import("x");
const common = @import("../x11/x11_common.zig");
const x11_extension_utils = @import("../x11/x11_extension_utils.zig");
const AppState = @import("app_state.zig").AppState;
const render_utils = @import("../utils/render_utils.zig");
const image_conversion = @import("../vision/image_conversion.zig");
const RGBImage = image_conversion.RGBImage;

/// Given an unsigned integer type, returns a signed integer type that can hold the
/// entire positive range of the unsigned integer type.
fn GetEncompassingSignedInt(comptime unsigned_T: type) type {
    if (@typeInfo(unsigned_T).Int.signedness == .signed) {
        @panic("This function only makes sense to use with unsigned integer types but you passed in a signed integer.");
    }

    return @Type(.{
        .Int = .{
            .bits = 2 * @typeInfo(unsigned_T).Int.bits,
            .signedness = .signed,
        },
    });
}

/// Stores the IDs of the all of the resources used when communicating with the X Window server.
pub const Ids = struct {
    const Self = @This();

    /// The drawable ID of the root window
    root: u32,
    /// The base resource ID that we can increment from to assign and designate to new
    /// resources.
    base_resource_id: u32,
    /// (not for external use) - Tracks the current incremented ID
    _current_id: u32,

    /// The drawable ID of our window
    window: u32 = 0,
    /// The drawable ID of the pixmap that we store screenshots in
    pixmap: u32 = 0,

    colormap: u32 = 0,
    /// Background graphics context. Defines the
    bg_gc: u32 = 0,
    /// Foreground graphics context
    fg_gc: u32 = 0,
    /// Graphics context to use on our pixmap
    pixmap_gc: u32 = 0,
    // We need to create a "picture" version of every drawable for use with the X Render
    // extension.
    picture_root: u32 = 0,
    picture_window: u32 = 0,
    picture_pixmap: u32 = 0,

    pub fn init(root: u32, base_resource_id: u32) Self {
        var ids = Ids{
            .root = root,
            .base_resource_id = base_resource_id,
            ._current_id = base_resource_id,
        };

        // For any ID that isn't set yet (still has the default value of 0), generate
        // a new ID. This is a lot more fool-proof than trying to set the IDs manually
        // for each new one added.
        inline for (std.meta.fields(@TypeOf(ids))) |field| {
            if (@field(ids, field.name) == 0) {
                @field(ids, field.name) = ids.generateMonotonicId();
            }
        }

        return ids;
    }

    /// Returns an ever-increasing ID everytime the function is called
    fn generateMonotonicId(self: *Ids) u32 {
        const current_id = self._current_id;
        self._current_id += 1;
        return current_id;
    }
};

/// Copy the `rgb_image` data to the pixmap `data_buffer`.
fn copyRgbImageToPixmap(
    rgb_image: RGBImage,
    x_image_format: x.Format,
    image_byte_order: std.builtin.Endian,
    data_buffer: []u8,
) void {
    const bytes_per_pixel = x_image_format.bits_per_pixel / 8;
    const scanline_len = std.mem.alignForward(
        u16,
        @as(u16, @intCast(bytes_per_pixel * rgb_image.width)),
        x_image_format.scanline_pad / 8,
    );

    var row: usize = 0;
    while (row < rgb_image.height) : (row += 1) {
        var data_offset: usize = row * scanline_len;

        var col: usize = 0;
        while (col < rgb_image.width) : (col += 1) {
            const current_pixel_index = (row * rgb_image.width) + col;
            const current_pixel = rgb_image.pixels[current_pixel_index];

            const rgb24_color = current_pixel.toHexNumber();

            switch (x_image_format.depth) {
                16 => std.mem.writeInt(
                    u16,
                    data_buffer[data_offset..][0..2],
                    x.rgb24To16(rgb24_color),
                    image_byte_order,
                ),
                24 => std.mem.writeInt(
                    u24,
                    data_buffer[data_offset..][0..3],
                    rgb24_color,
                    image_byte_order,
                ),
                32 => {
                    // Shift the alpha component all the way up to the top
                    const alpha = 0xff;
                    // 0x000000ff -> 0xff000000
                    const alpha_shifted: u32 = alpha << 24;

                    std.mem.writeInt(
                        u32,
                        data_buffer[data_offset..][0..4],
                        alpha_shifted | rgb24_color,
                        image_byte_order,
                    );
                },
                else => std.debug.panic("TODO: implement image depth {}", .{x_image_format.depth}),
            }
            data_offset += (x_image_format.bits_per_pixel / 8);
        }
    }
}

/// Bootstraps all of the X resources we will need use when rendering the UI.
pub fn createResources(
    sock: std.os.socket_t,
    buffer: *x.ContiguousReadBuffer,
    ids: *const Ids,
    screen: *align(4) x.Screen,
    extensions: *const x11_extension_utils.Extensions(&.{.render}),
    state: *const AppState,
) !void {
    const reader = common.SocketReader{ .context = sock };
    const buffer_limit = buffer.half_len;

    const root_screen_dimensions = state.root_screen_dimensions;
    const window_depth = state.window_depth;
    const pixmap_depth = state.pixmap_depth;
    const num_screenshots = state.num_screenshots;

    var arena_allocator = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_allocator.deinit();
    const allocator = arena_allocator.allocator();
    // We need to find a visual type that matches the depth of our window that we want to create.
    const matching_visual_type = try screen.findMatchingVisualType(
        window_depth,
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
            .depth = window_depth,
            // Place it in the top-right corner of the screen
            .x = 0,
            .y = 0,
            .width = @intCast(root_screen_dimensions.width),
            .height = @intCast(root_screen_dimensions.height),
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
            // .win_gravity = .north_east,
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

    // Create a pixmap drawable to capture the screenshot onto
    {
        var message_buffer: [x.create_pixmap.len]u8 = undefined;
        x.create_pixmap.serialize(&message_buffer, .{
            .id = ids.pixmap,
            .drawable_id = ids.window,
            .depth = pixmap_depth,
            .width = @intCast(root_screen_dimensions.width),
            .height = @intCast(num_screenshots * root_screen_dimensions.height),
        });
        try common.send(sock, &message_buffer);
    }

    {
        const color_black: u32 = 0xff000000;
        const color_blue: u32 = 0xff0000ff;

        std.log.info("background_graphics_context_id {0} 0x{0x}", .{ids.bg_gc});
        var message_buffer: [x.create_gc.max_len]u8 = undefined;
        const len = x.create_gc.serialize(&message_buffer, .{
            .gc_id = ids.bg_gc,
            .drawable_id = ids.window,
        }, .{
            .background = color_black,
            .foreground = color_blue,
            // This option will prevent `NoExposure` events when we send `CopyArea`.
            // We're no longer using `CopyArea` in favor of X Render `Composite` though
            // so this isn't of much use. Still seems applicable to keep around in the
            // spirit of what we want to do.
            .graphics_exposures = false,
        });
        try common.send(sock, message_buffer[0..len]);
    }
    {
        const color_black: u32 = 0xff000000;
        const color_yellow: u32 = 0xffffff00;

        std.log.info("foreground_graphics_context_id {0} 0x{0x}", .{ids.fg_gc});
        var message_buffer: [x.create_gc.max_len]u8 = undefined;
        const len = x.create_gc.serialize(&message_buffer, .{
            .gc_id = ids.fg_gc,
            .drawable_id = ids.window,
        }, .{
            .background = color_black,
            .foreground = color_yellow,
            // This option will prevent `NoExposure` events when we send `CopyArea`.
            // We're no longer using `CopyArea` in favor of X Render `Composite` though
            // so this isn't of much use. Still seems applicable to keep around in the
            // spirit of what we want to do.
            .graphics_exposures = false,
        });
        try common.send(sock, message_buffer[0..len]);
    }
    {
        const color_black: u32 = 0xff000000;
        const color_purple: u32 = 0xffff00ff;

        std.log.info("pixmap_graphics_context_id {0} 0x{0x}", .{ids.pixmap_gc});
        var message_buffer: [x.create_gc.max_len]u8 = undefined;
        const len = x.create_gc.serialize(&message_buffer, .{
            .gc_id = ids.pixmap_gc,
            .drawable_id = ids.pixmap,
        }, .{
            .background = color_black,
            .foreground = color_purple,
            // This option will prevent `NoExposure` events when we send `CopyArea`.
            // We're no longer using `CopyArea` in favor of X Render `Composite` though
            // so this isn't of much use. Still seems applicable to keep around in the
            // spirit of what we want to do.
            .graphics_exposures = false,
        });
        try common.send(sock, message_buffer[0..len]);
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
    try common.checkMessageLengthFitsInBuffer(message_length, buffer_limit);
    const optional_picture_formats_data: ?struct { matching_picture_format_24: x.render.PictureFormatInfo, matching_picture_format_32: x.render.PictureFormatInfo } = blk: {
        switch (x.serverMsgTaggedUnion(@alignCast(buffer.double_buffer_ptr))) {
            .reply => |msg_reply| {
                const msg: *x.render.query_pict_formats.Reply = @ptrCast(msg_reply);
                // std.log.debug("RENDER extension: pict formats num_formats={}, num_screens={}, num_depths={}, num_visuals={}", .{
                //     msg.num_formats,
                //     msg.num_screens,
                //     msg.num_depths,
                //     msg.num_visuals,
                // });
                // for (msg.getPictureFormats(), 0..) |format, i| {
                //     std.log.debug("RENDER extension: pict format ({}) {any}", .{
                //         i,
                //         format,
                //     });
                // }
                break :blk .{
                    .matching_picture_format_24 = try common.findMatchingPictureFormatForDepth(msg.getPictureFormats()[0..], 24),
                    .matching_picture_format_32 = try common.findMatchingPictureFormatForDepth(msg.getPictureFormats()[0..], 32),
                };
            },
            else => |msg| {
                std.log.err("expected a reply for `x.render.query_pict_formats` but got {}", .{msg});
                return error.ExpectedReplyButGotSomethingElse;
            },
        }
    };
    const picture_formats_data = optional_picture_formats_data orelse @panic("Matching picture formats not found");
    const matching_picture_format_for_window = switch (window_depth) {
        24 => picture_formats_data.matching_picture_format_24,
        32 => picture_formats_data.matching_picture_format_32,
        else => |captured_depth| {
            std.log.err("Matching picture format not found for depth {}", .{captured_depth});
            @panic("Matching picture format not found for depth");
        },
    };
    const matching_picture_format_for_pixmap = switch (pixmap_depth) {
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
            .format_id = matching_picture_format_for_window.picture_format_id,
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
            .format_id = matching_picture_format_for_pixmap.picture_format_id,
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

/// Context struct pattern where we can hold some state that we can access in any of the
/// methods. This is useful because we have to call `render()` in many places and we
/// don't want to have to wrangle all of those arguments each time.
pub const RenderContext = struct {
    sock: *const std.os.socket_t,
    ids: *const Ids,
    extensions: *const x11_extension_utils.Extensions(&.{.render}),
    image_byte_order: std.builtin.Endian,
    pixmap_format: x.Format,
    state: *AppState,

    /// Renders the UI to our window.
    pub fn render(self: *const @This()) !void {
        const sock = self.sock.*;
        const ids = self.ids.*;
        const extensions = self.extensions.*;
        const state = self.state.*;

        const root_screen_dimensions = state.root_screen_dimensions;
        const screenshot_index = state.screenshot_index;

        // // Draw a big blue square in the middle of the window
        // {
        //     var msg: [x.poly_fill_rectangle.getLen(1)]u8 = undefined;
        //     x.poly_fill_rectangle.serialize(&msg, .{
        //         .drawable_id = ids.window,
        //         .gc_id = ids.bg_gc,
        //     }, &[_]x.Rectangle{
        //         .{ .x = 100, .y = 100, .width = 200, .height = 200 },
        //     });
        //     try common.send(sock, &msg);
        // }
        // // Make a cut-out in the middle of the blue square
        // {
        //     var msg: [x.clear_area.len]u8 = undefined;
        //     x.clear_area.serialize(&msg, false, ids.window, .{
        //         .x = 150,
        //         .y = 150,
        //         .width = 100,
        //         .height = 100,
        //     });
        //     try common.send(sock, &msg);
        // }

        // Copy the screenshot to our window
        {
            var msg: [x.render.composite.len]u8 = undefined;
            x.render.composite.serialize(&msg, extensions.render.opcode, .{
                .picture_operation = .over,
                .src_picture_id = ids.picture_pixmap,
                .mask_picture_id = 0,
                .dst_picture_id = ids.picture_window,
                .src_x = 0,
                .src_y = @intCast(screenshot_index * root_screen_dimensions.height),
                .mask_x = 0,
                .mask_y = 0,
                .dst_x = 0,
                .dst_y = 0,
                .width = @intCast(root_screen_dimensions.width),
                .height = @intCast(root_screen_dimensions.height),
            });
            try common.send(sock, &msg);
        }
    }

    /// Store an image/screenshot on our pixmap on the X server to use later.
    pub fn copyImageToPixmapAtIndex(self: *@This(), rgb_image: RGBImage, pixmap_index: u8, allocator: std.mem.Allocator) !void {
        const sock = self.sock.*;
        const ids = self.ids.*;
        // const extensions = self.extensions.*;
        const state = self.state.*;
        const pixmap_format = self.pixmap_format;

        const pixmap_depth = state.pixmap_depth;

        {
            const whole_data_len = common.getPutImageDataLenBytes(
                rgb_image.width,
                rgb_image.height,
                self.pixmap_format,
            );
            const whole_request_len = x.put_image.data_offset + std.mem.alignForward(usize, whole_data_len, 4);
            // If the request is too big, we need to split it up into multiple requests
            if (whole_request_len > common.MAX_REQUEST_LENGTH_BYTES) {
                // The minimum number of requests we could send if we could simply split
                // the data into chunks of `MAX_REQUEST_LENGTH_BYTES` bytes. But we
                // can't do that because we need to send rectangles of pixels, not just
                // raw pixels.
                const minimum_num_requests = try std.math.divCeil(
                    usize,
                    whole_data_len,
                    (common.MAX_REQUEST_LENGTH_BYTES - x.put_image.data_offset),
                );
                // We add one to make sure we can floor at any pixel row and still have
                // enough requests to send everything. We assume that one pixel row is
                // below the limit.
                const num_requests = minimum_num_requests + 1;

                const rows_per_request = @divFloor(rgb_image.height, minimum_num_requests);
                for (0..num_requests) |request_index| {
                    const start_pixel_row = request_index * rows_per_request;
                    const end_pixel_row = @min(start_pixel_row + rows_per_request, rgb_image.height);

                    if (start_pixel_row >= rgb_image.height) {
                        break;
                    }

                    const actual_height = end_pixel_row - start_pixel_row;
                    const cropped_rgb_image = RGBImage{
                        .width = rgb_image.width,
                        .height = actual_height,
                        .pixels = rgb_image.pixels[start_pixel_row * rgb_image.width .. end_pixel_row * rgb_image.width],
                    };

                    const data_len = common.getPutImageDataLenBytes(
                        cropped_rgb_image.width,
                        cropped_rgb_image.height,
                        self.pixmap_format,
                    );
                    var put_image_msg = try allocator.alloc(u8, x.put_image.getLen(@intCast(data_len)));
                    defer allocator.free(put_image_msg);
                    copyRgbImageToPixmap(
                        cropped_rgb_image,
                        pixmap_format,
                        self.image_byte_order,
                        put_image_msg[x.put_image.data_offset..],
                    );
                    x.put_image.serializeNoDataCopy(put_image_msg.ptr, @intCast(data_len), .{
                        .format = .z_pixmap,
                        .drawable_id = ids.pixmap,
                        .gc_id = ids.pixmap_gc,
                        .width = @intCast(rgb_image.width),
                        .height = @intCast(actual_height),
                        .x = 0,
                        .y = @intCast(start_pixel_row),
                        // "The left-pad must be zero for ZPixmap format"
                        .left_pad = 0,
                        .depth = pixmap_depth,
                    });
                    try common.send(sock, put_image_msg);
                }
            } else {
                var put_image_msg = try allocator.alloc(u8, whole_request_len);
                defer allocator.free(put_image_msg);
                copyRgbImageToPixmap(
                    rgb_image,
                    pixmap_format,
                    self.image_byte_order,
                    put_image_msg[x.put_image.data_offset..],
                );
                x.put_image.serializeNoDataCopy(put_image_msg.ptr, @intCast(whole_data_len), .{
                    .format = .z_pixmap,
                    .drawable_id = ids.pixmap,
                    .gc_id = ids.pixmap_gc,
                    .width = @intCast(rgb_image.width),
                    .height = @intCast(rgb_image.height),
                    .x = 0,
                    .y = @intCast(pixmap_index * rgb_image.height),
                    // "The left-pad must be zero for ZPixmap format"
                    .left_pad = 0,
                    .depth = pixmap_depth,
                });
                try common.send(sock, put_image_msg);
            }
        }
    }
};
