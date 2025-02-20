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
        const conn = try common.connect(allocator);
        defer std.os.shutdown(conn.sock, .both) catch {};
        defer conn.setup.deinit(allocator);

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

        const ids = render.Ids.init(
            screen.root,
            conn.setup.fixed().resource_id_base,
        );
        std.log.debug("ids: {any}", .{ids});

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

        // Create a big buffer that we can use to read messages and replies from the X server.
        const double_buffer = try x.DoubleBuffer.init(
            std.mem.alignForward(usize, 8000, std.mem.page_size),
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

        // Assemble a map of X extension info
        const extensions = x11_extension_utils.Extensions(&.{ .render, .input }){
            .render = render_extension,
            .input = input_extension,
        };

        try render.createResources(
            conn.sock,
            &buffer,
            &ids,
            screen,
            &extensions,
            depth,
            state,
        );

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
            try conn.send(message_buffer[0..]);
        }

        // Set a custom application ID property that we can use to find the window from
        // our screen_play app in the tests. This is better than just relying on the
        // window name because other applications might be named the same thing and the
        // window name could change during the lifetime of the application.
        {
            // Figure out the atom for our custom application ID property
            const custom_app_id_atom = try common.intern_atom(
                conn.sock,
                &buffer,
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
                try conn.send(message_buffer[0..]);
            }
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
        const font_dims: render_utils.FontDims = blk: {
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

        // Show the window. In the X11 protocol is called mapping a window, and hiding a
        // window is called unmapping. When windows are initially created, they are unmapped
        // (or hidden).
        {
            var msg: [x.map_window.len]u8 = undefined;
            x.map_window.serialize(&msg, ids.window);
            try conn.send(&msg);
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
            try conn.send(msg[0..len]);
        }

        var render_context = render.RenderContext{
            .sock = &conn.sock,
            .ids = &ids,
            .extensions = &extensions,
            .font_dims = &font_dims,
            .state = state,
        };

        while (true) {
            {
                const receive_buffer = buffer.nextReadBuffer();
                if (receive_buffer.len == 0) {
                    std.log.err("buffer size {} not big enough!", .{buffer.half_len});
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
                    .map_notify,
                    .reparent_notify,
                    .configure_notify,
                    => unreachable, // did not register for these
                }
            }
        }

        // Clean-up
        try render.cleanupResources(ids);
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
