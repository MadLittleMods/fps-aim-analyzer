const std = @import("std");
const x = @import("x");
const zigimg = @import("zigimg");
const common = @import("x11/x11_common.zig");
const x11_extension_utils = @import("x11/x11_extension_utils.zig");
const x_render_extension = @import("x11/x_render_extension.zig");
const x_input_extension = @import("x11/x_input_extension.zig");
const x_shape_extension = @import("x11/x_shape_extension.zig");
const render = @import("aim_analyzer/render.zig");
const AppState = @import("aim_analyzer/app_state.zig").AppState;
const render_utils = @import("utils/render_utils.zig");
const Dimensions = render_utils.Dimensions;
const BoundingClientRect = render_utils.BoundingClientRect;
const image_conversion = @import("vision/image_conversion.zig");
const RGBImage = image_conversion.RGBImage;
const math_utils = @import("utils/math_utils.zig");
const absoluteDifference = math_utils.absoluteDifference;
const halo_text_vision = @import("vision/halo_text_vision.zig");
const ScreenshotRegion = halo_text_vision.ScreenshotRegion;
const Screenshot = halo_text_vision.Screenshot;
const futureAmmoHeuristicBoundingClientRect = halo_text_vision.futureAmmoHeuristicBoundingClientRect;
const CharacterRecognition = @import("vision/ocr/character_recognition.zig").CharacterRecognition;
const save_load_utils = @import("vision/ocr/save_load_utils.zig");
const print_utils = @import("./utils/print_utils.zig");
const formatEachItemInSlice = print_utils.formatEachItemInSlice;
const printLabeledImage = print_utils.printLabeledImage;
const child_process_utils = @import("utils/child_process_utils.zig");
const ChildProcessRunner = child_process_utils.ChildProcessRunner;

// We only expect the time between a left-click and the time it would take to see the
// ammo counter go down by 1 to be at max 200ms.
const INPUT_DELAY_MAX_MS = 200;

fn projectSrcPath() []const u8 {
    const file_source_path = std.fs.path.dirname(@src().file) orelse ".";

    return file_source_path;
}

/// Capture a screenshot of the ammo counter to analyze and the reticle at the same time.
fn captureScreenshots(render_context: *render.RenderContext, state: *AppState) !void {
    const scratch_ring_buffer_size = state.scratch_ring_buffer_size;
    const current_scratch_index = state.next_scratch_index;

    // Capture a screenshot of the reticle so if we later determine the ammo counter
    // went down, we have the corresponding view of what you were shooting at.
    try render_context.captureScreenshotToPixmap(current_scratch_index);

    // At the same time, request a screenshot of the ammo counter so we can analyze it
    // locally
    try render_context.enqueueGetImageRequest(
        current_scratch_index,
        state.ammo_counter_bounding_box,
        state.ammo_counter_screenshot_region,
        @intCast(state.root_screen_dimensions.width),
        @intCast(state.root_screen_dimensions.height),
        // FIXME: We assume the game is being rendered 1:1 (100%), so the game
        // resolution is the same as the image resolution
        @intCast(state.root_screen_dimensions.width),
        @intCast(state.root_screen_dimensions.height),
    );

    // Advance the scratch index
    state.next_scratch_index = @rem(current_scratch_index + 1, scratch_ring_buffer_size);
}

const MainProgram = struct {
    state: ?*AppState = null,

    pub fn run_main(self: *@This()) !void {
        // FIXME: Ideally, we probably should be passing in an allocator here. But in
        // order to allow testing, we probably also need cooperative threading and add a
        // way to signal the loop here to stop so everything can be cleaned up to avoid
        // the testing allocator noticing the leaks.
        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        const allocator = gpa.allocator();
        defer switch (gpa.deinit()) {
            .ok => {},
            .leak => std.log.err("GPA allocator: Memory leak detected", .{}),
        };

        try x.wsaStartup();

        // We establish two distinct connections to the X server:
        //
        // 1. Event Connection: Used for reading events in the main event loop.
        //    - Make sure to call `x.change_window_attributes` on the windows you care about
        //      listening for events on. Specify `.event_mask` with the events you want the
        //      event loop to subscribe to.
        // 2. Request Connection: Used for making one-shot requests and reading their replies.
        //
        // This dual-connection approach offers several benefits:
        // - Clear Separation: It keeps event handling separate from one-shot requests.
        // - Simplified Reply Handling: We can easily get replies to one-shot requests
        //   without worrying about them being mixed with event messages.
        // - No Complex Queuing: Unlike the xcb library, we avoid the need for a
        //   cookie-based reply queue system.
        //
        // This design leads to cleaner, more maintainable code by reducing complexity
        // in handling different types of X server interactions.
        //
        // 1. Create an X connection for the event loop
        const x_event_connect_result = try common.connect(allocator);
        defer x_event_connect_result.setup.deinit(allocator);
        const x_event_connection = try common.XConnection.init(
            x_event_connect_result.sock,
            1000,
            allocator,
        );
        defer x_event_connection.deinit();
        // 2. Create an X connection for making one-off requests
        const x_request_connect_result = try common.connect(allocator);
        defer x_request_connect_result.setup.deinit(allocator);
        const x_request_connection = try common.XConnection.init(
            x_request_connect_result.sock,
            8000,
            allocator,
        );
        defer x_request_connection.deinit();

        const conn_setup_fixed_fields = x_event_connect_result.setup.fixed();
        // Print out some info about the X server we connected to
        {
            inline for (@typeInfo(@TypeOf(conn_setup_fixed_fields.*)).Struct.fields) |field| {
                std.log.debug("{s}: {any}", .{ field.name, @field(conn_setup_fixed_fields, field.name) });
            }
            std.log.debug("vendor: {s}", .{try x_event_connect_result.setup.getVendorSlice(conn_setup_fixed_fields.vendor_len)});
        }

        const screen = common.getFirstScreenFromConnectionSetup(x_event_connect_result.setup);
        std.log.info("root window ID {0} 0x{0x}", .{screen.root});
        inline for (@typeInfo(@TypeOf(screen.*)).Struct.fields) |field| {
            std.log.debug("SCREEN 0| {s}: {any}", .{ field.name, @field(screen, field.name) });
        }

        const pixmap_formats = try render.getPixmapFormatsFromConnectionSetup(x_event_connect_result.setup);
        const root_window_pixmap_format = try render.findMatchingPixmapFormatForDepth(
            pixmap_formats,
            screen.root_depth,
        );

        const image_byte_order: std.builtin.Endian = switch (conn_setup_fixed_fields.image_byte_order) {
            .lsb_first => .Little,
            .msb_first => .Big,
            else => |order| {
                std.log.err("unknown image-byte-order {}", .{order});
                return error.UnknownImageByteOrder;
            },
        };

        // We use the X Render extension for capturing screenshots and splatting them onto
        // our window. Useful because their "composite" request works with mismatched depths
        // between the source and destinations.
        const optional_render_extension = try x11_extension_utils.getExtensionInfo(
            x_request_connection,
            "RENDER",
        );
        const render_extension = optional_render_extension orelse @panic("RENDER extension not found");

        // We use the X Input extension to detect clicks on the game window (or whatever
        // window) they happen to be on. Useful because we can detect clicks even when our
        // window is not focused and doesn't have to be directly clicked.
        const optional_input_extension = try x11_extension_utils.getExtensionInfo(
            x_request_connection,
            "XInputExtension",
        );
        const input_extension = optional_input_extension orelse @panic("XInputExtension extension not found");

        // We use the X Shape extension to make the debug window click-through-able. If
        // you're familiar with CSS, we use this to apply `pointer-events: none;`.
        const optional_shape_extension = try x11_extension_utils.getExtensionInfo(
            x_request_connection,
            "SHAPE",
        );
        const shape_extension = optional_shape_extension orelse @panic("SHAPE extension not found");

        // We must run the query_version request of each extension on every connection that
        // interacts with the extension. Most extensions have this behavior in the spec that
        // it will return a "request" error (BadRequest) if haven't negotiated the version
        // of the extension.
        //
        // > The client must negotiate the version of the extension before executing
        // > extension requests.  Behavior of the server is undefined otherwise.
        //
        // > The client must negotiate the version of the extension before executing
        // > extension requests.  Otherwise, the server will return BadRequest for any
        // > operations other than QueryVersion.
        const x_connections = [_]common.XConnection{ x_event_connection, x_request_connection };
        for (x_connections) |x_connection| {
            try x_render_extension.ensureCompatibleVersionOfXRenderExtension(
                x_connection,
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

            try x_input_extension.ensureCompatibleVersionOfXInputExtension(
                x_connection,
                &input_extension,
                .{
                    // We arbitrarily require version 2.3 of the X Input extension
                    // because that's the latest version and is sufficiently old
                    // and ubiquitous.
                    .major_version = 2,
                    .minor_version = 3,
                },
            );

            try x_shape_extension.ensureCompatibleVersionOfXShapeExtension(
                x_connection,
                &shape_extension,
                .{
                    // We arbitrarily require version 1.1 of the X Shape extension
                    // because that's the latest version and is sufficiently old
                    // and ubiquitous.
                    .major_version = 1,
                    .minor_version = 1,
                },
            );
        }

        // Assemble a map of X extension info
        const extensions = x11_extension_utils.Extensions(&.{ .render, .input, .shape }){
            .render = render_extension,
            .input = input_extension,
            .shape = shape_extension,
        };

        // Since each connection has a `base_resource_id`, let's create most resources with
        // the request connection since that's easier
        const ids = render.Ids.init(
            screen.root,
            x_request_connect_result.setup.fixed().resource_id_base,
        );
        std.log.debug("ids: {any}", .{ids});

        // There are a few X extensions that couple creating objects with
        // subscribing/receiving events about those objects. For example, they coupled
        // creating the `x.damage.create` object with tracking the `DamageNotify`
        // events. In these cases, we have to use the event connection to create those
        // objects. This also happens with `create_window` but you can additionally
        // subscribe to events via `change_window_attributes` so there isn't a hard
        // coupling here.
        // var event_connection_id_generator = render.IdGenerator.init(
        //     x_event_connect_result.setup.fixed().resource_id_base,
        // );

        // We're using 32-bit depth so we can use ARGB colors that include alpha/transparency
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
        const ammo_counter_bounding_box_width = screen.pixel_width / 2;
        const ammo_counter_bounding_box_height = screen.pixel_height / 2;
        const ammo_counter_bounding_box = BoundingClientRect(usize){
            .x = screen.pixel_width - ammo_counter_bounding_box_width,
            .y = screen.pixel_height - ammo_counter_bounding_box_height,
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

        // Set the app state
        var state = try allocator.create(AppState);
        self.state = state;
        defer {
            allocator.destroy(state);
            self.state = null;
        }
        state.* = .{
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

        try render.createResources(
            x_request_connection,
            &ids,
            screen,
            &extensions,
            depth,
            state,
            allocator,
        );

        // Set the `_NET_WM_PID` atom so we can later find the window ID by the PID
        for ([_]u32{
            // List any other windows we create from this process
            ids.window,
        }) |window_id| {
            try common.set_window_pid_properties(
                x_request_connection,
                window_id,
            );
        }

        // Set the window name
        {
            const window_name = comptime x.Slice(u16, [*]const u8).initComptime("Aim Analyzer");
            const change_property = x.change_property.withFormat(u8);
            var message_buffer: [change_property.getLen(window_name.len)]u8 = undefined;
            change_property.serialize(&message_buffer, .{
                .mode = .replace,
                .window_id = ids.window,
                .property = x.Atom.WM_NAME,
                .type = x.Atom.STRING,
                .values = window_name,
            });
            try x_request_connection.send(message_buffer[0..]);
        }

        // Set a custom application ID property that we can use to find the window from
        // our screen_play app in the tests. This is better than just relying on the
        // window name because other applications might be named the same thing and the
        // window name could change during the lifetime of the application.
        {
            // Figure out the atom for our custom application ID property
            const custom_app_id_atom = try common.intern_atom(
                x_request_connection,
                comptime x.Slice(u16, [*]const u8).initComptime("madlittlemods.app_id"),
            );

            {
                const window_name = comptime x.Slice(u16, [*]const u8).initComptime("aim_analyzer");
                const change_property = x.change_property.withFormat(u8);
                var message_buffer: [change_property.getLen(window_name.len)]u8 = undefined;
                change_property.serialize(&message_buffer, .{
                    .mode = .replace,
                    .window_id = ids.window,
                    .property = custom_app_id_atom,
                    .type = x.Atom.STRING,
                    .values = window_name,
                });
                try x_request_connection.send(message_buffer[0..]);
            }
        }

        // Register for events from the window
        {
            var message_buffer: [x.change_window_attributes.max_len]u8 = undefined;
            const len = x.change_window_attributes.serialize(&message_buffer, ids.window, .{
                .event_mask = x.event.key_press | x.event.key_release | x.event.button_press | x.event.button_release | x.event.enter_window | x.event.leave_window | x.event.pointer_motion | x.event.keymap_state | x.event.exposure,
            });
            // XXX: Use the event connection so we get the events we subscribed to in the
            // `.event_mask` in the event loop
            try x_event_connection.send(message_buffer[0..len]);
        }
        {
            var message_buffer: [x.change_window_attributes.max_len]u8 = undefined;
            const len = x.change_window_attributes.serialize(&message_buffer, ids.debug_window, .{
                .event_mask = x.event.key_press | x.event.key_release | x.event.button_press | x.event.button_release | x.event.enter_window | x.event.leave_window | x.event.pointer_motion | x.event.keymap_state | x.event.exposure,
            });
            // XXX: Use the event connection so we get the events we subscribed to in the
            // `.event_mask` in the event loop
            try x_event_connection.send(message_buffer[0..len]);
        }

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
            try x_event_connection.send(message_buffer[0..len]);
        }

        // Show the window. In the X11 protocol, this is called mapping a window, and
        // hiding a window is called unmapping. When windows are initially created, they
        // are unmapped (or hidden).
        {
            var msg: [x.map_window.len]u8 = undefined;
            x.map_window.serialize(&msg, ids.window);
            try x_request_connection.send(&msg);
        }
        // Show the debug overlay window
        {
            var msg: [x.map_window.len]u8 = undefined;
            x.map_window.serialize(&msg, ids.debug_window);
            try x_request_connection.send(&msg);
        }

        // Try to make this window always on top (above `screen_play` in the tests). The
        // real magic is the `override_redirect: true` (which would put this on top of
        // everything with a proper window manager) but this is also the proper hint to
        // send in any case.
        //
        // Just trying to make the debug overlay window always on top (above
        // `screen_play` in the tests)
        {
            var msg: [x.configure_window.max_len]u8 = undefined;
            const len = x.configure_window.serialize(&msg, .{
                .window_id = ids.debug_window,
            }, .{
                .stack_mode = .above,
            });
            try x_request_connection.send(msg[0..len]);
        }
        // Make our actual application window above everything else. This works out
        // better in cases where a compositing manager isn't running as the debug window
        // covers the entire screen and will just be a big black screen covering
        // everything including our application window as well. We expect you to be
        // using a compositing manager of some sort (and we even have this setup in
        // tests) but you may run into this by simply running `DISPLAY=:99 zig build
        // run-main` against a Xephyr display without the compositing manager for quick
        // one-off tests).
        {
            var msg: [x.configure_window.max_len]u8 = undefined;
            const len = x.configure_window.serialize(&msg, .{
                .window_id = ids.window,
            }, .{
                .stack_mode = .above,
            });
            try x_request_connection.send(msg[0..len]);
        }

        // Since the debug window covers the whole screen, we want to make it so that
        // mouse events aren't affected by it all. Make it completely
        // click-through-able. If you're familiar with CSS, we use this to apply
        // `pointer-events: none;`.
        {
            const rectangle_list = [_]x.Rectangle{
                .{ .x = 0, .y = 0, .width = 0, .height = 0 },
            };
            var msg: [x.shape.rectangles.getLen(rectangle_list.len)]u8 = undefined;
            x.shape.rectangles.serialize(&msg, shape_extension.opcode, .{
                .destination_window_id = ids.debug_window,
                .destination_kind = .input,
                .operation = .set,
                .x_offset = 0,
                .y_offset = 0,
                .ordering = .unsorted,
                .rectangles = &rectangle_list,
            });
            try x_request_connection.send(&msg);
        }

        // Get some font information
        {
            const text_literal = [_]u16{'m'};
            const text = x.Slice(u16, [*]const u16){ .ptr = &text_literal, .len = text_literal.len };
            var message_buffer: [x.query_text_extents.getLen(text.len)]u8 = undefined;
            x.query_text_extents.serialize(&message_buffer, ids.fg_gc, text);
            try x_request_connection.send(&message_buffer);
        }
        const font_dims: render_utils.FontDims = blk: {
            const message_length = try x.readOneMsg(x_request_connection.reader(), @alignCast(x_request_connection.buffer.nextReadBuffer()));
            try common.checkMessageLengthFitsInBuffer(message_length, x_request_connection.buffer.half_len);
            switch (x.serverMsgTaggedUnion(@alignCast(x_request_connection.buffer.double_buffer_ptr))) {
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
                    return error.ExpecetedReplyForQueryTextExtents;
                },
            }
        };

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
            .x_connection = x_request_connection,
            .ids = &ids,
            .root_screen_depth = screen.root_depth,
            .extensions = &extensions,
            .font_dims = &font_dims,
            .image_byte_order = image_byte_order,
            .root_window_pixmap_format = root_window_pixmap_format,
            .state = state,
            .character_recognition = &character_recognition,
        };

        while (true) {
            {
                const receive_buffer = x_event_connection.buffer.nextReadBuffer();
                if (receive_buffer.len == 0) {
                    std.log.err("buffer size {} not big enough to fit the bytes we received!", .{x_event_connection.buffer.half_len});
                    return error.BufferSizeNotBigEnough;
                }
                const len = try x.readSock(x_event_connection.socket, receive_buffer, 0);
                if (len == 0) {
                    std.log.info("X server connection closed", .{});
                    return;
                }
                x_event_connection.buffer.reserve(len);
            }

            while (true) {
                const data = x_event_connection.buffer.nextReservedBuffer();
                if (data.len < 32)
                    break;
                const msg_len = x.parseMsgLen(data[0..32].*);
                if (data.len < msg_len)
                    break;
                x_event_connection.buffer.release(msg_len);

                //buf.resetIfEmpty();
                switch (x.serverMsgTaggedUnion(@alignCast(data.ptr))) {
                    .err => |msg| {
                        std.log.err("Received X error: {}", .{msg});
                        return error.ReceivedXError;
                    },
                    .reply => |msg| {
                        std.log.err(
                            "Unexpectedly received X reply on the `x_event_connection` (event-loop) " ++
                                "(did you mean to make this request using `x_request_connection`?): {}",
                            .{msg},
                        );
                        return error.UnexpectedXReplyReceivedOnEventConnection;
                    },
                    .generic_extension_event => |msg| {
                        if (msg.ext_opcode == extensions.input.opcode) {
                            switch (x.inputext.genericExtensionEventTaggedUnion(@alignCast(data.ptr))) {
                                .raw_button_press => |extension_message| {
                                    // std.log.info("raw_button_press {}", .{extension_message});
                                    const is_left_click = extension_message.detail == 1;
                                    if (is_left_click) {
                                        // Keep track of the left-click time. We should
                                        // expect the ammo counter to go down in an upcoming
                                        // capture (or at least to see the counter). If not,
                                        // we should reset the capture area and scan the
                                        // whole bottom-right quadrant again for the ammo
                                        // counter as it may have moved.
                                        state.last_left_click_ts = std.time.milliTimestamp();

                                        // If there is not already a request in the queue, get the loop
                                        // started by requesting a screenshot of the ammo counter
                                        if (render_context.get_image_request_queue.readableLength() == 0) {
                                            try captureScreenshots(&render_context, state);
                                        }
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
                    .create_notify,
                    .destroy_notify,
                    .map_notify,
                    .unmap_notify,
                    .reparent_notify,
                    .configure_notify,
                    .gravity_notify,
                    .circulate_notify,
                    // We did not register for these
                    => @panic("Received unexpected event event that we did not register for"),
                }
            }
        }

        // Clean-up
        try render.cleanupResources(x_request_connection, &ids);
    }
};

pub fn main() !void {
    var main_program = MainProgram{};
    try main_program.run_main();
}

test {
    _ = @import("utils/render_utils.zig");
    _ = @import("utils/print_utils.zig");
    _ = @import("vision/vision.zig");
}

// This test is meant to run on a 1920x1080p display. Create a virtual display (via Xvfb
// or Xephyr) and point the tests to that display by setting the `DISPLAY` environment
// variable (`DISPLAY=:99 zig build test`).
//
// FIXME: Ideally, this test should be able to be run standalone without any extra setup
// outside to create right size display. By default, it should just run in a headless
// environment and we'd have `Xvfb` as a dependency we build ourselves to run the tests.
// I hate when projects require you to install extra system dependencies to get things
// working. The only thing you should need is the right version of Zig.
test "end-to-end: click to capture screenshot" {
    const allocator = std.testing.allocator;

    // Ideally, we'd be able to build and run in the same command like `zig build
    // run-screen_play` but https://github.com/ziglang/zig/issues/20853 prevents us from being
    // able to kill the process cleanly. So we have to build and run in separate
    // commands.
    var x_compositing_manager_build_process_runner = try ChildProcessRunner.init(
        "screen_play build",
        &[_][]const u8{ "zig", "build", "x-compositing-manager" },
        allocator,
    );
    defer x_compositing_manager_build_process_runner.deinit();
    try x_compositing_manager_build_process_runner.waitForProcessToExitSuccessfully();

    // Start the X compositing manager process. This is needed for transparent window
    // support; useful for our debug overlay window which is transparent. Normally,
    // you'd get this same functionality for free via your desktop environment's window
    // manager which probably includes a "compositing manager" but virtual display
    // environments like Xvfb and Xephyr do not include a window manager.
    var x_compositing_manager_process_runner = try ChildProcessRunner.init(
        "x-compositing-manager",
        &[_][]const u8{"./zig-out/bin/x-compositing-manager"},
        allocator,
    );
    defer x_compositing_manager_process_runner.deinit();

    // Ideally, we'd be able to build and run in the same command like `zig build
    // run-screen_play` but https://github.com/ziglang/zig/issues/20853 prevents us from being
    // able to kill the process cleanly. So we have to build and run in separate
    // commands.
    var screen_play_build_process_runner = try ChildProcessRunner.init(
        "screen_play build",
        &[_][]const u8{ "zig", "build", "screen_play" },
        allocator,
    );
    defer screen_play_build_process_runner.deinit();
    try screen_play_build_process_runner.waitForProcessToExitSuccessfully();

    // Start the screen_play process. screen_play will start running through a series of
    // keyframes
    var screen_play_process_runner = try ChildProcessRunner.init(
        "screen_play",
        &[_][]const u8{"./zig-out/bin/screen_play"},
        allocator,
    );
    defer screen_play_process_runner.deinit();

    // Run the main aim_analyzer process in a background thread. We use a thread instead
    // of a child process so we can inspect the internal app state.
    var main_program = MainProgram{};
    const main_thread = try std.Thread.spawn(
        .{},
        MainProgram.run_main,
        .{&main_program},
    );
    main_thread.detach();

    // The screen_play process only ends after this call returns. screen_play will exit
    // after showing all keyframes.
    try screen_play_process_runner.waitForProcessToExitSuccessfully();

    // Analyze the state of the main process after we've simulated some game play.
    try std.testing.expect(main_program.state != null);
    try std.testing.expectEqual(main_program.state.?.max_screenshots_shown, 6);
    try std.testing.expectEqual(main_program.state.?.next_interesting_screenshot_index, 4);
}
