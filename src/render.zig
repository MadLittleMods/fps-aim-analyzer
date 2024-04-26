const std = @import("std");
const x = @import("x");
const common = @import("x11/x11_common.zig");
const x11_extension_utils = @import("x11/x11_extension_utils.zig");
const buffer_utils = @import("utils/buffer_utils.zig");
const AppState = @import("app_state.zig").AppState;
const image_conversion = @import("vision/image_conversion.zig");
const RGBImage = image_conversion.RGBImage;
const RGBPixel = image_conversion.RGBPixel;
const halo_text_vision = @import("vision/halo_text_vision.zig");
const Screenshot = halo_text_vision.Screenshot;
const CharacterRecognition = @import("vision/ocr/character_recognition.zig").CharacterRecognition;

/// Given an unsigned integer type, returns a signed integer type that can hold the
/// entire positive range of the unsigned integer type.
fn GetEncompassingSignedInt(comptime unsigned_T: type) type {
    if (@typeInfo(unsigned_T).Int.signedness == .signed) {
        @compileError("This function only makes sense to use with unsigned integer types but you passed in a signed integer.");
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
    colormap: u32 = 0,
    /// Background graphics context. Defines the
    bg_gc: u32 = 0,
    /// Foreground graphics context
    fg_gc: u32 = 0,
    /// The drawable ID of the pixmap that we store screenshots in
    pixmap: u32 = 0,
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

/// Given a list of picture formats, finds the first one that matches the desired depth.
pub fn findMatchingPictureFormatForDepth(
    formats: []const x.render.PictureFormatInfo,
    desired_depth: u8,
) !x.render.PictureFormatInfo {
    for (formats) |format| {
        if (format.depth != desired_depth) continue;
        return format;
    }
    return error.PictureFormatNotFound;
}

pub fn findMatchingPixmapFormatForDepth(
    formats: []const x.Format,
    desired_depth: u8,
) !x.Format {
    for (formats) |format| {
        if (format.depth != desired_depth) continue;
        return format;
    }
    return error.PixmapFormatNotFound;
}

pub fn getFirstScreenFromConnectionSetup(conn_setup: x.ConnectSetup) *x.Screen {
    const fixed = conn_setup.fixed();

    const format_list_offset = x.ConnectSetup.getFormatListOffset(fixed.vendor_len);
    const format_list_limit = x.ConnectSetup.getFormatListLimit(format_list_offset, fixed.format_count);
    const screen_ptr = conn_setup.getFirstScreenPtr(format_list_limit);

    return screen_ptr;
}

pub fn getPixmapFormatsFromConnectionSetup(conn_setup: x.ConnectSetup) ![]const x.Format {
    const fixed = conn_setup.fixed();

    const format_list_offset = x.ConnectSetup.getFormatListOffset(fixed.vendor_len);
    const format_list_limit = x.ConnectSetup.getFormatListLimit(format_list_offset, fixed.format_count);
    const pixmap_formats = try conn_setup.getFormatList(format_list_offset, format_list_limit);

    return pixmap_formats;
}

/// Bootstraps all of the X resources we will need use when rendering the UI.
pub fn createResources(
    sock: std.os.socket_t,
    buffer: *x.ContiguousReadBuffer,
    ids: *const Ids,
    screen: *align(4) x.Screen,
    extensions: *const x11_extension_utils.Extensions,
    depth: u8,
    state: *const AppState,
    base_allocator: std.mem.Allocator,
) !void {
    const reader = common.SocketReader{ .context = sock };
    const buffer_limit = buffer.half_len;

    const root_screen_dimensions = state.root_screen_dimensions;
    const window_dimensions = state.window_dimensions;
    const screenshot_capture_dimensions = state.screenshot_capture_dimensions;
    const max_screenshots_shown = state.max_screenshots_shown;
    const margin = state.margin;

    var arena_allocator = std.heap.ArenaAllocator.init(base_allocator);
    defer arena_allocator.deinit();
    const allocator = arena_allocator.allocator();
    // We need to find a visual type that matches the depth of our window that we want to create.
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
            .x = @intCast(root_screen_dimensions.width - window_dimensions.width - margin),
            .y = @intCast(margin),
            .width = @intCast(window_dimensions.width),
            .height = @intCast(window_dimensions.height),
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

    // Create a pixmap drawable to capture the screenshot onto
    {
        var message_buffer: [x.create_pixmap.len]u8 = undefined;
        x.create_pixmap.serialize(&message_buffer, .{
            .id = ids.pixmap,
            .drawable_id = ids.window,
            .depth = depth,
            .width = @intCast(screenshot_capture_dimensions.width),
            .height = @intCast(max_screenshots_shown * screenshot_capture_dimensions.height),
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
                // std.log.debug("RENDER extension: pict formats num_formats={}, num_screens={}, num_depths={}, num_visuals={}", .{
                //     msg.num_formats,
                //     msg.num_screens,
                //     msg.num_depths,
                //     msg.num_visuals,
                // });
                const picture_formats = msg.getPictureFormats();
                // for (picture_formats, 0..) |format, i| {
                //     std.log.debug("RENDER extension: pict format ({}) {any}", .{
                //         i,
                //         format,
                //     });
                // }
                break :blk .{
                    .matching_picture_format_24 = try findMatchingPictureFormatForDepth(
                        picture_formats[0..],
                        24,
                    ),
                    .matching_picture_format_32 = try findMatchingPictureFormatForDepth(
                        picture_formats[0..],
                        32,
                    ),
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

pub const FontDims = struct {
    width: u8,
    height: u8,
    font_left: i16, // pixels to the left of the text basepoint
    font_ascent: i16, // pixels up from the text basepoint to the top of the text
};

/// Context struct pattern where we can hold some state that we can access in any of the
/// methods. This is useful because we have to call `render()` in many places and we
/// don't want to have to wrangle all of those arguments each time.
pub const RenderContext = struct {
    sock: *const std.os.socket_t,
    ids: *const Ids,
    root_screen_depth: u8,
    extensions: *const x11_extension_utils.Extensions,
    font_dims: *const FontDims,
    image_byte_order: std.builtin.Endian,
    root_window_pixmap_format: x.Format,
    state: *AppState,
    character_recognition: *CharacterRecognition,

    /// Renders the UI to our window.
    pub fn render(self: *const @This()) !void {
        const sock = self.sock.*;
        const ids = self.ids.*;
        const extensions = self.extensions.*;
        const font_dims = self.font_dims.*;
        const state = self.state.*;

        const window_id = ids.window;
        const window_dimensions = state.window_dimensions;
        const screenshot_capture_dimensions = state.screenshot_capture_dimensions;
        const max_screenshots_shown = state.max_screenshots_shown;
        const next_screenshot_index = state.next_screenshot_index;
        const padding = state.padding;
        const mouse_x = state.mouse_x;

        // Draw a big blue square in the middle of the window
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
        // Make a cut-out in the middle of the blue square
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

        // Render some text in the middle of the square cut-out
        const text_length = 11;
        const text_width = font_dims.width * text_length;
        try renderString(
            sock,
            window_id,
            ids.fg_gc,
            @divFloor(window_dimensions.width - text_width, 2) + font_dims.font_left,
            @divFloor(window_dimensions.height - font_dims.height, 2) + font_dims.font_ascent,
            "Hello X! {}",
            .{
                mouse_x,
            },
        );

        // Copy the screenshots to our window
        for (0..max_screenshots_shown) |screen_shot_offset_usize| {
            const UnsignedInt = @TypeOf(max_screenshots_shown);
            const SignedInt = GetEncompassingSignedInt(@TypeOf(max_screenshots_shown));
            const screen_shot_offset = @as(UnsignedInt, @intCast(screen_shot_offset_usize));

            // We need a `SignedInt` during the calculation because we want to be able
            // to go negative and have `@mod(...)` wrap us back around within range.
            //
            // It's safe to cast from `SignedInt` back to `UnsignedInt` because the
            // `@mod(...)` guarantees that the result is no bigger than
            // `max_screenshots_shown` which is what `UnsignedInt` is derived from.
            const screen_shot_index: UnsignedInt = @as(UnsignedInt, @intCast(
                @mod(
                    @as(SignedInt, @intCast(next_screenshot_index)) - @as(SignedInt, @intCast(screen_shot_offset)) - 1,
                    max_screenshots_shown,
                ),
            ));

            var msg: [x.render.composite.len]u8 = undefined;
            x.render.composite.serialize(&msg, extensions.render.opcode, .{
                .picture_operation = .over,
                .src_picture_id = ids.picture_pixmap,
                .mask_picture_id = 0,
                .dst_picture_id = ids.picture_window,
                .src_x = 0,
                .src_y = @intCast(screen_shot_index * screenshot_capture_dimensions.height),
                .mask_x = 0,
                .mask_y = 0,
                .dst_x = padding,
                .dst_y = @intCast((screen_shot_offset * (screenshot_capture_dimensions.height + padding)) + padding),
                .width = @intCast(screenshot_capture_dimensions.width),
                .height = @intCast(screenshot_capture_dimensions.height),
            });
            try common.send(sock, &msg);
        }
    }

    /// Capture a screenshot of the root window (whatever is displayed on the screen)
    /// and store it in our pixmap.
    pub fn captureScreenshotToPixmap(self: *@This()) !void {
        const sock = self.sock.*;
        const ids = self.ids.*;
        const extensions = self.extensions.*;
        const state = self.state.*;

        const root_screen_dimensions = state.root_screen_dimensions;
        const screenshot_capture_dimensions = state.screenshot_capture_dimensions;
        const max_screenshots_shown = state.max_screenshots_shown;
        const next_screenshot_index = state.next_screenshot_index;

        const capture_x = @divFloor(root_screen_dimensions.width, 2) - @divFloor(screenshot_capture_dimensions.width, 2);
        const capture_y = @divFloor(root_screen_dimensions.height, 2) - @divFloor(screenshot_capture_dimensions.height, 2);

        std.log.debug("captureScreenshotToPixmap index={} from x={}, y={}, width={}, height={}", .{
            next_screenshot_index,
            capture_x,
            capture_y,
            screenshot_capture_dimensions.width,
            screenshot_capture_dimensions.height,
        });
        {
            // We use the `x.render.composite` request to copy the root window into our
            // pixmap instead of `x.copy_area` because that requires the depths to match and
            // we're using a 32-bit depth on our window and trying to copy from the 24-bit
            // depth root window.
            var msg: [x.render.composite.len]u8 = undefined;
            x.render.composite.serialize(&msg, extensions.render.opcode, .{
                .picture_operation = .over,
                .src_picture_id = ids.picture_root,
                .mask_picture_id = 0,
                .dst_picture_id = ids.picture_pixmap,
                .src_x = capture_x,
                .src_y = capture_y,
                .mask_x = 0,
                .mask_y = 0,
                .dst_x = 0,
                // We store all captured screenshots in the same `pixmap` in a film
                // strip layout stacked on top of each other. We only keep track of the
                // N most recent screenshots (defined by max_screenshots_shown).
                .dst_y = next_screenshot_index * screenshot_capture_dimensions.height,
                .width = @intCast(screenshot_capture_dimensions.width),
                .height = @intCast(screenshot_capture_dimensions.height),
            });
            try common.send(sock, &msg);
        }

        self.state.next_screenshot_index = @rem(next_screenshot_index + 1, max_screenshots_shown);
    }

    pub fn convertXGetImageReplyToRGBImage(
        self: *@This(),
        get_image_reply: *x.get_image.Reply,
        allocator: std.mem.Allocator,
    ) !RGBImage {
        const image_data = get_image_reply.getData();

        // Cast to an i64 so we can do big math with it (3840x2160 for example) (TODO:
        // figure out better way to do math here)
        const capture_width: i64 = self.state.ammo_counter_bounding_box.width;
        const capture_height: i64 = self.state.ammo_counter_bounding_box.height;
        const bytes_per_pixel_in_data = x.get_image.Reply.scanline_pad_bytes;

        // Given our request for an image with the width/height specified,
        // make sure we got at least the right amount of data back to
        // represent that size of image (there may also be padding at the
        // end).
        const expected_num_bytes = capture_width * capture_height * x.get_image.Reply.scanline_pad_bytes;
        if (image_data.len < expected_num_bytes) {
            std.log.err("Expected at least {} bytes of image data but only got {} bytes", .{
                expected_num_bytes,
                image_data.len,
            });
            return error.ExpectedMoreImageData;
        }

        const rgb_pixels = try allocator.alloc(RGBPixel, @intCast(capture_width * capture_height));
        defer allocator.free(rgb_pixels);
        const rgb_image = RGBImage{
            .width = @intCast(capture_width),
            .height = @intCast(capture_height),
            .pixels = rgb_pixels,
        };

        var x_index: usize = 0;
        var y_index: usize = 0;
        var image_data_index: u32 = 0;
        while ((image_data_index + bytes_per_pixel_in_data) < image_data.len) : (image_data_index += bytes_per_pixel_in_data) {
            if (x_index >= capture_width) {
                // For Debugging: Print a newline after each row
                // std.debug.print("\n", .{});
                x_index = 0;
                y_index += 1;
            }

            //  The image data might have padding on the end so make sure to stop when
            //  we expect the image to end
            if (y_index >= capture_height) {
                break;
            }

            const pixel_index: usize = y_index * @as(usize, @intCast(capture_width)) + x_index;

            const padded_pixel_value = image_data[image_data_index..(image_data_index + bytes_per_pixel_in_data)];
            // Read the raw value into a normal u32 (taking into account the byte order)
            const pixel_value = std.mem.readVarInt(
                u32,
                padded_pixel_value,
                self.image_byte_order,
            );
            // Break down the pixel value into its ARGB components
            //
            // const alpha = @as(u8, @intCast((pixel_value >> 24) & 0xff));
            const red = @as(u8, @intCast((pixel_value >> 16) & 0xff));
            const green = @as(u8, @intCast((pixel_value >> 8) & 0xff));
            const blue = @as(u8, @intCast(pixel_value & 0xff));

            // For Debugging: Print out the pixels
            // std.debug.print("0x{x} ", .{pixel_value});
            rgb_pixels[pixel_index] = RGBPixel{
                .r = @as(f32, @floatFromInt(red)) / 255.0,
                .g = @as(f32, @floatFromInt(green)) / 255.0,
                .b = @as(f32, @floatFromInt(blue)) / 255.0,
            };

            x_index += 1;
        }

        return rgb_image;
    }

    /// Grab the pixels from the window after we've rendered to it using `get_image` and
    /// check that the test image pattern was *actually* drawn to the window.
    pub fn analyzeScreenCapture(
        self: *@This(),
        screenshot: Screenshot(RGBImage),
        allocator: std.mem.Allocator,
    ) !void {
        const opt_asdf = try self.character_recognition.parseAmmoCounterImage(
            screenshot,
            null,
            allocator,
        );
        if (opt_asdf) |asdf| {
            std.log.err("asdf {any}", .{asdf});
        }
    }
};
