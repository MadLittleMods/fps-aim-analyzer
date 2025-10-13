const std = @import("std");
const x = @import("x");
const common = @import("x11/x11_common.zig");
const x11_extension_utils = @import("x11/x11_extension_utils.zig");
const x_render_extension = @import("x11/x_render_extension.zig");
const x_input_extension = @import("x11/x_input_extension.zig");
const render_utils = @import("utils/render_utils.zig");
const render = @import("aim_analyzer/render.zig");
const AppState = @import("aim_analyzer/app_state.zig").AppState;

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
        inline for (@typeInfo(@TypeOf(screen.*)).Struct.fields) |field| {
            std.log.debug("SCREEN 0| {s}: {any}", .{ field.name, @field(screen, field.name) });
        }
        std.log.info("root window ID {0} 0x{0x}", .{screen.root});

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
        }

        // Assemble a map of X extension info
        const extensions = x11_extension_utils.Extensions(&.{ .render, .input }){
            .render = render_extension,
            .input = input_extension,
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

        const root_screen_dimensions = render_utils.Dimensions{
            .width = @intCast(screen.pixel_width),
            .height = @intCast(screen.pixel_height),
        };

        const screenshot_capture_scale = 20;
        const screenshot_capture_dimensions = render_utils.Dimensions{
            .width = @intCast(@divTrunc(screen.pixel_width, screenshot_capture_scale)),
            .height = @intCast(@divTrunc(screen.pixel_height, screenshot_capture_scale)),
        };

        const max_screenshots_shown = 6;
        const margin = 20;
        const padding = 10;
        const window_dimensions = render_utils.Dimensions{
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

        // Show the window. In the X11 protocol is called mapping a window, and hiding a
        // window is called unmapping. When windows are initially created, they are unmapped
        // (or hidden).
        {
            var msg: [x.map_window.len]u8 = undefined;
            x.map_window.serialize(&msg, ids.window);
            try x_request_connection.send(&msg);
        }

        // Try to make this window always on top (above `screen_play` in the tests). The
        // real magic is the `override_redirect: false` (which would put this on top of
        // everything with a proper window manager) but this is also the proper hint to
        // send in any case.
        {
            var msg: [x.configure_window.max_len]u8 = undefined;
            const len = x.configure_window.serialize(&msg, .{
                .window_id = ids.window,
            }, .{
                .stack_mode = .above,
            });
            try x_request_connection.send(msg[0..len]);
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

        var render_context = render.RenderContext{
            .x_connection = x_request_connection,
            .ids = &ids,
            .extensions = &extensions,
            .font_dims = &font_dims,
            .state = state,
        };

        while (true) {
            {
                const receive_buffer = x_event_connection.buffer.nextReadBuffer();
                if (receive_buffer.len == 0) {
                    std.log.err("buffer size {} not big enough!", .{x_event_connection.buffer.half_len});
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
                        std.log.info("todo: handle a reply message {}", .{msg});
                        return error.TodoHandleReplyMessage;
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
                                else => unreachable, // We did not register for these events so we should not see them
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
                        std.log.info("todo: server msg {}", .{msg});
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
                    => unreachable, // did not register for these
                }
            }
        }

        // Clean-up
        try render.cleanupResources(x_request_connection, ids);
    }
};

pub fn main() !void {
    var main_program = MainProgram{};
    try main_program.run_main();
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

    // FIXME: Without a "compositing manager", the window will not show up as
    // transparent. We could make a basic one from scratch using the X `COMPOSITE`
    // extension. See https://magcius.github.io/xplain/article/composite.html for a
    // breakdown on how compositing works. Normally, you'd get this same functionality
    // for free via your desktop environment's window manager which probably includes a
    // "compositing manager".

    // Ideally, we'd be able to build and run in the same command like `zig build
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
    const screen_play_term = try screen_play_process.wait();
    // Term can be .Exited, .Signal, .Stopped, .Unknown
    try std.testing.expectEqual(std.ChildProcess.Term{ .Exited = 0 }, screen_play_term);

    // Analyze the state of the main process after we've simulated some game play.
    try std.testing.expect(main_program.state != null);
    try std.testing.expectEqual(main_program.state.?.max_screenshots_shown, 6);
    try std.testing.expectEqual(main_program.state.?.next_screenshot_index, 4);
}
