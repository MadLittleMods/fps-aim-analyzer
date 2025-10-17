const std = @import("std");
const x = @import("x");
const AppState = @import("app_state.zig").AppState;
const common = @import("../x11/x11_common.zig");
const render_utils = @import("../utils/render_utils.zig");
const BoundingClientRect = render_utils.BoundingClientRect;
const halo_text_vision = @import("../vision/halo_text_vision.zig");
const Screenshot = halo_text_vision.Screenshot;
const ScreenshotRegion = halo_text_vision.ScreenshotRegion;

pub const AsdfContext = struct {
    x_connection: common.XConnection,
    state: *AppState,

    pub fn loop(
        self: *@This(),
    ) void {

        self.state.last_left_click_ts.acquireRead();

        // Capture frames for 200ms (the max input delay we expect) after a
        // left-click. We only want to request another screenshot after the
        // last request finished processing so we do this check in this
        // image reply function.
        const current_ts = std.time.milliTimestamp();
        while (current_ts - state.last_left_click_ts < INPUT_DELAY_MAX_MS) {
            try captureScreenshots(&render_context, state);
        }
    }

    /// Make a new X GetImage request to capture a screenshot of a specific region of
    /// the root screen. Also keep track of the request so we can line it up when the
    /// reply comes in.
    pub fn enqueueGetImageRequest(
        self: *@This(),
        scratch_index: u32,
        /// The crop area from the screen that we requested
        bounding_box: BoundingClientRect(usize),
        /// Region type of the game window that was captured
        screenshot_region: ScreenshotRegion,
        /// Width of the entire game window
        pre_crop_width: usize,
        /// Height of the entire game window
        pre_crop_height: usize,
        /// Resolution width that the game is rendering at
        game_resolution_width: usize,
        /// Resolution height that the game is rendering at
        game_resolution_height: usize,
    ) !void {
        const x_connection = self.x_connection;
        const ids = self.ids.*;

        std.log.debug("enqueueGetImageRequest x={}, y={}, width={}, height={}", .{
            bounding_box.x,
            bounding_box.y,
            bounding_box.width,
            bounding_box.height,
        });

        const request_info = common.GetImageRequestInfo{
            .image_byte_order = TODO,
            .request_ts = std.time.milliTimestamp(),
            .bounding_box = bounding_box,
            .screenshot_region = screenshot_region,
            .pre_crop_width = pre_crop_width,
            .pre_crop_height = pre_crop_height,
            .game_resolution_width = game_resolution_width,
            .game_resolution_height = game_resolution_height,
        };

        {
            var get_image_msg: [x.get_image.len]u8 = undefined;
            x.get_image.serialize(&get_image_msg, .{
                .format = .z_pixmap,
                .drawable_id = ids.root,
                .x = @intCast(bounding_box.x),
                .y = @intCast(bounding_box.y),
                .width = @intCast(bounding_box.width),
                .height = @intCast(bounding_box.height),
                .plane_mask = 0xffffffff,
            });
            try x_connection.send(&get_image_msg);
        }
        const get_image_reply: *x.get_image.Reply = @ptrCast(try x_connection.readOneReply());
        // Convert the X image format to an `RGBImage` we can use in our vision code
        const before_conversion_ts = std.time.milliTimestamp();
        const screenshot = try self.convertXGetImageReplyToRGBImage(
            get_image_reply,
            request_info,
            allocator,
        );
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
    }
};
