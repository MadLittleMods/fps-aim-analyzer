const std = @import("std");
const assertions = @import("../utils/assertions.zig");
const assert = assertions.assert;
const comptime_assert = assertions.comptime_assert;
const render_utils = @import("../utils/render_utils.zig");
const Coordinate = render_utils.Coordinate;
const BoundingClientRect = render_utils.BoundingClientRect;
const findIntersection = render_utils.findIntersection;
const image_conversion = @import("image_conversion.zig");
const HSVPixel = image_conversion.HSVPixel;
const HSVImage = image_conversion.HSVImage;
const RGBImage = image_conversion.RGBImage;
const RGBPixel = image_conversion.RGBPixel;
const BinaryImage = image_conversion.BinaryImage;
const BinaryPixel = image_conversion.BinaryPixel;
const cropImage = image_conversion.cropImage;
const maskImage = image_conversion.maskImage;
const resizeImage = image_conversion.resizeImage;
const convertToRgbImage = image_conversion.convertToRgbImage;
const rgbToHsvImage = image_conversion.rgbToHsvImage;
const hsvToRgbImage = image_conversion.hsvToRgbImage;
const hsvToBinaryImage = image_conversion.hsvToBinaryImage;
const checkHsvPixelInRange = image_conversion.checkHsvPixelInRange;
const draw_utils = @import("../utils/draw_utils.zig");
const drawRectangleOnImage = draw_utils.drawRectangleOnImage;
const drawEllipseOnImage = draw_utils.drawEllipseOnImage;
const drawCrossOnImage = draw_utils.drawCrossOnImage;
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
    /// Bounding box around the entire row where the ammo counter resides alongside the
    /// total ammo count and weapon icon. Useful because the ammo counter switches
    /// around depending on the weapon.
    ammo_ui_strip,
    /// Bounding box specifically around the ammo counter in the bottom-right
    ammo_counter,

    /// Bounding box around the UI in the center of the screen where the reticle is
    center,
};

/// Screenshot of the game (or portion of the game)
pub fn Screenshot(comptime ImageType: type) type {
    return struct {
        image: ImageType,
        /// Region type of the game window that was captured
        crop_region: ScreenshotRegion,
        /// The x location of the region in the entire game window
        crop_region_x: usize,
        /// The y location of the region in the entire game window
        crop_region_y: usize,
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

pub const HSVBounds = struct {
    lower: HSVPixel,
    upper: HSVPixel,
};

pub const ChromaticAberrationCondition = enum {
    blue,
    cyan,
    yellow,
    red,
};

pub const ChromaticAberrationConditionToBoundsMap = std.EnumArray(ChromaticAberrationCondition, []const HSVBounds).init(.{
    .blue = &[_]HSVBounds{ .{
        .lower = HSVPixel.init(0.5, 0.31, 0.745098),
        .upper = HSVPixel.init(0.844444, 1.0, 1.0),
    }, .{
        .lower = HSVPixel.init(0.57, 0.3, 0.49),
        .upper = HSVPixel.init(0.66, 0.9, 0.745098),
    } },
    .cyan = &[_]HSVBounds{.{
        .lower = HSVPixel.init(0.472, 0.133333, 0.775),
        .upper = HSVPixel.init(0.755555, 1.0, 1.0),
    }},
    .yellow = &[_]HSVBounds{ .{
        .lower = HSVPixel.init(0.1, 0.078843, 0.5),
        .upper = HSVPixel.init(0.3975, 0.835, 1.0),
    }, .{
        .lower = HSVPixel.init(0.311111, 0.078843, 0.75),
        .upper = HSVPixel.init(0.438, 0.3, 1.0),
    } },
    .red = &[_]HSVBounds{ .{
        .lower = HSVPixel.init(0.0, 0.196078, 0.275),
        .upper = HSVPixel.init(0.11, 0.835, 1.0),
    }, .{
        .lower = HSVPixel.init(0.777, 0.196078, 0.275),
        .upper = HSVPixel.init(1.0, 0.835, 1.0),
    } },
});

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

pub fn checkForChromaticAberrationConditionInHsvPixel(
    hsv_pixel: HSVPixel,
    condition: ChromaticAberrationCondition,
) bool {
    for (ChromaticAberrationConditionToBoundsMap.get(condition)) |bounds| {
        if (checkHsvPixelInRange(
            hsv_pixel,
            bounds.lower,
            bounds.upper,
        )) {
            return true;
        }
    }

    return false;
}

pub const PatternSearchResult = struct {
    found_pattern: bool,
    start_index: usize,
    end_index: usize,
};

/// Checks for a series of blue, cyan, yellow, red pixels in order within a buffer which
/// indicates the chromatic aberration text in Halo.
pub fn checkForChromaticAberrationInPixelBuffer(hsv_pixel_buffer: []const HSVPixel) PatternSearchResult {
    // We want to check to see that the following conditions are met in order
    var conditions = std.EnumArray(ChromaticAberrationCondition, bool).initDefault(false, .{});
    const num_conditions = @typeInfo(ChromaticAberrationCondition).Enum.fields.len;

    var start_pattern_pixel_index: usize = 0;
    var end_pattern_pixel_index: usize = 0;

    // There aren't enough pixel values to meet all of the conditions so we can stop early
    if (hsv_pixel_buffer.len < num_conditions) {
        return .{
            .found_pattern = false,
            .start_index = start_pattern_pixel_index,
            .end_index = end_pattern_pixel_index,
        };
    }

    for (hsv_pixel_buffer, 0..) |hsv_pixel, pixel_index| {
        const possible_condition = _findNextUnmetCondition(conditions);
        const optional_next_unmet_condition = possible_condition.next_unmet_condition;
        const num_conditions_left = possible_condition.num_conditions_left;
        const is_first_condition = num_conditions_left == num_conditions;

        // We've met all the conditions (no more conditions) so we can stop early
        if (optional_next_unmet_condition == null) {
            return .{
                .found_pattern = true,
                .start_index = start_pattern_pixel_index,
                .end_index = end_pattern_pixel_index,
            };
        }

        // There aren't enough pixel values left to meet all of the conditions so we can
        // stop early
        if (hsv_pixel_buffer.len - pixel_index < num_conditions_left) {
            return .{
                .found_pattern = false,
                .start_index = start_pattern_pixel_index,
                .end_index = end_pattern_pixel_index,
            };
        }

        if (optional_next_unmet_condition) |next_unmet_condition| {
            const found_condition = checkForChromaticAberrationConditionInHsvPixel(
                hsv_pixel,
                next_unmet_condition,
            );
            conditions.set(next_unmet_condition, found_condition);

            // Keep track where the pattern starts and ends in the buffer
            if (found_condition and is_first_condition) {
                start_pattern_pixel_index = pixel_index;
            }
            end_pattern_pixel_index = pixel_index;
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
            return .{
                .found_pattern = false,
                .start_index = start_pattern_pixel_index,
                .end_index = end_pattern_pixel_index,
            };
        }
    }

    return .{
        .found_pattern = true,
        .start_index = start_pattern_pixel_index,
        .end_index = end_pattern_pixel_index,
    };
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

        var x: usize = 0;
        while (x < hsv_image.width) {
            // Look at the next X pixels in the row
            const current_pixel_index = row_start_pixel_index + x;
            // Make sure to not over-run the end of the row
            const buffer_end_pixel_index = @min(current_pixel_index + BUFFER_SIZE, row_end_pixel_index);
            const pixel_buffer = hsv_image.pixels[current_pixel_index..buffer_end_pixel_index];

            // Check if the pixels in the buffer match the chromatic aberration pattern
            const chromatic_aberration_buffer_results = checkForChromaticAberrationInPixelBuffer(pixel_buffer);
            if (chromatic_aberration_buffer_results.found_pattern) {
                // Copy the pixels that match the chromatic aberration pattern from the buffer into the output
                const start_index = current_pixel_index + chromatic_aberration_buffer_results.start_index;
                const end_index = current_pixel_index + chromatic_aberration_buffer_results.end_index + 1;
                @memcpy(
                    output_hsv_pixels[start_index..end_index],
                    hsv_image.pixels[start_index..end_index],
                );

                // This is a slight optimization we do by skipping over the pixels that
                // we know are part of the chromatic aberration pattern. For example, if
                // we find a match at index 10, we know that *at least* the next 4
                // pixels are exclusively part of the this pattern. We even skip to the
                // pixel where the last condition was met.
                const pattern_length = end_index - start_index;
                x += pattern_length;
            } else {
                x += 1;
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
            const chromatic_aberration_buffer_results = checkForChromaticAberrationInPixelBuffer(pixel_buffer);
            if (chromatic_aberration_buffer_results.found_pattern) {
                // Copy the pixels that match the chromatic aberration pattern from the buffer into the output
                const start = chromatic_aberration_buffer_results.start_index;
                const end = chromatic_aberration_buffer_results.end_index + 1;
                for (start..end) |i| {
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
        for (self.images.keys()) |key_string| {
            allocator.free(key_string);
        }
        for (self.images.values()) |image| {
            image.deinit(allocator);
        }
        self.images.deinit();
    }

    pub fn addImage(self: *@This(), label: []const u8, image: anytype, allocator: std.mem.Allocator) !void {
        // We make a copy of things so the caller can free the memory they pass in and
        // the downstream user can use the diagnostics without worrying about anything.
        const label_copy = try allocator.alloc(u8, label.len);
        @memcpy(label_copy, label);

        // (making a copy)
        const rgb_image = try convertToRgbImage(image, allocator);

        try self.images.put(label_copy, rgb_image);
    }
};

pub fn translateCoordinateToAnotherScreenshotSpace(
    source_x: usize,
    source_y: usize,
    source_screenshot: Screenshot(RGBImage),
    target_screenshot: Screenshot(RGBImage),
) Coordinate(usize) {
    const desired_game_resolution_height = @as(f32, @floatFromInt(target_screenshot.game_resolution_height));

    // Scale back up (or down) to match our desired target resolution
    const resolution_scale = desired_game_resolution_height /
        @as(f32, @floatFromInt(source_screenshot.game_resolution_height));
    const window_scale = @as(f32, @floatFromInt(target_screenshot.pre_crop_height)) /
        @as(f32, @floatFromInt(source_screenshot.pre_crop_height));

    const combined_scale = window_scale * resolution_scale;

    return .{
        .x = @intFromFloat(
            @as(f32, @floatFromInt(source_x)) * combined_scale,
        ),
        .y = @intFromFloat(
            @as(f32, @floatFromInt(source_y)) * combined_scale,
        ),
    };
}

pub fn translateBoundingClientRectToAnotherScreenshotSpace(
    rect: anytype,
    source_screenshot: Screenshot(RGBImage),
    target_screenshot: Screenshot(RGBImage),
) @TypeOf(rect) {
    const top_left = translateCoordinateToAnotherScreenshotSpace(
        rect.left(),
        rect.top(),
        source_screenshot,
        target_screenshot,
    );
    const bottom_right = translateCoordinateToAnotherScreenshotSpace(
        rect.right(),
        rect.bottom(),
        source_screenshot,
        target_screenshot,
    );

    return .{
        .x = top_left.x,
        .y = top_left.y,
        .width = bottom_right.x - top_left.x,
        .height = bottom_right.y - top_left.y,
    };
}

test "translateCoordinateToAnotherScreenshotSpace and resizeScreenshotToDesiredGameResolution" {
    const allocator = std.testing.allocator;

    const test_image = RGBImage{
        .width = 2560,
        .height = 1440,
        .pixels = &([1]RGBPixel{
            .{ .r = 0.0, .g = 0.0, .b = 0.0 },
        } ** (2560 * 1440)),
    };

    // The game is geing rendered at 1080p but the window is sized at 1440p
    const test_screenshot = Screenshot(RGBImage){
        .image = test_image,
        .crop_region = .full_screen,
        .crop_region_x = 0,
        .crop_region_y = 0,
        .pre_crop_width = test_image.width,
        .pre_crop_height = test_image.height,
        .game_resolution_width = 1920,
        .game_resolution_height = 1080,
    };

    // Normalize the image to 720p
    const normalized_screenshot = try resizeScreenshotToDesiredGameResolution(
        test_screenshot,
        720,
        allocator,
    );
    defer normalized_screenshot.image.deinit(allocator);

    // Translate from our normalized screenshot back out to our original screenshot screenspcae
    const translated_coord = translateCoordinateToAnotherScreenshotSpace(
        640,
        360,
        normalized_screenshot,
        test_screenshot,
    );

    try std.testing.expectEqual(Coordinate(usize){ .x = 1280, .y = 720 }, translated_coord);
}

pub fn resizeScreenshotToDesiredGameResolution(
    screenshot: Screenshot(RGBImage),
    desired_game_resolution_height: f32,
    allocator: std.mem.Allocator,
) !Screenshot(RGBImage) {
    // Scale the window size down (or up) to match the resolution
    const resolution_scale = @as(f32, @floatFromInt(screenshot.game_resolution_height)) /
        @as(f32, @floatFromInt(screenshot.pre_crop_height));
    // Scale back up (or down) to match our desired resolution
    const window_scale = desired_game_resolution_height /
        @as(f32, @floatFromInt(screenshot.game_resolution_height));

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
        .crop_region = screenshot.crop_region,
        .crop_region_x = @intFromFloat(
            @as(f32, @floatFromInt(screenshot.crop_region_x)) * combined_scale,
        ),
        .crop_region_y = @intFromFloat(
            @as(f32, @floatFromInt(screenshot.crop_region_y)) * combined_scale,
        ),
        .pre_crop_width = @intFromFloat(
            @as(f32, @floatFromInt(screenshot.pre_crop_width)) * combined_scale,
        ),
        .pre_crop_height = @intFromFloat(
            @as(f32, @floatFromInt(screenshot.pre_crop_height)) * combined_scale,
        ),
        // No matter what size the window is, the game is still rendering at the same
        // resolution.
        .game_resolution_width = screenshot.game_resolution_width,
        .game_resolution_height = screenshot.game_resolution_height,
    };
}

/// Crop image to at least the bottom-right quadrant of the screen (where the ammo
/// counter is) and resize to a consistent 1080 height so the UI size is consistent.
pub fn normalizeHaloScreenshot(
    screenshot: Screenshot(RGBImage),
    diagnostics: ?*IsolateDiagnostics,
    allocator: std.mem.Allocator,
) !Screenshot(RGBImage) {
    // Crop the image so we have less to work with.
    // After this step, we will have to deal with 1/4 of the image or less.
    const cropped_screenshot = try switch (screenshot.crop_region) {
        .full_screen => blk: {
            // Crop to the bottom-right quadrant (where the ammo count is)
            const half_width = @divFloor(screenshot.image.width, 2);
            const half_height = @divFloor(screenshot.image.height, 2);
            const crop_x = half_width;
            const crop_y = half_height;
            const cropped_rgb_image = try cropImage(
                screenshot.image,
                crop_x,
                crop_y,
                screenshot.image.width - half_width,
                screenshot.image.height - half_height,
                allocator,
            );
            break :blk Screenshot(RGBImage){
                .image = cropped_rgb_image,
                .crop_region = .bottom_right_quadrant,
                .crop_region_x = crop_x,
                .crop_region_y = crop_y,
                // We're just cropping so the pre_crop and resolution is still the same
                .pre_crop_width = screenshot.pre_crop_width,
                .pre_crop_height = screenshot.pre_crop_height,
                .game_resolution_width = screenshot.game_resolution_width,
                .game_resolution_height = screenshot.game_resolution_height,
            };
        },
        // No need to do anything if we're already in the bottom-right quadrant or
        // something more specific
        .bottom_right_quadrant, .bottom_right_ui, .ammo_ui_strip, .ammo_counter => screenshot,
        // Other regions do not contain the ammo counter so it's impossible for us to
        // do anything
        .center => error.ScreenshotRegionDoesNotContainAmmoCounter,
    };
    defer {
        switch (screenshot.crop_region) {
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

    // Resize the image to a smaller size so we can have a consistent character size to
    // pass to the OCR. (and if we end up downsizing, less pixels again to deal with)
    const resized_screenshot = try resizeScreenshotToDesiredGameResolution(
        cropped_screenshot,
        DESIRED_GAME_RESOLUTION_HEIGHT,
        allocator,
    );
    // defer resized_screenshot.image.deinit(allocator);

    // Debug: Pixels after resizing
    if (diagnostics) |diag| {
        try diag.addImage("resized_rgb_image", resized_screenshot.image, allocator);
    }

    return resized_screenshot;
}

/// The target normalized resolution we want to work with in all of our detection methods
/// (for consistent UI character size)
const DESIRED_GAME_RESOLUTION_HEIGHT: f32 = 1080;
/// The minimum resolution the game needs to be rendered at to have enough detail for
/// our detection methods to work.
const MIN_GAME_RESOLUTION_HEIGHT: f32 = 720;
/// The ammo counter is 0-padded to two characters ("01", "03", "00", etc)
pub const MIN_NUM_AMMO_CHARACTERS = 2;
/// We only expect 2-3 characters in the ammo counter most of the time. 4 characters
/// seems possible and 5 doesn't seem like it will happen at all.
pub const MAX_NUM_AMMO_CHARACTERS = 5;
/// The "1" character (9px wide) is the skinniest character we expect to see in the
/// ammo counter. The other digits are 14px wide. (at 1080p resolution)
const CHARACTER_MIN_WIDTH = 9;
// "4" character seems to be the widest (18px wide) (at 1080p resolution)
const CHARACTER_MAX_WIDTH = 18;
// All of the characters are the same height (21px tall) (at 1080p resolution)
const CHARACTER_MIN_HEIGHT = 22;
/// The max spacing we will see is between "11" characters.
/// Characters are centered in their position. (at 1080p resolution)
const CHARACTER_MAX_SPACING = 10;
/// The min spacing we will see is between "44" (at 1080p resolution)
const CHARACTER_MIN_SPACING = 1;
/// The amount of active pixels in the bounding box. Characters should be in big
/// blocks of pixels with lots of coverage. This helps get rid of false-positives
/// found elsewhere in the image.
const BOUNDING_BOX_COVERAGE = 0.75;
/// We find the average point of all of the chromatic abberation UI being displayed and
/// only consider bounding boxes that are within this specified proximity to the
/// midpoint.
const MIDPOINT_PROXIMITY_X = 250;
const MIDPOINT_PROXIMITY_Y = 75;

/// Should be big enough to connect ammo characters together
const CHARACTER_DILATE_WIDTH: usize = 19;
/// Should be big enough to connect various pieces of detected chromatic aberration from a character together vertically
const CHARACTER_DILATE_HEIGHT: usize = 13;
comptime {
    const dilate_width_min_size = (2 * @divTrunc(CHARACTER_MAX_SPACING, 2)) + 1;
    comptime_assert(
        CHARACTER_DILATE_WIDTH > dilate_width_min_size,
        "Dilate width size is too small and we will probably have problems connecting characters together. " ++
            "Characters can be spaced {}px apart. Since the dilate kernel is centered around a given pixel it will only " ++
            "extend out by half of the kernel width in each direction. So the dilate kernel should be at least {}px wide " ++
            "(or bigger since pixels aren't perfect after resizing and our detection isn't perfect) (also needs to be odd).",
        .{ CHARACTER_MAX_SPACING, dilate_width_min_size },
    );
}

/// Given a screenshot of Halo Infinite, isolate the ammo counter region.
pub fn isolateHaloAmmoCounter(
    // Screenshot must be normalized to make the UI size equivalent to 1080p.
    // In order for the detection ot work correclty.
    screenshot: Screenshot(RGBImage),
    diagnostics: ?*IsolateDiagnostics,
    allocator: std.mem.Allocator,
) !?Screenshot(RGBImage) {
    assert(
        screenshot.game_resolution_height > MIN_GAME_RESOLUTION_HEIGHT,
        "The screenshot must be rendered >= {d}p resolution to have enough detail for us to parse" ++
            "(game resolution: {d}x{d})",
        .{
            MIN_GAME_RESOLUTION_HEIGHT,
            screenshot.game_resolution_width,
            screenshot.game_resolution_height,
        },
    );
    assert(
        screenshot.pre_crop_height == DESIRED_GAME_RESOLUTION_HEIGHT,
        "The screenshot must be scaled so the UI is equivalent to {d}p resolution but saw {d}p " ++
            "(you probably need to use `normalizeHaloScreenshot`)" ++
            "(pre-crop resolution: {d}x{d}) (game resolution: {d}x{d}) (image crop: {s} {d}x{d}) (image resolution: {d}x{d})",
        .{
            DESIRED_GAME_RESOLUTION_HEIGHT,
            screenshot.pre_crop_height,
            screenshot.pre_crop_width,
            screenshot.pre_crop_height,
            screenshot.game_resolution_width,
            screenshot.game_resolution_height,
            @tagName(screenshot.crop_region),
            screenshot.crop_region_x,
            screenshot.crop_region_y,
            screenshot.image.width,
            screenshot.image.height,
        },
    );

    const hsv_image = try rgbToHsvImage(screenshot.image, allocator);
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
        //         screenshot.image,
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
        //
        // Tricky connecting examples:
        // - `screenshot-data/halo-infinite/4k/default/11 - streets2.png`
        // - `screenshot-data/halo-infinite/4k/default/18 - streets burger.png`
        //
        // TODO: Create the kernel once outside of the function
        const dilate_kernel = blk: {
            const rectangle_pixels = try allocator.alloc(BinaryPixel, CHARACTER_DILATE_WIDTH * CHARACTER_DILATE_HEIGHT);
            @memset(rectangle_pixels, BinaryPixel{ .value = true });

            // Bias the kernel to the right by turning off the pixels on the left-side.
            // This way we can connect characters together without accidentally
            // connecting other things we didn't mean to on the other side.
            const kernel_pixels = rectangle_pixels;
            for (0..5) |x| {
                for (0..CHARACTER_DILATE_HEIGHT) |y| {
                    const pixel_index = (y * CHARACTER_DILATE_WIDTH) + x;
                    kernel_pixels[pixel_index] = .{ .value = false };
                }
            }
            // Only a single line jutting out from the left-side of the kernel
            // const center_y = CHARACTER_DILATE_HEIGHT / 2;
            // const start_pixel_index = (center_y * CHARACTER_DILATE_WIDTH) + 0;
            // @memset(kernel_pixels[start_pixel_index..(start_pixel_index + 5)], .{ .value = true });

            break :blk BinaryImage{
                .width = CHARACTER_DILATE_WIDTH,
                .height = CHARACTER_DILATE_HEIGHT,
                .pixels = kernel_pixels,
            };
        };
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
    var traced_rgb_image: RGBImage = undefined;
    defer {
        if (diagnostics) |_| {
            traced_rgb_image.deinit(allocator);
        }
    }
    if (diagnostics) |diag| {
        // Debug: Pixels after opening (erode/dilate)
        const opened_chromatic_pattern_rgb_image = try maskImage(
            screenshot.image,
            chromatic_pattern_opened_mask,
            allocator,
        );
        defer opened_chromatic_pattern_rgb_image.deinit(allocator);
        try diag.addImage("opened_chromatic_pattern_rgb_image", opened_chromatic_pattern_rgb_image, allocator);

        // Debug: Trace contours
        traced_rgb_image = try traceContoursOnRgbImage(
            opened_chromatic_pattern_rgb_image,
            chromatic_contours,
            allocator,
        );
        errdefer traced_rgb_image.deinit(allocator);
        try diag.addImage("contour_traced_rgb_image", traced_rgb_image, allocator);
    }

    // Calculate the bounding boxes and the total area of all of the bounding boxes
    const bounding_boxes = try allocator.alloc(BoundingClientRect(usize), chromatic_contours.len);
    var total_bound_box_area: usize = 0.0;
    for (chromatic_contours, 0..) |contour, contour_index| {
        const bounding_box = boundingRect(contour);
        bounding_boxes[contour_index] = bounding_box;

        total_bound_box_area += bounding_box.width * bounding_box.height;
    }

    // Weighted average of the bounding box centers, weighted by the area of the bounding box
    //
    // We use the midpoint as a heuristic that the ammo counter should be within a
    // certain range of it.
    var total_x: usize = 0.0;
    var total_y: usize = 0.0;
    for (bounding_boxes) |bounding_box| {
        const center_x = bounding_box.centerX();
        const center_y = bounding_box.centerY();

        const area = bounding_box.width * bounding_box.height;
        const weight = area;

        total_x += center_x * weight;
        total_y += center_y * weight;
    }
    const midpoint_x = total_x / total_bound_box_area;
    const midpoint_y = total_y / total_bound_box_area;
    // Create a bounding box around the midpoint to use as a heuristic to find the ammo counter
    const midpoint_proximity_bounding_box = BoundingClientRect(usize){
        .x = midpoint_x - MIDPOINT_PROXIMITY_X,
        .y = midpoint_y - MIDPOINT_PROXIMITY_Y,
        .width = (MIDPOINT_PROXIMITY_X * 2) + 1,
        .height = (MIDPOINT_PROXIMITY_Y * 2) + 1,
    };
    // Debug: ...
    if (diagnostics) |diag| {
        const circle_marked_image = try drawEllipseOnImage(
            traced_rgb_image,
            11,
            11,
            1,
            RGBPixel{ .r = 1.0, .g = 0.0, .b = 0.0 },
            midpoint_x,
            midpoint_y,
            .center,
            .center,
            allocator,
        );
        defer circle_marked_image.deinit(allocator);

        const cross_marked_image = try drawCrossOnImage(
            circle_marked_image,
            11,
            11,
            RGBPixel{ .r = 1.0, .g = 0.0, .b = 0.0 },
            midpoint_x,
            midpoint_y,
            .center,
            .center,
            allocator,
        );
        defer cross_marked_image.deinit(allocator);

        const rectangle_boundary_image = try drawRectangleOnImage(
            cross_marked_image,
            midpoint_proximity_bounding_box.width,
            midpoint_proximity_bounding_box.height,
            2,
            RGBPixel{ .r = 1.0, .g = 0.0, .b = 0.0 },
            midpoint_proximity_bounding_box.left(),
            midpoint_proximity_bounding_box.top(),
            .left,
            .top,
            allocator,
        );
        defer rectangle_boundary_image.deinit(allocator);

        try diag.addImage("midpoint_boundary", rectangle_boundary_image, allocator);
    }

    // Find the bounding box around the contours that is big enough to be one or more characters.
    //
    // We assume the list of contours is already sorted with the bottom-left most
    // contours first (this is how `findContours` works right now so no need to sort).
    var ammo_counter_bounding_box = blk_bounding_box: {
        for (bounding_boxes) |bounding_box| {
            // Only consider bounding boxes that are big enough to be characters.
            //
            // We look for 2x characters because the ammo is always padded with a zero
            // up to two characters.
            //
            // TODO: We might also want to add the dilation padding to these expected measurements.
            const is_character_sized_bounding_box = bounding_box.width > (2 * CHARACTER_MAX_WIDTH) and
                bounding_box.height > CHARACTER_MIN_HEIGHT;
            if (!is_character_sized_bounding_box) {
                continue;
            }

            // We assume that characters we're looking for have a lot of chromatic
            // aberration as opposed errant false-positives which may have large
            // bounding boxes but very little coverage inside.
            const has_enough_coverage = blk: {
                const coverage = calculateCoverageInBoundingBox(chromatic_pattern_opened_mask, bounding_box);
                break :blk coverage > BOUNDING_BOX_COVERAGE;
            };
            if (!has_enough_coverage) {
                continue;
            }

            // Make sure the bounding box is within the proximity of the midpoint of the
            // rest of the chromatic abberation that we detected. This way we can avoid
            // false-positives like the text from picking up equipment which is also
            // appears on the left (ex. `screenshot-data/halo-infinite/4k/default/36 - breaker turbine goo.png`)
            const intersection = findIntersection(bounding_box, midpoint_proximity_bounding_box);
            if (intersection == null) {
                continue;
            }

            break :blk_bounding_box bounding_box;
        } else {
            // None of the contours matched our criteria
            return null;
        }
    };

    const ammo_cropped_image = try cropImage(
        screenshot.image,
        ammo_counter_bounding_box.x,
        ammo_counter_bounding_box.y,
        ammo_counter_bounding_box.width,
        ammo_counter_bounding_box.height,
        allocator,
    );

    return Screenshot(RGBImage){
        .image = ammo_cropped_image,
        .crop_region = .ammo_counter,
        .crop_region_x = ammo_counter_bounding_box.x,
        .crop_region_y = ammo_counter_bounding_box.y,
        .pre_crop_width = screenshot.pre_crop_width,
        .pre_crop_height = screenshot.pre_crop_height,
        .game_resolution_width = screenshot.game_resolution_width,
        .game_resolution_height = screenshot.game_resolution_height,
    };
}

pub const Boundary = struct {
    start_index: usize,
    end_index: usize,
};

pub fn splitAmmoCounterRegionIntoDigits(
    screenshot: Screenshot(RGBImage),
    diagnostics: ?*IsolateDiagnostics,
    allocator: std.mem.Allocator,
) ![]const RGBImage {
    const hsv_image = try rgbToHsvImage(screenshot.image, allocator);
    defer hsv_image.deinit(allocator);

    // Find the chromatic aberration text
    const chromatic_pattern_hsv_img = try findHaloChromaticAberrationText(hsv_image, allocator);
    defer chromatic_pattern_hsv_img.deinit(allocator);
    // Debug: Pixels after finding chromatic aberration pattern
    if (diagnostics) |diag| {
        try diag.addImage("digits_chromatic_pattern_hsv_img", chromatic_pattern_hsv_img, allocator);
    }

    // Scan each column of the image where each digit starts and ends horizontally
    var number_of_boundaries: usize = 0;
    var character_boundary_accumulator: [MAX_NUM_AMMO_CHARACTERS]Boundary = undefined;
    // Track whether we're currently in the middle of a character
    var in_character = false;
    // Track the last column/x position we found an active pixel in the character
    var last_x_in_character: usize = 0;
    const ALLOWED_GAP = 1;
    for (0..chromatic_pattern_hsv_img.width) |x| {
        const is_column_active = column_blk: for (0..chromatic_pattern_hsv_img.height) |y| {
            const pixel_index = (y * chromatic_pattern_hsv_img.width) + x;
            const pixel = chromatic_pattern_hsv_img.pixels[pixel_index];
            const is_pixel_active = pixel.h > 0.0 or pixel.s > 0.0 or pixel.v > 0.0;
            if (is_pixel_active) {
                break :column_blk is_pixel_active;
            }
        } else {
            break :column_blk false;
        };

        if (is_column_active) {
            if (!in_character) {
                // Find how big the previous boundary is
                const previous_boundary_index: usize = blk: {
                    if (number_of_boundaries > 0) {
                        break :blk number_of_boundaries - 1;
                    }
                    break :blk 0;
                };
                const previous_boundary_found_width = (character_boundary_accumulator[previous_boundary_index].end_index - character_boundary_accumulator[previous_boundary_index].start_index) + 1;

                // If the gap is small enough and the width is still less than the max
                // width we expect a character to be, then we can go back and extend the
                // previous boundary. (ex. `screenshot-data/halo-infinite/4k/default/100
                // - dredge hammer2.png`)
                if (previous_boundary_found_width < CHARACTER_MAX_WIDTH and x - last_x_in_character <= (ALLOWED_GAP + 1)) {
                    // Go back to the previous boundary and extend it
                    if (number_of_boundaries > 0) {
                        number_of_boundaries -= 1;
                    }
                    character_boundary_accumulator[number_of_boundaries].end_index = x;
                }
                // Otherwise, start a new boundary
                else {
                    character_boundary_accumulator[number_of_boundaries].start_index = x;
                }

                in_character = true;
            }
        } else {
            // Smear over any small gaps in the characters by making sure we have
            // enough width to be the smallest character we expect.
            //
            // This also helps only pick up things that are big enough to be characters
            if (in_character) {
                const previous_active_x = x - 1;
                const found_width = (previous_active_x - character_boundary_accumulator[number_of_boundaries].start_index) + 1;
                if (found_width >= CHARACTER_MIN_WIDTH) {
                    character_boundary_accumulator[number_of_boundaries].end_index = previous_active_x;
                    in_character = false;
                    number_of_boundaries += 1;
                }

                last_x_in_character = previous_active_x;
            }
        }
    }

    // Debug: Pixels after finding chromatic aberration pattern
    if (diagnostics) |diag| {
        const copy_pixels = try allocator.alloc(HSVPixel, chromatic_pattern_hsv_img.pixels.len);
        std.mem.copyForwards(HSVPixel, copy_pixels, chromatic_pattern_hsv_img.pixels);

        for (0..number_of_boundaries) |boundary_index| {
            const start_index = character_boundary_accumulator[boundary_index].start_index;
            const end_index = character_boundary_accumulator[boundary_index].end_index;

            const first_row_index = 0;
            const top_start_pixel_index = (first_row_index * chromatic_pattern_hsv_img.width) + start_index;
            const top_end_pixel_index = (first_row_index * chromatic_pattern_hsv_img.width) + end_index;

            const last_row_index = chromatic_pattern_hsv_img.height - 1;
            const bottom_start_pixel_index = (last_row_index * chromatic_pattern_hsv_img.width) + start_index;
            const bottom_end_pixel_index = (last_row_index * chromatic_pattern_hsv_img.width) + end_index;

            copy_pixels[top_start_pixel_index] = .{ .h = 0.3333, .s = 1.0, .v = 1.0 };
            copy_pixels[bottom_start_pixel_index] = .{ .h = 0.3333, .s = 1.0, .v = 1.0 };

            copy_pixels[top_end_pixel_index] = .{ .h = 0.0, .s = 1.0, .v = 1.0 };
            copy_pixels[bottom_end_pixel_index] = .{ .h = 0.0, .s = 1.0, .v = 1.0 };
        }

        const marked_hsv_image = HSVImage{
            .width = chromatic_pattern_hsv_img.width,
            .height = chromatic_pattern_hsv_img.height,
            .pixels = copy_pixels,
        };
        defer marked_hsv_image.deinit(allocator);

        try diag.addImage("digits_chromatic_pattern_with_boundaries", marked_hsv_image, allocator);
    }

    // Sanity check that we found enough characters
    if (number_of_boundaries < MIN_NUM_AMMO_CHARACTERS) {
        std.log.err("Unable to detect enough characters in ammo counter. Found {d} characters but we expect at least {d}", .{
            number_of_boundaries,
            MIN_NUM_AMMO_CHARACTERS,
        });
        return error.NotAbleToDetectEnoughCharactersInAmmoCounter;
    }

    const ammo_cropped_digits = try allocator.alloc(RGBImage, number_of_boundaries);
    var num_digits_allocated: usize = 0;
    errdefer {
        for (0..num_digits_allocated) |boundary_index| {
            ammo_cropped_digits[boundary_index].deinit(allocator);
        }
        allocator.free(ammo_cropped_digits);
    }

    const capture_width = CHARACTER_MAX_WIDTH + 8;
    const capture_height = CHARACTER_MIN_HEIGHT + 6;

    for (0..number_of_boundaries) |boundary_index| {
        const found_start_x_index = character_boundary_accumulator[boundary_index].start_index;
        const found_width = (character_boundary_accumulator[boundary_index].end_index - character_boundary_accumulator[boundary_index].start_index) + 1;

        if (found_width < CHARACTER_MIN_WIDTH) {
            std.log.err("Found character width {d}px should be >= {d}px.", .{
                found_width,
                CHARACTER_MIN_WIDTH,
            });
            return error.DetectedCharacterWidthTooSmall;
        }

        if (found_width > capture_width) {
            std.log.err("Found character width {d}px should be <= {d}px.", .{
                found_width,
                CHARACTER_MAX_WIDTH,
            });
            return error.DetectedCharacterWidthTooBig;
        }

        const screenshot_box = BoundingClientRect(isize){
            .x = 0,
            .y = 0,
            .width = @as(isize, @intCast(screenshot.image.width)),
            .height = @as(isize, @intCast(screenshot.image.height)),
        };
        const capture_box = BoundingClientRect(isize){
            .x = @as(isize, @intCast(found_start_x_index)) - @divTrunc(@as(isize, @intCast(capture_width - found_width)), 2),
            .y = @divTrunc(@as(isize, @intCast(screenshot.image.height)) - @as(isize, @intCast(capture_height)), 2),
            .width = @as(isize, @intCast(capture_width)),
            .height = @as(isize, @intCast(capture_height)),
        };
        const maybe_overlap_box = findIntersection(screenshot_box, capture_box);

        if (maybe_overlap_box) |actual_capture_box| {
            ammo_cropped_digits[boundary_index] = try cropImage(
                screenshot.image,
                @as(usize, @intCast(actual_capture_box.x)),
                @as(usize, @intCast(actual_capture_box.y)),
                @as(usize, @intCast(actual_capture_box.width)),
                @as(usize, @intCast(actual_capture_box.height)),
                allocator,
            );
            num_digits_allocated += 1;
        } else {
            std.log.err("Expected capture overlap but didn't find any ({any} {any}). This is probably programmer error.", .{
                screenshot_box,
                capture_box,
            });
            return error.ExpectedCaptureOverlap;
        }
    }

    return ammo_cropped_digits;
}

/// Given a screenshot of Halo Infinite, grab the digits from the amount of ammo
/// currently in the weapon.
pub fn findHaloAmmoDigits(
    screenshot: Screenshot(RGBImage),
    diagnostics: ?*IsolateDiagnostics,
    allocator: std.mem.Allocator,
) !?struct {
    digit_images: []const RGBImage,
    ammo_counter_bounding_box: BoundingClientRect(usize),
} {
    const normalized_screenshot = try normalizeHaloScreenshot(
        screenshot,
        diagnostics,
        allocator,
    );
    defer normalized_screenshot.image.deinit(allocator);

    const maybe_ammo_counter_screenshot = try isolateHaloAmmoCounter(
        normalized_screenshot,
        diagnostics,
        allocator,
    );
    if (maybe_ammo_counter_screenshot) |ammo_counter_screenshot| {
        defer ammo_counter_screenshot.image.deinit(allocator);

        const digit_images = try splitAmmoCounterRegionIntoDigits(
            ammo_counter_screenshot,
            diagnostics,
            allocator,
        );

        const ammo_counter_bounding_box = BoundingClientRect(usize){
            .x = normalized_screenshot.crop_region_x + ammo_counter_screenshot.crop_region_x,
            .y = normalized_screenshot.crop_region_y + ammo_counter_screenshot.crop_region_y,
            .width = ammo_counter_screenshot.image.width,
            .height = ammo_counter_screenshot.image.height,
        };

        return .{
            .digit_images = digit_images,
            .ammo_counter_bounding_box = translateBoundingClientRectToAnotherScreenshotSpace(
                ammo_counter_bounding_box,
                ammo_counter_screenshot,
                screenshot,
            ),
        };
    }

    return null;
}

test "Find Halo ammo counter region" {
    const allocator = std.testing.allocator;
    // const image_file_path = "screenshot-data/halo-infinite/1080/default/36 - argyle2.png";
    // const image_file_path = "screenshot-data/halo-infinite/1080/default/11 - forbidden needler.png";
    // const image_file_path = "screenshot-data/halo-infinite/1080/default/11 - forbidden sidekick.png";
    // const image_file_path = "screenshot-data/halo-infinite/1080/default/12 - forbidden sidekick.png";
    // const image_file_path = "screenshot-data/halo-infinite/1080/default/44 - argyle plasma rifle.png";
    // const image_file_path = "screenshot-data/halo-infinite/1080/default/01 - forbidden skewer.png";
    // const image_file_path = "screenshot-data/halo-infinite/1080/default/108 - argyle sentinel beam.png";
    // const image_file_path = "screenshot-data/halo-infinite/1080/default/211 - argyle sentinel beam.png";
    // const image_file_path = "screenshot-data/halo-infinite/1080/default/34.png";
    // const image_file_path = "screenshot-data/halo-infinite/1080/default/36.png";
    // const image_file_path = "screenshot-data/halo-infinite/1080/default/36 - argyle2.png";
    // const image_file_path = "screenshot-data/halo-infinite/1080/default/09 - argyle sidekick.png";
    // const image_file_path = "screenshot-data/halo-infinite/1080/default/11 - argyle2.png";
    // const image_file_path = "screenshot-data/halo-infinite/4k/default/11 - cliffhanger camo marker2.png";
    // const image_file_path = "screenshot-data/halo-infinite/4k/default/11 - streets2.png";
    // const image_file_path = "screenshot-data/halo-infinite/4k/default/12 - cliffhanger switching weapons.png";
    // const image_file_path = "screenshot-data/halo-infinite/4k/default/13 - dredge.png";
    // const image_file_path = "screenshot-data/halo-infinite/4k/default/13 - dredge2.png";
    // const image_file_path = "screenshot-data/halo-infinite/4k/default/13 - streets nairobi.png";
    // const image_file_path = "screenshot-data/halo-infinite/4k/default/16% - cliffhanger stalker.png";
    // const image_file_path = "screenshot-data/halo-infinite/4k/default/17 - streets.png";
    // const image_file_path = "screenshot-data/halo-infinite/4k/default/18 - streets burger.png";
    // const image_file_path = "screenshot-data/halo-infinite/4k/default/18 - streets blue.png";
    // const image_file_path = "screenshot-data/halo-infinite/4k/default/18 - streets kenya.png";
    // const image_file_path = "screenshot-data/halo-infinite/4k/default/24 - streets2.png";
    // const image_file_path = "screenshot-data/halo-infinite/4k/default/25 - streets burger.png";
    // const image_file_path = "screenshot-data/halo-infinite/4k/default/36 - breaker wall.png";
    const image_file_path = "screenshot-data/halo-infinite/4k/default/36 - breaker turbine goo.png";
    // const image_file_path = "screenshot-data/halo-infinite/4k/default/41% - cliffhanger stalker.png";
    // const image_file_path = "screenshot-data/halo-infinite/4k/default/66 - dredge sentinel beam.png";
    // const image_file_path = "screenshot-data/halo-infinite/4k/default/90% - dredge hammer.png";
    // const image_file_path = "screenshot-data/halo-infinite/4k/default/100% - dredge hammer2.png";
    // const image_file_path = "screenshot-data/halo-infinite/4k/default/125 - dredge sentinel beam.png";
    // const image_file_path = "screenshot-data/halo-infinite/4k/default/149 - dredge sentinel beam.png";
    const image_file_stem_name = std.fs.path.stem(image_file_path);

    const rgb_image = try RGBImage.loadImageFromFilePath(image_file_path, allocator);
    defer rgb_image.deinit(allocator);
    const full_screenshot = Screenshot(RGBImage){
        .image = rgb_image,
        .crop_region = .full_screen,
        .crop_region_x = 0,
        .crop_region_y = 0,
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
    //     .crop_region = .ammo_counter,
    //     .crop_region_x = 1410,
    //     .crop_region_y = 877,
    //     .pre_crop_width = full_screenshot.pre_crop_width,
    //     .pre_crop_height = full_screenshot.pre_crop_height,
    //     .game_resolution_width = full_screenshot.game_resolution_width,
    //     .game_resolution_height = full_screenshot.game_resolution_height,
    // };

    var isolate_diagnostics = IsolateDiagnostics.init(allocator);
    defer isolate_diagnostics.deinit(allocator);
    _ = blk: {
        const maybe_results = findHaloAmmoDigits(
            full_screenshot, //cropped_screenshot,
            &isolate_diagnostics,
            allocator,
        ) catch |err| break :blk err;
        if (maybe_results) |find_results| {
            const ammo_cropped_digits = find_results.digit_images;
            defer {
                for (ammo_cropped_digits) |ammo_cropped_digit| {
                    ammo_cropped_digit.deinit(allocator);
                }
                allocator.free(ammo_cropped_digits);
            }

            std.testing.expect(
                // TODO: remove me in favor of actual expectation
                false,
                // ammo_cropped_digits.len == 2
            ) catch |err| {
                // Show the ammo counter digits that were found
                for (ammo_cropped_digits, 0..) |ammo_cropped_digit, digit_index| {
                    const digit_label = try std.fmt.allocPrint(allocator, "Digit {}", .{digit_index});
                    defer allocator.free(digit_label);
                    try printLabeledImage(digit_label, ammo_cropped_digit, .half_block, allocator);
                }

                break :blk err;
            };
        } else {
            break :blk error.UnableToFindAmmoCounter;
        }
    } catch |err| {
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
            // For small images, make it easier to pixel peep
            if (image.width < 200 and image.height < 200) {
                try printLabeledImage(debug_full_file_path, image, .half_block, allocator);
            } else {
                try printLabeledImage(debug_full_file_path, image, .kitty, allocator);
            }
        }

        return err;
    };
}

/// Given the results of looking for ammo a frame, where to look for ammo in the next frame
fn futureAmmoHeuristicBoundingClientRect(ammo_counter_bounding_box: BoundingClientRect(usize)) BoundingClientRect(usize) {
    // The amount of horizontal slop on each side to account for the counter
    // moving around when switching weapons
    const NUM_PADDING_CHARACTERS = 2;
    // An area containing the max possible number of characters
    const STRIP_WIDTH = (MAX_NUM_AMMO_CHARACTERS +
        // Padding on each side
        (2 * NUM_PADDING_CHARACTERS)) *
        // The character width and spacing
        (CHARACTER_MAX_WIDTH + CHARACTER_MAX_SPACING);
    const HORIZONTAL_PADDING_LEFT = (NUM_PADDING_CHARACTERS * (CHARACTER_MAX_WIDTH + CHARACTER_MAX_SPACING));

    // The amount of vertical slop just to capture some surroundings around the characters
    const VERTICAL_PADDING = @divTrunc(CHARACTER_DILATE_HEIGHT, 2);
    const MIN_HEIGHT = CHARACTER_MIN_HEIGHT + (2 * VERTICAL_PADDING);

    return BoundingClientRect(usize){
        // The number is right-aligned so we want the strip_box to be right-aligned
        .x = ammo_counter_bounding_box.right() - STRIP_WIDTH + HORIZONTAL_PADDING_LEFT,
        .y = ammo_counter_bounding_box.top(),
        .width = STRIP_WIDTH,
        .height = @max(ammo_counter_bounding_box.height(), MIN_HEIGHT),
    };
}
