const std = @import("std");
const render_utils = @import("../utils/render_utils.zig");
const BoundingClientRect = render_utils.BoundingClientRect;
const image_conversion = @import("image_conversion.zig");
const HSVPixel = image_conversion.HSVPixel;
const HSVImage = image_conversion.HSVImage;
const RGBImage = image_conversion.RGBImage;
const BinaryImage = image_conversion.BinaryImage;
const cropImage = image_conversion.cropImage;
const maskImage = image_conversion.maskImage;
const resizeImage = image_conversion.resizeImage;
const convertToRgbImage = image_conversion.convertToRgbImage;
const rgbToHsvImage = image_conversion.rgbToHsvImage;
const hsvToRgbImage = image_conversion.hsvToRgbImage;
const hsvToBinaryImage = image_conversion.hsvToBinaryImage;
const checkHsvPixelInRange = image_conversion.checkHsvPixelInRange;
const morphological_operations = @import("morphological_operations.zig");
const getStructuringElement = morphological_operations.getStructuringElement;
const erode = morphological_operations.erode;
const dilate = morphological_operations.dilate;
const contours = @import("contours.zig");
const findContours = contours.findContours;
const traceContoursOnRgbImage = contours.traceContoursOnRgbImage;
const boundingRect = contours.boundingRect;
const print_utils = @import("../utils/print_utils.zig");
const printLabeledImage = print_utils.printLabeledImage;
const decorateStringWithAnsiColor = print_utils.decorateStringWithAnsiColor;

fn absoluteDifference(a: anytype, b: @TypeOf(a)) @TypeOf(a) {
    if (a > b) {
        return a - b;
    } else {
        return b - a;
    }
}

/// Basically representing the stage of cropping the process is at
pub const ScreenshotRegion = enum {
    full_screen,
    /// Cropped bottom-right quadrant of the screen
    bottom_right_quadrant,
    /// Bounding box around the UI in the bottom-right
    bottom_right_ui,
    /// Bounding box specifically around the ammo counter in the bottom-right
    ammo_counter,

    /// Bounding box around the UI in the center of the screen where the reticle is
    center,
};

/// Screenshot of the game (or portion of the game)
pub fn Screenshot(comptime ImageType: type) type {
    return struct {
        image: ImageType,
        /// Region of the game window that was captured
        region: ScreenshotRegion,
        /// Width of the entire game window
        pre_crop_width: usize,
        /// Height of the entire game window
        pre_crop_height: usize,
        /// Resolution width that the game is rendering at
        game_resolution_width: usize,
        /// Resolution height that the game is rendering at
        game_resolution_height: usize,
    };
}

// TODO: There is an optimization here where we could also take in the target coverage
// and stop early if we find a bounding box that meets the coverage requirement. Or flip
// the requirement and say when the target coverage is 90% for example, we could stop
// early if we find 10% dead space first.
fn calculateCoverageInBoundingBox(
    binary_image: BinaryImage,
    bounding_box: BoundingClientRect(usize),
) f32 {
    var active_count: usize = 0;
    for (0..bounding_box.height) |bounding_y| {
        const row_start_pixel_index = (bounding_box.top() + bounding_y) * binary_image.width;
        for (0..bounding_box.width) |bounding_x| {
            const current_pixel_index = row_start_pixel_index + (bounding_box.left() + bounding_x);
            if (binary_image.pixels[current_pixel_index].value) {
                active_count += 1;
            }
        }
    }

    return @as(f32, @floatFromInt(active_count)) / @as(f32, @floatFromInt(bounding_box.width * bounding_box.height));
}

pub const ChromaticAberrationCondition = enum {
    blue,
    cyan,
    yellow,
    red,
};

const PossibleCondition = struct {
    next_unmet_condition: ?ChromaticAberrationCondition,
    num_conditions_left: usize,
};

fn _findNextUnmetCondition(conditions: std.EnumArray(ChromaticAberrationCondition, bool)) PossibleCondition {
    var mutable_conditions_copy = conditions;
    var condition_iterator = mutable_conditions_copy.iterator();
    var index: usize = 0;
    while (condition_iterator.next()) |entry| {
        defer index += 1;
        if (entry.value.*) {
            continue;
        }

        const num_conditions = @typeInfo(ChromaticAberrationCondition).Enum.fields.len;
        return .{
            .next_unmet_condition = entry.key,
            .num_conditions_left = num_conditions - index,
        };
    }

    return .{
        .next_unmet_condition = null,
        .num_conditions_left = 0,
    };
}

pub fn checkForChromaticAberrationConditionInHsvPixel(hsv_pixel: HSVPixel, condition: ChromaticAberrationCondition) bool {
    return switch (condition) {
        .blue => checkHsvPixelInRange(
            hsv_pixel,
            // OpenCV:
            //  - h: [0, 180]
            //  - s: [0, 255]
            //  - v: [0, 255]
            //
            // OpenCV: (90, 34, 190)
            HSVPixel.init(0.5, 0.133333, 0.745098),
            // OpenCV: (152, 255, 255)
            HSVPixel.init(0.844444, 1.0, 1.0),
        ),
        .cyan => checkHsvPixelInRange(
            hsv_pixel,
            // OpenCV: (88, 34, 214)
            HSVPixel.init(0.488888, 0.133333, 0.839215),
            // OpenCV: (136, 255, 255)
            HSVPixel.init(0.755555, 1.0, 1.0),
        ),
        .yellow => checkHsvPixelInRange(
            hsv_pixel,
            // OpenCV: (16, 20, 157)
            HSVPixel.init(0.088888, 0.078843, 0.615686),
            // OpenCV: (56, 195, 255)
            HSVPixel.init(0.311111, 0.764705, 1.0),
        ),
        .red => checkHsvPixelInRange(
            hsv_pixel,
            // OpenCV: (0, 50, 126)
            HSVPixel.init(0.0, 0.196078, 0.494117),
            // OpenCV: (14, 185, 255)
            HSVPixel.init(0.077777, 0.725490, 1.0),
        ) or checkHsvPixelInRange(
            hsv_pixel,
            // OpenCV: (155, 51, 108)
            HSVPixel.init(0.861111, 0.2, 0.423529),
            // OpenCV: (180, 202, 255)
            HSVPixel.init(1.0, 0.792156, 1.0),
        ),
    };
}

/// Checks for a series of blue, cyan, yellow, red pixels in order within a buffer which
/// indicates the chromatic aberration text in Halo.
pub fn checkForChromaticAberrationInPixelBuffer(hsv_pixel_buffer: []const HSVPixel) bool {
    // We want to check to see that the following conditions are met in order
    var conditions = std.EnumArray(ChromaticAberrationCondition, bool).initDefault(false, .{});
    const num_conditions = @typeInfo(ChromaticAberrationCondition).Enum.fields.len;

    // There aren't enough pixel values to meet all of the conditions so we can stop early
    if (hsv_pixel_buffer.len < num_conditions) {
        return false;
    }

    for (hsv_pixel_buffer, 0..) |hsv_pixel, pixel_index| {
        const possible_condition = _findNextUnmetCondition(conditions);
        const optional_next_unmet_condition = possible_condition.next_unmet_condition;
        const num_conditions_left = possible_condition.num_conditions_left;

        // We've met all the conditions (no more conditions) so we can stop early
        if (optional_next_unmet_condition == null) {
            return true;
        }

        // There aren't enough pixel values left to meet all of the conditions so we can
        // stop early
        if (hsv_pixel_buffer.len - pixel_index < num_conditions_left) {
            return false;
        }

        if (optional_next_unmet_condition) |next_unmet_condition| {
            conditions.set(next_unmet_condition, checkForChromaticAberrationConditionInHsvPixel(
                hsv_pixel,
                next_unmet_condition,
            ));
        } else {
            @panic("Programmer error: We should have checked whether `optional_next_unmet_condition` " ++
                "was null before this point and return early because there are no more conditions to meet. " ++
                "This is a bug in the program itself (please report).");
        }
    }

    // Check that all conditions are met after looping through the buffer
    var condition_iterator = conditions.iterator();
    while (condition_iterator.next()) |entry| {
        if (!entry.value.*) {
            return false;
        }
    }

    return true;
}

pub fn findHaloChromaticAberrationText(hsv_image: HSVImage, allocator: std.mem.Allocator) !HSVImage {
    const output_hsv_pixels = try allocator.alloc(HSVPixel, hsv_image.pixels.len);
    errdefer allocator.free(output_hsv_pixels);
    @memset(output_hsv_pixels, HSVPixel{ .h = 0, .s = 0, .v = 0 });

    const total_pixels_in_image = hsv_image.width * hsv_image.height;

    const BUFFER_SIZE: usize = 6;

    // Look for Chromatic Aberration in the rows
    for (0..hsv_image.height) |y| {
        const row_start_pixel_index = y * hsv_image.width;
        const row_end_pixel_index = row_start_pixel_index + hsv_image.width;
        for (0..hsv_image.width) |x| {
            // Look at the next X pixels in the row
            const current_pixel_index = row_start_pixel_index + x;
            // Make sure to not over-run the end of the row
            const buffer_end_pixel_index = @min(current_pixel_index + BUFFER_SIZE, row_end_pixel_index);
            const pixel_buffer = hsv_image.pixels[current_pixel_index..buffer_end_pixel_index];

            // Check if the pixels in the buffer match the chromatic aberration pattern
            const has_chromatic_aberration = checkForChromaticAberrationInPixelBuffer(pixel_buffer);
            if (has_chromatic_aberration) {
                // Copy the pixels that match the chromatic aberration pattern from the buffer into the output
                @memcpy(
                    output_hsv_pixels[current_pixel_index..buffer_end_pixel_index],
                    hsv_image.pixels[current_pixel_index..buffer_end_pixel_index],
                );

                // TODO: There is a slight optimization we could additionally do by
                //       skipping over the pixels that we know are part of the chromatic
                //       aberration pattern. For example, if we find a match at index
                //       10, we know that *at least* the next 4 pixels are exclusively
                //       part of the this pattern. We could even skip to the pixel where
                //       the last condition was met.
            }
        }
    }

    // Look for Chromatic Aberration in the columns
    var column_pixel_buffer = try allocator.alloc(HSVPixel, BUFFER_SIZE);
    defer allocator.free(column_pixel_buffer);
    for (0..hsv_image.width) |x| {
        for (0..hsv_image.height) |y| {
            // Look at the next X pixels in the column
            var column_pixel_buffer_size: usize = 0;
            for (0..BUFFER_SIZE) |i| {
                const current_pixel_index = ((y + i) * hsv_image.width) + x;
                // Make sure to not over-run the end of the column
                if (current_pixel_index >= total_pixels_in_image) {
                    break;
                }
                column_pixel_buffer[i] = hsv_image.pixels[current_pixel_index];
                column_pixel_buffer_size = i + 1;
            }

            const pixel_buffer = column_pixel_buffer[0..column_pixel_buffer_size];

            // Check if the pixels in the buffer match the chromatic aberration pattern
            const has_chromatic_aberration = checkForChromaticAberrationInPixelBuffer(pixel_buffer);
            if (has_chromatic_aberration) {
                // Copy the pixels that match the chromatic aberration pattern from the buffer into the output
                for (0..column_pixel_buffer_size) |i| {
                    const current_pixel_index = ((y + i) * hsv_image.width) + x;
                    output_hsv_pixels[current_pixel_index] = hsv_image.pixels[current_pixel_index];
                }
            }
        }
    }

    return .{
        .width = hsv_image.width,
        .height = hsv_image.height,
        .pixels = output_hsv_pixels,
    };
}

/// Assemble a string showing which chromatic aberration conditions are met for a given pixel
fn _debugStringConditionsForPixel(hsv_pixel: HSVPixel, allocator: std.mem.Allocator) ![]const u8 {
    // Go over each pixel and make a little map showing which conditions are met
    const fields = @typeInfo(ChromaticAberrationCondition).Enum.fields;
    const condition_strings = try allocator.alloc([]const u8, fields.len);
    defer allocator.free(condition_strings);
    inline for (fields, 0..) |field, field_index| {
        const passes_condition = checkForChromaticAberrationConditionInHsvPixel(
            hsv_pixel,
            @field(ChromaticAberrationCondition, field.name),
        );
        condition_strings[field_index] = try decorateStringWithAnsiColor(
            if (passes_condition) "\u{29BF}" else " ",
            switch (@field(ChromaticAberrationCondition, field.name)) {
                .blue => 0x3383ff,
                .cyan => 0x35f5ff,
                .yellow => 0xd9f956,
                .red => 0xf95656,
            },
            null,
            allocator,
        );
    }

    // Combine the condition strings into a single string
    const condition_status_string = try std.mem.join(
        allocator,
        " ",
        condition_strings,
    );
    // After we're done with the condition strings, clean them up
    defer {
        for (condition_strings) |condition_string| {
            allocator.free(condition_string);
        }
    }

    return condition_status_string;
}

const FindHaloChromaticAberrationTextTestCase = struct {
    label: []const u8,
    x: usize,
    y: usize,
    width: usize,
    height: usize,
};

fn _testFindHaloChromaticAberrationText(
    rgb_image: RGBImage,
    test_case: FindHaloChromaticAberrationTextTestCase,
    allocator: std.mem.Allocator,
) !void {
    const cropped_image = try cropImage(
        rgb_image,
        test_case.x,
        test_case.y,
        test_case.width,
        test_case.height,
        allocator,
    );
    defer cropped_image.deinit(allocator);

    const hsv_image = try rgbToHsvImage(cropped_image, allocator);
    defer hsv_image.deinit(allocator);

    // Function under test
    const chromatic_pattern_hsv_img = try findHaloChromaticAberrationText(hsv_image, allocator);
    defer chromatic_pattern_hsv_img.deinit(allocator);

    // Get a binary version of the image so we can quickly check if any chromatic
    // aberration was copied over (`findHaloChromaticAberrationText` only copies
    // over pixels matching the chromatic aberration pattern are copied over)
    const chromatic_pattern_binary_mask = try hsvToBinaryImage(chromatic_pattern_hsv_img, allocator);
    defer chromatic_pattern_binary_mask.deinit(allocator);
    // Check if any chromatic aberration was found and copied over
    var found_chromatic_aberration = false;
    outer: for (0..chromatic_pattern_binary_mask.height) |y| {
        for (0..chromatic_pattern_binary_mask.width) |x| {
            const pixel_index = (y * chromatic_pattern_binary_mask.width) + x;
            const pixel = chromatic_pattern_binary_mask.pixels[pixel_index];
            if (pixel.value) {
                found_chromatic_aberration = true;
                break :outer;
            }
        }
    }

    // Return an error if no chromatic aberration was found and print out useful
    // debugging information
    if (!found_chromatic_aberration) {
        // Print a nice image to give some better context on what failed
        try printLabeledImage(
            test_case.label,
            cropped_image,
            .full_block,
            allocator,
        );

        // Print a list of pixels in the image and which conditions each pixel meets
        for (hsv_image.pixels, 0..) |pixel, pixel_index| {
            const condition_status_string = try _debugStringConditionsForPixel(pixel, allocator);
            defer allocator.free(condition_status_string);

            std.debug.print("\n\t{d: >3}: HSV({d:.6}, {d:.6}, {d:.6}) {s}", .{
                pixel_index,
                pixel.h,
                pixel.s,
                pixel.v,
                condition_status_string,
            });
        }

        return error.UnableToFindChromaticAberration;
    }
}

test "findHaloChromaticAberrationText" {
    const allocator = std.testing.allocator;

    {
        const rgb_image = try RGBImage.loadImageFromFilePath("screenshot-data/halo-infinite/1080/default/36.png", allocator);
        defer rgb_image.deinit(allocator);

        const test_cases = [_]FindHaloChromaticAberrationTextTestCase{
            // (3)6 tests
            // ----------------------------------------------
            .{
                .label = "Top terminal of the three (horizontal)",
                .x = 1424,
                .y = 829,
                .width = 4,
                .height = 1,
            },
            .{
                .label = "Top arm of the three (vertical)",
                .x = 1428,
                .y = 825,
                .width = 1,
                .height = 4,
            },
            .{
                .label = "Top arm of the three with margin above (vertical)",
                .x = 1428,
                .y = 823,
                .width = 1,
                .height = 6,
            },
            .{
                .label = "Top arm of the three with margin below (vertical)",
                .x = 1428,
                .y = 825,
                .width = 1,
                .height = 6,
            },
            .{
                .label = "Top stress of the three (horizonal)",
                .x = 1433,
                .y = 832,
                .width = 8,
                .height = 1,
            },
            .{
                .label = "Middle terminal of the three (vertical)",
                .x = 1430,
                .y = 831,
                .width = 1,
                .height = 8,
            },
            .{
                .label = "Bottom stress of the three (horizonal)",
                .x = 1434,
                .y = 840,
                .width = 6,
                .height = 1,
            },
            .{
                .label = "Bottom arm of the three (vertical)",
                .x = 1430,
                .y = 841,
                .width = 1,
                .height = 6,
            },
            // 3(6) tests
            // ----------------------------------------------
            .{
                .label = "Top terminal of the six (horizontal)",
                .x = 1451,
                .y = 829,
                .width = 6,
                .height = 1,
            },
            .{
                .label = "Top arm of the six (vertical)",
                .x = 1448,
                .y = 825,
                .width = 1,
                .height = 6,
            },
            .{
                .label = "Top stress of the six (horizontal)",
                .x = 1441,
                .y = 829,
                .width = 6,
                .height = 1,
            },
            .{
                .label = "Left-side of the bowl of the six (horizontal)",
                .x = 1442,
                .y = 838,
                .width = 6,
                .height = 1,
            },
            .{
                .label = "Right-side of the bowl of the six (horizontal)",
                .x = 1452,
                .y = 841,
                .width = 6,
                .height = 1,
            },
            .{
                .label = "Top-side of the bowl of the six (vertical)",
                .x = 1448,
                .y = 832,
                .width = 1,
                .height = 6,
            },
            .{
                .label = "Bottom-side of the bowl of the six (vertical)",
                .x = 1448,
                .y = 842,
                .width = 1,
                .height = 6,
            },
        };

        for (test_cases) |test_case| {
            try _testFindHaloChromaticAberrationText(rgb_image, test_case, allocator);
        }
    }

    {
        const rgb_image = try RGBImage.loadImageFromFilePath("screenshot-data/halo-infinite/1080/default/11 - forbidden sidekick.png", allocator);
        defer rgb_image.deinit(allocator);

        const test_cases = [_]FindHaloChromaticAberrationTextTestCase{
            // 1(1) tests
            //
            .{
                .label = "Bottom of second one (horizontal)",
                .x = 1448,
                .y = 899,
                .width = 6,
                .height = 1,
            },
        };

        for (test_cases) |test_case| {
            try _testFindHaloChromaticAberrationText(rgb_image, test_case, allocator);
        }
    }

    {
        const rgb_image = try RGBImage.loadImageFromFilePath("screenshot-data/halo-infinite/1080/default/01 - forbidden skewer.png", allocator);
        defer rgb_image.deinit(allocator);

        const test_cases = [_]FindHaloChromaticAberrationTextTestCase{
            // 0(1) tests
            //
            .{
                .label = "Bottom of second one (horizontal)",
                .x = 1448,
                .y = 899,
                .width = 6,
                .height = 1,
            },
        };

        for (test_cases) |test_case| {
            try _testFindHaloChromaticAberrationText(rgb_image, test_case, allocator);
        }
    }
}

pub const IsolateDiagnostics = struct {
    images: std.StringArrayHashMap(RGBImage),

    pub fn init(allocator: std.mem.Allocator) @This() {
        const images = std.StringArrayHashMap(RGBImage).init(allocator);
        return .{ .images = images };
    }

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        for (self.images.values()) |image| {
            image.deinit(allocator);
        }
        self.images.deinit();
    }

    pub fn addImage(self: *@This(), label: []const u8, image: anytype, allocator: std.mem.Allocator) !void {
        const rgb_image = try convertToRgbImage(image, allocator);
        try self.images.put(label, rgb_image);
    }
};

pub fn resizeScreenshotToDesiredGameResolution(
    screenshot: Screenshot(RGBImage),
    desired_game_resolution_height: f32,
    allocator: std.mem.Allocator,
) !Screenshot(RGBImage) {
    // Scale the window size down (or up) to match the resolution
    const resolution_scale = @as(f32, @floatFromInt(screenshot.pre_crop_height)) / @as(f32, @floatFromInt(screenshot.game_resolution_height));
    // Scale back up (or down) to match our desired resolution
    const window_scale = desired_game_resolution_height / @as(f32, @floatFromInt(screenshot.game_resolution_height));

    const combined_scale = window_scale * resolution_scale;

    const resized_rgb_image = try resizeImage(
        screenshot.image,
        @intFromFloat(
            @as(f32, @floatFromInt(screenshot.image.width)) * combined_scale,
        ),
        @intFromFloat(
            @as(f32, @floatFromInt(screenshot.image.height)) * combined_scale,
        ),
        .box,
        allocator,
    );

    return .{
        .image = resized_rgb_image,
        .region = screenshot.region,
        .pre_crop_width = @intFromFloat(
            @as(f32, @floatFromInt(screenshot.pre_crop_width)) * combined_scale,
        ),
        .pre_crop_height = @intFromFloat(
            @as(f32, @floatFromInt(screenshot.pre_crop_height)) * combined_scale,
        ),
        .game_resolution_width = @intFromFloat(
            @as(f32, @floatFromInt(screenshot.game_resolution_width)) * combined_scale,
        ),
        .game_resolution_height = @intFromFloat(
            @as(f32, @floatFromInt(screenshot.game_resolution_height)) * combined_scale,
        ),
    };
}

/// We only expect 2-3 characters in the ammo counter most of the time. 4 characters
/// seems possible and 5 doesn't seem like it will happen at all.
pub const MAX_NUM_AMMO_CHARACTERS = 5;

/// Given a screenshot of Halo Infinite, isolate the ammo counter region.
pub fn isolateHaloAmmoCounter(
    screenshot: Screenshot(RGBImage),
    diagnostics: ?*IsolateDiagnostics,
    allocator: std.mem.Allocator,
) ![]const RGBImage {
    // Crop the image so we have less to work with.
    // After this step, we will have to deal with 1/4 of the image or less.
    const cropped_screenshot = try switch (screenshot.region) {
        .full_screen => blk: {
            // Crop to the bottom-right quadrant (where the ammo count is)
            const half_width = @divFloor(screenshot.image.width, 2);
            const half_height = @divFloor(screenshot.image.height, 2);
            const cropped_rgb_image = try cropImage(
                screenshot.image,
                half_width,
                half_height,
                screenshot.image.width - half_width,
                screenshot.image.height - half_height,
                allocator,
            );
            break :blk Screenshot(RGBImage){
                .image = cropped_rgb_image,
                .region = .bottom_right_quadrant,
                // We're just cropping so the pre_crop and resolution is still the same
                .pre_crop_width = screenshot.pre_crop_width,
                .pre_crop_height = screenshot.pre_crop_height,
                .game_resolution_width = screenshot.game_resolution_width,
                .game_resolution_height = screenshot.game_resolution_height,
            };
        },
        // No need to do anything if we're already in the bottom-right quadrant or
        // something more specific
        .bottom_right_quadrant, .bottom_right_ui, .ammo_counter => screenshot,
        // Other regions do not contain the ammo counter so it's impossible for us to
        // do anything
        .center => error.ScreenshotRegionDoesNotContainAmmoCounter,
    };
    defer {
        switch (screenshot.region) {
            .full_screen => {
                cropped_screenshot.image.deinit(allocator);
            },
            else => {},
        }
    }
    // Debug: Pixels after cropping
    if (diagnostics) |diag| {
        try diag.addImage("cropped_screenshot", cropped_screenshot.image, allocator);
    }

    // Resize the image to a smaller size so we can work with it faster and have a
    // consistent character size to pass to the OCR
    const DESIRED_GAME_RESOLUTION_HEIGHT: f32 = 1080;
    const resized_screenshot = try resizeScreenshotToDesiredGameResolution(
        cropped_screenshot,
        DESIRED_GAME_RESOLUTION_HEIGHT,
        allocator,
    );
    defer resized_screenshot.image.deinit(allocator);
    // Debug: Pixels after resizing
    if (diagnostics) |diag| {
        try diag.addImage("resized_rgb_image", resized_screenshot.image, allocator);
    }

    const hsv_image = try rgbToHsvImage(resized_screenshot.image, allocator);
    defer hsv_image.deinit(allocator);

    // Find the chromatic aberration text
    const chromatic_pattern_hsv_img = try findHaloChromaticAberrationText(hsv_image, allocator);
    defer chromatic_pattern_hsv_img.deinit(allocator);
    // Debug: Pixels after finding chromatic aberration pattern
    if (diagnostics) |diag| {
        try diag.addImage("chromatic_pattern_hsv_img", chromatic_pattern_hsv_img, allocator);
    }

    // Erode and dilate (open). Erode the mask to get rid of some of the smaller
    // chromatic aberration captures that aren't the text we want. Dilate the mask to
    // connect the text characters.
    const chromatic_pattern_opened_mask = opened_mask: {
        const chromatic_pattern_binary_mask = try hsvToBinaryImage(chromatic_pattern_hsv_img, allocator);
        defer chromatic_pattern_binary_mask.deinit(allocator);

        // Erode the mask to get rid of some of the smaller chromatic aberration captures
        // const erode_kernel = try getStructuringElement(
        //     .cross,
        //     3,
        //     3,
        //     allocator,
        // );
        // defer erode_kernel.deinit(allocator);
        // const chromatic_pattern_eroded_mask = try erode(
        //     chromatic_pattern_binary_mask,
        //     erode_kernel,
        //     allocator,
        // );
        // defer chromatic_pattern_eroded_mask.deinit(allocator);
        // // Debug: After eroding
        // {
        //     const eroded_chromatic_pattern_rgb_image = try maskImage(
        //         resized_screenshot.image,
        //         chromatic_pattern_eroded_mask,
        //         allocator,
        //     );
        //     defer eroded_chromatic_pattern_rgb_image.deinit(allocator);
        //     // Debug: Pixels after eroding
        //     if (diagnostics) |diag| {
        //         try diag.addImage("eroded_chromatic_pattern_rgb_image", eroded_chromatic_pattern_rgb_image, allocator);
        //     }
        // }
        const chromatic_pattern_eroded_mask = chromatic_pattern_binary_mask;

        // Create a horizontal kernel and dilate to connect text characters
        const dilate_kernel = try getStructuringElement(
            .rectangle,
            13,
            13,
            allocator,
        );
        defer dilate_kernel.deinit(allocator);
        const chromatic_pattern_dilated_mask = try dilate(
            chromatic_pattern_eroded_mask,
            dilate_kernel,
            allocator,
        );
        // defer chromatic_pattern_dilated_mask.deinit(allocator);

        break :opened_mask chromatic_pattern_dilated_mask;
    };
    defer chromatic_pattern_opened_mask.deinit(allocator);

    // Find the contours in the opened mask
    const chromatic_contours = try findContours(
        chromatic_pattern_opened_mask,
        .square,
        allocator,
    );
    defer {
        for (chromatic_contours) |contour| {
            allocator.free(contour);
        }
        allocator.free(chromatic_contours);
    }
    // Debug: ...
    if (diagnostics) |diag| {
        // Debug: Pixels after opening (erode/dilate)
        const opened_chromatic_pattern_rgb_image = try maskImage(
            resized_screenshot.image,
            chromatic_pattern_opened_mask,
            allocator,
        );
        defer opened_chromatic_pattern_rgb_image.deinit(allocator);
        try diag.addImage("opened_chromatic_pattern_rgb_image", opened_chromatic_pattern_rgb_image, allocator);

        // Debug: Trace contours
        const traced_rgb_image = try traceContoursOnRgbImage(
            opened_chromatic_pattern_rgb_image,
            chromatic_contours,
            allocator,
        );
        defer traced_rgb_image.deinit(allocator);
        try diag.addImage("contour_traced_rgb_image", traced_rgb_image, allocator);
    }

    // The "1" character is the skinniest character we expect to see in the ammo counter
    // (9px wide). The other digits are 14px wide.
    const CHARACTER_MIN_WIDTH = 9;
    // All of the characters are the same height
    const CHARACTER_MIN_HEIGHT = 21;
    // The max spacing we will see is between "11" characters
    const CHARACTER_MAX_SPACING = 10;
    // The amount of active pixels in the bounding box. Characters should be in big
    // blocks of pixels with lots of coverage. This helps get rid of false-positives
    // found elsewhere in the image.
    const BOUNDING_BOX_COVERAGE = 0.75;

    // Find the bounding boxes around the contours that are big enough to be characters
    var num_ammo_characters: u4 = 0;
    var ammo_digit_bounding_boxes: [MAX_NUM_AMMO_CHARACTERS]BoundingClientRect(usize) = undefined;
    for (chromatic_contours) |contour| {
        const bounding_box = boundingRect(contour);
        // Only consider bounding boxes that are big enough to be characters
        const is_character_sized_bounding_box = bounding_box.width > CHARACTER_MIN_WIDTH and
            bounding_box.height > CHARACTER_MIN_HEIGHT;
        const is_horizontally_close_to_previous_character = num_ammo_characters == 0 or
            absoluteDifference(bounding_box.x, ammo_digit_bounding_boxes[num_ammo_characters - 1].right()) <= CHARACTER_MAX_SPACING;
        const has_enough_coverage = blk: {
            const coverage = calculateCoverageInBoundingBox(chromatic_pattern_opened_mask, bounding_box);
            break :blk coverage > BOUNDING_BOX_COVERAGE;
        };

        std.debug.print("\nis_character_sized_bounding_box={}, width {} > {}, height {} > {} --- " ++
            "is_horizontally_close_to_previous_character={}, {} <= {} --- " ++
            "has_enough_coverage={}, {d:.3} > {d:.3}", .{
            is_character_sized_bounding_box,
            bounding_box.width,
            CHARACTER_MIN_WIDTH,
            bounding_box.height,
            CHARACTER_MIN_HEIGHT,
            is_horizontally_close_to_previous_character,
            if (num_ammo_characters > 0) @as(isize, @intCast(
                absoluteDifference(bounding_box.x, ammo_digit_bounding_boxes[num_ammo_characters - 1].right()),
            )) else -1,
            CHARACTER_MAX_SPACING,
            has_enough_coverage,
            calculateCoverageInBoundingBox(chromatic_pattern_opened_mask, bounding_box),
            BOUNDING_BOX_COVERAGE,
        });
        if (is_character_sized_bounding_box and
            is_horizontally_close_to_previous_character and
            has_enough_coverage)
        {
            ammo_digit_bounding_boxes[num_ammo_characters] = bounding_box;
            num_ammo_characters += 1;

            // Stop after we find the max number of characters we expect
            if (num_ammo_characters >= MAX_NUM_AMMO_CHARACTERS) {
                break;
            }
        }
        // We expect the ammo counter bounding boxes to be consecutive so if we find a
        // bounding box that is too small after we already found some digits, we can
        // stop looking for more
        else if (!is_character_sized_bounding_box and num_ammo_characters > 0) {
            break;
        }
    }

    var ammo_digit_rgb_images = try allocator.alloc(RGBImage, num_ammo_characters);
    for (ammo_digit_bounding_boxes[0..num_ammo_characters], ammo_digit_rgb_images) |bounding_box, *ammo_digit_rgb_image| {
        ammo_digit_rgb_image.* = try cropImage(
            resized_screenshot.image,
            bounding_box.x,
            bounding_box.y,
            bounding_box.width,
            bounding_box.height,
            allocator,
        );
    }

    return ammo_digit_rgb_images;
}

test "Find Halo ammo counter region" {
    const allocator = std.testing.allocator;
    // const image_file_path = "screenshot-data/halo-infinite/1080/default/36 - argyle2.png";
    // const image_file_path = "screenshot-data/halo-infinite/1080/default/11 - forbidden sidekick.png";
    // const image_file_path = "screenshot-data/halo-infinite/1080/default/12 - forbidden sidekick.png";
    // const image_file_path = "screenshot-data/halo-infinite/1080/default/44 - argyle plasma rifle.png";
    // const image_file_path = "screenshot-data/halo-infinite/1080/default/01 - forbidden skewer.png";
    // const image_file_path = "screenshot-data/halo-infinite/1080/default/211 - argyle sentinel beam.png";
    // const image_file_path = "screenshot-data/halo-infinite/1080/default/34.png";
    // const image_file_path = "screenshot-data/halo-infinite/1080/default/36.png";
    // const image_file_path = "screenshot-data/halo-infinite/1080/default/11 - forbidden needler.png";
    const image_file_path = "screenshot-data/halo-infinite/1080/default/09 - argyle sidekick.png";
    // const image_file_path = "screenshot-data/halo-infinite/1080/default/11 - argyle2.png";
    const image_file_stem_name = std.fs.path.stem(image_file_path);

    const rgb_image = try RGBImage.loadImageFromFilePath(image_file_path, allocator);
    defer rgb_image.deinit(allocator);
    const full_screenshot = Screenshot(RGBImage){
        .image = rgb_image,
        .region = .full_screen,
        // Since these are full screen images, the pre_crop_width and
        // pre_crop_height are the same as the width and height
        .pre_crop_width = rgb_image.width,
        .pre_crop_height = rgb_image.height,
        // These are 1:1 screenshots, so the game resolution is the same
        // as the image resolution
        .game_resolution_width = rgb_image.width,
        .game_resolution_height = rgb_image.height,
    };

    // Useful when debugging to only work with a little bit of data
    // const cropped_rgb_image = try cropImage(
    //     rgb_image,
    //     // Hard-coded values for the cropped image ("/home/eric/Downloads/36-1080-export-from-gimp.png")
    //     1410,
    //     877,
    //     40,
    //     26,
    //     allocator,
    // );
    // defer cropped_rgb_image.deinit(allocator);
    // const cropped_screenshot = Screenshot(RGBImage){
    //     .image = cropped_rgb_image,
    //     .region = .ammo_counter,
    //     .pre_crop_width = full_screenshot.pre_crop_width,
    //     .pre_crop_height = full_screenshot.pre_crop_height,
    //     .game_resolution_width = full_screenshot.game_resolution_width,
    //     .game_resolution_height = full_screenshot.game_resolution_height,
    // };

    var isolate_diagnostics = IsolateDiagnostics.init(allocator);
    defer isolate_diagnostics.deinit(allocator);
    const ammo_cropped_digits = try isolateHaloAmmoCounter(
        full_screenshot, //cropped_screenshot,
        &isolate_diagnostics,
        allocator,
    );
    defer {
        for (ammo_cropped_digits) |ammo_cropped_digit| {
            ammo_cropped_digit.deinit(allocator);
        }
        allocator.free(ammo_cropped_digits);
    }

    std.testing.expect(ammo_cropped_digits.len == 9) catch |err| {
        // Debug: Show what happened during the isolation process
        for (isolate_diagnostics.images.keys(), isolate_diagnostics.images.values(), 0..) |label, image, image_index| {
            const debug_file_name = try std.fmt.allocPrint(allocator, "{s} - step{}: {s}.png", .{
                image_file_stem_name,
                image_index,
                label,
            });
            defer allocator.free(debug_file_name);
            const debug_full_file_path = try std.fs.path.join(allocator, &.{
                "debug/test/",
                debug_file_name,
            });
            defer allocator.free(debug_full_file_path);

            try image.saveImageToFilePath(debug_full_file_path, allocator);
            try printLabeledImage(debug_full_file_path, image, .kitty, allocator);
        }

        // Show the ammo counter digits that were found
        for (ammo_cropped_digits, 0..) |ammo_cropped_digit, digit_index| {
            const digit_label = try std.fmt.allocPrint(allocator, "Digit {}", .{digit_index});
            defer allocator.free(digit_label);
            try printLabeledImage(digit_label, ammo_cropped_digit, .half_block, allocator);
        }

        return err;
    };
}
