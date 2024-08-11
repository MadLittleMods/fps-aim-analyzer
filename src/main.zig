const std = @import("std");
const x = @import("x");
const zigimg = @import("zigimg");
const common = @import("x11/x11_common.zig");
const x11_extension_utils = @import("x11/x11_extension_utils.zig");
const x_render_extension = @import("x11/x_render_extension.zig");
const x_input_extension = @import("x11/x_input_extension.zig");
const x_shape_extension = @import("x11/x_shape_extension.zig");
const render = @import("aim_analyzer/render.zig");
const GetImageRequestInfo = render.GetImageRequestInfo;
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

// We only expect the time between a left-click and the time it would take to see the
// ammo counter go down by 1 to be at max 200ms.
const INPUT_DELAY_MAX_MS = 200;

fn projectSrcPath() []const u8 {
    const file_source_path = std.fs.path.dirname(@src().file) orelse ".";

    return file_source_path;
}

/// Capture a screenshot of the ammo counter tp analyze and the reticle at the same time.
fn captureScreenshots(render_context: *render.RenderContext, state: *AppState) !void {
    const scratch_ring_buffer_size = state.scratch_ring_buffer_size;
    const current_scratch_index = state.next_scratch_index;

    // Request a screenshot of the ammo counter
    try render_context.enqueueGetImageRequest(
        current_scratch_index,
        state.ammo_counter_bounding_box,
        state.ammo_counter_screenshot_region,
        @intCast(state.root_screen_dimensions.width),
        @intCast(state.root_screen_dimensions.height),
        // We assume the game is being rendered 1:1 (100%), so the game
        // resolution is the same as the image resolution
        @intCast(state.root_screen_dimensions.width),
        @intCast(state.root_screen_dimensions.height),
    );
    // Also capture a screenshot of the reticle at the same time
    // so if we determine the ammo counter went down, we have
    // the corresponding view of what you were shooting at.
    try render_context.captureScreenshotToPixmap(current_scratch_index);

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
                return error.UnknownImageByteOrder;
            },
        };

        std.log.info("root window ID {0} 0x{0x}", .{screen.root});
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

        // We use the X Input extension to detect clicks on the game window (or whatever
        // window) they happen to be on. Useful because we can detect clicks even when our
        // window is not focused and doesn't have to be directly clicked.
        const optional_shape_extension = try x11_extension_utils.getExtensionInfo(
            conn.sock,
            &buffer,
            "SHAPE",
        );
        const shape_extension = optional_shape_extension orelse @panic("SHAPE extension not found");

        try x_shape_extension.ensureCompatibleVersionOfXShapeExtension(
            conn.sock,
            &buffer,
            &shape_extension,
            .{
                // We arbitrarily require version 1.1 of the X Shape extension
                // because that's the latest version and is sufficiently old
                // and ubiquitous.
                .major_version = 1,
                .minor_version = 1,
            },
        );

        // Assemble a map of X extension info
        const extensions = x11_extension_utils.Extensions(&.{ .render, .input, .shape }){
            .render = render_extension,
            .input = input_extension,
            .shape = shape_extension,
        };

        try render.createResources(
            conn.sock,
            &buffer,
            &ids,
            screen,
            &extensions,
            depth,
            state,
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
            try common.checkMessageLengthFitsInBuffer(message_length, buffer_limit);
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
                    return error.ExpecetedReplyForQueryTextExtents;
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
        // Show the debug window
        {
            var msg: [x.map_window.len]u8 = undefined;
            x.map_window.serialize(&msg, ids.debug_window);
            try conn.send(&msg);
        }

        // Since the debug window covers the whole screen, we want to make it so that mouse
        // events aren't affected by it all. Make it completely click-through-able.
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
            .state = state,
            .character_recognition = &character_recognition,
            .get_image_request_queue = std.fifo.LinearFifo(GetImageRequestInfo, .{ .Static = 256 }).init(),
        };

        while (true) {
            {
                const receive_buffer = buffer.nextReadBuffer();
                if (receive_buffer.len == 0) {
                    std.log.err("buffer size {} not big enough to fit the bytes we received!", .{
                        buffer.half_len,
                    });
                    return error.BufferSizeNotBigEnough;
                }
                const len = try x.readSock(conn.sock, receive_buffer, 0);
                if (len == 0) {
                    std.log.info("X server connection closed", .{});
                    return;
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
                        return error.ReceivedXError;
                    },
                    .reply => |msg| {
                        // Note: We assume any reply here will be to the `get_image` request
                        // but normally you would want some state machine sequencer to match
                        // up requests with replies.
                        const get_image_reply: *x.get_image.Reply = @ptrCast(msg);

                        // Convert the X image format to an `RGBImage` we can use in our vision code
                        const processed_results = try render_context.processNextGetImageRequest(
                            get_image_reply,
                            allocator,
                        );
                        const scratch_index = processed_results.request_info.scratch_index;
                        const screenshot = processed_results.screenshot;
                        defer screenshot.image.deinit(allocator);

                        // try printLabeledImage("analyzing screenshot", screenshot.image, .kitty, allocator);

                        // Run text detection and OCR on the ammo counter
                        const before_analyze_ts = std.time.milliTimestamp();
                        const opt_ammo_results = try render_context.analyzeScreenCapture(screenshot, allocator);
                        const after_analyze_ts = std.time.milliTimestamp();
                        std.log.debug("Analysis time {}", .{
                            std.fmt.fmtDurationSigned((after_analyze_ts - before_analyze_ts) * std.time.ns_per_ms),
                        });
                        if (opt_ammo_results) |ammo_results| {
                            const confidence_level_string = try formatEachItemInSlice(
                                f64,
                                ammo_results.confidence_levels,
                                "{d:.4}",
                                allocator,
                            );
                            defer allocator.free(confidence_level_string);
                            std.log.debug("ammo_results {d} (confidence {s})", .{
                                ammo_results.ammo_value,
                                confidence_level_string,
                            });

                            const ammo_ui_strip_bounding_box = futureAmmoHeuristicBoundingClientRect(ammo_results.ammo_counter_bounding_box);

                            // Keep track of where we last found the ammo counter so we can
                            // capture a lot less of the screen next time.
                            state.ammo_counter_bounding_box = ammo_ui_strip_bounding_box;
                            state.ammo_counter_screenshot_region = .ammo_ui_strip;
                            std.log.debug("New state.ammo_counter_bounding_box {d}x{d} ({d}, {d})", .{
                                state.ammo_counter_bounding_box.width,
                                state.ammo_counter_bounding_box.height,
                                state.ammo_counter_bounding_box.x,
                                state.ammo_counter_bounding_box.y,
                            });

                            const prev_ammo_value = state.ammo_value;
                            const current_ammo_value = ammo_results.ammo_value;

                            // Keep track of the ammo count
                            state.ammo_value = current_ammo_value;

                            // If the ammo went down by 1 (meaning a bullet was shot), copy
                            // the screenshot from the scratchpad to our list of screenshots
                            // of interest.
                            if (current_ammo_value < prev_ammo_value and (prev_ammo_value - current_ammo_value) == 1) {
                                try render_context.copyScreenshotFromScratchpad(scratch_index);
                                // Re-render the UI to show the new screenshot
                                try render_context.render();
                            }

                            // Draw debug gizmos again
                            try render_context.render();
                        }

                        // Capture frames for 200ms (the max input delay we expect) after a
                        // left-click. We only want to request another screenshot after the
                        // last request finished processing so we do this check in this
                        // image reply function.
                        const current_ts = std.time.milliTimestamp();
                        if (current_ts - state.last_left_click_ts < INPUT_DELAY_MAX_MS) {
                            try captureScreenshots(&render_context, state);
                        }
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

    // Ideally, we'd be able to build in run in the same command like `zig build
    // run-main` but https://github.com/ziglang/zig/issues/20853 prevents us from being
    // able to kill the process cleanly. So we have to build and run in separate
    // commands.
    const build_argv = [_][]const u8{ "zig", "build", "screen_play" };
    var build_process = std.ChildProcess.init(&build_argv, allocator);
    // Prevent writing to `stdout` so the test runner doesn't hang,
    // see https://github.com/ziglang/zig/issues/15091
    build_process.stdin_behavior = .Ignore;
    build_process.stdout_behavior = .Ignore;
    build_process.stderr_behavior = .Ignore;

    try build_process.spawn();
    const build_term = try build_process.wait();
    try std.testing.expectEqual(std.ChildProcess.Term{ .Exited = 0 }, build_term);

    const screen_play_argv = [_][]const u8{"./zig-out/bin/screen_play"};
    var screen_play_process = std.ChildProcess.init(&screen_play_argv, allocator);
    // Prevent writing to `stdout` so the test runner doesn't hang,
    // see https://github.com/ziglang/zig/issues/15091
    screen_play_process.stdin_behavior = .Ignore;
    screen_play_process.stdout_behavior = .Ignore;
    screen_play_process.stderr_behavior = .Ignore;

    // Start the screen_play process. screen_play will start running through a series of
    // keyframes
    try screen_play_process.spawn();

    // Sleep a little bit so the main aim_analyzer process will display on top of the
    // screen_play process. The delay allows the screen_play process to "map_window"
    // before we start the main process.
    //
    // FIXME: It would be better to detect this properly instead of sleeping for an
    // arbitrary amount of time. We could wait to see `map_window` request to the X11
    // server or maybe we could listen for the `map_notify` event, or maybe just have
    // the process emit some ready signal that we can detect.
    std.time.sleep(0.5 * std.time.ns_per_s);

    // Run the main aim_analyzer process in a background thread
    var main_program = MainProgram{};
    const main_thread = try std.Thread.spawn(
        .{},
        MainProgram.run_main,
        .{&main_program},
    );
    main_thread.detach();

    // The screen_play process only ends after this call returns. screen_play will exit
    // after showing all keyframes.
    const screen_play_term = try screen_play_process.wait();
    // Term can be .Exited, .Signal, .Stopped, .Unknown
    try std.testing.expectEqual(std.ChildProcess.Term{ .Exited = 0 }, screen_play_term);

    // Analyze the state of the main process after we've simulated some game play.
    try std.testing.expect(main_program.state != null);
    try std.testing.expectEqual(main_program.state.?.max_screenshots_shown, 6);
    try std.testing.expectEqual(main_program.state.?.next_screenshot_index, 4);
}
